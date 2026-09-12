//
//  AnthropicProvider.swift
//  leanring-buddy
//
//  Anthropic's Claude as a `ModelProvider`, over the raw Messages API (there is
//  no official Swift SDK). A bring-your-own-key cloud backend, mirroring
//  `GeminiProvider`: a `ModelRequest` becomes the Messages `messages` shape on
//  the way out, and the streamed reply becomes an ordered `BuddyChatTurn` on the
//  way back.
//
//  Thinking is deliberately DISABLED. Wisp's conversation model
//  (`BuddyContentBlock`) has no representation for a thinking block, so it could
//  not replay one — and Claude requires the thinking block that preceded a
//  `tool_use` to be echoed back on the following request when thinking is on,
//  which would make the agent loop's multi-turn tool use fail. Disabling
//  thinking also removes latency that a spoken companion cannot afford. The
//  trade is Claude's documented disabled-thinking failure modes (it may
//  occasionally narrate a tool call as text); acceptable here and worth
//  re-checking at runtime.
//
//  Nothing constructs this until the factory selects `.anthropic`. The API key
//  is user-supplied via `ProviderKeychainStore` and travels in a request header.
//

import Foundation

/// Streams one turn from Anthropic's Messages API.
///
/// `@unchecked Sendable` for the same reason as the other providers: only
/// immutable state, but `URLSession` is not formally `Sendable`.
final class AnthropicProvider: ModelProvider, @unchecked Sendable {
    private let modelName: String
    private let apiKey: String?
    private let session: URLSession

    /// The API version header value every Messages request must send.
    private static let anthropicAPIVersion = "2023-06-01"

    /// Default model. Per Anthropic's own guidance the capable default is Opus;
    /// overridable via the initializer so the factory (or a future setting) can
    /// point at a cheaper, faster tier without a code change.
    static let defaultModelName = "claude-opus-5"

    /// Claude requires `max_tokens` on every request. When a request does not
    /// specify one, this is the ceiling used — generous enough not to truncate a
    /// spoken reply, modest enough not to invite a runaway one.
    private static let defaultMaxOutputTokens = 4096

    init(
        apiKey: String?,
        modelName: String = AnthropicProvider.defaultModelName,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.modelName = modelName
        self.session = session
    }

    var identifier: String { "anthropic/\(modelName)" }

    var capabilities: ModelCapabilities {
        ModelCapabilities(
            supportsVision: true,
            supportsTools: true,
            supportsNativeToolCalls: true,
            supportsStreaming: true,
            supportsStructuredOutput: false,
            contextWindowTokens: 1_000_000
        )
    }

    var deployment: ModelDeployment {
        ModelDeployment(
            location: .remote(serviceName: "Anthropic"),
            approximateOutputTokensPerSecond: nil
        )
    }

    // MARK: - Running a turn

    func streamTurn(
        _ request: ModelRequest,
        onTextDelta: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> BuddyChatTurn {
        try validateAgainstCapabilities(request)

        guard let apiKey, !apiKey.isEmpty else {
            throw BuddyChatError.authenticationFailed(providerName: identifier)
        }

        let urlRequest = try buildURLRequest(for: request, apiKey: apiKey)
        let startTime = Date()

        do {
            let (byteStream, response) = try await session.bytes(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw BuddyChatError.providerUnavailable(
                    providerName: identifier,
                    underlyingDescription: "no HTTP response"
                )
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                var errorBody = Data()
                for try await byte in byteStream { errorBody.append(byte) }
                throw mapHTTPFailure(statusCode: httpResponse.statusCode,
                                     httpResponse: httpResponse,
                                     body: errorBody)
            }

            return try await consumeStream(
                byteStream,
                startTime: startTime,
                onTextDelta: onTextDelta
            )
        } catch let error as URLError where error.code == .cancelled {
            // Interrupting mid-sentence is the user speaking again, not a
            // failure — reinterpret only when this task really was cancelled.
            if Task.isCancelled { throw CancellationError() }
            throw error
        } catch let error as URLError where Self.indicatesServerIsUnreachable(error.code) {
            throw BuddyChatError.providerUnavailable(
                providerName: identifier,
                underlyingDescription: error.localizedDescription
            )
        }
    }

    /// Consumes the Messages SSE stream, emitting text deltas as they arrive and
    /// assembling ordered content blocks.
    ///
    /// Claude streams one content block at a time, in order, identified by
    /// index: a `content_block_start` opens a block, `content_block_delta`s
    /// append to it (text as `text_delta`, a tool call's arguments as
    /// `input_json_delta` fragments that must be concatenated and parsed once
    /// whole), and `content_block_stop` closes it. With thinking disabled there
    /// is no interleaving, so processing the open block sequentially is enough.
    private func consumeStream(
        _ byteStream: URLSession.AsyncBytes,
        startTime: Date,
        onTextDelta: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> BuddyChatTurn {
        var orderedBlocks: [BuddyContentBlock] = []
        var promptTokens: Int?
        var outputTokens: Int?
        var stopReasonRaw: String?

        // The block currently being streamed.
        var openBlockType: String?
        var openToolUseID: String?
        var openToolName: String?
        var accumulatedToolArgumentsJSON = ""

        func finalizeOpenBlock() {
            switch openBlockType {
            case "tool_use":
                let argumentsValue: JSONValue
                if let data = accumulatedToolArgumentsJSON.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) {
                    argumentsValue = JSONValue(untypedValue: parsed)
                } else {
                    // An empty-argument tool call streams no input_json_delta at
                    // all, which is valid; treat unparseable/empty as {}.
                    argumentsValue = .object([:])
                }
                orderedBlocks.append(.toolUse(
                    id: openToolUseID ?? UUID().uuidString,
                    name: openToolName ?? "",
                    input: argumentsValue
                ))
            default:
                break
            }
            openBlockType = nil
            openToolUseID = nil
            openToolName = nil
            accumulatedToolArgumentsJSON = ""
        }

        func appendText(_ newText: String) {
            if case .text(let existingText)? = orderedBlocks.last {
                orderedBlocks[orderedBlocks.count - 1] = .text(existingText + newText)
            } else {
                orderedBlocks.append(.text(newText))
            }
        }

        do {
            for try await line in byteStream.lines {
                // Each SSE `data:` line carries a JSON event whose `type` field
                // says what it is; the `event:` lines are redundant with that
                // and ignored.
                guard line.hasPrefix("data:") else { continue }
                let payloadText = line.dropFirst("data:".count)
                    .trimmingCharacters(in: .whitespaces)
                guard !payloadText.isEmpty,
                      let payloadData = payloadText.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                      let eventType = event["type"] as? String
                else { continue }

                switch eventType {
                case "message_start":
                    if let message = event["message"] as? [String: Any],
                       let usage = message["usage"] as? [String: Any] {
                        promptTokens = usage["input_tokens"] as? Int ?? promptTokens
                    }

                case "content_block_start":
                    if let contentBlock = event["content_block"] as? [String: Any] {
                        openBlockType = contentBlock["type"] as? String
                        openToolUseID = contentBlock["id"] as? String
                        openToolName = contentBlock["name"] as? String
                        accumulatedToolArgumentsJSON = ""
                    }

                case "content_block_delta":
                    guard let delta = event["delta"] as? [String: Any],
                          let deltaType = delta["type"] as? String else { break }
                    switch deltaType {
                    case "text_delta":
                        if let text = delta["text"] as? String, !text.isEmpty {
                            appendText(text)
                            await onTextDelta(text)
                        }
                    case "input_json_delta":
                        if let partialJSON = delta["partial_json"] as? String {
                            accumulatedToolArgumentsJSON += partialJSON
                        }
                    default:
                        // thinking_delta and any other delta types are ignored.
                        break
                    }

                case "content_block_stop":
                    finalizeOpenBlock()

                case "message_delta":
                    if let delta = event["delta"] as? [String: Any],
                       let stopReason = delta["stop_reason"] as? String {
                        stopReasonRaw = stopReason
                    }
                    if let usage = event["usage"] as? [String: Any] {
                        outputTokens = usage["output_tokens"] as? Int ?? outputTokens
                    }

                case "message_stop":
                    break

                default:
                    break
                }
            }
        } catch let error as URLError where error.code == .cancelled {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }

        let hasToolCalls = orderedBlocks.toolUses.isEmpty == false
        return BuddyChatTurn(
            content: orderedBlocks,
            stopReason: Self.stopReason(stopReasonRaw: stopReasonRaw, hasToolCalls: hasToolCalls),
            duration: Date().timeIntervalSince(startTime),
            promptTokens: promptTokens,
            outputTokens: outputTokens
        )
    }

    // MARK: - Request construction

    private func buildURLRequest(for request: ModelRequest, apiKey: String) throws -> URLRequest {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw BuddyChatError.providerUnavailable(
                providerName: identifier,
                underlyingDescription: "could not form request URL"
            )
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The key rides in a header, never the URL.
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.anthropicAPIVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: buildRequestBody(from: request))
        return urlRequest
    }

    private func buildRequestBody(from request: ModelRequest) -> [String: Any] {
        var body: [String: Any] = [
            "model": modelName,
            "max_tokens": request.maxOutputTokens ?? Self.defaultMaxOutputTokens,
            "stream": true,
            // See the file header: thinking cannot be replayed by Wisp's block
            // model, so it must be off for the agent loop's tool use to work.
            "thinking": ["type": "disabled"],
            "messages": request.messages.compactMap(Self.anthropicMessage(from:))
        ]

        if !request.systemPrompt.isEmpty {
            body["system"] = request.systemPrompt
        }

        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": tool.inputSchema.untypedValue
                ]
            }
        }

        if let temperature = request.temperature {
            body["temperature"] = temperature
        }

        return body
    }

    /// Translates one message into a Claude `message` object, or `nil` if it
    /// carries nothing (an empty content array is rejected).
    private static func anthropicMessage(from message: BuddyChatMessage) -> [String: Any]? {
        var contentBlocks: [[String: Any]] = []

        for block in message.blocks {
            switch block {
            case .text(let value) where !value.isEmpty:
                contentBlocks.append(["type": "text", "text": value])
            case .text:
                continue
            case .image(let data, _):
                contentBlocks.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": imageMediaType(for: data),
                        "data": data.base64EncodedString()
                    ]
                ])
            case .toolUse(let id, let name, let input):
                contentBlocks.append([
                    "type": "tool_use",
                    "id": id,
                    "name": name,
                    "input": input.untypedValue
                ])
            case .toolResult(let toolUseID, _, let content, let isError):
                contentBlocks.append([
                    "type": "tool_result",
                    "tool_use_id": toolUseID,
                    "content": content,
                    "is_error": isError
                ])
            }
        }

        guard !contentBlocks.isEmpty else { return nil }

        return [
            "role": message.role == .assistant ? "assistant" : "user",
            "content": contentBlocks
        ]
    }

    // MARK: - Small helpers

    /// The image's media type, sniffed from its leading bytes. Claude accepts
    /// PNG, JPEG, GIF, and WebP; PNG is the safe fallback for the screenshots
    /// this app captures.
    private static func imageMediaType(for data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        return "image/png"
    }

    private static func stopReason(stopReasonRaw: String?, hasToolCalls: Bool) -> BuddyStopReason {
        if hasToolCalls { return .toolUse }
        switch stopReasonRaw {
        case "end_turn", nil: return .endTurn
        case "max_tokens": return .maxTokens
        case "tool_use": return .toolUse
        case let other?: return .other(other)
        }
    }

    private static func indicatesServerIsUnreachable(_ code: URLError.Code) -> Bool {
        switch code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
             .notConnectedToInternet, .timedOut, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    private func mapHTTPFailure(
        statusCode: Int,
        httpResponse: HTTPURLResponse,
        body: Data
    ) -> BuddyChatError {
        switch statusCode {
        case 401, 403:
            return .authenticationFailed(providerName: identifier)
        case 429:
            let retryAfterSeconds = httpResponse.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init)
            return .rateLimited(providerName: identifier, retryAfter: retryAfterSeconds)
        default:
            return .providerUnavailable(
                providerName: identifier,
                underlyingDescription: Self.errorMessage(from: body) ?? "HTTP \(statusCode)"
            )
        }
    }

    /// Pulls Claude's `error.message` out of a failure body, when present.
    private static func errorMessage(from body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return nil
        }
        return message
    }
}
