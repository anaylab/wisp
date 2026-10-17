//
//  WispAdvancedFeaturesPreference.swift
//  leanring-buddy
//
//  One persisted switch for the surfaces most people never need: buddy
//  characters' styling choices, specialties, buddies asking each other for help,
//  a per-buddy model, sharing, and the buddy/brain sections of the window. Off by
//  default. Turning it off only hides things -- no code, stored buddy or brain
//  data is removed, and existing buddies keep running exactly as configured.
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
