//
//  FluidAudioSpeechModels.swift
//  leanring-buddy
//
//  The on-device speech models Wisp runs through FluidAudio (CoreML on the
//  Apple Neural Engine): Parakeet TDT v3 for speech-to-text and Kokoro 82M for
//  text-to-speech.
//
//  Inference never leaves this Mac. The only network use is the one-time
//  download of the model files from HuggingFace the first time they are
//  needed; after that they load from FluidAudio's on-disk cache
//  (`~/Library/Application Support/FluidAudio/Models/` for Parakeet,
//  `~/.cache/fluidaudio/Models/` for Kokoro).
//
//  Why one shared owner: each model costs resident memory, and this Mac also
//  keeps a local LLM resident. Every model is loaded exactly once, here, and
//  the transcription provider and the voice client borrow the loaded engines
//  rather than each loading their own copy.
//
//  Why loading happens in the background: the first download is several
//  hundred megabytes and the first ANE compile takes tens of seconds. Launch
//  must not wait for either, so the providers fall back to Apple's speech
//  (recogniser and synthesizer) until the matching engine below is ready.
//

import AVFoundation
import Combine
import Darwin
import FluidAudio
import Foundation

/// Where one of the FluidAudio models is in its life, for the "What's running"
/// readout and for the fallback decision.
enum FluidAudioModelLoadState: Equatable {
    case notStarted
    /// Downloading from HuggingFace (first use only) or compiling for the ANE.
    /// The fraction is nil when the library doesn't report progress.
    case downloading(fractionCompleted: Double?)
    case loading
    case ready
    case failed(reason: String)

    var isReady: Bool { self == .ready }

    /// A few words for the readout, e.g. "downloading 42%".
    var shortStatusDescription: String {
        switch self {
        case .notStarted:
            return "waiting to load"
        case .downloading(let fractionCompleted):
            if let fractionCompleted {
                return "downloading \(Int((fractionCompleted * 100).rounded()))%"
            }
            return "downloading"
        case .loading:
            return "loading"
        case .ready:
            return "ready"
        case .failed:
            return "failed to load"
        }
    }
}

@MainActor
final class FluidAudioSpeechModels: ObservableObject {
    static let shared = FluidAudioSpeechModels()

    @Published private(set) var speechRecognitionLoadState: FluidAudioModelLoadState = .notStarted
    @Published private(set) var speechSynthesisLoadState: FluidAudioModelLoadState = .notStarted

    /// Set once Parakeet is loaded and warmed; nil until then (and forever if
    /// loading failed), which is the transcription provider's cue to use Apple
    /// Speech instead.
    private(set) var parakeetTranscriptionEngine: ParakeetTranscriptionEngine?

    /// Set once Kokoro is loaded and warmed; nil means "use the Apple voice".
    private(set) var kokoroSynthesisEngine: KokoroSynthesisEngine?

    private var speechRecognitionLoadTask: Task<Void, Never>?
    private var speechSynthesisLoadTask: Task<Void, Never>?

    private init() {}

    /// Starts loading whichever FluidAudio models Info.plist selects. Called
    /// once at launch; returns immediately.
    func preloadConfiguredModelsInBackground() {
        if BuddyTranscriptionProviderFactory.isParakeetConfigured {
            preloadSpeechRecognitionModelsInBackground()
        }
        if BuddyTTSProviderFactory.isKokoroConfigured {
            preloadSpeechSynthesisModelsInBackground()
        }
    }

    /// Downloads (first use only), loads and warms Parakeet. Idempotent, and a
    /// failure is logged and leaves Apple Speech in charge — it never throws
    /// to the caller.
    func preloadSpeechRecognitionModelsInBackground() {
        guard speechRecognitionLoadTask == nil else { return }

        speechRecognitionLoadState = .downloading(fractionCompleted: nil)
        speechRecognitionLoadTask = Task { [weak self] in
            let loadStartDate = Date()
            let footprintBeforeLoadMegabytes = ProcessMemoryFootprint.currentMegabytes()
            print("🎙️ Parakeet: preparing on-device speech recognition (app footprint \(footprintBeforeLoadMegabytes) MB)")

            do {
                let loadedEngine = try await Task.detached(priority: .utility) {
                    try await ParakeetTranscriptionEngine.downloadLoadAndWarm(
                        reportDownloadProgress: { downloadProgress in
                            Task { @MainActor in
                                FluidAudioSpeechModels.shared.updateSpeechRecognitionDownloadProgress(
                                    downloadProgress.fractionCompleted
                                )
                            }
                        }
                    )
                }.value

                let footprintAfterLoadMegabytes = ProcessMemoryFootprint.currentMegabytes()
                print(
                    "🎙️ Parakeet: ready in \(String(format: "%.1f", Date().timeIntervalSince(loadStartDate)))s — "
                        + "app footprint \(footprintBeforeLoadMegabytes) → \(footprintAfterLoadMegabytes) MB "
                        + "(+\(footprintAfterLoadMegabytes - footprintBeforeLoadMegabytes) MB)"
                )
                self?.parakeetTranscriptionEngine = loadedEngine
                self?.speechRecognitionLoadState = .ready
            } catch {
                print("⚠️ Parakeet: failed to load, dictation stays on Apple Speech — \(error)")
                self?.speechRecognitionLoadState = .failed(reason: error.localizedDescription)
            }
        }
    }

    /// Downloads (first use only), loads and warms Kokoro. Waits for Parakeet
    /// to finish first so the two first-run downloads and ANE compiles don't
    /// compete — dictation is used more than speech, so it goes first.
    func preloadSpeechSynthesisModelsInBackground() {
        guard speechSynthesisLoadTask == nil else { return }

        speechSynthesisLoadState = .downloading(fractionCompleted: nil)
        let speechRecognitionLoadTaskToWaitFor = speechRecognitionLoadTask
        speechSynthesisLoadTask = Task { [weak self] in
            await speechRecognitionLoadTaskToWaitFor?.value

            let loadStartDate = Date()
            let footprintBeforeLoadMegabytes = ProcessMemoryFootprint.currentMegabytes()
            print("🔊 Kokoro: preparing on-device voice (app footprint \(footprintBeforeLoadMegabytes) MB)")

            do {
                let loadedEngine = try await Task.detached(priority: .utility) {
                    try await KokoroSynthesisEngine.downloadLoadAndWarm()
                }.value

                let footprintAfterLoadMegabytes = ProcessMemoryFootprint.currentMegabytes()
                print(
                    "🔊 Kokoro: ready (voice \(KokoroSynthesisEngine.voiceIdentifier)) in "
                        + "\(String(format: "%.1f", Date().timeIntervalSince(loadStartDate)))s — "
                        + "app footprint \(footprintBeforeLoadMegabytes) → \(footprintAfterLoadMegabytes) MB "
                        + "(+\(footprintAfterLoadMegabytes - footprintBeforeLoadMegabytes) MB)"
                )
                self?.kokoroSynthesisEngine = loadedEngine
                self?.speechSynthesisLoadState = .ready
            } catch {
                print("⚠️ Kokoro: failed to load, replies stay on the Apple voice — \(error)")
                self?.speechSynthesisLoadState = .failed(reason: error.localizedDescription)
            }
        }
    }

    private func updateSpeechRecognitionDownloadProgress(_ fractionCompleted: Double) {
        // Progress callbacks can trail the completion hop; never move a
        // finished state back to "downloading".
        guard case .downloading(let previousFractionCompleted) = speechRecognitionLoadState else { return }
        // Publish whole-percent steps only, so a fast download doesn't
        // re-render the readout hundreds of times.
        let previousWholePercent = previousFractionCompleted.map { Int($0 * 100) } ?? -1
        guard Int(fractionCompleted * 100) != previousWholePercent else { return }
        speechRecognitionLoadState = .downloading(fractionCompleted: fractionCompleted)
    }
}

// MARK: - Parakeet (speech-to-text)

/// Parakeet TDT 0.6B v3 behind one serial queue.
///
/// v3 rather than the English-only v2 because Wisp's dictation language is
/// user-selectable and v3 covers 25 European languages with strong English;
/// running both would double the resident memory. The int8 encoder is
/// FluidAudio's default and the smallest.
///
/// Decodes are serialised on purpose: `AsrManager` is an actor, but its
/// transcribe call suspends internally, so two overlapping calls (a live
/// partial and the final transcript) could interleave on its shared model
/// state. Each call here waits for the one before it.
actor ParakeetTranscriptionEngine {
    /// The 25 languages Parakeet TDT v3 was trained on, as ISO 639-1 codes.
    /// A dictation language outside this set falls back to Apple Speech.
    nonisolated static let supportedLanguageCodes: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
        "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
    ]

    /// Parakeet wants 16 kHz mono Float32.
    nonisolated static let modelSampleRate: Double = 16_000

    /// Shorter clips are rejected by FluidAudio (it needs 0.3 s); a quick tap
    /// of the hotkey is padded with silence instead of failing.
    private static let minimumDecodableSampleCount = 16_000

    private let asrManager: AsrManager
    private let audioConverter = AudioConverter()
    private var tailOfSerialDecodeQueue: Task<Void, Never>?

    /// The CTC keyword-spotting model behind vocabulary boosting, loaded the
    /// first time the user's dictionary is non-empty (it is a second ~100 MB
    /// download and ~65 MB resident that nobody without a dictionary needs).
    private var vocabularyBoostingCtcModelsLoadTask: Task<CtcModels, Error>?
    private var vocabularyBoostingSessionForTerms: (terms: [String], session: VocabularyBoostingSession)?
    private var vocabularyBoostingPreparation: (terms: [String], task: Task<Void, Never>)?

    private init(asrManager: AsrManager) {
        self.asrManager = asrManager
    }

    static func downloadLoadAndWarm(
        reportDownloadProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> ParakeetTranscriptionEngine {
        let loadedModels = try await AsrModels.downloadAndLoad(
            version: .v3,
            progressHandler: reportDownloadProgress
        )
        let asrManager = AsrManager(config: .default, models: loadedModels)
        let engine = ParakeetTranscriptionEngine(asrManager: asrManager)

        // The first prediction pays the ANE's one-off specialisation cost.
        // Paying it here keeps it out of the user's first push-to-talk.
        let oneSecondOfSilence = [Float](repeating: 0, count: Int(modelSampleRate))
        _ = try await engine.transcribe(
            monoSamples: oneSecondOfSilence,
            sampleRate: modelSampleRate,
            languageCode: nil,
            vocabularyBoostingTerms: []
        )
        return engine
    }

    /// Transcribes mono samples captured at `sampleRate` (resampled to 16 kHz
    /// here, off the main actor). Vocabulary boosting runs only when terms are
    /// given — the final transcript, not the live partials, since it costs a
    /// second encoder pass — and only once `prepareVocabularyBoosting` has
    /// finished building it.
    func transcribe(
        monoSamples: [Float],
        sampleRate: Double,
        languageCode: String?,
        vocabularyBoostingTerms: [String]
    ) async throws -> String {
        let previousDecode = tailOfSerialDecodeQueue
        let thisDecode = Task<String, Error> {
            _ = await previousDecode?.value
            return try await self.decodeImmediately(
                monoSamples: monoSamples,
                sampleRate: sampleRate,
                languageCode: languageCode,
                vocabularyBoostingTerms: vocabularyBoostingTerms
            )
        }
        tailOfSerialDecodeQueue = Task { _ = try? await thisDecode.value }
        return try await thisDecode.value
    }

    private func decodeImmediately(
        monoSamples: [Float],
        sampleRate: Double,
        languageCode: String?,
        vocabularyBoostingTerms: [String]
    ) async throws -> String {
        var samplesAtModelRate = sampleRate == Self.modelSampleRate
            ? monoSamples
            : try audioConverter.resample(monoSamples, from: sampleRate)

        if samplesAtModelRate.count < Self.minimumDecodableSampleCount {
            samplesAtModelRate.append(
                contentsOf: [Float](repeating: 0, count: Self.minimumDecodableSampleCount - samplesAtModelRate.count)
            )
        }

        let languageHint = languageCode.flatMap { Language(rawValue: $0) }
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let recognitionResult = try await asrManager.transcribe(
            samplesAtModelRate,
            decoderState: &decoderState,
            language: languageHint
        )

        var transcriptText = recognitionResult.text
        if !vocabularyBoostingTerms.isEmpty,
           let tokenTimings = recognitionResult.tokenTimings,
           let boostingSession = readyVocabularyBoostingSession(forTerms: vocabularyBoostingTerms),
           let rescoredTranscript = await boostingSession.rescore(
               text: transcriptText,
               tokenTimings: tokenTimings,
               audioSamples: samplesAtModelRate
           ),
           rescoredTranscript.wasModified {
            print("🎙️ Parakeet: dictionary boosting corrected the transcript")
            transcriptText = rescoredTranscript.text
        }

        return transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Starts building the boosting session for these terms in the background
    /// if it isn't built yet. Called when a dictation session starts, so that
    /// by the time the hotkey is released the session is usually ready — the
    /// final transcript never waits for the CTC model to download or load.
    func prepareVocabularyBoosting(forTerms vocabularyBoostingTerms: [String]) {
        guard !vocabularyBoostingTerms.isEmpty else { return }
        if let cachedSession = vocabularyBoostingSessionForTerms, cachedSession.terms == vocabularyBoostingTerms {
            return
        }
        if let preparation = vocabularyBoostingPreparation, preparation.terms == vocabularyBoostingTerms {
            return
        }

        let preparationTask = Task {
            await self.buildVocabularyBoostingSession(forTerms: vocabularyBoostingTerms)
        }
        vocabularyBoostingPreparation = (vocabularyBoostingTerms, preparationTask)
    }

    /// The boosting session for exactly these terms if it's already built,
    /// otherwise nil — the transcript then goes out unboosted rather than
    /// waiting (and preparation is started for next time).
    private func readyVocabularyBoostingSession(forTerms vocabularyBoostingTerms: [String]) -> VocabularyBoostingSession? {
        if let cachedSession = vocabularyBoostingSessionForTerms, cachedSession.terms == vocabularyBoostingTerms {
            return cachedSession.session
        }
        print("🎙️ Parakeet: vocabulary boosting not ready yet, this transcript goes out without it")
        prepareVocabularyBoosting(forTerms: vocabularyBoostingTerms)
        return nil
    }

    /// Builds a boosting session for exactly these terms. Leaves boosting off
    /// (plain transcripts) if the CTC model can't be loaded — boosting must
    /// never break dictation.
    private func buildVocabularyBoostingSession(forTerms vocabularyBoostingTerms: [String]) async {
        defer {
            if vocabularyBoostingPreparation?.terms == vocabularyBoostingTerms {
                vocabularyBoostingPreparation = nil
            }
        }

        do {
            if vocabularyBoostingCtcModelsLoadTask == nil {
                vocabularyBoostingCtcModelsLoadTask = Task {
                    print("🎙️ Parakeet: loading the vocabulary-boosting model for the custom dictionary")
                    return try await CtcModels.downloadAndLoad(variant: .ctc110m)
                }
            }
            guard let ctcModelsLoadTask = vocabularyBoostingCtcModelsLoadTask else { return }
            let ctcModels = try await ctcModelsLoadTask.value

            let ctcTokenizer = try await CtcTokenizer.load(
                from: CtcModels.defaultCacheDirectory(for: .ctc110m)
            )
            let tokenizedTerms = vocabularyBoostingTerms.compactMap { term -> CustomVocabularyTerm? in
                let ctcTokenIds = ctcTokenizer.encode(term)
                guard !ctcTokenIds.isEmpty else { return nil }
                return CustomVocabularyTerm(text: term, ctcTokenIds: ctcTokenIds)
            }
            guard !tokenizedTerms.isEmpty else { return }

            // FluidAudio's documented "short vocabulary" settings rather than
            // its defaults. A personal dictionary is a handful of short names
            // in ordinary dictated English, which is exactly where the
            // defaults over-fire: measured here, they turned "Ask Kakoro and
            // Parakeet to read the anthropic paper, then open Xcode" into
            // "Ask Kokoro Parakeet Parakeet Parakeet Xcode". Missing a
            // spelling is far better than rewriting what the user said.
            let conservativeRescorerConfig = VocabularyRescorer.Config(
                shortTermCbwTaperPivot: 5,
                spotterRescueMinSimilarity: 0.30,
                spotterRescueMultiWordMinSimilarity: 0.50,
                spotterRescueEnabled: false
            )
            let boostingSession = try await VocabularyBoostingSession(
                vocabulary: CustomVocabularyContext(terms: tokenizedTerms),
                ctcModels: ctcModels,
                config: conservativeRescorerConfig
            )
            vocabularyBoostingSessionForTerms = (vocabularyBoostingTerms, boostingSession)
            print("🎙️ Parakeet: vocabulary boosting ready for \(tokenizedTerms.count) terms")
        } catch {
            print("⚠️ Parakeet: vocabulary boosting unavailable, transcribing without it — \(error)")
            // Let a later session retry (e.g. after a network blip mid-download).
            vocabularyBoostingCtcModelsLoadTask = nil
        }
    }
}

// MARK: - Kokoro (text-to-speech)

/// One clip of synthesised speech: mono Float32 samples.
struct KokoroSynthesizedClip: Sendable {
    let monoSamples: [Float]
    let sampleRate: Double
}

/// Kokoro 82M (FluidAudio's ANE-resident 7-stage chain) behind one serial
/// queue, for the same reentrancy reason as `ParakeetTranscriptionEngine`: a
/// reply interrupted and replaced must not interleave two syntheses inside
/// the manager.
actor KokoroSynthesisEngine {
    /// `af_heart`: Kokoro's flagship American English voice — warm, natural
    /// and the best-rated of its voices, and the one this conversion ships
    /// with by default (others would be a further download).
    nonisolated static let voiceIdentifier = "af_heart"

    private let kokoroManager: KokoroAneManager
    private var tailOfSerialSynthesisQueue: Task<Void, Never>?

    private init(kokoroManager: KokoroAneManager) {
        self.kokoroManager = kokoroManager
    }

    static func downloadLoadAndWarm() async throws -> KokoroSynthesisEngine {
        let kokoroManager = KokoroAneManager(defaultVoice: voiceIdentifier)
        try await kokoroManager.initialize()
        let engine = KokoroSynthesisEngine(kokoroManager: kokoroManager)

        // The first-ever run compiles every stage for the ANE (~20 s); doing
        // it here keeps that wait out of the first spoken reply.
        _ = try await engine.synthesize(text: "Hi.")
        return engine
    }

    func synthesize(text: String) async throws -> KokoroSynthesizedClip {
        let previousSynthesis = tailOfSerialSynthesisQueue
        let thisSynthesis = Task<KokoroSynthesizedClip, Error> {
            _ = await previousSynthesis?.value
            let synthesisResult = try await self.kokoroManager.synthesizeDetailed(
                text: text,
                voice: Self.voiceIdentifier
            )
            return KokoroSynthesizedClip(
                monoSamples: synthesisResult.samples,
                sampleRate: Double(synthesisResult.sampleRate)
            )
        }
        tailOfSerialSynthesisQueue = Task { _ = try? await thisSynthesis.value }
        return try await thisSynthesis.value
    }
}

// MARK: - Memory

/// This process's physical footprint — the number Activity Monitor shows as
/// "Memory" — used to log what each model costs once it's loaded.
nonisolated enum ProcessMemoryFootprint {
    static func currentMegabytes() -> Int {
        var vmInfo = task_vm_info_data_t()
        var vmInfoCount = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &vmInfo) { vmInfoPointer in
            vmInfoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmInfoCount)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPointer, &vmInfoCount)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(vmInfo.phys_footprint / 1_048_576)
    }
}
