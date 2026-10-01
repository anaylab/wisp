//
//  ModelProviderFactory.swift
//  leanring-buddy
//
//  Builds the `ModelProvider` for the user's current selection. This is the one
//  place that maps a `BuddyChatProviderKind` — plus its Keychain API key, for a
//  cloud provider — onto a concrete backend, so `CompanionManager` asks for "the
//  selected provider" and never names Ollama or Gemini itself.
//
//  This is what `CompanionManager`'s turn path uses instead of the old
//  `BuddyVisionChatClientFactory`, which could only ever return the local Ollama
//  client. That legacy factory still exists for `BrowserAgent`'s own internal
//  vision, which stays local for now.
//

import Foundation

enum ModelProviderFactory {
    /// Builds the provider for a selection, defaulting to whatever the user has
    /// chosen. Non-throwing on purpose: a cloud provider selected without a key
    /// is still constructed, and reports the missing key as an
    /// `authenticationFailed` when it is actually asked to run — which the
    /// settings UI can surface without the app ever being without a provider.
    static func make(
        _ providerKind: BuddyChatProviderKind = BuddyChatProviderSelection.current,
        claudeModelOverride: AnthropicModelChoice? = nil
    ) -> any ModelProvider {
        switch providerKind {
        case .localOllama:
            let ollamaBaseURL = AppBundleConfiguration.stringValue(forKey: "OllamaBaseURL")
                ?? "http://localhost:11434"
            let ollamaModel = AppBundleConfiguration.stringValue(forKey: "OllamaModel")
                ?? "qwen2.5vl:3b"
            return OllamaProvider(baseURL: ollamaBaseURL, model: ollamaModel)

        case .gemini:
            return GeminiProvider(apiKey: ProviderKeychainStore.apiKey(for: .gemini))

        case .anthropic:
            return AnthropicProvider(
                apiKey: ProviderKeychainStore.apiKey(for: .anthropic),
                modelChoice: claudeModelOverride ?? AnthropicModelSettings.selectedModel,
                effortLevel: AnthropicModelSettings.effortLevel,
                isWebAccessEnabled: AnthropicModelSettings.isWebAccessEnabled
            )

        case .openAI:
            return OpenAIProvider(apiKey: ProviderKeychainStore.apiKey(for: .openAI))
        }
    }

    /// Builds the provider a buddy chose for itself, so one buddy can run on
    /// Claude while another stays on the local model.
    static func make(_ buddyModelChoice: BuddyModelChoice) -> any ModelProvider {
        make(buddyModelChoice.providerKind, claudeModelOverride: buddyModelChoice.claudeModel)
    }
}
