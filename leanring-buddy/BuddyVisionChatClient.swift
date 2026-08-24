//
//  BuddyVisionChatClient.swift
//  leanring-buddy
//
//  Shared protocol surface for the screenshot + voice chat backend
//  (currently Claude via the Cloudflare Worker, or a local Ollama model).
//

import Foundation

protocol BuddyVisionChatClient: AnyObject {
    var model: String { get set }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval)
}

enum BuddyVisionChatClientFactory {
    /// Ollama is the only backend. The cloud clients were removed: they could
    /// not have worked anyway — the proxy URL they pointed at was still the
    /// placeholder from the upstream template — and keeping unreachable
    /// branches around invites the reader to believe there is a choice here.
    static func makeDefaultProvider() -> any BuddyVisionChatClient {
        let baseURL = AppBundleConfiguration.stringValue(forKey: "OllamaBaseURL")
            ?? "http://localhost:11434"
        let model = AppBundleConfiguration.stringValue(forKey: "OllamaModel")
            ?? "qwen2.5vl:7b"
        print("🧠 Chat: using Ollama (local) — \(model) at \(baseURL)")
        return LocalOllamaAPI(baseURL: baseURL, model: model)
    }
}
