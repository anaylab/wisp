//
//  BuddyChatProviderSelection.swift
//  leanring-buddy
//
//  The user's currently selected chat provider, persisted across launches.
//  This is the single source of truth the provider factory reads to build the
//  right backend, and the same value the local-only-machinery gates consult to
//  decide whether keep-warm, the push-to-talk preload, and residency
//  serialisation should run at all.
//
//  Nothing consumes this type yet — it is landed ahead of the factory and the
//  settings UI so those later changes stay small.
//

import Foundation

/// Reads and writes which `BuddyChatProviderKind` is active.
///
/// Backed by `UserDefaults` rather than Info.plist because the choice is made
/// at runtime in the dashboard. API keys are *not* stored here — those live in
/// the Keychain (`ProviderKeychainStore`); this type holds only the harmless
/// fact of which provider is selected.
enum BuddyChatProviderSelection {
    private static let selectedProviderUserDefaultsKey = "SelectedChatProviderKind"

    /// The provider the user has selected, or the shipped default on first run.
    ///
    /// The default is always local: a cloud provider cannot be a sensible
    /// default because it needs an API key the user has not entered yet. The
    /// Info.plist `ChatProvider` key is honoured only insofar as it names the
    /// local backend, which it always does today.
    static var current: BuddyChatProviderKind {
        guard
            let storedRawValue = UserDefaults.standard.string(forKey: selectedProviderUserDefaultsKey),
            let storedProviderKind = BuddyChatProviderKind(rawValue: storedRawValue)
        else {
            return .localOllama
        }
        return storedProviderKind
    }

    /// Persists a new provider selection. The caller is responsible for asking
    /// `CompanionManager` to rebuild its provider so the change takes effect
    /// without a relaunch.
    static func set(_ selectedProviderKind: BuddyChatProviderKind) {
        UserDefaults.standard.set(
            selectedProviderKind.rawValue,
            forKey: selectedProviderUserDefaultsKey
        )
    }
}
