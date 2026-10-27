//
//  SpokenSentenceStreamer.swift
//  leanring-buddy
//
//  Turns a stream of model tokens into complete sentences that can be spoken
//  before the rest of the reply exists.
//
//  The app used to generate the whole answer and only then start speaking. A
//  spoken reply runs to a couple of hundred tokens at roughly thirty tokens a
//  second, so that is several seconds of silence in which the app appears to
//  have done nothing — the single largest contributor to it feeling slow, and
//  entirely avoidable, because the first sentence is usually complete about a
//  second in.
//
//  The only real subtlety is that the model appends machine-readable tags —
//  [POINT:x,y:label], [BOX:...] — at the end of its answer. Those must never
//  be read aloud, and a naive splitter would happily speak half of one while
//  the rest is still arriving. So anything from an unclosed bracket onward is
//  held back until it closes or the stream ends.
//

import Foundation

/// Accumulates streamed text and emits whole sentences, tags removed.
///
/// Not thread-safe by design: it is driven from the streaming callback, which
/// already runs on the main actor.
@MainActor
final class SpokenSentenceStreamer {
    private var pending = ""
    private var hasEmittedAnything = false

    /// Called with each complete, speakable sentence.
    private let onSentence: (String) -> Void

    init(onSentence: @escaping (String) -> Void) {
        self.onSentence = onSentence
    }

    /// Whether anything has been spoken yet, so the caller can tell whether the
    /// terminal flush is the first audio or a continuation.
    var hasSpokenAnything: Bool { hasEmittedAnything }

    func append(_ chunk: String) {
        pending += chunk
        drainCompleteSentences()
    }

    /// Emits whatever is left, including a trailing fragment with no
    /// terminator — models routinely end without final punctuation, and
    /// dropping the last clause would be worse than speaking it early.
    func finish() {
        let remainder = Self.strippingTags(from: pending).trimmingCharacters(in: .whitespacesAndNewlines)
        pending = ""
        guard !remainder.isEmpty else { return }
        hasEmittedAnything = true
        onSentence(remainder)
    }

    // MARK: - Splitting

    private func drainCompleteSentences() {
        while true {
            // Never emit past an unclosed tag: the closing bracket may still be
            // arriving, and half a tag read aloud is gibberish.
            let safeUpperBound = pending.firstIndex(of: "[") ?? pending.endIndex

            guard let boundary = Self.sentenceBoundary(in: pending, before: safeUpperBound) else { return }

            let sentence = String(pending[pending.startIndex...boundary])
            pending = String(pending[pending.index(after: boundary)...])

            let speakable = Self.strippingTags(from: sentence)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !speakable.isEmpty else { continue }

            hasEmittedAnything = true
            onSentence(speakable)
        }
    }

    /// Index of the last character of the first complete sentence.
    private static func sentenceBoundary(in text: String, before limit: String.Index) -> String.Index? {
        var index = text.startIndex
        while index < limit {
            let character = text[index]
            if character == "." || character == "!" || character == "?" || character == "\n" {
                let next = text.index(after: index)
                // A terminator only ends a sentence when whitespace follows it.
                //
                // Requiring the whitespace to have actually arrived is the
                // whole point: mid-stream, "3." is indistinguishable from the
                // end of a sentence until the next character shows up, and
                // guessing splits "3.5 gigabytes" into "3." and "5 gigabytes".
                // A trailing fragment with no terminator is not lost — finish()
                // flushes it once the stream is genuinely over.
                guard next < limit else { return nil }
                if text[next] == " " || text[next] == "\n" { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Removes bracketed machine tags. Anything from an unclosed bracket
    /// onward is dropped, which is correct at end-of-stream: a tag that never
    /// closed was truncated and was never speech.
    private static func strippingTags(from text: String) -> String {
        var output = ""
        var depth = 0
        for character in text {
            if character == "[" {
                depth += 1
            } else if character == "]" {
                depth = max(0, depth - 1)
            } else if depth == 0 {
                output.append(character)
            }
        }
        return output
    }
}
