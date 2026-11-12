// Adapted from Sentient OS's DoubleTapInference (AGPL-3.0).
//
// One screenshot plus what Wisp knows about the user goes to the local vision model, which
// answers with either the reply to paste or the sentinel NOT_A_MESSAGE. Wisp's chat client is not
// reused because it appends a spoken-reply brevity rule and expects a streamed voice turn.

import Foundation

enum DoubleTapInference {
    enum Verdict: Equatable {
        case notAMessage
        case reply(String)
    }

    nonisolated static let maximumReplyBytes = 4_000

    static let instructions = """
    The user just pressed a shortcut while their cursor sat in a text box. The screenshot is their \
    screen at that moment.

    Who the user is: the person described under "about the user", if present. They own this Mac and \
    the account on screen: "me" in an email's recipients, the sending side of a chat. Write as them, \
    never as anyone else in the thread.

    Step 1: decide whether the focused text box is a reply box for an EMAIL or a MESSAGE (chat, DM, \
    SMS, iMessage, WhatsApp, Slack, Discord, LinkedIn and the like) that the user is replying to. \
    Code editors, terminals, search fields, forms, notes, documents, spreadsheets, address bars and \
    a blank compose window with no message to answer are NOT.

    If it is NOT, output exactly:
    NOT_A_MESSAGE

    If it IS, write the reply the user would send:
    - Answer the most recent message addressed to the user in the thread the reply box belongs to. \
    Other replies visible on screen are context only; never copy them.
    - Use only facts you can see on screen or in "about the user"; never invent commitments, dates \
    or details. If you cannot answer from what you have, write a short reply that asks for what is missing.
    - For a chat MESSAGE, match the user's own earlier messages in the thread: length, capitalization, \
    punctuation, slang, emoji and how casual they are. A chat reply is usually one short line with no \
    greeting or sign-off.
    - For an EMAIL, keep a natural greeting and sign-off only if the thread shows the user using them.
    - No em dashes.
    Output ONLY the reply text, nothing else.
    """

    static func draft(screenshotJPEG: Data, aboutTheUser: String) async throws -> Verdict {
        let baseURLString = AppBundleConfiguration.stringValue(forKey: "OllamaBaseURL") ?? "http://localhost:11434"
        let modelName = AppBundleConfiguration.stringValue(forKey: "OllamaModel") ?? "qwen2.5vl:3b"
        guard let baseURL = URL(string: baseURLString) else { throw Failure.unavailable }
        let request = makeRequest(baseURL: baseURL, modelName: modelName, screenshotJPEG: screenshotJPEG, aboutTheUser: aboutTheUser)

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            // Ollama is local, so a failed connection means it is not running.
            throw Failure.unavailable
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let envelope = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              envelope["done_reason"] as? String != "length",
              let message = envelope["message"] as? [String: Any],
              let content = message["content"] as? String else { throw Failure.incomplete }
        return try verdict(from: content)
    }

    static func makeRequest(baseURL: URL, modelName: String, screenshotJPEG: Data, aboutTheUser: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"), cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": modelName,
            "stream": false,
            "messages": [
                ["role": "system", "content": instructions + aboutTheUser],
                ["role": "user", "content": "Write the reply for the focused text box.", "images": [screenshotJPEG.base64EncodedString()]],
            ],
            // Must equal the context size the rest of Wisp uses, or Ollama reloads the model (see LocalOllamaAPI).
            "options": ["temperature": 0.4, "num_ctx": LocalOllamaAPI.activeContextWindowTokens, "num_predict": 400],
            "keep_alive": LocalOllamaAPI.modelResidencyWindow,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The sentinel, tolerant of the decoration models add around it (`**NOT_A_MESSAGE**`,
    /// backticks, quotes, a trailing period). Anything else is the reply.
    nonisolated static func verdict(from rawReply: String) throws -> Verdict {
        let reply = rawReply.trimmingCharacters(in: .whitespacesAndNewlines)
        let decoration = CharacterSet(charactersIn: "*`_\"'“”.:!").union(.whitespacesAndNewlines)
        let core = reply.trimmingCharacters(in: decoration).uppercased()
        if core.hasPrefix("NOT_A_MESSAGE") || core.hasPrefix("NOT A MESSAGE") { return .notAMessage }
        if reply.count < 40, core.contains("NOT_A_MESSAGE") { return .notAMessage }
        guard !reply.isEmpty, reply.utf8.count <= maximumReplyBytes, !reply.contains("\0") else { throw Failure.incomplete }
        return .reply(reply)
    }

    nonisolated enum Failure: LocalizedError {
        case unavailable, incomplete
        var errorDescription: String? {
            switch self {
            case .unavailable: "Wisp couldn’t reach the local model. Make sure Ollama is running."
            case .incomplete: "The draft couldn’t finish."
            }
        }
    }
}
