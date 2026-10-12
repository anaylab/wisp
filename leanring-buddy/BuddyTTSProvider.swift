//
//  BuddyTTSProvider.swift
//  leanring-buddy
//
//  Shared protocol surface for text-to-speech backends.
//

import Foundation

protocol BuddyTTSProvider: AnyObject {
    /// Sends `text` to the backend and plays the resulting audio.
    /// Throws on network or decoding errors. Cancellation-safe.
    ///
    /// Providers that stream sentence-by-sentence only return once the whole
    /// reply has finished playing, so callers must not rely on this returning
    /// at the moment audio starts — use `onPlaybackStarted` for that.
    func speakText(_ text: String) async throws

    /// Called on the main actor the moment the first audio actually becomes
    /// audible, which is when the UI should drop its "thinking" spinner.
    var onPlaybackStarted: (@MainActor () -> Void)? { get set }

    /// Whether TTS audio is currently playing back.
    var isPlaying: Bool { get }

    /// Stops any in-progress playback immediately.
    func stopPlayback()

    /// Speaks a fragment now, queued behind anything already speaking.
    ///
    /// The point is to start talking before the model has finished thinking.
    /// A spoken reply is generated at roughly thirty tokens a second, so
    /// waiting for the whole thing means several seconds of silence during
    /// which the app looks broken — while the first sentence is usually ready
    /// in about one.
    func speakIncremental(_ text: String)

    /// Whether `speakIncremental` actually does anything.
    var supportsIncrementalSpeech: Bool { get }

    /// Waits for everything queued to finish playing.
    func waitForPlaybackToFinish() async
}

extension BuddyTTSProvider {
    /// Providers that synthesise a whole clip before playing it gain nothing
    /// from fragments, so they opt out and keep the speak-once path.
    func speakIncremental(_ text: String) {}
    var supportsIncrementalSpeech: Bool { false }
    func waitForPlaybackToFinish() async {}
}

enum BuddyTTSProviderFactory {
    /// Kokoro (FluidAudio, on the Neural Engine) when Info.plist says `fluid`
    /// — the shipped default — Chatterbox if it says `chatterbox`, otherwise
    /// the system synthesizer.
    ///
    /// Kokoro is the default because it sounds close to a person while running
    /// in-process with a fixed footprint. Chatterbox sounds warm too but held
    /// several gigabytes of Python and grew with use, which on a machine
    /// shared with a local model is most of the headroom. `apple` remains for
    /// anyone who wants no model memory at all, and is Kokoro's automatic
    /// fallback until its model is ready.
    static func makeDefaultProvider() -> any BuddyTTSProvider {
        if configuredProviderName == "chatterbox" {
            let baseURL = AppBundleConfiguration
                .stringValue(forKey: "ChatterboxTTSServerURL")
                ?? "http://localhost:8004"
            print("🔊 TTS: using Chatterbox (local) at \(baseURL)")
            return LocalChatterboxTTSClient(baseURL: baseURL)
        }

        if isKokoroConfigured {
            return KokoroSpeechSynthesisClient()
        }

        return AppleSpeechSynthesisClient()
    }

    /// Whether `VoiceTTSProvider` selects Kokoro (`fluid`; `fluidaudio` and
    /// `kokoro` are accepted as spellings of the same thing).
    static var isKokoroConfigured: Bool {
        ["fluid", "fluidaudio", "kokoro"].contains(configuredProviderName)
    }

    private static var configuredProviderName: String? {
        AppBundleConfiguration
            .stringValue(forKey: "VoiceTTSProvider")?
            .lowercased()
    }
}
