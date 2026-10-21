//
//  WispHapticPlayer.swift
//  leanring-buddy
//
//  Trackpad haptics that pair with Wisp's sound cues, so key moments are felt as
//  well as heard. macOS only fires these on a Force Touch trackpad, and only while
//  a finger is on it (a click, a drag, moving the pointer). Hold-to-talk by
//  keyboard alone stays silent, which is the system's rule, not ours.
//
//  macOS offers just three patterns (generic, alignment, level change), so a cue's
//  character comes from sequencing them: one tap for a small event, two for a
//  resolved one.
//

import AppKit
import Combine
import Foundation

/// Whether Wisp plays trackpad haptics. Persisted, default on; separate from the
/// sound cues so either can be muted alone.
@MainActor
final class WispHapticPreference: ObservableObject {
    static let shared = WispHapticPreference()

    private static let hapticsEnabledUserDefaultsKey = "wisp.haptics.enabled"

    @Published var areHapticsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(areHapticsEnabled, forKey: Self.hapticsEnabledUserDefaultsKey)
        }
    }

    private init() {
        // Absent defaults to enabled, so a fresh install ships with haptics on.
        if UserDefaults.standard.object(forKey: Self.hapticsEnabledUserDefaultsKey) == nil {
            areHapticsEnabled = true
        } else {
            areHapticsEnabled = UserDefaults.standard.bool(forKey: Self.hapticsEnabledUserDefaultsKey)
        }
    }
}

@MainActor
final class WispHapticPlayer {
    static let shared = WispHapticPlayer()

    /// One tap, or a short run of taps.
    enum Feel {
        /// A light tick: something small happened (a button pressed, the notch opened).
        case tick
        /// A firm tap: the mic opened or the turn was sent.
        case tap
        /// Two taps that rise: it worked.
        case success
        /// Two soft taps: Wisp needs the user's attention.
        case attention
        /// One soft tap with no follow-up: a deliberate "no", not a failure.
        case soft
        /// A tap, a gap, then a heavier tap: something went wrong.
        case problem
    }

    private init() {}

    func play(_ feel: Feel) {
        guard WispHapticPreference.shared.areHapticsEnabled else { return }
        let performer = NSHapticFeedbackManager.defaultPerformer

        switch feel {
        case .tick:
            performer.perform(.alignment, performanceTime: .now)
        case .tap:
            performer.perform(.generic, performanceTime: .now)
        case .soft:
            performer.perform(.alignment, performanceTime: .now)
        case .success:
            performer.perform(.generic, performanceTime: .now)
            performFollowUp(.levelChange, afterSeconds: 0.09)
        case .attention:
            performer.perform(.alignment, performanceTime: .now)
            performFollowUp(.alignment, afterSeconds: 0.12)
        case .problem:
            performer.perform(.generic, performanceTime: .now)
            performFollowUp(.levelChange, afterSeconds: 0.14)
        }
    }

    /// Haptics play on the system's own clock, so a second tap is scheduled rather than slept on.
    private func performFollowUp(_ pattern: NSHapticFeedbackManager.FeedbackPattern, afterSeconds delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        }
    }
}
