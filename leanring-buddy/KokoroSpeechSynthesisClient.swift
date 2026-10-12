//
//  KokoroSpeechSynthesisClient.swift
//  leanring-buddy
//
//  Text-to-speech with Kokoro 82M (FluidAudio, CoreML on the Apple Neural
//  Engine), voice `af_heart`, with the built-in macOS synthesizer as the
//  automatic fallback.
//
//  Kokoro sounds far closer to a person than the compact system voices, and
//  unlike Chatterbox it runs inside this process on the ANE: no server, no
//  Python, and a fixed footprint that doesn't grow with use.
//
//  Kokoro synthesises a whole clip before it can play (it is not
//  autoregressive), so a reply is split into sentences: the first sentence is
//  synthesised and starts playing, and each next one is synthesised while the
//  previous plays, so the first word is audible after one short synthesis
//  rather than after the whole reply.
//
//  Falls back to `AppleSpeechSynthesisClient` — logged, never a crash — while
//  the model is still downloading/loading on first launch, if it failed to
//  load, or if a synthesis fails midway (the rest of the reply is then spoken
//  by the Apple voice).
//

import AVFoundation
import Foundation
import NaturalLanguage

@MainActor
final class KokoroSpeechSynthesisClient: BuddyTTSProvider {
    var onPlaybackStarted: (@MainActor () -> Void)? {
        didSet { appleSpeechFallbackClient.onPlaybackStarted = onPlaybackStarted }
    }

    var isPlaying: Bool {
        isKokoroSpeechInProgress || appleSpeechFallbackClient.isPlaying
    }

    private let appleSpeechFallbackClient = AppleSpeechSynthesisClient()
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    /// The sample rate the player node is currently connected at; Kokoro
    /// always produces 24 kHz, but this is checked rather than assumed.
    private var playerNodeConnectedSampleRate: Double?

    /// Bumped by every new reply and every stop, so work belonging to an
    /// interrupted reply (a synthesis finishing late, a buffer's completion
    /// callback) recognises itself as stale and does nothing.
    private var currentPlaybackGeneration = 0
    /// True from the moment a Kokoro reply starts (synthesis included) until
    /// its last buffer has played or it is stopped, so callers that wait on
    /// `isPlaying` don't slip through the gap before the first audio.
    private var isKokoroSpeechInProgress = false
    private var scheduledBuffersStillPlayingCount = 0
    private var allScheduledBuffersPlayedContinuation: CheckedContinuation<Void, Never>?

    init() {
        audioEngine.attach(playerNode)
        // Normally already started at launch; this covers any other caller.
        FluidAudioSpeechModels.shared.preloadSpeechSynthesisModelsInBackground()
        print("🔊 TTS: using Kokoro (on-device, voice \(KokoroSynthesisEngine.voiceIdentifier)) with the Apple voice as fallback")
    }

    func speakText(_ text: String) async throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        stopPlayback()

        let speechModels = FluidAudioSpeechModels.shared
        guard let kokoroEngine = speechModels.kokoroSynthesisEngine else {
            print("🔊 TTS: using the Apple voice for this reply — Kokoro is \(speechModels.speechSynthesisLoadState.shortStatusDescription)")
            try await appleSpeechFallbackClient.speakText(trimmedText)
            return
        }

        currentPlaybackGeneration += 1
        let playbackGeneration = currentPlaybackGeneration
        isKokoroSpeechInProgress = true

        await withTaskCancellationHandler {
            await speakWithKokoro(
                trimmedText,
                kokoroEngine: kokoroEngine,
                playbackGeneration: playbackGeneration
            )
        } onCancel: {
            // The user pressing push-to-talk mid-answer is the common case,
            // so this cuts off at once rather than finishing the sentence.
            Task { @MainActor in self.stopPlayback() }
        }

        if playbackGeneration == currentPlaybackGeneration {
            finishKokoroSpeech()
        }
    }

    func stopPlayback() {
        currentPlaybackGeneration += 1
        if isKokoroSpeechInProgress || playerNode.isPlaying {
            // Stopping the node also fires the pending buffers' completion
            // callbacks; the generation bump above makes them no-ops.
            playerNode.stop()
        }
        finishKokoroSpeech()
        appleSpeechFallbackClient.stopPlayback()
    }

    // MARK: - Kokoro playback

    private func speakWithKokoro(
        _ text: String,
        kokoroEngine: KokoroSynthesisEngine,
        playbackGeneration: Int
    ) async {
        let speechChunks = KokoroSpeechTextChunker.speechChunks(from: text)
        guard !speechChunks.isEmpty else { return }

        let replyStartDate = Date()
        var nextChunkSynthesis: Task<KokoroSynthesizedClip, Error>? = Task {
            try await kokoroEngine.synthesize(text: speechChunks[0])
        }

        for chunkIndex in speechChunks.indices {
            guard let currentChunkSynthesis = nextChunkSynthesis else { return }

            let synthesizedClip: KokoroSynthesizedClip
            do {
                synthesizedClip = try await currentChunkSynthesis.value
            } catch {
                guard playbackGeneration == currentPlaybackGeneration else { return }
                let unspokenText = speechChunks[chunkIndex...].joined(separator: " ")
                print("⚠️ Kokoro: synthesis failed, finishing this reply with the Apple voice — \(error)")
                await finishReplyWithAppleVoice(unspokenText, playbackGeneration: playbackGeneration)
                return
            }

            guard playbackGeneration == currentPlaybackGeneration, !Task.isCancelled else { return }

            // Start the next sentence now, so it is ready by the time this
            // one finishes playing.
            let nextChunkIndex = chunkIndex + 1
            nextChunkSynthesis = nextChunkIndex < speechChunks.count
                ? Task { try await kokoroEngine.synthesize(text: speechChunks[nextChunkIndex]) }
                : nil

            do {
                try schedule(synthesizedClip, playbackGeneration: playbackGeneration)
            } catch {
                print("⚠️ Kokoro: couldn't start audio output, finishing this reply with the Apple voice — \(error)")
                let unspokenText = speechChunks[chunkIndex...].joined(separator: " ")
                await finishReplyWithAppleVoice(unspokenText, playbackGeneration: playbackGeneration)
                return
            }

            if chunkIndex == 0 {
                let firstAudioMilliseconds = Int(Date().timeIntervalSince(replyStartDate) * 1000)
                print("🔊 Kokoro: first audio \(firstAudioMilliseconds) ms after the reply was handed over")
                onPlaybackStarted?()
            }
        }

        await waitForScheduledBuffersToFinishPlaying()
    }

    /// Queues one clip on the player node behind whatever is already queued,
    /// starting the engine and the node if they are idle.
    private func schedule(_ synthesizedClip: KokoroSynthesizedClip, playbackGeneration: Int) throws {
        guard let clipFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: synthesizedClip.sampleRate,
            channels: 1,
            interleaved: false
        ),
            let clipBuffer = AVAudioPCMBuffer(
                pcmFormat: clipFormat,
                frameCapacity: AVAudioFrameCount(synthesizedClip.monoSamples.count)
            ),
            let clipChannelData = clipBuffer.floatChannelData
        else {
            throw KokoroSpeechPlaybackError.couldNotCreateAudioBuffer
        }

        clipBuffer.frameLength = AVAudioFrameCount(synthesizedClip.monoSamples.count)
        synthesizedClip.monoSamples.withUnsafeBufferPointer { sourceSamples in
            guard let sourceBaseAddress = sourceSamples.baseAddress else { return }
            clipChannelData[0].update(from: sourceBaseAddress, count: sourceSamples.count)
        }

        if playerNodeConnectedSampleRate != synthesizedClip.sampleRate {
            if audioEngine.isRunning { audioEngine.stop() }
            audioEngine.disconnectNodeOutput(playerNode)
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: clipFormat)
            playerNodeConnectedSampleRate = synthesizedClip.sampleRate
        }

        // The engine is stopped between replies (and macOS stops it when the
        // output device changes), so it is (re)started here on demand.
        if !audioEngine.isRunning {
            audioEngine.prepare()
            try audioEngine.start()
        }

        scheduledBuffersStillPlayingCount += 1
        playerNode.scheduleBuffer(clipBuffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                self?.handleScheduledBufferFinishedPlaying(playbackGeneration: playbackGeneration)
            }
        }

        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    private func handleScheduledBufferFinishedPlaying(playbackGeneration: Int) {
        guard playbackGeneration == currentPlaybackGeneration else { return }
        scheduledBuffersStillPlayingCount = max(0, scheduledBuffersStillPlayingCount - 1)
        if scheduledBuffersStillPlayingCount == 0 {
            resumeAllScheduledBuffersPlayedContinuation()
        }
    }

    private func waitForScheduledBuffersToFinishPlaying() async {
        guard scheduledBuffersStillPlayingCount > 0 else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            allScheduledBuffersPlayedContinuation = continuation
        }
    }

    private func resumeAllScheduledBuffersPlayedContinuation() {
        guard let continuation = allScheduledBuffersPlayedContinuation else { return }
        allScheduledBuffersPlayedContinuation = nil
        continuation.resume()
    }

    /// Lets the already-synthesised sentences finish, then speaks the rest of
    /// the reply with the Apple voice.
    private func finishReplyWithAppleVoice(_ unspokenText: String, playbackGeneration: Int) async {
        await waitForScheduledBuffersToFinishPlaying()
        guard playbackGeneration == currentPlaybackGeneration, !Task.isCancelled else { return }
        try? await appleSpeechFallbackClient.speakText(unspokenText)
    }

    /// Releases the output device between replies and wakes anything waiting
    /// on the current reply.
    private func finishKokoroSpeech() {
        isKokoroSpeechInProgress = false
        scheduledBuffersStillPlayingCount = 0
        resumeAllScheduledBuffersPlayedContinuation()
        // Stop the node with the engine so the next reply's `play()` starts
        // it afresh rather than relying on a node left "playing" on a
        // stopped engine.
        if playerNode.isPlaying {
            playerNode.stop()
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
    }
}

private enum KokoroSpeechPlaybackError: LocalizedError {
    case couldNotCreateAudioBuffer

    var errorDescription: String? {
        switch self {
        case .couldNotCreateAudioBuffer:
            return "couldn't create an audio buffer for the synthesized speech"
        }
    }
}

/// Splits a reply into pieces Kokoro can synthesise one at a time.
///
/// Sentence-sized because the first sentence's synthesis time is the delay
/// before the user hears anything, and because this Kokoro conversion accepts
/// at most ~510 phonemes per call — roughly 300 characters of English — so an
/// over-long sentence is split again at commas, then at spaces.
nonisolated enum KokoroSpeechTextChunker {
    static let maximumChunkCharacterCount = 260

    static func speechChunks(from text: String) -> [String] {
        let sentenceTokenizer = NLTokenizer(unit: .sentence)
        sentenceTokenizer.string = text

        var sentences: [String] = []
        sentenceTokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { sentenceRange, _ in
            let sentence = text[sentenceRange].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
            return true
        }
        if sentences.isEmpty {
            sentences = [text]
        }

        return sentences.flatMap { sentence in
            splitOverlongSentence(sentence)
        }
    }

    private static func splitOverlongSentence(_ sentence: String) -> [String] {
        guard sentence.count > maximumChunkCharacterCount else { return [sentence] }

        var chunks: [String] = []
        var chunkInProgress = ""
        // Prefer breaking after a comma (a natural pause); a clause that is
        // still too long is broken between words.
        for clause in sentence.split(separator: ",", omittingEmptySubsequences: true) {
            let clauseText = clause.trimmingCharacters(in: .whitespaces)
            for word in clauseText.split(separator: " ") {
                let candidateChunk = chunkInProgress.isEmpty ? String(word) : chunkInProgress + " " + word
                if candidateChunk.count > maximumChunkCharacterCount, !chunkInProgress.isEmpty {
                    chunks.append(chunkInProgress)
                    chunkInProgress = String(word)
                } else {
                    chunkInProgress = candidateChunk
                }
            }
            chunkInProgress += ","
        }
        if chunkInProgress.hasSuffix(",") {
            chunkInProgress.removeLast()
        }
        if !chunkInProgress.isEmpty {
            chunks.append(chunkInProgress)
        }
        return chunks
    }
}
