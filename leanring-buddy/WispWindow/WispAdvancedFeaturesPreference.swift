//
//  WispAdvancedFeaturesPreference.swift
//  leanring-buddy
//
//  One persisted switch for the surfaces most people never need: buddies asking
//  each other for help (`ask_buddy`), a per-buddy model, sharing/importing
//  buddies and routines, and the Brain, Routines, History and Connections
//  sections of the window. Buddies themselves are first-class and never hidden:
//  their characters, moods, personalities, specialties and automations are
//  always visible. Off by default. Turning it off only hides things -- no code,
//  stored buddy or brain data is removed, and existing buddies keep running
//  exactly as configured.
//

import Combine
import Foundation

@MainActor
final class WispAdvancedFeaturesPreference: ObservableObject {
    static let shared = WispAdvancedFeaturesPreference()

    private static let userDefaultsKey = "wisp.advancedFeatures.enabled"

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.userDefaultsKey)
        }
    }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.userDefaultsKey)
    }

    /// Synchronous read for code that is not on the main actor or not a view
    /// (tool registration, run setup). Reads the same stored value.
    nonisolated static var isEnabledNow: Bool {
        UserDefaults.standard.bool(forKey: userDefaultsKey)
    }
}
