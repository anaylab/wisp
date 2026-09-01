//
//  OllamaProvider.swift
//  leanring-buddy
//
//  Presents the local Ollama client as a `ModelProvider`.
//
//  This is a translator and nothing else. It converts a `ModelRequest` into
//  the flat strings-and-images shape `LocalOllamaAPI` has always sent, and
//  converts what comes back into a `BuddyChatTurn`. It does not run tools, it
//  does not know that `AgentToolRegistry` exists, and it cannot reach the
//  browser, the filesystem, or MCP. Tool execution stays behind the registry,
//  where permission is enforced, so adding a provider can never become a way
//  around an approval prompt.
//
//  The other thing it contains is the `[TOOL:name:{…}]` convention. A 7B local
//  model is unreliable at native tool calls, so tools are offered as prompt
//  text and recovered by parsing the reply. That is a fact about *this model*,
//  not about agents in general — so `StructuredTextToolProtocol` is used here
//  and only here, and the runtime above sees ordinary `toolUse` blocks with no
//  idea a tag was ever involved.
//

import Foundation

final class OllamaProvider: ModelProvider, @unchecked Sendable {
    /// Unchecked rather than genuinely `Sendable` because `LocalOllamaAPI` is a
    /// plain class with a settable `model` — a requirement of the older
    /// `BuddyVisionChatClient` protocol. This type never writes to it. The
    /// client is created once, read from every call, and owns a long-lived
    /// `URLSession` that must be shared rather than rebuilt: the AssemblyAI
    /// path already learned that recreating sessions corrupts the OS
    /// connection pool. Holding one client is the safe arrangement; the
    /// annotation records that the compiler cannot see why.
    private let client: LocalOllamaAPI
    private let modelName: String

    init(client: LocalOllamaAPI, modelName: String) {
        self.client = client
        self.modelName = modelName
    }

    convenience init(baseURL: String, model: String) {
        self.init(client: LocalOllamaAPI(baseURL: baseURL, model: model), modelName: model)
    }

    var identifier: String { "ollama/\(modelName)" }

    var capabilities: ModelCapabilities {
        ModelCapabilities(
            supportsVision: true,
            supportsTools: true,
            // The model does not emit structured tool calls. They are parsed
            // out of ordinary text, which is why the echo guard below exists.
            supportsNativeToolCalls: false,
            supportsStreaming: true,
            supportsStructuredOutput: false,
            // Read from the client so there is exactly one place that decides
            // it. Changing this value between requests makes Ollama reload the
            // model — 8.85 seconds on this machine, with the model already
            // resident — so a second opinion here would be expensive.
            contextWindowTokens: LocalOllamaAPI.activeContextWindowTokens
        )
    }

    var deployment: ModelDeployment {
        ModelDeployment(
            location: .onThisMachine,
            // Measured on an M3 Pro against qwen2.5vl:7b: 31 tokens in 1.19s,
            // 48 in 1.84s, 55 in 2.10s — about 26 a second across the range.
            approximateOutputTokensPerSecond: 26
        )
    }

    // MARK: - Running a turn

    func streamTurn(
        _ request: ModelRequest,
        onTextDelta: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> BuddyChatTurn {
        // Refuses rather than quietly dropping an image this model cannot see.
        try validateAgainstCapabilities(request)

        let conversation = Self.translate(request)

        // Tool instructions are prompt text for this model, so they belong in
        // the system prompt rather than in a wire-level `tools` field. Built
        // here so the caller never has to know which convention is in play.
        let systemPromptWithTools = request.systemPrompt
            + StructuredTextToolProtocol.promptInstructions(for: request.tools)

        let result: LocalOllamaAPI.StreamedChatResult
        do {
            result = try await client.streamChat(
                images: conversation.images,
                systemPrompt: systemPromptWithTools,
                conversationHistory: conversation.history,
                userPrompt: conversation.userPrompt,
                // nil flows through to the client's own default, so the
                // generic layer never has to know what that default is.
                maxOutputTokens: request.maxOutputTokens,
                // Passed straight through: `streamChat` emits new text only,
                // which is what the protocol promises and what
                // SpokenSentenceStreamer needs. Re-sending the accumulated
                // reply here would produce duplicated, garbled speech.
                onTextDelta: onTextDelta
            )
        } catch let error as URLError where error.code == .cancelled {
            // URLSession reports an interrupted request as URLError.cancelled
            // (NSURLErrorDomain -999), not as a CancellationError. That
            // distinction matters upstream: the response pipeline catches
            // cancellation to abandon a turn quietly and withdraw any pending
            // permission prompt, while every other error is reported to the
            // user. Left untranslated, interrupting Wisp mid-sentence — which
            // is just the user speaking again — would surface as a failure.
            //
            // Only reinterpreted when this task really was cancelled. A -999
            // arriving for any other reason is a genuine transport fault and
            // keeps its own identity.
            if Task.isCancelled { throw CancellationError() }
            throw error
        } catch let error as URLError where Self.indicatesServerIsUnreachable(error.code) {
            // Ollama not running is the most likely failure on a local-first
            // app, and "could not connect to the server" tells the caller
            // nothing about which server or whether retrying is sensible.
            throw BuddyChatError.providerUnavailable(
                providerName: identifier,
                underlyingDescription: error.localizedDescription
            )
        }

        return Self.turn(from: result, knownToolNames: Set(request.tools.map(\.name)))
    }

    /// URL failures that mean "nothing is listening", as opposed to a request
    /// that reached the server and was refused. Only these become
    /// `providerUnavailable`; anything else keeps its own identity rather than
    /// being flattened into one catch-all.
    private static func indicatesServerIsUnreachable(_ code: URLError.Code) -> Bool {
        switch code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
             .notConnectedToInternet, .timedOut, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    // MARK: - Request translation

    /// The flat shape `LocalOllamaAPI` accepts.
    private struct OllamaConversation {
        let history: [(userPlaceholder: String, assistantResponse: String)]
        let userPrompt: String
        let images: [(data: Data, label: String)]
    }

    /// Flattens typed messages into Ollama's alternating string pairs.
    ///
    /// Only the final user message's images are sent. That is not a policy
    /// decision made here — it falls out of translating faithfully, because
    /// the caller decides which message carries an image and the agent loop
    /// attaches one to the first pass only. A provider that re-sent every
    /// image it had ever seen would add roughly six seconds of prompt
    /// evaluation to every later iteration.
    private static func translate(_ request: ModelRequest) -> OllamaConversation {
        var history: [(userPlaceholder: String, assistantResponse: String)] = []
        var pendingUserText: String?

        // Everything except the final user message becomes history.
        let messages = request.messages
        let finalUserIndex = messages.lastIndex { $0.role == .user }

        for (index, message) in messages.enumerated() {
            if index == finalUserIndex { continue }
            let text = renderedText(of: message)
            switch message.role {
            case .user:
                pendingUserText = text
            case .assistant:
                history.append((userPlaceholder: pendingUserText ?? "", assistantResponse: text))
                pendingUserText = nil
            }
        }

        // A user message with no assistant reply after it would otherwise be
        // dropped — it is context the model still needs.
        if let leftover = pendingUserText, !leftover.isEmpty {
            history.append((userPlaceholder: leftover, assistantResponse: ""))
        }

        guard let finalUserIndex else {
            return OllamaConversation(history: history, userPrompt: "", images: [])
        }

        let finalMessage = messages[finalUserIndex]
        return OllamaConversation(
            history: history,
            userPrompt: renderedText(of: finalMessage),
            images: images(in: finalMessage)
        )
    }

    /// Renders one message's blocks as the plain text this model reads best.
    ///
    /// Tool results are rendered through the same helper the text protocol
    /// uses for them, so a result reaches the model in the wording it was
    /// tuned against rather than as a JSON envelope.
    private static func renderedText(of message: BuddyChatMessage) -> String {
        var parts: [String] = []
        for block in message.blocks {
            switch block {
            case .text(let value):
                parts.append(value)
            case .toolResult(_, let toolName, let content, let isError):
                parts.append(
                    StructuredTextToolProtocol.resultMessageText(
                        toolName: toolName, content: content, isError: isError
                    )
                )
            case .toolUse(_, let name, let input):
                // The assistant's own past call, replayed so the model can see
                // what it already asked for.
                parts.append("[TOOL:\(name):\(input.compactDescription)]")
            case .image:
                // Carried separately — Ollama takes images as a base64 array
                // on the message, not inline in the text.
                continue
            }
        }
        return parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func images(in message: BuddyChatMessage) -> [(data: Data, label: String)] {
        message.blocks.compactMap { block in
            if case .image(let data, let label) = block { return (data: data, label: label) }
            return nil
        }
    }

    // MARK: - Response translation

    /// Turns a finished reply into a `BuddyChatTurn`.
    ///
    /// Parsing happens on the complete text rather than incrementally: the
    /// parser chooses its pattern by scanning the whole reply, and a tag split
    /// across two deltas would be unrecognisable. Streaming and parsing are
    /// therefore separate concerns — deltas are for speech, this is for
    /// meaning.
    private static func turn(
        from result: LocalOllamaAPI.StreamedChatResult,
        knownToolNames: Set<String>
    ) -> BuddyChatTurn {
        let parsed = StructuredTextToolProtocol.parse(result.text, knownToolNames: knownToolNames)

        // Calls that merely echo the prompt's worked example are dropped: they
        // appear on turns needing no tool at all, and acting on one would
        // answer a request the user never made.
        let genuineCalls = parsed.toolCalls.filter {
            !StructuredTextToolProtocol.isEchoOfPromptExample($0)
        }

        let toolUses = genuineCalls.map { call in
            (id: call.id, name: call.name, input: call.input)
        }

        return BuddyChatTurn(
            text: parsed.spokenText,
            toolUses: toolUses,
            stopReason: toolUses.isEmpty ? .endTurn : .toolUse,
            duration: result.duration,
            promptTokens: result.promptTokens,
            outputTokens: result.outputTokens,
            // Carried up rather than discarded: the runtime needs to know the
            // model attempted a call it could not express, both to tell it so
            // and to refuse to speak the surrounding text as if it were an
            // answer.
            malformedToolCallDescriptions: parsed.malformedTags
        )
    }
}
