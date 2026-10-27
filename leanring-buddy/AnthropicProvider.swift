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
//  Thinking is ON (adaptive) for Opus 5.5 and Sonnet 5.5 — those models no
//  longer accept it being disabled, and thinking is what keeps Claude from
//  writing a tool call as prose instead of making it. `effort` is the speed
//  lever instead. Claude signs each thinking block against the conversation
//  before it and requires it back, unchanged, on the next request of a tool
//  loop; those blocks are kept as `.providerReplay` and resent verbatim. The
//  agent loop keeps each turn append-only for this provider
//  (`requiresAppendOnlyHistoryWithinTurn`), and `drop_block` is requested so a
//  block that no longer matches (e.g. after a model switch) is dropped rather
//  than failing the request. Across turns the transcript is an edited
//  projection, so replay blocks are not carried into the next turn at all.
//
//  Also here: prompt caching (the system prompt, and the growing conversation
//  inside a tool loop), Anthropic's server-side web search / fetch on turns
//  that offer tools, and the server-side refusal fallback.
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
    private let modelChoice: AnthropicModelChoice
    private let effortLevel: AnthropicEffortLevel
    private let isWebAccessEnabled: Bool
    private let apiKey: String?
    private let session: URLSession

    private var modelName: String { modelChoice.apiModelIdentifier }

    /// The API version header value every Messages request must send.
    private static let anthropicAPIVersion = "2023-06-01"

    /// Beta features this provider opts into, sent together in one
    /// `anthropic-beta` header:
    /// - thinking binding controls, so `prefix_mismatch_behavior: drop_block`
    ///   can be set and a stale thinking block is dropped instead of a 400;
    /// - server-side refusal fallback (`fallbacks: "default"`), so a safety
    ///   classifier false positive is retried on another model rather than
    ///   ending the turn.
    private static let thinkingBindingControlsBeta = "thinking-binding-controls-2026-08-01"
    private static let serverSideRefusalFallbackBeta = "server-side-fallback-2026-07-01"

    /// The reply ceiling when a request does not set one — generous enough
    /// not to truncate a spoken reply, modest enough not to invite a runaway.
    private static let defaultReplyTokenCeiling = 4096

    /// Added on top of the reply ceiling for models that think: thinking counts
    /// toward `max_tokens` even though its text is not returned, so a ceiling
    /// sized for the reply alone would cut the reply off.
    private static let thinkingTokenAllowance = 16_000

    /// A web search or fetch can pause a long server-side turn
    /// (`stop_reason: pause_turn`); it is resumed by sending it back. Bounded
    /// so a runaway can't loop forever.
    private static let maximumPauseTurnContinuations = 4

    /// Per-request caps on Anthropic's web tools, to bound cost and latency.
    private static let maximumWebSearchesPerRequest = 5
    private static let maximumWebFetchesPerRequest = 5

    /// Marks provider replay blocks produced here, so another provider (or a
    /// different Claude integration) never receives them.
    static let replayProviderFamily = "anthropic"

    init(
        apiKey: String?,
        modelChoice: AnthropicModelChoice = .opus,
        effortLevel: AnthropicEffortLevel = .low,
        isWebAccessEnabled: Bool = true,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.modelChoice = modelChoice
        self.effortLevel = effortLevel
        self.isWebAccessEnabled = isWebAccessEnabled
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
            contextWindowTokens: modelChoice == .haiku ? 200_000 : 1_000_000,
            requiresAppendOnlyHistoryWithinTurn: true
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

        let startTime = Date()
        var collectedBlocks: [BuddyContentBlock] = []
        var promptTokens: Int?
        var outputTokens: Int?
        var cacheReadTokens: Int?
        var cacheWriteTokens: Int?
        var finalStopReasonRaw: String?

        // Usually one pass. A server-side web search can pause a long turn
        // (`pause_turn`); it is resumed by sending the partial assistant
        // message straight back, and the passes are merged into one turn.
        for _ in 0...Self.maximumPauseTurnContinuations {
            try Task.checkCancellation()

            var messagesToSend = request.messages
            if !collectedBlocks.isEmpty {
                messagesToSend.append(BuddyChatMessage(role: .assistant, blocks: collectedBlocks))
            }

            let pass = try await streamOnePass(
                request: request,
                messages: messagesToSend,
                apiKey: apiKey,
                onTextDelta: onTextDelta
            )

            collectedBlocks.append(contentsOf: pass.blocks)
            promptTokens = (promptTokens ?? 0) + (pass.promptTokens ?? 0)
            outputTokens = (outputTokens ?? 0) + (pass.outputTokens ?? 0)
            cacheReadTokens = (cacheReadTokens ?? 0) + (pass.cacheReadTokens ?? 0)
            cacheWriteTokens = (cacheWriteTokens ?? 0) + (pass.cacheWriteTokens ?? 0)
            finalStopReasonRaw = pass.stopReasonRaw

            if pass.stopReasonRaw != "pause_turn" { break }
        }

        // A safety classifier (or Claude itself) declined, and no fallback
        // model took over. Any partial output is discarded, as Anthropic
        // advises, and replaced with a plain explanation.
        if finalStopReasonRaw == "refusal" {
            collectedBlocks = [.text("Claude declined to help with that request.")]
        }

        let hasToolCalls = collectedBlocks.toolUses.isEmpty == false
        return BuddyChatTurn(
            content: collectedBlocks,
            stopReason: Self.stopReason(stopReasonRaw: finalStopReasonRaw, hasToolCalls: hasToolCalls),
            duration: Date().timeIntervalSince(startTime),
            promptTokens: promptTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens
        )
    }

    /// What one streamed Messages response produced.
    private struct StreamedPass {
        let blocks: [BuddyContentBlock]
        let stopReasonRaw: String?
        let promptTokens: Int?
        let outputTokens: Int?
        let cacheReadTokens: Int?
        let cacheWriteTokens: Int?
    }

    private func streamOnePass(
        request: ModelRequest,
        messages: [BuddyChatMessage],
        apiKey: String,
        onTextDelta: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> StreamedPass {
        let urlRequest = try buildURLRequest(for: request, messages: messages, apiKey: apiKey)

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

            return try await consumeStream(byteStream, onTextDelta: onTextDelta)
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
    /// append to it, and `content_block_stop` closes it.
    /// - `text` → `.text` (adjacent text blocks are joined).
    /// - `tool_use` → `.toolUse`; its arguments arrive as `input_json_delta`
    ///   fragments that are concatenated and parsed once whole.
    /// - `thinking` → a replay block rebuilt from its `thinking_delta` and
    ///   `signature_delta`s (the thinking text is empty under the default
    ///   display; the signature is what matters).
    /// - `server_tool_use` (web search / fetch) → a replay block, its input
    ///   assembled like a tool call's.
    /// - anything else (`redacted_thinking`, web search / fetch results, and
    ///   block types added later) arrives whole in `content_block_start` and is
    ///   kept verbatim as a replay block.
    /// - `fallback` marks where a refusal handed the turn to another model.
    private func consumeStream(
        _ byteStream: URLSession.AsyncBytes,
        onTextDelta: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> StreamedPass {
        var orderedBlocks: [BuddyContentBlock] = []
        var promptTokens: Int?
        var outputTokens: Int?
        var cacheReadTokens: Int?
        var cacheWriteTokens: Int?
        var stopReasonRaw: String?

        // The block currently being streamed.
        var openBlockType: String?
        var openBlockStartPayload: [String: Any] = [:]
        var accumulatedToolArgumentsJSON = ""
        var accumulatedThinkingText = ""
        var accumulatedThinkingSignature = ""

        func parsedToolArguments() -> JSONValue {
            if let data = accumulatedToolArgumentsJSON.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) {
                return JSONValue(untypedValue: parsed)
            }
            // An empty-argument call streams no input_json_delta at all, which
            // is valid; treat unparseable/empty as {}.
            return .object([:])
        }

        func appendReplayBlock(_ blockPayload: [String: Any]) {
            orderedBlocks.append(.providerReplay(
                providerFamily: Self.replayProviderFamily,
                block: JSONValue(untypedValue: blockPayload)
            ))
        }

        func finalizeOpenBlock() {
            switch openBlockType {
            case "text", nil:
                break
            case "tool_use":
                orderedBlocks.append(.toolUse(
                    id: openBlockStartPayload["id"] as? String ?? UUID().uuidString,
                    name: openBlockStartPayload["name"] as? String ?? "",
                    input: parsedToolArguments()
                ))
            case "thinking":
                appendReplayBlock([
                    "type": "thinking",
                    "thinking": accumulatedThinkingText,
                    "signature": accumulatedThinkingSignature
                ])
            case "server_tool_use":
                var serverToolUsePayload = openBlockStartPayload
                serverToolUsePayload["input"] = parsedToolArguments().untypedValue
                appendReplayBlock(serverToolUsePayload)
            case "fallback":
                discardBlocksTheFallbackModelCannotContinueFrom()
            default:
                appendReplayBlock(openBlockStartPayload)
            }
            openBlockType = nil
            openBlockStartPayload = [:]
            accumulatedToolArgumentsJSON = ""
            accumulatedThinkingText = ""
            accumulatedThinkingSignature = ""
        }

        /// After a refusal mid-output hands the turn to a fallback model, the
        /// blocks before that point must not be echoed back except text and
        /// completed server-tool pairs (Anthropic's documented rule): the
        /// declined model's thinking and tool calls are not the fallback
        /// model's to continue from.
        func discardBlocksTheFallbackModelCannotContinueFrom() {
            var answeredServerToolUseIDs: Set<String> = []
            for block in orderedBlocks {
                if case .providerReplay(_, let replayBlock) = block,
                   case .object(let fields) = replayBlock,
                   case .string(let answeredToolUseID)? = fields["tool_use_id"] {
                    answeredServerToolUseIDs.insert(answeredToolUseID)
                }
            }
            orderedBlocks.removeAll { block in
                switch block {
                case .toolUse:
                    return true
                case .providerReplay(_, let replayBlock):
                    guard case .object(let fields) = replayBlock,
                          case .string(let blockType)? = fields["type"] else { return true }
                    if blockType == "server_tool_use" {
                        if case .string(let serverToolUseID)? = fields["id"] {
                            return !answeredServerToolUseIDs.contains(serverToolUseID)
                        }
                        return true
                    }
                    return blockType == "thinking" || blockType == "redacted_thinking"
                default:
                    return false
                }
            }
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
                        // Cached tokens are reported separately from
                        // `input_tokens`; the prompt is all three together.
                        let uncachedInputTokens = usage["input_tokens"] as? Int ?? 0
                        let messageCacheReadTokens = usage["cache_read_input_tokens"] as? Int ?? 0
                        let messageCacheWriteTokens = usage["cache_creation_input_tokens"] as? Int ?? 0
                        promptTokens = uncachedInputTokens + messageCacheReadTokens + messageCacheWriteTokens
                        cacheReadTokens = messageCacheReadTokens
                        cacheWriteTokens = messageCacheWriteTokens
                        print("☁️ Claude prompt: \(promptTokens ?? 0) tokens (\(messageCacheReadTokens) from cache, \(messageCacheWriteTokens) newly cached)")
                    }

                case "content_block_start":
                    if let contentBlock = event["content_block"] as? [String: Any] {
                        openBlockType = contentBlock["type"] as? String
                        openBlockStartPayload = contentBlock
                        accumulatedToolArgumentsJSON = ""
                        accumulatedThinkingText = contentBlock["thinking"] as? String ?? ""
                        accumulatedThinkingSignature = contentBlock["signature"] as? String ?? ""
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
                    case "thinking_delta":
                        if let thinkingText = delta["thinking"] as? String {
                            accumulatedThinkingText += thinkingText
                        }
                    case "signature_delta":
                        if let signature = delta["signature"] as? String {
                            accumulatedThinkingSignature += signature
                        }
                    default:
                        // citations_delta and any other delta types are ignored.
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

                case "error":
                    // An error mid-stream (e.g. overloaded) arrives as an SSE
                    // event after the 200.
                    let errorDetails = event["error"] as? [String: Any]
                    throw BuddyChatError.providerUnavailable(
                        providerName: identifier,
                        underlyingDescription: errorDetails?["message"] as? String ?? "stream error"
                    )

                default:
                    break
                }
            }
        } catch let error as URLError where error.code == .cancelled {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }

        return StreamedPass(
            blocks: orderedBlocks,
            stopReasonRaw: stopReasonRaw,
            promptTokens: promptTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens
        )
    }

    // MARK: - Request construction

    private func buildURLRequest(
        for request: ModelRequest,
        messages: [BuddyChatMessage],
        apiKey: String
    ) throws -> URLRequest {
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

        var enabledBetaFeatures: [String] = []
        if modelChoice.usesAdaptiveThinkingAndEffort {
            enabledBetaFeatures.append(Self.thinkingBindingControlsBeta)
        }
        if modelChoice.supportsServerSideRefusalFallback {
            enabledBetaFeatures.append(Self.serverSideRefusalFallbackBeta)
        }
        if !enabledBetaFeatures.isEmpty {
            urlRequest.setValue(enabledBetaFeatures.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        }

        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: buildRequestBody(from: request, messages: messages)
        )
        return urlRequest
    }

    private func buildRequestBody(from request: ModelRequest, messages: [BuddyChatMessage]) -> [String: Any] {
        let replyTokenCeiling = request.maxOutputTokens ?? Self.defaultReplyTokenCeiling

        var body: [String: Any] = [
            "model": modelName,
            "stream": true,
            "messages": messages.compactMap(Self.anthropicMessage(from:)),
            // Automatic caching: the breakpoint rides on the last block and
            // moves forward as a tool loop grows, so each pass of the loop
            // reads everything the previous pass sent from cache.
            "cache_control": ["type": "ephemeral"]
        ]

        if modelChoice.usesAdaptiveThinkingAndEffort {
            body["max_tokens"] = replyTokenCeiling + Self.thinkingTokenAllowance
            body["thinking"] = [
                "type": "adaptive",
                // A replayed thinking block that no longer matches the
                // conversation (a model switch, a fallback) is dropped and
                // Claude re-plans, rather than the whole request failing.
                "block_binding": ["prefix_mismatch_behavior": "drop_block"]
            ]
            body["output_config"] = ["effort": effortLevel.rawValue]
        } else {
            body["max_tokens"] = replyTokenCeiling
        }

        if modelChoice.supportsServerSideRefusalFallback {
            // A safety-classifier decline is retried on the model Anthropic
            // recommends for that category instead of ending the turn.
            body["fallbacks"] = "default"
        }

        if !request.systemPrompt.isEmpty {
            // An explicit breakpoint on the system prompt: the large, stable
            // part of every request gets a guaranteed cache read point.
            body["system"] = [[
                "type": "text",
                "text": request.systemPrompt,
                "cache_control": ["type": "ephemeral"]
            ]]
        }

        var tools: [[String: Any]] = request.tools.map { tool in
            [
                "name": tool.name,
                "description": tool.description,
                "input_schema": tool.inputSchema.untypedValue
            ]
        }
        // Web access only rides along on turns that already offer tools
        // (agent mode). Summaries, pointing fallbacks and plain answers stay
        // exactly as they were asked.
        if isWebAccessEnabled && !request.tools.isEmpty {
            tools.append([
                "type": modelChoice.webSearchToolType,
                "name": "web_search",
                "max_uses": Self.maximumWebSearchesPerRequest
            ])
            tools.append([
                "type": modelChoice.webFetchToolType,
                "name": "web_fetch",
                "max_uses": Self.maximumWebFetchesPerRequest
            ])
        }
        if !tools.isEmpty {
            body["tools"] = tools
        }

        // Opus 5.5 and Sonnet 5.5 reject sampling parameters outright (a 400),
        // so a caller's temperature is honoured only where it is accepted.
        if let temperature = request.temperature, !modelChoice.usesAdaptiveThinkingAndEffort {
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

            case .providerReplay(let providerFamily, let block):
                // Claude's own thinking / web blocks, sent back exactly as they
                // arrived. Another provider's private blocks mean nothing here.
                guard providerFamily == replayProviderFamily,
                      let replayedBlock = block.untypedValue as? [String: Any] else { continue }
                contentBlocks.append(replayedBlock)
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
        // "refusal", "pause_turn" (after the continuation cap) and anything newer.
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
