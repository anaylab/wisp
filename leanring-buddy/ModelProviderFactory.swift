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
        _ providerKind: BuddyChatProviderKind = BuddyChatProviderSelection.current
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

        case .anthropic, .openAI:
            // These providers are planned but not yet written. Returning a stub
            // keeps this switch total and fails honestly at call time, rather
            // than the app trapping on an unhandled case. Each stub is replaced
            // by its real provider as that provider lands.
            return UnimplementedModelProvider(providerKind: providerKind)
        }
    }
}

/// Stands in for a selected-but-unimplemented provider. It never produces a
/// turn; it exists so the factory is total and the failure is a clear,
/// reportable error instead of a crash.
private struct UnimplementedModelProvider: ModelProvider {
    let providerKind: BuddyChatProviderKind

    var identifier: String { "unimplemented/\(providerKind.rawValue)" }

    var capabilities: ModelCapabilities {
        ModelCapabilities(
            supportsVision: false,
            supportsTools: false,
            supportsNativeToolCalls: false,
            supportsStreaming: false,
            contextWindowTokens: 0
        )
    }

    var deployment: ModelDeployment {
        ModelDeployment(location: .remote(serviceName: providerKind.displayName))
    }

    func streamTurn(
        _ request: ModelRequest,
        onTextDelta: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> BuddyChatTurn {
        throw BuddyChatError.providerUnavailable(
            providerName: providerKind.displayName,
            underlyingDescription: "this provider is not available yet"
        )
    }
}
