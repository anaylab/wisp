//
//  SpokenLineParser.swift
//  leanring-buddy
//
//  Parses the optional `[SAY: ...]` tag out of a model reply. This is how the
//  model decides, per reply, whether Wisp should speak — and exactly what to
//  say — while voice mode is on. The full answer always renders visually in the
//  notch regardless; the spoken line is a short, separate utterance.
//
//  Semantics (applied by `CompanionManager`, not here):
//    - Voice mode on  + tag present → speak only the tag's line.
//    - Voice mode on  + no tag      → stay silent (visual-first).
//    - Voice mode off (silent mode) → ignore the tag entirely, never speak.
//
//  Like the other structured-text parsers (`ScreenAnnotationParser`,
//  `GlanceCardParser`), this only pulls its own tag out and strips it from the
//  text; it never decides what happens with the result.
//

import Foundation

enum SpokenLineParser {
    /// The result of parsing a reply for a `[SAY:]` tag.
    struct ParseResult: Equatable {
        /// The reply with the `[SAY:]` tag removed — what should be displayed
        /// and stored, never containing the tag itself.
        let displayText: String
        /// The short line the model asked to be spoken, if it supplied one.
        /// `nil` means the model chose not to speak this reply.
        let spokenLine: String?
    }

    /// Terse system-prompt instructions teaching the model the one tag. Kept as
    /// short as the annotation instructions because it shares the prompt window
    /// with a screenshot.
    static let promptInstructions = """


    SPEAKING (voice): the user reads your full answer on screen. Add ONE tag \
    [SAY: a short spoken line] only when saying something out loud adds value \
    (a conversational reply, a heads-up, a confirmation). Put it at the very end. \
    Keep it to one short sentence — it is spoken, not the whole answer. Omit it \
    entirely for silent, visual-only answers (pointing, boxes, lists, a card). \
    Never read your whole answer aloud; never wrap it in quotes.
    """

    /// Extracts the first `[SAY:...]` tag from `responseText`, returning the
    /// text with that tag removed and the spoken line it carried (if any).
    ///
    /// Only the first tag is honored; any additional `[SAY:]` tags are also
    /// stripped from the display text so stray tags never reach the user.
    static func parse(_ responseText: String) -> ParseResult {
        guard let regularExpression = try? NSRegularExpression(
            pattern: "\\[SAY:(.*?)\\]",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return ParseResult(displayText: responseText, spokenLine: nil)
        }

        let fullRange = NSRange(responseText.startIndex..., in: responseText)
        let matches = regularExpression.matches(in: responseText, range: fullRange)
        guard let firstMatch = matches.first else {
            return ParseResult(displayText: responseText, spokenLine: nil)
        }

        var spokenLine: String? = nil
        if let capturedRange = Range(firstMatch.range(at: 1), in: responseText) {
            let trimmedLine = String(responseText[capturedRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedLine.isEmpty {
                spokenLine = trimmedLine
            }
        }

        // Remove every [SAY:] tag from the displayed text, back to front so the
        // earlier ranges stay valid as we mutate the string.
        var displayText = responseText
        for match in matches.reversed() {
            if let tagRange = Range(match.range, in: displayText) {
                displayText.removeSubrange(tagRange)
            }
        }
        displayText = displayText.trimmingCharacters(in: .whitespacesAndNewlines)

        return ParseResult(displayText: displayText, spokenLine: spokenLine)
    }
}
