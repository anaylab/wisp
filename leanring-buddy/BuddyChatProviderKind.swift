//
//  BuddyChatProviderKind.swift
//  leanring-buddy
//
//  Which backend answers the user: the local Ollama model, or one of the
//  bring-your-own-key cloud providers. This is the vocabulary the provider
//  factory, the settings UI, and the local-only-machinery gates all share.
//
//  Nothing consumes this type yet — it is landed ahead of the factory and the
//  settings UI so those later changes stay small.
//

import Foundation

/// The chat backend the user has chosen.
///
/// The selection is a *runtime* setting (see `BuddyChatProviderSelection`), not
/// a compile-time Info.plist value, because the user changes it live in the
/// dashboard. The Info.plist `ChatProvider` key survives only as the shipped
/// default, which is always local.
enum BuddyChatProviderKind: String, CaseIterable, Identifiable, Sendable {
    /// The on-device Ollama model. The default, and the only provider whose
    /// requests never leave this machine.
    case localOllama

    /// Anthropic's Claude, over the network, with a user-supplied API key.
    case anthropic

    /// OpenAI's GPT, over the network, with a user-supplied API key.
    case openAI

    /// Google's Gemini, over the network, with a user-supplied API key.
    case gemini

    var id: String { rawValue }

    /// The human-readable name shown in the provider picker.
    var displayName: String {
        switch self {
        case .localOllama: return "Local (Ollama)"
        case .anthropic:   return "Claude (Anthropic)"
        case .openAI:      return "GPT (OpenAI)"
        case .gemini:      return "Gemini (Google)"
        }
    }

    /// Whether choosing this provider sends screenshots and the voice
    /// transcript off this machine.
    ///
    /// Drives two things that must never disagree: the privacy notice shown in
    /// the settings UI, and the gates that switch off the local-only machinery
    /// (keep-warm heartbeat, push-to-talk preload, residency serialisation)
    /// when the model no longer lives on this machine.
    var sendsScreenshotsOffThisMachine: Bool {
        self != .localOllama
    }

    /// Whether this provider needs a user-supplied API key before it can run.
    ///
    /// Only the local provider works without one. A cloud provider selected
    /// without a stored key is a configuration error the UI must surface rather
    /// than a request that silently fails.
    var requiresAPIKey: Bool {
        self != .localOllama
    }
}
