// Adapted from Sentient OS's SummarizeInference (AGPL-3.0).
//
// Streams a summary of the document text from the local Ollama model. Wisp's chat client is not
// reused because it appends a "two sentences, under 200 characters" rule meant for spoken replies.
// A reply that stops before Ollama reports `done` is an error, though the text so far is kept.

import Foundation

enum SummarizeInference {
    nonisolated static let deadline: Duration = .seconds(120)

    private static let systemPrompt = """
    You summarize the document the user shares. Lead with one sentence saying what it is, then \
    give the key points as short bullets. Be faithful to the text: do not add facts, opinions or \
    advice. Never mention the application, the title, the scope or how the text was captured: \
    describe only what the document itself says. If the text was abbreviated, summarize what you were given without guessing the rest. \
    Reply in the same language as the document unless the user's preference says otherwise.
    """

    /// Streams the summary, calling `onText` with the cumulative text each time it grows.
    static func stream(source: SummarySource, preference: String,
                       onText: @escaping @MainActor @Sendable (String) -> Void) async throws -> String {
        let baseURLString = AppBundleConfiguration.stringValue(forKey: "OllamaBaseURL") ?? "http://localhost:11434"
        let modelName = AppBundleConfiguration.stringValue(forKey: "OllamaModel") ?? "qwen2.5vl:3b"
        guard let baseURL = URL(string: baseURLString) else { throw Failure.unavailable }
        let request = try makeRequest(baseURL: baseURL, modelName: modelName, source: source, preference: preference)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            // Ollama is local, so a failed connection means it is not running.
            throw Failure.unavailable
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.invalidResponse }

        var accumulatedText = ""
        var sawDone = false
        for try await line in bytes.lines {
            guard let lineData = line.data(using: .utf8),
                  let chunk = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            if let message = chunk["message"] as? [String: Any], let piece = message["content"] as? String, !piece.isEmpty {
                accumulatedText += piece
                await onText(accumulatedText)
            }
            if chunk["done"] as? Bool == true {
                sawDone = true
                if chunk["done_reason"] as? String == "length" { throw Failure.incomplete }
            }
        }
        guard sawDone else { throw Failure.incomplete }
        return accumulatedText
    }

    static func makeRequest(baseURL: URL, modelName: String, source: SummarySource, preference: String) throws -> URLRequest {
        guard !source.text.isEmpty,
              source.text.utf8.count <= SummaryAccessibility.maximumTextBytes,
              preference.utf8.count <= 1_000 else { throw Failure.invalidRequest }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"), cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var userMessage = source.title.isEmpty ? "" : "Document title: \(source.title)\n"
        if source.truncated { userMessage += "Note: the text below was abbreviated to fit.\n" }
        if !preference.isEmpty { userMessage += "Preference: \(preference)\n" }
        userMessage += "\n--- Document text ---\n\(source.text)"

        let body: [String: Any] = [
            "model": modelName,
            "stream": true,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage],
            ],
            // Must equal the context size the rest of Wisp uses, or Ollama reloads the model (see LocalOllamaAPI).
            "options": ["temperature": 0.2, "num_ctx": LocalOllamaAPI.activeContextWindowTokens, "num_predict": 700],
            "keep_alive": LocalOllamaAPI.modelResidencyWindow,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    nonisolated enum Failure: LocalizedError, Equatable {
        case unavailable, invalidRequest, invalidResponse, incomplete, empty, timedOut
        var errorDescription: String? {
            switch self {
            case .unavailable: "Wisp couldn’t reach the local model. Make sure Ollama is running, then try again."
            case .timedOut: "The summary took too long. Try again."
            case .incomplete: "The summary was interrupted. You can read the available text or try again."
            case .empty: "No summary came back. Try again."
            case .invalidRequest: "This document couldn’t be prepared for a summary. Try again."
            case .invalidResponse: "The summary couldn’t finish. Try again."
            }
        }
    }
}
