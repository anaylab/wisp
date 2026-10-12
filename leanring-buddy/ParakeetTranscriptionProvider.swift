//
//  ParakeetTranscriptionProvider.swift
//  leanring-buddy
//
//  Push-to-talk transcription with FluidAudio's Parakeet TDT v3, on the Apple
//  Neural Engine, with Apple Speech as the automatic fallback.
//
//  Parakeet is a batch model, so live text is produced by re-decoding the
//  audio captured so far every half second or so while the hotkey is held
//  (each decode of a few seconds of speech takes tens of milliseconds), and
//  the final transcript is one more decode of the whole clip on release.
//  Recording itself is untouched — `BuddyDictationManager` starts the mic on
//  key press exactly as before and simply hands the buffers to this session.
//
//  The fallback is per session and automatic: until the Parakeet model has
//  downloaded and loaded (first launch), if it failed to load, or when the
//  chosen dictation language isn't one Parakeet knows, the session is an
//  ordinary Apple Speech session and the reason is logged.
//
//  The custom dictionary becomes FluidAudio vocabulary boosting (CTC keyword
//  spotting + rescoring) on the final transcript.
//

import AVFoundation
import Foundation

final class ParakeetTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Parakeet (on-device), Apple Speech fallback"
    /// Still true: the Apple Speech fallback needs speech-recognition
    /// permission, and the fallback is what runs on the very first launch
    /// while the model downloads.
    let requiresSpeechRecognitionPermission = true
    let isConfigured = true
    let unavailableExplanation: String? = nil

    private let appleSpeechFallbackProvider = AppleSpeechTranscriptionProvider()

    init() {
        // Normally already started at launch; this covers any other caller.
        FluidAudioSpeechModels.shared.preloadSpeechRecognitionModelsInBackground()
    }

    func startStreamingSession(
        keyterms: [String],
        localeIdentifier: String?,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        let dictationLanguageCode = Self.dictationLanguageCode(forLocaleIdentifier: localeIdentifier)
        let speechModels = FluidAudioSpeechModels.shared

        let reasonToUseAppleSpeech: String?
        if !ParakeetTranscriptionEngine.supportedLanguageCodes.contains(dictationLanguageCode) {
            reasonToUseAppleSpeech = "Parakeet doesn't support the dictation language '\(dictationLanguageCode)'"
        } else if speechModels.parakeetTranscriptionEngine == nil {
            reasonToUseAppleSpeech = "Parakeet is \(speechModels.speechRecognitionLoadState.shortStatusDescription)"
        } else {
            reasonToUseAppleSpeech = nil
        }

        guard reasonToUseAppleSpeech == nil, let parakeetEngine = speechModels.parakeetTranscriptionEngine else {
            print("🎙️ Transcription: using Apple Speech for this session — \(reasonToUseAppleSpeech ?? "Parakeet unavailable")")
            return try await appleSpeechFallbackProvider.startStreamingSession(
                keyterms: keyterms,
                localeIdentifier: localeIdentifier,
                onTranscriptUpdate: onTranscriptUpdate,
                onFinalTranscriptReady: onFinalTranscriptReady,
                onError: onError
            )
        }

        // Boosting needs a second (CTC) model, so it is switched on by the
        // user having a custom dictionary; it then boosts the dictionary along
        // with the app's built-in keyterms ("Wisp", "Xcode", …) that the
        // dictation manager folds into `keyterms`.
        let vocabularyBoostingTerms = DictationSettingsStore.shared.customDictionaryWords.isEmpty
            ? []
            : keyterms
        // Not awaited: the mic starts only after this function returns, so
        // nothing here may wait on the engine (it could be mid-decode).
        Task { await parakeetEngine.prepareVocabularyBoosting(forTerms: vocabularyBoostingTerms) }

        return ParakeetStreamingTranscriptionSession(
            parakeetEngine: parakeetEngine,
            languageCode: dictationLanguageCode,
            vocabularyBoostingTerms: vocabularyBoostingTerms,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }

    /// The ISO 639-1 code for the chosen dictation locale, or for the Mac's
    /// own language when dictation is on Automatic (matching how the Apple
    /// recogniser picks its locale).
    private static func dictationLanguageCode(forLocaleIdentifier localeIdentifier: String?) -> String {
        let dictationLocale = localeIdentifier.map { Locale(identifier: $0) } ?? Locale.autoupdatingCurrent
        return dictationLocale.language.languageCode?.identifier.lowercased() ?? "en"
    }
}

/// The mic buffers of one push-to-talk hold, kept at the input's native rate.
///
/// Appended from the audio engine's realtime tap thread and read from the
/// session's decode tasks, so it's guarded by a lock rather than an actor
/// (the tap must never wait on a task hop). Resampling is left to decode time,
/// where one pass over the whole clip avoids per-buffer edge artefacts.
nonisolated private final class CapturedMicrophoneAudio: @unchecked Sendable {
    private let lock = NSLock()
    private var monoSamplesAtCaptureRate: [Float] = []
    private var captureSampleRate: Double = 0

    func appendMonoSamples(from audioBuffer: AVAudioPCMBuffer) {
        guard let channelData = audioBuffer.floatChannelData else { return }
        let frameCount = Int(audioBuffer.frameLength)
        let channelCount = Int(audioBuffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return }

        // Downmix by averaging channels; most Mac mics are mono anyway.
        var monoFrames = [Float](repeating: 0, count: frameCount)
        for channelIndex in 0..<channelCount {
            let channelSamples = channelData[channelIndex]
            for frameIndex in 0..<frameCount {
                monoFrames[frameIndex] += channelSamples[frameIndex]
            }
        }
        if channelCount > 1 {
            let channelCountAsFloat = Float(channelCount)
            for frameIndex in 0..<frameCount {
                monoFrames[frameIndex] /= channelCountAsFloat
            }
        }

        lock.lock()
        captureSampleRate = audioBuffer.format.sampleRate
        monoSamplesAtCaptureRate.append(contentsOf: monoFrames)
        lock.unlock()
    }

    func snapshot() -> (monoSamples: [Float], sampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (monoSamplesAtCaptureRate, captureSampleRate)
    }
}

private final class ParakeetStreamingTranscriptionSession: BuddyStreamingTranscriptionSession {
    /// How long the dictation manager waits for the final transcript before
    /// settling for the latest live text. The final decode normally lands in a
    /// fraction of a second; this is only a safety net for a stuck decode.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 3.0

    /// The fastest the live text refreshes. Long holds slow down on their own
    /// (see `waitBeforeNextPartialDecodeSeconds`).
    private static let minimumSecondsBetweenPartialDecodes: TimeInterval = 0.45
    /// Don't spend a decode on less new audio than this.
    private static let minimumNewAudioSecondsForPartialDecode: Double = 0.25

    private let parakeetEngine: ParakeetTranscriptionEngine
    private let languageCode: String
    private let vocabularyBoostingTerms: [String]
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let capturedMicrophoneAudio = CapturedMicrophoneAudio()
    private var partialDecodeLoopTask: Task<Void, Never>?
    private var finalDecodeTask: Task<Void, Never>?
    private var latestPartialTranscriptText = ""
    private var hasRequestedFinalTranscript = false
    private var isCancelled = false

    init(
        parakeetEngine: ParakeetTranscriptionEngine,
        languageCode: String,
        vocabularyBoostingTerms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.parakeetEngine = parakeetEngine
        self.languageCode = languageCode
        self.vocabularyBoostingTerms = vocabularyBoostingTerms
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError

        print("🎙️ Transcription: using Parakeet for this session (language \(languageCode))")
        startPartialDecodeLoop()
    }

    /// Called on the audio engine's tap thread. Only touches the lock-guarded
    /// buffer, never the session's main-actor state.
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        capturedMicrophoneAudio.appendMonoSamples(from: audioBuffer)
    }

    func requestFinalTranscript() {
        guard !hasRequestedFinalTranscript, !isCancelled else { return }
        hasRequestedFinalTranscript = true
        partialDecodeLoopTask?.cancel()
        partialDecodeLoopTask = nil

        let releaseDate = Date()
        let capturedAudio = capturedMicrophoneAudio.snapshot()
        let parakeetEngine = parakeetEngine
        let languageCode = languageCode
        let vocabularyBoostingTerms = vocabularyBoostingTerms

        finalDecodeTask = Task { [weak self] in
            guard !capturedAudio.monoSamples.isEmpty, capturedAudio.sampleRate > 0 else {
                self?.deliverFinalTranscript("")
                return
            }

            do {
                let finalTranscriptText = try await parakeetEngine.transcribe(
                    monoSamples: capturedAudio.monoSamples,
                    sampleRate: capturedAudio.sampleRate,
                    languageCode: languageCode,
                    vocabularyBoostingTerms: vocabularyBoostingTerms
                )
                let releaseToFinalMilliseconds = Int(Date().timeIntervalSince(releaseDate) * 1000)
                let capturedAudioSeconds = Double(capturedAudio.monoSamples.count) / capturedAudio.sampleRate
                print(
                    "🎙️ Parakeet: final transcript \(releaseToFinalMilliseconds) ms after release "
                        + "(\(String(format: "%.1f", capturedAudioSeconds))s of audio"
                        + (vocabularyBoostingTerms.isEmpty ? "" : ", dictionary boosting on") + ")"
                )
                self?.deliverFinalTranscript(finalTranscriptText)
            } catch {
                guard let self, !self.isCancelled else { return }
                print("⚠️ Parakeet: final decode failed — \(error)")
                // Live text already shown is better than nothing; only
                // surface an error when there's nothing to hand back.
                if !self.latestPartialTranscriptText.isEmpty {
                    self.deliverFinalTranscript(self.latestPartialTranscriptText)
                } else {
                    self.onError(error)
                }
            }
        }
    }

    func cancel() {
        isCancelled = true
        partialDecodeLoopTask?.cancel()
        partialDecodeLoopTask = nil
        finalDecodeTask?.cancel()
        finalDecodeTask = nil
    }

    private func deliverFinalTranscript(_ finalTranscriptText: String) {
        guard !isCancelled else { return }
        onTranscriptUpdate(finalTranscriptText)
        onFinalTranscriptReady(finalTranscriptText)
    }

    /// Re-decodes everything captured so far, on a cadence that backs off as
    /// the clip grows, so the live text keeps up without the Neural Engine
    /// running flat out during a long hold.
    private func startPartialDecodeLoop() {
        partialDecodeLoopTask = Task { [weak self] in
            var waitBeforeNextPartialDecodeSeconds = Self.minimumSecondsBetweenPartialDecodes
            var capturedSampleCountAtLastDecode = 0

            while true {
                try? await Task.sleep(for: .seconds(waitBeforeNextPartialDecodeSeconds))
                guard let self, !Task.isCancelled, !self.hasRequestedFinalTranscript, !self.isCancelled else { return }

                let capturedAudio = self.capturedMicrophoneAudio.snapshot()
                guard capturedAudio.sampleRate > 0 else { continue }
                let newAudioSeconds = Double(capturedAudio.monoSamples.count - capturedSampleCountAtLastDecode)
                    / capturedAudio.sampleRate
                guard newAudioSeconds >= Self.minimumNewAudioSecondsForPartialDecode else { continue }
                capturedSampleCountAtLastDecode = capturedAudio.monoSamples.count

                let decodeStartDate = Date()
                do {
                    let partialTranscriptText = try await self.parakeetEngine.transcribe(
                        monoSamples: capturedAudio.monoSamples,
                        sampleRate: capturedAudio.sampleRate,
                        languageCode: self.languageCode,
                        vocabularyBoostingTerms: []
                    )
                    // The release may have landed while this decode ran; the
                    // final transcript owns the text from then on.
                    guard !Task.isCancelled, !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
                    self.latestPartialTranscriptText = partialTranscriptText
                    self.onTranscriptUpdate(partialTranscriptText)
                } catch {
                    // A failed partial is not worth interrupting the user
                    // over; the final decode will try again with all the audio.
                    print("⚠️ Parakeet: live decode failed — \(error)")
                }

                let decodeDurationSeconds = Date().timeIntervalSince(decodeStartDate)
                waitBeforeNextPartialDecodeSeconds = max(
                    Self.minimumSecondsBetweenPartialDecodes,
                    decodeDurationSeconds * 3
                )
            }
        }
    }
}
