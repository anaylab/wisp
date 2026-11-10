// Adapted from Sentient OS's ProofreadInference (AGPL-3.0).
//
// Sends only the selected text to the local Ollama model and requires a strictly shaped JSON
// answer. Partial JSON, extra keys, refusals and changed line breaks never reach the user's
// text. Wisp's chat client is not reused because it appends a "keep replies very short"
// instruction meant for spoken answers, which would truncate a correction.

import Foundation

enum ProofreadInference {
    nonisolated static let maximumInputBytes = 12_000
    nonisolated static let maximumOutputBytes = 24_000

    private static let systemPrompt = """
    You are a proofreader. Fix spelling, grammar, punctuation and capitalization in the text \
    the user sends. Keep the author's wording, tone, language, formatting and every line break. \
    Do not summarize, translate, explain or add anything. If nothing needs fixing, return the \
    text unchanged. Reply with JSON of the form {"corrected_text": "..."} and nothing else.
    """

    static func correct(_ text: String) async throws -> String {
        let baseURLString = AppBundleConfiguration.stringValue(forKey: "OllamaBaseURL") ?? "http://localhost:11434"
        let modelName = AppBundleConfiguration.stringValue(forKey: "OllamaModel") ?? "qwen2.5vl:3b"
        guard let baseURL = URL(string: baseURLString) else { throw Failure.unavailable }

        let request = try makeRequest(baseURL: baseURL, modelName: modelName, text: text)
        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await URLSession.shared.data(for: request)
        } catch {
            // Ollama is local, so a failed connection means it is not running.
            throw Failure.unavailable
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let envelope = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              envelope["done_reason"] as? String != "length",
              let message = envelope["message"] as? [String: Any],
              let content = message["content"] as? String else { throw Failure.incomplete }
        return try decode(content, original: text)
    }

    static func makeRequest(baseURL: URL, modelName: String, text: String) throws -> URLRequest {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= maximumInputBytes else { throw Failure.tooLarge }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"), cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": modelName,
            "stream": false,
            // Ollama constrains the output to this schema, which is what makes the strict decode below practical on a small model.
            "format": [
                "type": "object",
                "properties": ["corrected_text": ["type": "string"]],
                "required": ["corrected_text"],
            ],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text],
            ],
            // Must equal the context size the rest of Wisp uses, or Ollama reloads the model (see LocalOllamaAPI).
            "options": ["temperature": 0, "num_ctx": LocalOllamaAPI.activeContextWindowTokens],
            "keep_alive": LocalOllamaAPI.modelResidencyWindow,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    nonisolated static func decode(_ response: String, original: String? = nil) throws -> String {
        guard response.utf8.count <= 160_000,
              let value = try? JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any],
              Set(value.keys) == ["corrected_text"], let corrected = value["corrected_text"] as? String,
              !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              corrected.utf8.count <= maximumOutputBytes, !corrected.contains("\0") else { throw Failure.incomplete }
        guard let original else { return corrected }
        // Boundary whitespace belongs to the selection, not the model. Preserve it mechanically.
        let leading = String(original.prefix(while: { $0.isWhitespace }))
        let trailing = String(original.reversed().prefix(while: { $0.isWhitespace }).reversed())
        let result = leading + corrected.trimmingCharacters(in: .whitespacesAndNewlines) + trailing
        let originalBreaks = original.unicodeScalars.filter { CharacterSet.newlines.contains($0) }
        guard result.unicodeScalars.filter({ CharacterSet.newlines.contains($0) }).elementsEqual(originalBreaks),
              result.utf8.count <= maximumOutputBytes else { throw Failure.incomplete }
        return result
    }

    nonisolated enum Failure: LocalizedError {
        case unavailable, tooLarge, incomplete
        var errorDescription: String? {
            switch self {
            case .unavailable: "Wisp couldn’t reach the local model. Make sure Ollama is running, then try again."
            case .tooLarge: "Select a shorter passage to proofread."
            case .incomplete: "The correction couldn’t finish. Your text hasn’t been changed."
            }
        }
    }
}
