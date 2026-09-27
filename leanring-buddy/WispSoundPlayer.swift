//
//  WispSoundPlayer.swift
//  leanring-buddy
//
//  Short, tasteful audio cues for the Dynamic Island's key moments, so the user
//  gets an ear on what Wisp is doing without having to watch the notch: a soft
//  cue when it starts listening, a lighter one when it begins thinking, a
//  pleasant one when a reply lands, and a low one when something fails.
//
//  The cues are built-in macOS system sounds (`/System/Library/Sounds/*.aiff`),
//  so nothing is bundled and they already match the platform's sonic identity.
//  Everything is gated behind `WispSoundPreference` (default on) so the whole
//  set can be muted from the notch header, mirroring the voice/silent toggle.
//

import AppKit
import Combine
import Foundation

/// The single source of truth for whether Wisp plays its interaction sound cues.
/// Modeled on `VoiceOutputPreference`: a `@Published` flag persisted across
/// launches, defaulting to on so a fresh install is audibly responsive.
@MainActor
final class WispSoundPreference: ObservableObject {
    static let shared = WispSoundPreference()

    private static let soundCuesEnabledUserDefaultsKey = "wisp.sound.cuesEnabled"

    /// Whether the interaction cues (listening / thinking / reply / error) play.
    /// When `false`, Wisp stays silent except for spoken replies, which are
    /// governed separately by `VoiceOutputPreference`.
    @Published var areSoundCuesEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                areSoundCuesEnabled,
                forKey: Self.soundCuesEnabledUserDefaultsKey
            )
        }
    }

    private init() {
        // Absent defaults to enabled, so a fresh install ships with cues on.
        if UserDefaults.standard.object(forKey: Self.soundCuesEnabledUserDefaultsKey) == nil {
            areSoundCuesEnabled = true
        } else {
            areSoundCuesEnabled = UserDefaults.standard.bool(forKey: Self.soundCuesEnabledUserDefaultsKey)
        }
    }
}

/// Plays the Dynamic Island's interaction sound cues. Each cue is a named system
/// sound at a deliberately low volume so it reads as a subtle notification tick
/// rather than an alert.
@MainActor
final class WispSoundPlayer {
    static let shared = WispSoundPlayer()

    /// The moments the island marks with a sound. Each maps to one built-in
    /// system sound plus a volume tuned so the set feels cohesive and quiet.
    enum SoundCue {
        /// The mic just opened — Wisp started hearing the user.
        case listening
        /// The turn began — Wisp is now reasoning with the model.
        case thinking
        /// A reply has landed and is being shown/spoken.
        case reply
        /// A moment of resolution after an action completed.
        case success
        /// Something failed or was declined.
        case error

        /// The built-in system sound file (in `/System/Library/Sounds`) for this cue.
        fileprivate var systemSoundName: String {
            switch self {
            case .listening: return "Pop"
            case .thinking:  return "Tink"
            case .reply:     return "Glass"
            case .success:   return "Glass"
            case .error:     return "Basso"
            }
        }

        /// A low playback volume (0–1) so the cue stays a gentle tick.
        fileprivate var volume: Float {
            switch self {
            case .listening: return 0.35
            case .thinking:  return 0.3
            case .reply:     return 0.4
            case .success:   return 0.4
            case .error:     return 0.5
            }
        }
    }

    private init() {}

    /// Plays the cue, unless the user has muted the interaction sounds. A fresh
    /// `NSSound` is created per call so a cue can retrigger before the previous
    /// one has finished (system sounds are lightweight, so this is cheap).
    func play(_ cue: SoundCue) {
        guard WispSoundPreference.shared.areSoundCuesEnabled else { return }
        guard let sound = NSSound(named: NSSound.Name(cue.systemSoundName)) else { return }
        sound.volume = cue.volume
        sound.play()
    }
}
