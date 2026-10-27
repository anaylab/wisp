//
//  GeminiProvider.swift
//  leanring-buddy
//
//  Google Gemini as a `ModelProvider`. The first bring-your-own-key cloud
//  backend.
//
//  Gemini is chosen as the first cloud provider because it has the strongest
//  pixel-grounding of the cloud options, and pointing — the [POINT:x,y] tags —
//  is the capability this app is built around. Everything else here is faithful
//  translation: a `ModelRequest` becomes Gemini's `contents` shape on the way
//  out, and the streamed reply becomes an ordered `BuddyChatTurn` on the way
//  back. Unlike the local model, Gemini returns *native* function calls, so
//  there is no `[TOOL:...]` text convention and no anti-echo guard here.
//
//  Nothing constructs this yet — it is landed ahead of the factory and the
//  spoken-path migration so those changes stay small. The API key is supplied
//  by the user and stored in `ProviderKeychainStore`; it travels in a request
//  header, never in the URL.
//

import Foundation

/// Streams one turn from Google's Gemini API.
///
/// `@unchecked Sendable` for the same reason `OllamaProvider` is: the only
/// stored state is immutable, but `URLSession` is not formally `Sendable` in the
/// SDK. This type never mutates after `init`, so the annotation records what the
/// compiler cannot prove rather than papering over a real data race.
final class GeminiProvider: ModelProvider, @unchecked Sendable {
    /// The model id, e.g. `gemini-2.5-flash`. Kept configurable because the
    /// exact id is the one thing likely to change out from under this file, and
    /// a wrong default should be a one-line fix, not a rewrite.
    private let modelName: String

    /// The user's API key, or `nil` if none is stored. A `nil` or empty key is
    /// not a crash — it is an `authenticationFailed` the caller can surface,
    /// because a cloud provider selected before its key is entered is a normal
    /// state the settings UI walks the user out of.
    private let apiKey: String?

    private let session: URLSession

    /// The default model. Gemini's Flash tier is the sensible starting point:
    /// fast and cheap enough for a conversational companion, and strong at the
    /// visual grounding pointing needs. Overridable via the initializer so the
    /// factory can later read it from configuration.
    static let defaultModelName = "gemini-2.5-flash"

    init(
        apiKey: String?,
        modelName: String = GeminiProvider.defaultModelName,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.modelName = modelName
        self.session = session
    }

    var identifier: String { "gemini/\(modelName)" }

    var capabilities: ModelCapabilities {
        ModelCapabilities(
            supportsVision: true,
            supportsTools: true,
            // Gemini returns real `functionCall` parts, not text to be parsed.
            supportsNativeToolCalls: true,
            supportsStreaming: true,
            supportsStructuredOutput: false,
            // Gemini's Flash tier carries a very large input window. Declared
            // for a router to compare against; nothing trims on it yet.
            contextWindowTokens: 1_048_576
        )
    }

    var deployment: ModelDeployment {
        ModelDeployment(
            // Remote by construction, which is what makes
            // `sendsDataOffThisMachine` true and drives the privacy notice and
            // the local-only-machinery gates.
            location: .remote(serviceName: "Google Gemini"),
            // Unmeasured. Left nil deliberately — the field's contract is that
            // nil means "unknown", which a caller must not read as "fast".
            approximateOutputTokensPerSecond: nil
        )
    }

    // MARK: - Running a turn

    func streamTurn(
        _ request: ModelRequest,
        onTextDelta: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> BuddyChatTurn {
        // Refuse rather than quietly drop an image, exactly as the local path
        // does — though Gemini can see, so this only ever trips on tools.
        try validateAgainstCapabilities(request)

        guard let apiKey, !apiKey.isEmpty else {
            // No key is a credentials failure, not a transport one: retrying
            // without entering a key can never succeed.
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
                // Drain the body so the server's own error message can be
                // reported rather than a bare status code.
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
            // URLSession reports an interrupted request as URLError.cancelled
            // (-999), not CancellationError. The distinction matters upstream:
            // the response pipeline abandons a cancelled turn quietly and
            // withdraws any pending permission prompt, while a real error is
            // shown to the user. Interrupting Wisp mid-sentence is just the
            // user speaking again, so it must not look like a failure — but
            // only reinterpret when this task actually was cancelled.
            if Task.isCancelled { throw CancellationError() }
            throw error
        } catch let error as URLError where Self.indicatesServerIsUnreachable(error.code) {
            throw BuddyChatError.providerUnavailable(
                providerName: identifier,
                underlyingDescription: error.localizedDescription
            )
        }
    }

    /// Consumes the SSE stream, emitting text deltas as they arrive and
    /// assembling the ordered content blocks that become the turn.
    ///
    /// Text is emitted immediately so speech can begin, and simultaneously
    /// folded into an ordered block list so the *meaning* of the turn — prose
    /// and function calls in the order Gemini produced them — is preserved.
    /// Consecutive text deltas are coalesced into a single block; a function
    /// call starts a new block after them, which is what keeps interleaving
    /// faithful without one block per token.
    private func consumeStream(
        _ byteStream: URLSession.AsyncBytes,
        startTime: Date,
        onTextDelta: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> BuddyChatTurn {
        var orderedBlocks: [BuddyContentBlock] = []
        var promptTokens: Int?
        var outputTokens: Int?
        var cachedPromptTokens: Int?
        var lastFinishReason: String?

        func appendText(_ newText: String) {
            if case .text(let existingText)? = orderedBlocks.last {
                orderedBlocks[orderedBlocks.count - 1] = .text(existingText + newText)
            } else {
                orderedBlocks.append(.text(newText))
            }
        }

        do {
            for try await line in byteStream.lines {
                // alt=sse frames every JSON object as a `data:` line, with
                // blank lines between events. Anything else is a keep-alive or
                // a comment and is ignored.
                guard line.hasPrefix("data:") else { continue }
                let payloadText = line.dropFirst("data:".count)
                    .trimmingCharacters(in: .whitespaces)
                guard !payloadText.isEmpty,
                      let payloadData = payloadText.data(using: .utf8),
                      let chunk = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
                else { continue }

                if let usage = chunk["usageMetadata"] as? [String: Any] {
                    promptTokens = usage["promptTokenCount"] as? Int ?? promptTokens
                    // Reasoning ("thoughts") tokens are billed as output but
                    // reported beside, not inside, the candidates count.
                    if let candidatesTokenCount = usage["candidatesTokenCount"] as? Int {
                        outputTokens = candidatesTokenCount + (usage["thoughtsTokenCount"] as? Int ?? 0)
                    }
                    cachedPromptTokens = usage["cachedContentTokenCount"] as? Int ?? cachedPromptTokens
                }

                guard let candidates = chunk["candidates"] as? [[String: Any]],
                      let firstCandidate = candidates.first else { continue }

                if let finishReason = firstCandidate["finishReason"] as? String {
                    lastFinishReason = finishReason
                }

                guard let content = firstCandidate["content"] as? [String: Any],
                      let parts = content["parts"] as? [[String: Any]] else { continue }

                for part in parts {
                    if let text = part["text"] as? String, !text.isEmpty {
                        appendText(text)
                        // Newly generated text only — the protocol's contract.
                        // Gemini's stream is already incremental, so no diffing
                        // is needed here.
                        await onTextDelta(text)
                    } else if let functionCall = part["functionCall"] as? [String: Any],
                              let name = functionCall["name"] as? String {
                        let argumentsObject = functionCall["args"] as? [String: Any] ?? [:]
                        // Gemini does not assign call ids — it correlates a
                        // result to a call by function name — so one is minted
                        // here purely for internal pairing within the runtime.
                        orderedBlocks.append(.toolUse(
                            id: UUID().uuidString,
                            name: name,
                            input: JSONValue(untypedValue: argumentsObject)
                        ))
                    }
                }
            }
        } catch let error as URLError where error.code == .cancelled {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }

        let hasToolCalls = orderedBlocks.toolUses.isEmpty == false
        return BuddyChatTurn(
            content: orderedBlocks,
            stopReason: Self.stopReason(finishReason: lastFinishReason, hasToolCalls: hasToolCalls),
            duration: Date().timeIntervalSince(startTime),
            promptTokens: promptTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cachedPromptTokens
        )
    }

    // MARK: - Request construction

    private func buildURLRequest(for request: ModelRequest, apiKey: String) throws -> URLRequest {
        // The key rides in a header, never the URL — a URL with a secret in its
        // query string ends up in logs and proxies.
        guard let url = URL(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):streamGenerateContent?alt=sse"
        ) else {
            throw BuddyChatError.providerUnavailable(
                providerName: identifier,
                underlyingDescription: "could not form request URL"
            )
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: buildRequestBody(from: request))
        return urlRequest
    }

    private func buildRequestBody(from request: ModelRequest) -> [String: Any] {
        var body: [String: Any] = [
            "contents": request.messages.compactMap(Self.geminiContent(from:))
        ]

        if !request.systemPrompt.isEmpty {
            body["systemInstruction"] = ["parts": [["text": request.systemPrompt]]]
        }

        if !request.tools.isEmpty {
            body["tools"] = [[
                "functionDeclarations": request.tools.map { tool in
                    [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.inputSchema.untypedValue
                    ]
                }
            ]]
        }

        var generationConfig: [String: Any] = [:]
        if let maxOutputTokens = request.maxOutputTokens {
            generationConfig["maxOutputTokens"] = maxOutputTokens
        }
        if let temperature = request.temperature {
            generationConfig["temperature"] = temperature
        }
        if !generationConfig.isEmpty {
            body["generationConfig"] = generationConfig
        }

        return body
    }

    /// Translates one message into a Gemini `content` object, or `nil` if it
    /// carries nothing Gemini can use (an empty parts array is rejected).
    private static func geminiContent(from message: BuddyChatMessage) -> [String: Any]? {
        var parts: [[String: Any]] = []

        for block in message.blocks {
            switch block {
            case .text(let value) where !value.isEmpty:
                parts.append(["text": value])
            case .text:
                continue
            case .image(let data, _):
                parts.append([
                    "inlineData": [
                        "mimeType": imageMimeType(for: data),
                        "data": data.base64EncodedString()
                    ]
                ])
            case .toolUse(_, let name, let input):
                // The assistant's own past call, replayed so Gemini sees what it
                // already asked for.
                parts.append([
                    "functionCall": [
                        "name": name,
                        "args": input.untypedValue
                    ]
                ])
            case .toolResult(_, let toolName, let content, _):
                // Gemini matches a response to its call by name, and wants the
                // response as an object rather than a bare string.
                parts.append([
                    "functionResponse": [
                        "name": toolName,
                        "response": ["result": content]
                    ]
                ])
            case .providerReplay:
                // Another provider's private block; meaningless here.
                continue
            }
        }

        guard !parts.isEmpty else { return nil }

        return [
            // Gemini's two roles are "user" and "model"; there is no "assistant".
            "role": message.role == .assistant ? "model" : "user",
            "parts": parts
        ]
    }

    // MARK: - Small helpers

    /// The image's media type, sniffed from its leading bytes. Gemini requires
    /// a correct `mimeType`; defaulting to PNG is the safe fallback for the
    /// screenshots this app captures.
    private static func imageMimeType(for data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        return "image/png"
    }

    private static func stopReason(finishReason: String?, hasToolCalls: Bool) -> BuddyStopReason {
        if hasToolCalls { return .toolUse }
        switch finishReason {
        case "MAX_TOKENS": return .maxTokens
        case "STOP", nil: return .endTurn
        case let other?: return .other(other)
        }
    }

    /// URL failures that mean "nothing answered", as opposed to a request that
    /// reached Gemini and was refused. Mirrors the local provider's set so the
    /// two agree on what "unavailable" means.
    private static func indicatesServerIsUnreachable(_ code: URLError.Code) -> Bool {
        switch code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
             .notConnectedToInternet, .timedOut, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    /// Maps a non-2xx response onto the shared error vocabulary so routing code
    /// can decide retry-or-report without reading status codes itself.
    private func mapHTTPFailure(
        statusCode: Int,
        httpResponse: HTTPURLResponse,
        body: Data
    ) -> BuddyChatError {
        switch statusCode {
        case 401, 403:
            // Credentials missing, expired, or rejected — never retried.
            return .authenticationFailed(providerName: identifier)
        case 429:
            let retryAfterSeconds = (httpResponse.value(forHTTPHeaderField: "Retry-After"))
                .flatMap(TimeInterval.init)
            return .rateLimited(providerName: identifier, retryAfter: retryAfterSeconds)
        default:
            // Everything else carries the server's own message, which says more
            // than the status code alone. A 4xx here is imperfectly retryable,
            // but the shared vocabulary has no bad-request case and the message
            // makes the real cause visible.
            return .providerUnavailable(
                providerName: identifier,
                underlyingDescription: Self.errorMessage(from: body) ?? "HTTP \(statusCode)"
            )
        }
    }

    /// Pulls Gemini's `error.message` out of a failure body, when present.
    private static func errorMessage(from body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return nil
        }
        return message
    }
}
