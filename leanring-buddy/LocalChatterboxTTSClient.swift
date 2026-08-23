//
//  LocalChatterboxTTSClient.swift
//  leanring-buddy
//
//  Text-to-speech client for a locally self-hosted Chatterbox-TTS-Server
//  (https://github.com/devnen/Chatterbox-TTS-Server), run as a separate
//  process the user starts manually. Uses its OpenAI-compatible
//  /v1/audio/speech endpoint. No API key, no data leaves the machine.
//
//  Local synthesis cost scales with text length (measured on this hardware:
//  roughly a third of a second of compute per character). Sending a whole
//  multi-sentence reply as one request therefore means the user hears
//  nothing for a minute or more. Instead this client splits the reply into
//  sentences and runs a two-stage pipeline: it synthesizes sentence N+1
//  while sentence N is still playing, so speech starts as soon as the FIRST
//  sentence is ready instead of the whole reply.
//

import AVFoundation
import Foundation

@MainActor
final class LocalChatterboxTTSClient: NSObject, BuddyTTSProvider {
    private let speechEndpointURL: URL
    private let voiceID: String
    private let session: URLSession

    var onPlaybackStarted: (@MainActor () -> Void)?

    private var audioPlayer: AVAudioPlayer?
    /// Set while a multi-sentence reply is still being synthesized/played.
    /// `isPlaying` reports true for the whole run so the overlay's
    /// transient-hide poll doesn't fade the cursor out between sentences.
    private var isSpeakingSequence = false
    /// Resumes `waitForCurrentSentenceToFinish()` when playback ends.
    private var sentencePlaybackContinuation: CheckedContinuation<Void, Never>?

    /// - Parameters:
    ///   - baseURL: Base URL of the running Chatterbox-TTS-Server, e.g. "http://localhost:8004".
    ///   - voiceID: Predefined voice filename (see GET /get_predefined_voices on the server
    ///     for available options). Falls back to "ChatterboxVoiceID" in Info.plist, then a default.
    init(baseURL: String, voiceID: String? = nil) {
        self.speechEndpointURL = URL(string: "\(baseURL)/v1/audio/speech")!
        self.voiceID = voiceID
            ?? AppBundleConfiguration.stringValue(forKey: "ChatterboxVoiceID")
            ?? "Emily.wav"

        let configuration = URLSessionConfiguration.default
        // Per-sentence requests are much smaller than a whole reply, but
        // local inference still has no hard upper bound under memory
        // pressure, so keep the timeouts generous.
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 240
        self.session = URLSession(configuration: configuration)

        super.init()
    }

    func speakText(_ text: String) async throws {
        let sentences = Self.splitIntoSpokenSentences(text)
        guard !sentences.isEmpty else { return }

        isSpeakingSequence = true
        defer { isSpeakingSequence = false }

        // Kick off synthesis of the first sentence, then loop: wait for the
        // current sentence's audio, immediately start synthesizing the next
        // one, and play the current one while that runs.
        var pendingSynthesis: Task<Data, Error>? = synthesisTask(for: sentences[0])

        for sentenceIndex in sentences.indices {
            guard let currentSynthesis = pendingSynthesis else { break }

            let audioData: Data
            do {
                audioData = try await currentSynthesis.value
            } catch is CancellationError {
                return
            }

            try Task.checkCancellation()

            // Start the next sentence synthesizing before playing this one,
            // so generation overlaps playback instead of following it.
            let nextIndex = sentenceIndex + 1
            pendingSynthesis = nextIndex < sentences.count
                ? synthesisTask(for: sentences[nextIndex])
                : nil

            do {
                try playSentenceAudio(audioData, sentenceNumber: sentenceIndex + 1, totalSentences: sentences.count)
            } catch {
                pendingSynthesis?.cancel()
                throw error
            }

            // The first sentence is already audible at this point, which is
            // the latency that actually matters. Wait for it to finish before
            // playing the next so sentences don't overlap.
            await waitForCurrentSentenceToFinish()

            if Task.isCancelled {
                pendingSynthesis?.cancel()
                return
            }
        }
    }

    /// Requests audio for a single sentence. Runs as a detached Task so the
    /// caller can overlap it with playback of the previous sentence.
    private func synthesisTask(for sentence: String) -> Task<Data, Error> {
        Task { [session, speechEndpointURL, voiceID] in
            var request = URLRequest(url: speechEndpointURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: Any] = [
                "model": "tts-1",
                "input": sentence,
                "voice": voiceID,
                "response_format": "wav"
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(domain: "LocalChatterboxTTS", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw NSError(domain: "LocalChatterboxTTS", code: httpResponse.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "Chatterbox TTS error (\(httpResponse.statusCode)): \(errorBody)"])
            }

            return data
        }
    }

    private func playSentenceAudio(_ audioData: Data, sentenceNumber: Int, totalSentences: Int) throws {
        let player = try AVAudioPlayer(data: audioData)
        player.delegate = self
        audioPlayer = player
        player.play()
        print("🔊 Chatterbox TTS: playing sentence \(sentenceNumber)/\(totalSentences) (\(audioData.count / 1024)KB)")

        if sentenceNumber == 1 {
            onPlaybackStarted?()
        }
    }

    /// Suspends until the current sentence finishes playing (or playback is
    /// stopped). Resumed from `audioPlayerDidFinishPlaying` / `stopPlayback`.
    private func waitForCurrentSentenceToFinish() async {
        guard let player = audioPlayer, player.isPlaying else { return }

        await withCheckedContinuation { continuation in
            sentencePlaybackContinuation = continuation
        }
    }

    private func resumeSentencePlaybackWaiter() {
        guard let continuation = sentencePlaybackContinuation else { return }
        sentencePlaybackContinuation = nil
        continuation.resume()
    }

    /// Splits a reply into sentence-sized synthesis units. Very short
    /// fragments are merged into the previous sentence — a two-word request
    /// costs nearly as much round-trip overhead as a full sentence, and
    /// chopping too finely makes the delivery sound clipped.
    static func splitIntoSpokenSentences(_ text: String) -> [String] {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return [] }

        var sentences: [String] = []
        var currentSentence = ""

        for character in trimmedText {
            currentSentence.append(character)

            if character == "." || character == "!" || character == "?" || character == "\n" {
                let candidate = currentSentence.trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty {
                    sentences.append(candidate)
                }
                currentSentence = ""
            }
        }

        let trailingText = currentSentence.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailingText.isEmpty {
            sentences.append(trailingText)
        }

        // Merge stubs (e.g. "ok." or a stray abbreviation) into their neighbor.
        let minimumStandaloneSentenceLength = 12
        var mergedSentences: [String] = []
        for sentence in sentences {
            if let lastSentence = mergedSentences.last,
               sentence.count < minimumStandaloneSentenceLength {
                mergedSentences[mergedSentences.count - 1] = lastSentence + " " + sentence
            } else {
                mergedSentences.append(sentence)
            }
        }

        return mergedSentences
    }

    var isPlaying: Bool {
        isSpeakingSequence || (audioPlayer?.isPlaying ?? false)
    }

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        isSpeakingSequence = false
        resumeSentencePlaybackWaiter()
    }
}

extension LocalChatterboxTTSClient: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.resumeSentencePlaybackWaiter()
        }
    }
}
