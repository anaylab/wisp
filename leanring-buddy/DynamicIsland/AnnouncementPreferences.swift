//
//  AnnouncementPreferences.swift
//  leanring-buddy
//
//  The switches for the things Wisp brings up on its own, set in the
//  dashboard's Agent tab: the once-a-day morning suggestions banner, and
//  staying quiet while the user is on a call (`QuietModeMonitor`).
//  Both default on. Modeled on `VoiceOutputPreference`.
//

import Combine
import Foundation

@MainActor
final class AnnouncementPreferences: ObservableObject {
    static let shared = AnnouncementPreferences()

    private static let morningSuggestionsEnabledUserDefaultsKey = "wisp.announcements.morningSuggestionsEnabled"
    private static let quietDuringCallsEnabledUserDefaultsKey = "wisp.announcements.quietDuringCallsEnabled"

    /// Whether the notch offers the day's suggestions the first time the user is
    /// at the Mac each day. When the Jobs checklist exists for today, the same
    /// switch governs dropping that checklist instead of the generic suggestions.
    @Published var areMorningSuggestionsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(areMorningSuggestionsEnabled, forKey: Self.morningSuggestionsEnabledUserDefaultsKey)
        }
    }

    /// Whether Wisp holds back its unprompted announcements while the user is on
    /// a call (another app using the microphone, or a camera on).
    @Published var isQuietDuringCallsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isQuietDuringCallsEnabled, forKey: Self.quietDuringCallsEnabledUserDefaultsKey)
        }
    }

    private init() {
        areMorningSuggestionsEnabled = Self.readBool(Self.morningSuggestionsEnabledUserDefaultsKey, defaultValue: true)
        isQuietDuringCallsEnabled = Self.readBool(Self.quietDuringCallsEnabledUserDefaultsKey, defaultValue: true)
    }

    /// Reads a stored flag, treating "never set" as `defaultValue` so a fresh
    /// install gets the intended default rather than `false`.
    private static func readBool(_ userDefaultsKey: String, defaultValue: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: userDefaultsKey) != nil else { return defaultValue }
        return UserDefaults.standard.bool(forKey: userDefaultsKey)
    }
}
