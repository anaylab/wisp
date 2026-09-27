//
//  OpenAIProvider.swift
//  leanring-buddy
//
//  OpenAI's GPT as a `ModelProvider`, over the raw Chat Completions API (no
//  official Swift SDK). A bring-your-own-key cloud backend, mirroring the other
//  providers.
//
//  One structural difference from Claude and Gemini shapes the translation
//  here: OpenAI carries a tool result as its own `role:"tool"` message keyed by
//  `tool_call_id`, not as a block inside a user turn. So one `BuddyChatMessage`
//  can expand into several OpenAI messages — an assistant turn's tool calls
//  become a `tool_calls` array, and a user turn's tool results become separate
//  `tool` messages.
//
//  Nothing constructs this until the factory selects `.openAI`. The API key is
//  user-supplied via `ProviderKeychainStore` and travels in the Authorization
//  header.
//

import Foundation

/// Streams one turn from OpenAI's Chat Completions API.
///
/// `@unchecked Sendable` for the same reason as the other providers.
final class OpenAIProvider: ModelProvider, @unchecked Sendable {
    private let modelName: String
    private let apiKey: String?
    private let session: URLSession

    /// Default model. A vision- and tool-capable GPT; overridable via the
    /// initializer, since OpenAI's exact model ids move faster than this file.
    static let defaultModelName = "gpt-4o"

    init(
        apiKey: String?,
        modelName: String = OpenAIProvider.defaultModelName,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.modelName = modelName
        self.session = session
    }

    var identifier: String { "openai/\(modelName)" }

    var capabilities: ModelCapabilities {
        ModelCapabilities(
            supportsVision: true,
            supportsTools: true,
            supportsNativeToolCalls: true,
            supportsStreaming: true,
            supportsStructuredOutput: false,
            contextWindowTokens: 128_000
        )
    }

    var deployment: ModelDeployment {
        ModelDeployment(
            location: .remote(serviceName: "OpenAI"),
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
            if Task.isCancelled { throw CancellationError() }
            throw error
        } catch let error as URLError where Self.indicatesServerIsUnreachable(error.code) {
            throw BuddyChatError.providerUnavailable(
                providerName: identifier,
                underlyingDescription: error.localizedDescription
            )
        }
    }

    /// Consumes the Chat Completions SSE stream.
    ///
    /// Text arrives as `choices[0].delta.content` fragments. A tool call arrives
    /// as `choices[0].delta.tool_calls[]` fragments keyed by `index`: the first
    /// fragment for an index carries the id and function name, later fragments
    /// carry pieces of the argument JSON string that must be concatenated and
    /// parsed once whole. The stream ends with a literal `data: [DONE]`.
    private func consumeStream(
        _ byteStream: URLSession.AsyncBytes,
        startTime: Date,
        onTextDelta: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> BuddyChatTurn {
        var orderedTextBlocks: [BuddyContentBlock] = []
        var promptTokens: Int?
        var outputTokens: Int?
        var finishReason: String?

        // Tool calls accumulate by their streamed index, since their argument
        // JSON arrives in fragments across many chunks.
        struct StreamingToolCall {
            var id: String = ""
            var name: String = ""
            var argumentsJSON: String = ""
        }
        var toolCallsByIndex: [Int: StreamingToolCall] = [:]

        func appendText(_ newText: String) {
            if case .text(let existingText)? = orderedTextBlocks.last {
                orderedTextBlocks[orderedTextBlocks.count - 1] = .text(existingText + newText)
            } else {
                orderedTextBlocks.append(.text(newText))
            }
        }

        do {
            for try await line in byteStream.lines {
                guard line.hasPrefix("data:") else { continue }
                let payloadText = line.dropFirst("data:".count)
                    .trimmingCharacters(in: .whitespaces)
                guard !payloadText.isEmpty else { continue }
                if payloadText == "[DONE]" { break }

                guard let payloadData = payloadText.data(using: .utf8),
                      let chunk = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
                else { continue }

                if let usage = chunk["usage"] as? [String: Any] {
                    promptTokens = usage["prompt_tokens"] as? Int ?? promptTokens
                    outputTokens = usage["completion_tokens"] as? Int ?? outputTokens
                }

                guard let choices = chunk["choices"] as? [[String: Any]],
                      let firstChoice = choices.first else { continue }

                if let reason = firstChoice["finish_reason"] as? String {
                    finishReason = reason
                }

                guard let delta = firstChoice["delta"] as? [String: Any] else { continue }

                if let text = delta["content"] as? String, !text.isEmpty {
                    appendText(text)
                    await onTextDelta(text)
                }

                if let toolCallFragments = delta["tool_calls"] as? [[String: Any]] {
                    for fragment in toolCallFragments {
                        let index = fragment["index"] as? Int ?? 0
                        var toolCall = toolCallsByIndex[index] ?? StreamingToolCall()
                        if let id = fragment["id"] as? String { toolCall.id = id }
                        if let function = fragment["function"] as? [String: Any] {
                            if let name = function["name"] as? String { toolCall.name = name }
                            if let argumentsFragment = function["arguments"] as? String {
                                toolCall.argumentsJSON += argumentsFragment
                            }
                        }
                        toolCallsByIndex[index] = toolCall
                    }
                }
            }
        } catch let error as URLError where error.code == .cancelled {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }

        // Text first, then tool calls in their streamed index order — matching
        // the order the assistant produced them.
        var orderedBlocks = orderedTextBlocks
        for index in toolCallsByIndex.keys.sorted() {
            guard let toolCall = toolCallsByIndex[index] else { continue }
            let argumentsValue: JSONValue
            if let data = toolCall.argumentsJSON.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) {
                argumentsValue = JSONValue(untypedValue: parsed)
            } else {
                argumentsValue = .object([:])
            }
            orderedBlocks.append(.toolUse(
                id: toolCall.id.isEmpty ? UUID().uuidString : toolCall.id,
                name: toolCall.name,
                input: argumentsValue
            ))
        }

        let hasToolCalls = orderedBlocks.toolUses.isEmpty == false
        return BuddyChatTurn(
            content: orderedBlocks,
            stopReason: Self.stopReason(finishReason: finishReason, hasToolCalls: hasToolCalls),
            duration: Date().timeIntervalSince(startTime),
            promptTokens: promptTokens,
            outputTokens: outputTokens
        )
    }

    // MARK: - Request construction

    private func buildURLRequest(for request: ModelRequest, apiKey: String) throws -> URLRequest {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw BuddyChatError.providerUnavailable(
                providerName: identifier,
                underlyingDescription: "could not form request URL"
            )
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The key rides in the Authorization header, never the URL.
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: buildRequestBody(from: request))
        return urlRequest
    }

    private func buildRequestBody(from request: ModelRequest) -> [String: Any] {
        var openAIMessages: [[String: Any]] = []
        if !request.systemPrompt.isEmpty {
            openAIMessages.append(["role": "system", "content": request.systemPrompt])
        }
        openAIMessages.append(contentsOf: request.messages.flatMap(Self.openAIMessages(from:)))

        var body: [String: Any] = [
            "model": modelName,
            "stream": true,
            // Ask for a usage summary on the final chunk.
            "stream_options": ["include_usage": true],
            "messages": openAIMessages
        ]

        // Unlike Claude, OpenAI does not require a token ceiling; send one only
        // when the request specifies it.
        if let maxOutputTokens = request.maxOutputTokens {
            body["max_tokens"] = maxOutputTokens
        }

        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.inputSchema.untypedValue
                    ]
                ]
            }
        }

        if let temperature = request.temperature {
            body["temperature"] = temperature
        }

        return body
    }

    /// Translates one `BuddyChatMessage` into the one-or-more OpenAI messages it
    /// maps to.
    ///
    /// An assistant turn becomes a single message whose text is `content` and
    /// whose tool calls are a `tool_calls` array. A user turn's tool results
    /// each become their own `role:"tool"` message; any remaining text and
    /// images become a `role:"user"` message.
    private static func openAIMessages(from message: BuddyChatMessage) -> [[String: Any]] {
        switch message.role {
        case .assistant:
            var assistantMessage: [String: Any] = ["role": "assistant"]

            let combinedText = message.blocks.compactMap { block -> String? in
                if case .text(let value) = block, !value.isEmpty { return value }
                return nil
            }.joined(separator: "\n\n")
            if !combinedText.isEmpty {
                assistantMessage["content"] = combinedText
            }

            let toolCalls: [[String: Any]] = message.blocks.compactMap { block in
                guard case .toolUse(let id, let name, let input) = block else { return nil }
                // OpenAI wants the arguments as a JSON *string*.
                let argumentsJSON = (try? JSONSerialization.data(withJSONObject: input.untypedValue))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                return [
                    "id": id,
                    "type": "function",
                    "function": ["name": name, "arguments": argumentsJSON]
                ]
            }
            if !toolCalls.isEmpty {
                assistantMessage["tool_calls"] = toolCalls
            }

            // An assistant message with neither content nor tool calls is
            // invalid; drop it rather than send an empty turn.
            guard assistantMessage["content"] != nil || assistantMessage["tool_calls"] != nil else {
                return []
            }
            return [assistantMessage]

        case .user:
            var producedMessages: [[String: Any]] = []

            // Each tool result is its own message, keyed to the call it answers.
            for block in message.blocks {
                if case .toolResult(let toolUseID, _, let content, _) = block {
                    producedMessages.append([
                        "role": "tool",
                        "tool_call_id": toolUseID,
                        "content": content
                    ])
                }
            }

            // Text and images form a normal user message. OpenAI accepts a bare
            // string for text-only, or an array of parts when an image is present.
            let hasImage = message.blocks.contains { if case .image = $0 { return true }; return false }
            if hasImage {
                var contentParts: [[String: Any]] = []
                for block in message.blocks {
                    switch block {
                    case .text(let value) where !value.isEmpty:
                        contentParts.append(["type": "text", "text": value])
                    case .image(let data, _):
                        let dataURL = "data:\(imageMediaType(for: data));base64,\(data.base64EncodedString())"
                        contentParts.append(["type": "image_url", "image_url": ["url": dataURL]])
                    default:
                        continue
                    }
                }
                if !contentParts.isEmpty {
                    producedMessages.append(["role": "user", "content": contentParts])
                }
            } else {
                let combinedText = message.blocks.compactMap { block -> String? in
                    if case .text(let value) = block, !value.isEmpty { return value }
                    return nil
                }.joined(separator: "\n\n")
                if !combinedText.isEmpty {
                    producedMessages.append(["role": "user", "content": combinedText])
                }
            }

            return producedMessages
        }
    }

    // MARK: - Small helpers

    private static func imageMediaType(for data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        return "image/png"
    }

    private static func stopReason(finishReason: String?, hasToolCalls: Bool) -> BuddyStopReason {
        if hasToolCalls { return .toolUse }
        switch finishReason {
        case "stop", nil: return .endTurn
        case "length": return .maxTokens
        case "tool_calls": return .toolUse
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

    /// Pulls OpenAI's `error.message` out of a failure body, when present.
    private static func errorMessage(from body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return nil
        }
        return message
    }
}
