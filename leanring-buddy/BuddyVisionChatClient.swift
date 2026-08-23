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
    private enum PreferredProvider: String {
        case claude = "claude"
        case ollama = "ollama"
    }

    static func makeDefaultProvider(claudeProxyURL: String, claudeModel: String) -> any BuddyVisionChatClient {
        let preferredProviderRawValue = AppBundleConfiguration
            .stringValue(forKey: "ChatProvider")?
            .lowercased()
        let preferredProvider = preferredProviderRawValue.flatMap(PreferredProvider.init(rawValue:))

        if preferredProvider == .ollama {
            let baseURL = AppBundleConfiguration.stringValue(forKey: "OllamaBaseURL")
                ?? "http://localhost:11434"
            let model = AppBundleConfiguration.stringValue(forKey: "OllamaModel")
                ?? "qwen2.5vl:7b"
            print("🧠 Chat: using Ollama (local) — \(model) at \(baseURL)")
            return LocalOllamaAPI(baseURL: baseURL, model: model)
        }

        print("🧠 Chat: using Claude")
        return ClaudeAPI(proxyURL: claudeProxyURL, model: claudeModel)
    }
}
