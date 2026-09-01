//
//  LocalOllamaAPI.swift
//  Local vision-chat client backed by a self-hosted Ollama server.
//
//  Pointing is supported here, on measured evidence.
//
//  An early spike appeared to show that this model could not produce
//  pixel-accurate [POINT:x,y] coordinates, and pointing was disabled as a
//  result. That spike was itself wrong: its test image was rendered on a
//  Retina display at twice the requested size, while the prompt still
//  declared the smaller dimensions, so the model's correct answers looked
//  like wild misses. Re-measured against an image whose true pixel size
//  matches its declared size, qwen2.5vl:7b landed inside the target element
//  in 5 of 5 cases with a median error of 6 pixels, using the app's own full
//  system prompt, in about a second per call.
//
//  The app does not have the flaw the spike did: CompanionScreenCaptureUtility
//  sets the capture dimensions explicitly and labels each image with those
//  same numbers, so what the model is told matches what it is shown.
//

import Foundation

final class LocalOllamaAPI: BuddyVisionChatClient {
    private let chatURL: URL
    var model: String
    private let session: URLSession

    /// Ollama's default context window (4096 tokens) is too small for the
    /// companion system prompt plus a labeled screenshot — real requests
    /// overflow it and return a 400 (exceed_context_size_error). Confirmed
    /// during the local-model validation spike; 8192 comfortably covers the
    /// current prompt + one screenshot. Increase further if screenshots or
    /// conversation history grow.
    private static let contextWindowTokens = 8192

    /// Tool calling needs materially more room than a spoken reply: tool
    /// schemas sit in the prompt, and every tool result is appended to the
    /// conversation for the remainder of the exchange.
    private static let agentContextWindowTokens = 16384

    /// A spoken answer is capped short because synthesis time scales with
    /// characters. That cap cannot apply when tools are in play — a reply cut
    /// off mid-sentence is merely terse, but a *tool call* cut off mid-JSON is
    /// unparseable, which fails the whole turn rather than shortening it.
    private static let spokenReplyTokenLimit = 120
    private static let agentReplyTokenLimit = 1024

    /// The context size every request must use — heartbeat included.
    ///
    /// Ollama reloads the model whenever `num_ctx` changes between requests,
    /// which costs about six seconds. The keep-warm heartbeat used to omit the
    /// option entirely, so it ran at the model default, evicted the model it
    /// existed to keep resident, and made the user's next turn pay a second
    /// reload on top. Deriving both from one value is what prevents that, so
    /// this must stay the single source for every caller.
    static var activeContextWindowTokens: Int {
        CompanionManager.isAgentModeEnabled ? agentContextWindowTokens : contextWindowTokens
    }

    /// Reply ceiling. Unlike `num_ctx`, changing this between requests does not
    /// reload anything, but it is derived from the same flag for consistency.
    static var activeReplyTokenLimit: Int {
        CompanionManager.isAgentModeEnabled ? agentReplyTokenLimit : spokenReplyTokenLimit
    }

    /// How long Ollama holds the model after a request. Must match across
    /// callers: the shortest value wins, so a heartbeat asking for less than a
    /// real turn quietly shortens the residency it is meant to extend.
    ///
    /// Deliberately short. The model is six gigabytes on an eighteen gigabyte
    /// machine that the user also needs for their actual work, so it should be
    /// resident while they are talking to Wisp and released when they are not.
    /// The heartbeat refreshes this window for as long as the conversation is
    /// live, so in practice the model only unloads after a real idle stretch —
    /// and the cost of being wrong is one reload of a few seconds, paid by the
    /// person who came back, rather than gigabytes held from everyone else.
    static let modelResidencyWindow = "5m"

    init(baseURL: String, model: String) {
        self.chatURL = URL(string: "\(baseURL)/api/chat")!
        self.model = model

        let config = URLSessionConfiguration.default
        // Local inference on modest hardware can take a while, especially
        // for the first request after the model loads into memory.
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }

    /// One streamed reply, with the server's own accounting attached.
    ///
    /// Ollama reports `prompt_eval_count` and `eval_count` on the final NDJSON
    /// line, and this client used to discard both. They are the only honest
    /// record of what a turn cost — anything upstream would be guessing — so
    /// they now travel back with the text.
    struct StreamedChatResult {
        let text: String
        let duration: TimeInterval
        let promptTokens: Int?
        let outputTokens: Int?
    }

    /// Collects streamed text so the older cumulative callback can keep its
    /// contract while the transport underneath emits increments.
    ///
    /// A reference type because the closure handed to `streamChat` is
    /// `@Sendable`, and a `@Sendable` closure cannot capture a mutable local.
    private final class AccumulatedReplyText: @unchecked Sendable {
        var value = ""
    }

    /// The original entry point, unchanged in behaviour.
    ///
    /// Note the callback contract: `onTextChunk` receives the whole reply so
    /// far, not the newest fragment. That is preserved here deliberately —
    /// this method is still on the live voice path, and altering what it emits
    /// would change what the app speaks. `streamChat` below emits true
    /// increments, which is what new callers should use.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        // Attaching the screenshot is by far the most expensive thing this
        // request can do. Measured against qwen2.5-vl on an M3 Pro: encoding
        // one 896px capture costs ~6.3s of prompt evaluation, while generating
        // the reply itself costs ~1s. Purely conversational turns ("how's it
        // going?") gain nothing from the screen, so the image is only attached
        // when the wording suggests the user is actually referring to it.
        //
        // This choice belongs to the caller, not to the model: it is about
        // what is worth sending, not about what the model can see. It stays on
        // this path only; `streamChat` sends whatever it is given.
        let shouldAttachScreenshot = Self.promptLikelyRefersToScreen(userPrompt)
        let attachedImages = shouldAttachScreenshot ? images : []
        print("👁️ Ollama: screenshot \(shouldAttachScreenshot ? "attached" : "skipped") for \"\(userPrompt.prefix(60))\"")

        let accumulated = AccumulatedReplyText()
        let result = try await streamChat(
            images: attachedImages,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            onTextDelta: { delta in
                accumulated.value += delta
                onTextChunk(accumulated.value)
            }
        )
        return (text: result.text, duration: result.duration)
    }

    /// Streams one chat completion, emitting **new text only**.
    ///
    /// Two differences from `analyzeImageStreaming`, both required by the
    /// provider layer: every image passed in is sent (deciding what to attach
    /// is the caller's job, and a provider that quietly dropped one would let
    /// the model answer confidently about a screen it never saw), and the
    /// server's token counts come back with the reply.
    ///
    /// The transport itself — endpoint, options, `keep_alive`, NDJSON handling
    /// — is unchanged from what this client has always sent.
    /// - Parameter maxOutputTokens: Reply ceiling for this request, or `nil`
    ///   to use this client's own. `nil` is the normal case and keeps
    ///   `activeReplyTokenLimit` the single owner of that default; a supplied
    ///   value overrides it for this request only and is never written back,
    ///   so no caller can change what the next one gets.
    func streamChat(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        maxOutputTokens: Int? = nil,
        onTextDelta: @MainActor @Sendable (String) -> Void
    ) async throws -> StreamedChatResult {
        let startTime = Date()

        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Downstream local TTS synthesis costs roughly a third of a second of
        // compute per character, so reply length is the single biggest driver
        // of how long the user waits to hear anything.
        let brevityInstructionForLocalModel = """


        keep replies very short: at most two sentences, and under 200 characters total, unless the user explicitly asks you to go deeper.
        """

        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt + brevityInstructionForLocalModel]
        ]

        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Ollama's chat API takes images as a flat base64 string array on the
        // user message, unlike Anthropic's content-block-with-source wrapper.
        let base64Images = images.map { $0.data.base64EncodedString() }
        let imageLabelsText = images.map(\.label).joined(separator: "\n")
        let combinedUserContent = imageLabelsText.isEmpty
            ? userPrompt
            : "\(imageLabelsText)\n\n\(userPrompt)"

        var userMessage: [String: Any] = [
            "role": "user",
            "content": combinedUserContent
        ]
        if !base64Images.isEmpty {
            userMessage["images"] = base64Images
        }
        messages.append(userMessage)

        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": messages,
            // keep_alive holds the multi-GB model resident between utterances.
            // Without it Ollama evicts after its short default idle window and
            // every request pays a full reload from disk.
            "keep_alive": Self.modelResidencyWindow,
            "options": [
                // Both derived from the one place that owns them. Changing
                // num_ctx between requests makes Ollama reload the model —
                // measured at 8.85s with the model already resident — so no
                // caller gets to supply its own value.
                "num_ctx": Self.activeContextWindowTokens,
                // The caller's ceiling when it gave one, this client's own
                // otherwise. num_predict can change between requests without
                // costing a reload, unlike num_ctx above.
                "num_predict": maxOutputTokens ?? Self.activeReplyTokenLimit
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "LocalOllamaAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyChunks: [String] = []
            for try await line in byteStream.lines {
                errorBodyChunks.append(line)
            }
            let errorBody = errorBodyChunks.joined(separator: "\n")
            throw NSError(
                domain: "LocalOllamaAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Ollama error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        // Ollama streams one JSON object per line (NDJSON), not SSE.
        var accumulatedResponseText = ""
        var promptTokens: Int?
        var outputTokens: Int?

        for try await line in byteStream.lines {
            guard let lineData = line.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            if let message = eventPayload["message"] as? [String: Any],
               let textChunk = message["content"] as? String,
               !textChunk.isEmpty {
                accumulatedResponseText += textChunk
                await onTextDelta(textChunk)
            }

            if let isDone = eventPayload["done"] as? Bool, isDone {
                // Only the final line carries the accounting.
                promptTokens = eventPayload["prompt_eval_count"] as? Int
                outputTokens = eventPayload["eval_count"] as? Int
                break
            }
        }

        let duration = Date().timeIntervalSince(startTime)
        // The [POINT:...] tag is left intact for the caller to parse —
        // see the file header for the accuracy measurements behind that.
        return StreamedChatResult(
            text: accumulatedResponseText,
            duration: duration,
            promptTokens: promptTokens,
            outputTokens: outputTokens
        )
    }


    /// Whether the user's wording suggests they're asking about something on
    /// screen, and the (expensive) screenshot is therefore worth attaching.
    ///
    /// Deliberately biased toward attaching: answering a screen question
    /// blind is a visibly wrong answer, whereas a needless attach only costs
    /// seconds. So this matches demonstratives ("this", "here"), anything
    /// naming screen furniture, and any reading/looking verb — and only skips
    /// when a turn looks purely conversational.
    static func promptLikelyRefersToScreen(_ userPrompt: String) -> Bool {
        let lowercasedPrompt = userPrompt.lowercased()

        let screenReferenceTerms = [
            // demonstratives — strong signal the user is pointing at something
            "this", "these", "those", "here",
            // the screen itself
            "screen", "display", "monitor", "window", "tab", "page", "app",
            "desktop", "browser",
            // things on it
            "button", "menu", "icon", "cursor", "sidebar", "toolbar", "dialog",
            "highlighted", "selected", "field", "box", "link",
            // looking / reading
            "see", "look", "looking", "show", "showing", "shows", "read",
            "reading", "view", "visible", "says",
            // working on something
            "click", "open", "close", "press", "select", "type",
            "error", "bug", "warning", "code", "line", "file", "function",
            "fix", "wrong", "broken", "failing", "output", "log",
            // common phrasings
            "what is that", "what's that", "what am i", "how do i",
        ]

        for term in screenReferenceTerms {
            // Multi-word phrases are matched as substrings; single words are
            // matched on word boundaries so "this" doesn't fire inside
            // unrelated words.
            if term.contains(" ") {
                if lowercasedPrompt.contains(term) { return true }
            } else if lowercasedPrompt.range(of: "\\b\(term)\\b", options: .regularExpression) != nil {
                return true
            }
        }

        return false
    }

}
