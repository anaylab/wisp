//
//  BuddyTranscriptionProvider.swift
//  leanring-buddy
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

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

    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let provider = resolveProvider()
        print("🎙️ Transcription: using \(provider.displayName)")
        return provider
    }

    /// Whether Info.plist's `VoiceTranscriptionProvider` selects Parakeet.
    /// `apple` keeps Apple Speech only; anything else (the shipped
    /// `fluidaudio`, or the key missing) means Parakeet with Apple Speech as
    /// its automatic fallback.
    static var isParakeetConfigured: Bool {
        let configuredProviderName = AppBundleConfiguration
            .stringValue(forKey: "VoiceTranscriptionProvider")?
            .lowercased()
        return configuredProviderName != "apple"
    }

    private static func resolveProvider() -> any BuddyTranscriptionProvider {
        if isParakeetConfigured {
            return ParakeetTranscriptionProvider()
        }
        return AppleSpeechTranscriptionProvider()
    }
}
