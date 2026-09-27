//
//  VoiceOutputPreference.swift
//  leanring-buddy
//
//  The single source of truth for whether Wisp speaks its replies aloud —
//  the "voice mode" / "silent mode" switch. When voice mode is on, replies may
//  be spoken (the model decides per reply via the [SAY:] tag); when it is off
//  (silent mode), no reply is ever synthesized and the notch HUD is the only
//  place the answer appears.
//
//  This gates only *reply* speech. Fixed spoken strings that are part of a
//  safety flow — the tool-confirmation prompt and failure fallbacks — are left
//  audible on purpose and do not consult this preference.
//
//  Modeled on the app's other UserDefaults-backed stores (e.g.
//  `GlanceCardDataPreference` / `BuddyChatProviderSelection`): a `@Published`
//  source of truth that persists across launches.
//

import Combine
import Foundation

@MainActor
final class VoiceOutputPreference: ObservableObject {
    static let shared = VoiceOutputPreference()

    private static let replySpeechEnabledUserDefaultsKey = "wisp.voiceOutput.replySpeechEnabled"

    /// Whether spoken replies are allowed at all. When `false`, Wisp is in
    /// silent mode: reply speech is skipped entirely (never synthesized and
    /// discarded), and every answer is shown as text plus an optional glance
    /// card in the notch.
    ///
    /// Defaults to `true` (voice mode on) so a fresh install still talks; the
    /// model then decides per reply whether a spoken line adds value.
    @Published var isReplySpeechEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                isReplySpeechEnabled,
                forKey: Self.replySpeechEnabledUserDefaultsKey
            )
        }
    }

    private init() {
        // Absent defaults to enabled, so a fresh install ships with voice on.
        if UserDefaults.standard.object(forKey: Self.replySpeechEnabledUserDefaultsKey) == nil {
            isReplySpeechEnabled = true
        } else {
            isReplySpeechEnabled = UserDefaults.standard.bool(forKey: Self.replySpeechEnabledUserDefaultsKey)
        }
    }
}
