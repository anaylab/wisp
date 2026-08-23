//
//  FluidAudioTranscriptionProvider.swift
//  leanring-buddy
//
//  Local, on-device transcription provider backed by FluidAudio's Parakeet
//  CoreML models. Runs entirely on-device — no network calls, no API key.
//

import AVFoundation
import FluidAudio
import Foundation

struct FluidAudioTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

/// Actor-isolated cache for the shared AsrManager so concurrent session
/// starts during the (potentially slow, first-use) model download/load all
/// await the same in-flight load, without needing a lock from async code.
private actor FluidAudioModelLoader {
    static let shared = FluidAudioModelLoader()

    private var loadTask: Task<AsrManager, Error>?

    func sharedAsrManager() async throws -> AsrManager {
        if let existingTask = loadTask {
            return try await existingTask.value
        }

        let task = Task<AsrManager, Error> {
            print("🧠 FluidAudio: downloading/loading Parakeet models (first use may take a while)…")
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            print("🧠 FluidAudio: Parakeet models ready")
            return manager
        }
        loadTask = task
        return try await task.value
    }
}

final class FluidAudioTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Parakeet (local)"
    let requiresSpeechRecognitionPermission = false

    var isConfigured: Bool {
        // Local model — always "configured" in the sense that no API key is
        // required. First use may trigger a model download, surfaced via
        // unavailableExplanation while that's in flight.
        true
    }

    var unavailableExplanation: String? {
        nil
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        FluidAudioTranscriptionSession(
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }

    /// Loads (downloading on first use) and returns the shared AsrManager.
    /// Safe to call concurrently — all callers await the same load.
    static func sharedAsrManager() async throws -> AsrManager {
        try await FluidAudioModelLoader.shared.sharedAsrManager()
    }
}

private final class FluidAudioTranscriptionSession: BuddyStreamingTranscriptionSession {
    // Local inference is fast — no need for a long network-timeout fallback.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 3.0

    private static let targetSampleRate = 16_000

    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.learningbuddy.fluidaudio.transcription")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(
        targetSampleRate: Double(targetSampleRate)
    )

    private var bufferedPCM16AudioData = Data()
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false
    private var transcriptionTask: Task<Void, Never>?

    init(
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }

        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.bufferedPCM16AudioData.append(audioPCM16Data)
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = true

            let bufferedPCM16AudioData = self.bufferedPCM16AudioData
            self.transcriptionTask = Task { [weak self] in
                await self?.transcribeBufferedAudio(bufferedPCM16AudioData)
            }
        }
    }

    func cancel() {
        // Weak capture is required here: cancel() is also called from deinit,
        // and a strong self-capture in an escaping closure created during
        // deinit trips Swift's runtime protection against retaining an
        // object mid-deallocation, crashing with SIGABRT.
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.isCancelled = true
            self.bufferedPCM16AudioData.removeAll(keepingCapacity: false)
        }

        transcriptionTask?.cancel()
    }

    private func transcribeBufferedAudio(_ bufferedPCM16AudioData: Data) async {
        guard !Task.isCancelled else { return }

        let isEmptyOrCancelled = stateQueue.sync {
            isCancelled || bufferedPCM16AudioData.isEmpty
        }

        if isEmptyOrCancelled {
            print("🧠 FluidAudio: buffer was empty or cancelled at requestFinalTranscript time")
            deliverFinalTranscript("")
            return
        }

        do {
            let audioSamples = Self.pcm16DataToFloatSamples(bufferedPCM16AudioData)
            let peakAmplitude = audioSamples.map { abs($0) }.max() ?? 0
            print("🧠 FluidAudio: transcribing \(bufferedPCM16AudioData.count) bytes (\(audioSamples.count) samples, peak amplitude \(peakAmplitude))")
            let asrManager = try await FluidAudioTranscriptionProvider.sharedAsrManager()
            // Fresh decoder state per utterance — push-to-talk sessions are
            // independent one-shot transcriptions, not a continuous stream,
            // so there's no LSTM context to carry over between them.
            var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
            let result = try await asrManager.transcribe(audioSamples, decoderState: &decoderState)
            guard !stateQueue.sync(execute: { isCancelled }) else { return }

            print("🧠 FluidAudio: raw result text=\"\(result.text)\" confidence=\(result.confidence)")
            let transcriptText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !transcriptText.isEmpty {
                onTranscriptUpdate(transcriptText)
            }
            deliverFinalTranscript(transcriptText)
        } catch {
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            print("[FluidAudio Transcription] ❌ Inference failed: \(error.localizedDescription)")
            onError(error)
        }
    }

    /// Converts little-endian PCM16 mono audio data into normalized Float samples
    /// in [-1.0, 1.0], the format FluidAudio's ASR manager expects.
    private static func pcm16DataToFloatSamples(_ pcm16Data: Data) -> [Float] {
        let sampleCount = pcm16Data.count / MemoryLayout<Int16>.size
        var samples = [Float](repeating: 0, count: sampleCount)
        pcm16Data.withUnsafeBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            for index in 0..<sampleCount {
                samples[index] = Float(Int16(littleEndian: int16Buffer[index])) / Float(Int16.max)
            }
        }
        return samples
    }

    private func deliverFinalTranscript(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(transcriptText)
    }

    deinit {
        cancel()
    }
}
