//
//  AppleSpeechTranscriptionProvider.swift
//  leanring-buddy
//
//  On-device transcription through Apple's Speech framework. It is the
//  fallback for Parakeet and the engine when `VoiceTranscriptionProvider`
//  is set to `apple`.
//

import AVFoundation
import Foundation
import Speech

struct AppleSpeechTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

final class AppleSpeechTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Apple Speech"
    let requiresSpeechRecognitionPermission = true
    let isConfigured = true
    let unavailableExplanation: String? = nil

    func startStreamingSession(
        keyterms: [String],
        localeIdentifier: String?,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard let recognizer = Self.firstAvailableRecognizer(preferring: localeIdentifier) else {
            throw AppleSpeechTranscriptionProviderError(message: "dictation is not available on this mac.")
        }

        return try AppleSpeechTranscriptionSession(
            speechRecognizer: recognizer,
            keyterms: keyterms,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }

    /// Tries the user's chosen language, then the system language, then US
    /// English, and finally whatever recogniser the system will hand out.
    private static func firstAvailableRecognizer(preferring chosenLocaleIdentifier: String?) -> SFSpeechRecognizer? {
        let chosenLocale = chosenLocaleIdentifier.map { Locale(identifier: $0) }
        let candidateLocales = [chosenLocale, .autoupdatingCurrent, Locale(identifier: "en-US")]
            .compactMap { $0 }

        for candidateLocale in candidateLocales {
            if let recognizer = SFSpeechRecognizer(locale: candidateLocale) {
                return recognizer
            }
        }
        return SFSpeechRecognizer()
    }
}

private final class AppleSpeechTranscriptionSession: NSObject, BuddyStreamingTranscriptionSession {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 1.8

    private let audioRequest = SFSpeechAudioBufferRecognitionRequest()
    private var recognitionTask: SFSpeechRecognitionTask?

    private let reportPartialTranscript: (String) -> Void
    private let reportFinalTranscript: (String) -> Void
    private let reportError: (Error) -> Void

    private var mostRecentText = ""
    private var finalTranscriptWasRequested = false
    private var finalTranscriptWasDelivered = false

    init(
        speechRecognizer: SFSpeechRecognizer,
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) throws {
        reportPartialTranscript = onTranscriptUpdate
        reportFinalTranscript = onFinalTranscriptReady
        reportError = onError

        super.init()

        audioRequest.shouldReportPartialResults = true
        audioRequest.taskHint = .dictation
        audioRequest.addsPunctuation = true

        // The user's dictionary words and the built-in keyterms nudge recognition
        // toward the right spelling of names and jargon.
        if !keyterms.isEmpty {
            audioRequest.contextualStrings = keyterms
        }

        // Keep audio on the Mac whenever the recogniser can do so.
        audioRequest.requiresOnDeviceRecognition = speechRecognizer.supportsOnDeviceRecognition

        recognitionTask = speechRecognizer.recognitionTask(with: audioRequest) { [weak self] result, error in
            self?.handle(result: result, error: error)
        }
    }

    deinit {
        cancel()
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard !finalTranscriptWasRequested else { return }
        audioRequest.append(audioBuffer)
    }

    func requestFinalTranscript() {
        guard !finalTranscriptWasRequested else { return }
        finalTranscriptWasRequested = true
        audioRequest.endAudio()
    }

    func cancel() {
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            mostRecentText = result.bestTranscription.formattedString
            reportPartialTranscript(mostRecentText)

            if result.isFinal {
                deliverFinalTranscriptOnce(mostRecentText)
                return
            }
        }

        guard let error else { return }

        // Speech sometimes ends with an error after the user has already stopped;
        // if there is text to show, that still counts as success.
        let hasUsableText = !mostRecentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if finalTranscriptWasRequested && hasUsableText {
            deliverFinalTranscriptOnce(mostRecentText)
        } else {
            reportError(error)
        }
    }

    private func deliverFinalTranscriptOnce(_ transcriptText: String) {
        guard !finalTranscriptWasDelivered else { return }
        finalTranscriptWasDelivered = true
        reportFinalTranscript(transcriptText)
    }
}
