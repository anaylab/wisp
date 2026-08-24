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
}

enum BuddyTTSProviderFactory {
    /// Chatterbox if the user is running the server, otherwise the system
    /// synthesizer.
    ///
    /// Apple is the default because it costs no resident memory: Chatterbox
    /// sounds warmer but held several gigabytes and grew with use, which on a
    /// machine shared with a local model is most of the headroom.
    static func makeDefaultProvider() -> any BuddyTTSProvider {
        let preferred = AppBundleConfiguration
            .stringValue(forKey: "VoiceTTSProvider")?
            .lowercased()

        if preferred == "chatterbox" {
            let baseURL = AppBundleConfiguration
                .stringValue(forKey: "ChatterboxTTSServerURL")
                ?? "http://localhost:8004"
            print("🔊 TTS: using Chatterbox (local) at \(baseURL)")
            return LocalChatterboxTTSClient(baseURL: baseURL)
        }

        return AppleSpeechSynthesisClient()
    }
}
