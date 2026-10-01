//
//  AnthropicModelSettings.swift
//  leanring-buddy
//
//  What the user has chosen for Claude when it is the selected provider: which
//  model, how hard it thinks (effort), and whether it may search and read the
//  web itself. Persisted in UserDefaults — none of it is secret; the API key
//  lives in the Keychain (`ProviderKeychainStore`).
//
//  Read by `ModelProviderFactory` when it builds `AnthropicProvider`, and edited
//  in Settings → Model. A change takes effect on the next turn after
//  `CompanionManager.rebuildSelectedModelProvider()`.
//

import Foundation

/// The Claude models Wisp offers, most capable first.
///
/// Each model's API differences live here, as data, so `AnthropicProvider`
/// asks the model rather than comparing model-name strings.
enum AnthropicModelChoice: String, CaseIterable, Identifiable, Sendable, Codable {
    case opus = "claude-opus-5-5"
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-4-5"

    var id: String { rawValue }

    /// The exact model id sent to the Messages API.
    var apiModelIdentifier: String { rawValue }

    var displayName: String {
        switch self {
        case .opus: return "Claude Opus 5.5"
        case .sonnet: return "Claude Sonnet 5.5"
        case .haiku: return "Claude Haiku 4.5"
        }
    }

    var shortDescription: String {
        switch self {
        case .opus: return "Smartest. Best for multi-step tasks, tools and reading your screen."
        case .sonnet: return "Fast and capable. A good everyday balance."
        case .haiku: return "Fastest and cheapest. Best for quick questions."
        }
    }

    /// Opus 5.5 and Sonnet 5.5 always think (adaptively) and take an effort
    /// level; Haiku 4.5 rejects `effort` and, without a thinking budget, runs
    /// without thinking at all.
    var usesAdaptiveThinkingAndEffort: Bool {
        switch self {
        case .opus, .sonnet: return true
        case .haiku: return false
        }
    }

    /// Server-side refusal fallback (`fallbacks: "default"`) is offered for the
    /// models whose safety classifiers can decline a request.
    var supportsServerSideRefusalFallback: Bool {
        usesAdaptiveThinkingAndEffort
    }

    /// The newest web search / fetch tool versions this model accepts. The
    /// 2026 versions filter results on Anthropic's side and need a 5.x-era
    /// model; Haiku 4.5 takes the basic ones.
    var webSearchToolType: String {
        usesAdaptiveThinkingAndEffort ? "web_search_20260209" : "web_search_20250305"
    }

    var webFetchToolType: String {
        usesAdaptiveThinkingAndEffort ? "web_fetch_20260209" : "web_fetch_20250910"
    }
}

/// How much Claude thinks before answering — the main lever between answer
/// quality and speed on Opus 5.5 and Sonnet 5.5. Ignored for Haiku 4.5.
enum AnthropicEffortLevel: String, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: return "Quick"
        case .medium: return "Balanced"
        case .high: return "Thorough"
        }
    }
}

/// Reads and writes the Claude settings. A plain namespace over UserDefaults,
/// like `BuddyChatProviderSelection`, so the provider factory can read it from
/// anywhere without holding an observable object.
enum AnthropicModelSettings {
    private static let selectedModelUserDefaultsKey = "AnthropicSelectedModel"
    private static let effortLevelUserDefaultsKey = "AnthropicEffortLevel"
    private static let webAccessEnabledUserDefaultsKey = "AnthropicWebAccessEnabled"

    /// Opus 5.5 by default: the most capable model, and at a low effort it is
    /// still quick enough for a spoken companion.
    static var selectedModel: AnthropicModelChoice {
        get {
            UserDefaults.standard.string(forKey: selectedModelUserDefaultsKey)
                .flatMap(AnthropicModelChoice.init(rawValue:)) ?? .opus
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: selectedModelUserDefaultsKey)
        }
    }

    /// `low` by default: Wisp is voice-first, so time to the first word
    /// matters more than squeezing out the last bit of depth. Tasks that need
    /// more can raise it in Settings → Model.
    static var effortLevel: AnthropicEffortLevel {
        get {
            UserDefaults.standard.string(forKey: effortLevelUserDefaultsKey)
                .flatMap(AnthropicEffortLevel.init(rawValue:)) ?? .low
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: effortLevelUserDefaultsKey)
        }
    }

    /// Whether Claude may use Anthropic's own web search and web fetch tools
    /// on turns that already offer tools (agent mode). On by default: choosing
    /// Claude already sends the conversation off this machine, and searching
    /// runs on Anthropic's servers without touching the user's browser.
    static var isWebAccessEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: webAccessEnabledUserDefaultsKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: webAccessEnabledUserDefaultsKey)
        }
    }
}
