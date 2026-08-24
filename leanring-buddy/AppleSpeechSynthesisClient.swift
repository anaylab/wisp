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

    /// Picks the best-sounding installed English voice.
    ///
    /// Quality varies enormously: the default compact voices are the robotic
    /// ones people associate with system speech, while the premium and enhanced
    /// downloads are close to natural. Sorting by quality means the app sounds
    /// as good as whatever the user happens to have installed, and improves for
    /// free when they add a better voice in System Settings.
    private static func bestAvailableVoice() -> AVSpeechSynthesisVoice? {
        let englishVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }

        let rank: (AVSpeechSynthesisVoiceQuality) -> Int = { quality in
            switch quality {
            case .premium: return 3
            case .enhanced: return 2
            default: return 1
            }
        }

        // Prefer en-US among equals, so the voice matches the accent the
        // prompts are written in.
        return englishVoices.max { left, right in
            let leftScore = (rank(left.quality), left.language == "en-US" ? 1 : 0)
            let rightScore = (rank(right.quality), right.language == "en-US" ? 1 : 0)
            return leftScore < rightScore
        }
    }

    func speakText(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stopPlayback()

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = voice
        // Slightly above default. The default reads as deliberate to the point
        // of sounding slow for short conversational replies, which is all this
        // app produces.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.06
        utterance.postUtteranceDelay = 0

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
