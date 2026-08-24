//
//  AppleSpeechSynthesisClient.swift
//  leanring-buddy
//
//  Text-to-speech using the synthesizer built into macOS.
//
//  Chatterbox produces a warmer voice, and it costs several gigabytes of
//  resident Python to do it — on an 18GB machine shared with a 6GB model, that
//  is most of the headroom the user needs for their actual work. It also grows
//  with use: measured at 2.9GB fresh, 5.6GB after a few minutes of synthesis,
//  and 12GB after three days, at which point the machine had 60MB free and
//  every model call was paging off disk.
//
//  AVSpeechSynthesizer is a system service. It adds no resident memory to this
//  app, cannot leak into it, and needs no server to be running for the app to
//  work at all.
//
//  It is also faster in the way that matters. Chatterbox synthesises before it
//  can play, so the user waits — which is why that client streams
//  sentence-by-sentence, to overlap synthesis with playback. This one begins
//  speaking essentially immediately, so the whole reply can be handed over at
//  once and the first word is audible in well under a second.
//

import AVFoundation
import Foundation

@MainActor
final class AppleSpeechSynthesisClient: NSObject, BuddyTTSProvider {
    var onPlaybackStarted: (@MainActor () -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?

    /// Resumed when the current utterance finishes or is cancelled.
    private var playbackContinuation: CheckedContinuation<Void, Never>?

    var isPlaying: Bool { synthesizer.isSpeaking }

    override init() {
        self.voice = Self.bestAvailableVoice()
        super.init()
        synthesizer.delegate = self

        let description = voice.map { "\($0.name) (\($0.quality == .premium ? "premium" : $0.quality == .enhanced ? "enhanced" : "standard"))" }
            ?? "system default"
        print("🔊 TTS: using Apple speech synthesis — \(description)")
    }

    /// Whether any voice good enough to not sound robotic is installed.
    ///
    /// macOS ships only compact voices by default. Enhanced and premium ones
    /// are a free download and sound close to natural, but nothing tells the
    /// user they exist — so the app does, rather than letting them conclude it
    /// simply sounds bad.
    static var hasHighQualityVoiceInstalled: Bool {
        AVSpeechSynthesisVoice.speechVoices().contains {
            $0.language.hasPrefix("en") && ($0.quality == .premium || $0.quality == .enhanced)
        }
    }

    /// Voices that are jokes rather than voices.
    ///
    /// macOS ships these alongside the real ones at identical quality, so a
    /// ranking that only considers quality can and does select them. Being
    /// answered by "Bubbles" is a worse failure than sounding robotic, and it
    /// is only luck that the current ranking lands on Samantha instead.
    private static let noveltyVoiceIdentifierFragments = [
        "bahh", "bells", "boing", "bubbles", "cellos", "wobble", "jester",
        "organ", "trinoids", "whisper", "zarvox", "albert", "badnews",
        "goodnews", "bad news", "good news", "grandma", "grandpa", "superstar",
        "junior", "ralph", "kathy", "princess", "deranged", "hysterical",
        "bruce", "agnes", "fred",
    ]

    /// Picks the best-sounding installed English voice.
    ///
    /// Quality first, then a curated preference among the compact voices,
    /// because when everything ties at default quality — the common case — the
    /// tiebreak is what decides whether the app sounds like a person or a
    /// cartoon.
    private static func bestAvailableVoice() -> AVSpeechSynthesisVoice? {
        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .filter { voice in
                let haystack = (voice.identifier + " " + voice.name).lowercased()
                return !noveltyVoiceIdentifierFragments.contains { haystack.contains($0) }
            }

        let rank: (AVSpeechSynthesisVoiceQuality) -> Int = { quality in
            switch quality {
            case .premium: return 3
            case .enhanced: return 2
            default: return 1
            }
        }

        // The most natural of the compact voices, best first. Only consulted
        // when quality cannot separate the candidates.
        let preferredNames = ["Ava", "Zoe", "Allison", "Susan", "Samantha", "Tom", "Alex", "Daniel"]
        let preference: (AVSpeechSynthesisVoice) -> Int = { voice in
            preferredNames.firstIndex { voice.name.hasPrefix($0) }
                .map { preferredNames.count - $0 } ?? 0
        }

        return candidates.max { left, right in
            let leftScore = (rank(left.quality), preference(left), left.language == "en-US" ? 1 : 0)
            let rightScore = (rank(right.quality), preference(right), right.language == "en-US" ? 1 : 0)
            return leftScore < rightScore
        }
    }

    func speakText(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stopPlayback()

        let utterance = makeUtterance(trimmed)

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                playbackContinuation = continuation
                synthesizer.speak(utterance)
            }
        } onCancel: {
            // The user interrupting is the common case here — they press
            // push-to-talk again mid-answer — so this has to cut off promptly
            // rather than finishing the sentence.
            Task { @MainActor in self.stopPlayback() }
        }
    }

    // MARK: - Incremental speech

    /// AVSpeechSynthesizer queues utterances natively, so each sentence can be
    /// handed over the moment it exists and playback runs continuously while
    /// the rest of the reply is still being generated.
    var supportsIncrementalSpeech: Bool { true }

    func speakIncremental(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        synthesizer.speak(makeUtterance(trimmed))
    }

    func waitForPlaybackToFinish() async {
        // Polled rather than driven by the delegate: the delegate fires per
        // utterance, and what matters here is the whole queue draining.
        while synthesizer.isSpeaking {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return }
        }
    }

    private func makeUtterance(_ text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        // Slightly above default. The default reads as deliberate to the point
        // of sounding slow for short conversational replies.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.06
        utterance.postUtteranceDelay = 0
        return utterance
    }

    func stopPlayback() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        resumePlaybackContinuation()
    }

    private func resumePlaybackContinuation() {
        guard let continuation = playbackContinuation else { return }
        playbackContinuation = nil
        continuation.resume()
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension AppleSpeechSynthesisClient: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.onPlaybackStarted?() }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.resumePlaybackContinuation() }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.resumePlaybackContinuation() }
    }
}
