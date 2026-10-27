//
//  LearnedShortcutPreference.swift
//  leanring-buddy
//
//  The one switch for replaying learned shortcuts, in Settings → Agent. Off by default: nothing
//  is replayed until the user turns it on. Saving a shortcut (the notch's "Save as shortcut")
//  does not depend on it. Modeled on `AnnouncementPreferences`.
//

import Combine
import Foundation

@MainActor
final class LearnedShortcutPreference: ObservableObject {
    static let shared = LearnedShortcutPreference()

    private static let isReplayEnabledUserDefaultsKey = "wisp.learnedShortcuts.isReplayEnabled"

    @Published var isReplayEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isReplayEnabled, forKey: Self.isReplayEnabledUserDefaultsKey)
        }
    }

    private init() {
        // Never set means off: this is the opt-in.
        isReplayEnabled = UserDefaults.standard.bool(forKey: Self.isReplayEnabledUserDefaultsKey)
    }
}
