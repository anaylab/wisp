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
    private enum PreferredProvider: String {
        case elevenLabs = "elevenlabs"
        case chatterbox = "chatterbox"
    }

    static func makeDefaultProvider(elevenLabsProxyURL: String) -> any BuddyTTSProvider {
        let preferredProviderRawValue = AppBundleConfiguration
            .stringValue(forKey: "VoiceTTSProvider")?
            .lowercased()
        let preferredProvider = preferredProviderRawValue.flatMap(PreferredProvider.init(rawValue:))

        if preferredProvider == .chatterbox {
            let chatterboxBaseURL = AppBundleConfiguration
                .stringValue(forKey: "ChatterboxTTSServerURL")
                ?? "http://localhost:8004"
            print("🔊 TTS: using Chatterbox (local) at \(chatterboxBaseURL)")
            return LocalChatterboxTTSClient(baseURL: chatterboxBaseURL)
        }

        print("🔊 TTS: using ElevenLabs")
        return ElevenLabsTTSClient(proxyURL: elevenLabsProxyURL)
    }
}
