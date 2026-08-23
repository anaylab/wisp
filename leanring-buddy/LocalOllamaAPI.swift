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

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Downstream local TTS synthesis costs roughly a third of a second of
        // compute per character, so reply length is the single biggest driver
        // of how long the user waits to hear anything. Reinforce brevity for
        // the local provider only — the Claude path keeps the prompt as-is.
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

        // Attaching the screenshot is by far the most expensive thing this
        // request can do. Measured against qwen2.5-vl on an M3 Pro: encoding
        // one 896px capture costs ~7s, while generating the reply itself
        // costs ~1s. Purely conversational turns ("how's it going?") gain
        // nothing from the screen, so the image is only attached when the
        // wording suggests the user is actually referring to it.
        let shouldAttachScreenshot = Self.promptLikelyRefersToScreen(userPrompt)
        let attachedImages = shouldAttachScreenshot ? images : []
        print("👁️ Ollama: screenshot \(shouldAttachScreenshot ? "attached" : "skipped") for \"\(userPrompt.prefix(60))\"")

        // Ollama's chat API takes images as a flat base64 string array on the
        // user message, unlike Anthropic's content-block-with-source wrapper.
        let base64Images = attachedImages.map { $0.data.base64EncodedString() }
        let imageLabelsText = attachedImages.map(\.label).joined(separator: "\n")
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
            "keep_alive": "30m",
            "options": [
                "num_ctx": Self.contextWindowTokens,
                // Hard ceiling on reply length as a backstop to the prompt
                // instruction above, since TTS time scales with characters.
                "num_predict": Self.spokenReplyTokenLimit
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

        for try await line in byteStream.lines {
            guard let lineData = line.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            if let message = eventPayload["message"] as? [String: Any],
               let textChunk = message["content"] as? String,
               !textChunk.isEmpty {
                accumulatedResponseText += textChunk
                let currentAccumulatedText = accumulatedResponseText
                await onTextChunk(currentAccumulatedText)
            }

            if let isDone = eventPayload["done"] as? Bool, isDone {
                break
            }
        }

        let duration = Date().timeIntervalSince(startTime)
        // The [POINT:...] tag is left intact for CompanionManager to parse —
        // see the file header for the accuracy measurements behind that.
        return (text: accumulatedResponseText, duration: duration)
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
