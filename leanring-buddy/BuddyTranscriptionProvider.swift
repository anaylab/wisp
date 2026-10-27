//
//  BuddyTranscriptionProvider.swift
//  leanring-buddy
//
//  The seam between push-to-talk and whichever engine turns microphone audio
//  into text, plus the choice of engine.
//

import AVFoundation
import Foundation

/// One in-flight recognition: audio goes in, partial and final text come out
/// through the callbacks the session was started with.
protocol BuddyStreamingTranscriptionSession: AnyObject {
    /// How long the caller waits after asking for the final transcript before
    /// settling for the last partial it saw.
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)

    /// Signals that the user stopped talking; the final text follows via the callback.
    func requestFinalTranscript()

    /// Abandons the session without producing a final transcript.
    func cancel()
}

/// A speech-to-text engine.
protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    func startStreamingSession(
        keyterms: [String],
        localeIdentifier: String?,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}

enum BuddyTranscriptionProviderFactory {

    /// Whether the `VoiceTranscriptionProvider` Info.plist value selects Parakeet.
    /// Only the value `apple` opts out; `fluidaudio` (the shipped value) or a
    /// missing key both mean Parakeet, with Apple Speech as its fallback.
    static var isParakeetConfigured: Bool {
        let configuredValue = AppBundleConfiguration.stringValue(forKey: "VoiceTranscriptionProvider")
        return configuredValue?.lowercased() != "apple"
    }

    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let chosenProvider: any BuddyTranscriptionProvider = isParakeetConfigured
            ? ParakeetTranscriptionProvider()
            : AppleSpeechTranscriptionProvider()

        print("🎙️ Transcription: using \(chosenProvider.displayName)")
        return chosenProvider
    }
}
