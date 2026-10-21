//
//  WispSoundPlayer.swift
//  leanring-buddy
//
//  Short, tasteful audio cues for the Dynamic Island's key moments, so the user
//  gets an ear on what Wisp is doing without having to watch the notch: a soft
//  cue when it starts listening, a lighter one when it begins thinking, a
//  pleasant one when a reply lands, and a low one when something fails.
//
//  The cues are synthesized in code (`WispSoundSynthesizer`): soft, bell-like
//  notes from one shared pentatonic palette, so every cue sounds like the same
//  instrument and nothing is bundled. Everything is gated behind `WispSoundPreference` (default on) so the whole
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

/// Builds Wisp's cues as tiny 16-bit mono WAV files in memory. Every cue is a few
/// soft bell notes (a sine plus quiet overtones, a fast attack, an exponential
/// decay and a faint echo) drawn from the C major pentatonic scale, so any two
/// cues sit well together and none of them has the harsh buzz of a system alert.
enum WispSoundSynthesizer {
    private static let sampleRate = 44_100.0

    /// One note: a pitch in Hz, when it starts and how long it rings (seconds).
    struct Note {
        let frequency: Double
        let start: Double
        let ringDuration: Double
        var loudness: Double = 1.0
    }

    // C major pentatonic, so notes never clash.
    static let g4 = 392.00, a4 = 440.00, c5 = 523.25, d5 = 587.33, e5 = 659.25
    static let g5 = 783.99, a5 = 880.00, c6 = 1046.50, e6 = 1318.51

    static func wavData(for notes: [Note], echoDelay: Double = 0.09, echoLevel: Double = 0.22) -> Data {
        let totalSeconds = (notes.map { $0.start + $0.ringDuration }.max() ?? 0.1) + echoDelay * 2
        let sampleCount = Int(totalSeconds * sampleRate)
        var mix = [Double](repeating: 0, count: sampleCount)

        for note in notes {
            let firstSample = Int(note.start * sampleRate)
            let noteSampleCount = Int(note.ringDuration * sampleRate)
            for offset in 0..<noteSampleCount where firstSample + offset < sampleCount {
                let time = Double(offset) / sampleRate
                // 6ms attack avoids a click; the decay time constant is a fifth of the ring.
                let attack = min(1.0, time / 0.006)
                let decay = exp(-time / (note.ringDuration * 0.2))
                let phase = 2.0 * Double.pi * note.frequency * time
                let tone = sin(phase) + 0.30 * sin(2 * phase) * exp(-time * 14) + 0.10 * sin(3 * phase) * exp(-time * 22)
                mix[firstSample + offset] += tone * attack * decay * note.loudness
            }
        }

        // Two faint echo taps give the dry notes a little room.
        let echoSampleOffset = Int(echoDelay * sampleRate)
        for index in stride(from: sampleCount - 1, through: echoSampleOffset, by: -1) {
            mix[index] += mix[index - echoSampleOffset] * echoLevel
            if index >= echoSampleOffset * 2 {
                mix[index] += mix[index - echoSampleOffset * 2] * echoLevel * 0.4
            }
        }

        let peak = max(mix.map { abs($0) }.max() ?? 1, 0.0001)
        let fadeOutSamples = Int(0.02 * sampleRate)
        var pcm = Data(capacity: sampleCount * 2)
        for index in 0..<sampleCount {
            let fadeOut = index > sampleCount - fadeOutSamples ? Double(sampleCount - index) / Double(fadeOutSamples) : 1.0
            var sample = Int16(max(-1, min(1, mix[index] / peak * 0.9 * fadeOut)) * Double(Int16.max)).littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }

        func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
            withUnsafeBytes(of: value.littleEndian) { Array($0) }
        }
        var header = Data("RIFF".utf8)
        header.append(contentsOf: littleEndianBytes(UInt32(36 + pcm.count)))
        header.append(Data("WAVEfmt ".utf8))
        header.append(contentsOf: littleEndianBytes(UInt32(16)))
        header.append(contentsOf: littleEndianBytes(UInt16(1)))        // PCM
        header.append(contentsOf: littleEndianBytes(UInt16(1)))        // mono
        header.append(contentsOf: littleEndianBytes(UInt32(sampleRate)))
        header.append(contentsOf: littleEndianBytes(UInt32(sampleRate) * 2))
        header.append(contentsOf: littleEndianBytes(UInt16(2)))
        header.append(contentsOf: littleEndianBytes(UInt16(16)))
        header.append(Data("data".utf8))
        header.append(contentsOf: littleEndianBytes(UInt32(pcm.count)))
        return header + pcm
    }
}

/// Plays the Dynamic Island's interaction sound cues. Each cue is synthesized once
/// and played at a deliberately low volume so it reads as a gentle tick rather
/// than an alert.
@MainActor
final class WispSoundPlayer {
    static let shared = WispSoundPlayer()

    /// The moments the island marks with a sound.
    enum SoundCue: CaseIterable {
        /// The mic just opened — Wisp started hearing the user (rising, "go ahead").
        case listening
        /// The user let go and Wisp is sending what it heard (a short falling tap).
        case heard
        /// The turn began — Wisp is reasoning with the model (a soft double pulse).
        case thinking
        /// A reply has landed and is being shown/spoken (a warm two-note chime).
        case reply
        /// A moment of resolution after an action completed (a bright rising arpeggio).
        case success
        /// Wisp needs the user's OK before doing something (a gentle "excuse me").
        case needsApproval
        /// The user chose Cancel. Deliberately neutral: a choice, not a failure.
        case declined
        /// Something genuinely went wrong. Soft and low, never a buzz.
        case error

        fileprivate var notes: [WispSoundSynthesizer.Note] {
            typealias S = WispSoundSynthesizer
            switch self {
            case .listening:
                return [.init(frequency: S.e5, start: 0, ringDuration: 0.16, loudness: 0.8),
                        .init(frequency: S.a5, start: 0.07, ringDuration: 0.22)]
            case .heard:
                return [.init(frequency: S.a5, start: 0, ringDuration: 0.12, loudness: 0.8),
                        .init(frequency: S.e5, start: 0.06, ringDuration: 0.16, loudness: 0.7)]
            case .thinking:
                return [.init(frequency: S.g4, start: 0, ringDuration: 0.18, loudness: 0.7),
                        .init(frequency: S.d5, start: 0.11, ringDuration: 0.2, loudness: 0.6)]
            case .reply:
                return [.init(frequency: S.g5, start: 0, ringDuration: 0.3, loudness: 0.8),
                        .init(frequency: S.c6, start: 0.1, ringDuration: 0.5)]
            case .success:
                return [.init(frequency: S.c5, start: 0, ringDuration: 0.3, loudness: 0.8),
                        .init(frequency: S.e5, start: 0.08, ringDuration: 0.3, loudness: 0.85),
                        .init(frequency: S.g5, start: 0.16, ringDuration: 0.3, loudness: 0.9),
                        .init(frequency: S.c6, start: 0.24, ringDuration: 0.55)]
            case .needsApproval:
                return [.init(frequency: S.d5, start: 0, ringDuration: 0.2, loudness: 0.8),
                        .init(frequency: S.d5, start: 0.15, ringDuration: 0.3)]
            case .declined:
                return [.init(frequency: S.c5, start: 0, ringDuration: 0.16, loudness: 0.7)]
            case .error:
                return [.init(frequency: S.e5, start: 0, ringDuration: 0.2, loudness: 0.8),
                        .init(frequency: S.g4, start: 0.12, ringDuration: 0.35)]
            }
        }

        /// The trackpad feel that goes with this cue.
        fileprivate var haptic: WispHapticPlayer.Feel {
            switch self {
            case .listening:     return .tap
            case .heard:         return .tick
            case .thinking:      return .tick
            case .reply:         return .tick
            case .success:       return .success
            case .needsApproval: return .attention
            case .declined:      return .soft
            case .error:         return .problem
            }
        }

        /// A low playback volume (0–1) so the cue stays a gentle tick.
        fileprivate var volume: Float {
            switch self {
            case .listening, .heard, .thinking: return 0.3
            case .reply, .needsApproval:        return 0.4
            case .success:                      return 0.45
            case .declined:                     return 0.25
            case .error:                        return 0.4
            }
        }
    }

    /// Each cue's WAV bytes, built on first use and kept.
    private var cachedWavDataByCue: [SoundCue: Data] = [:]

    private init() {}

    /// Plays the cue, unless the user has muted the interaction sounds. A fresh
    /// `NSSound` is created per call so a cue can retrigger before the previous
    /// one has finished.
    func play(_ cue: SoundCue) {
        // Haptics have their own switch, so they play even with the sounds muted.
        WispHapticPlayer.shared.play(cue.haptic)
        guard WispSoundPreference.shared.areSoundCuesEnabled else { return }
        let wavData = cachedWavDataByCue[cue] ?? WispSoundSynthesizer.wavData(for: cue.notes)
        cachedWavDataByCue[cue] = wavData
        guard let sound = NSSound(data: wavData) else { return }
        sound.volume = cue.volume
        sound.play()
    }
}
