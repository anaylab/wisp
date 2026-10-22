//
//  ChromeFocusCommand.swift
//  leanring-buddy
//
//  Recognises spoken focus-mode commands (phase 09): "focus on my essay for 45
//  minutes", "focus mode for half an hour", "stop focus". Pure, so
//  Tests/ChromeExtFocusMode can pin down what matches and, as importantly, what
//  doesn't.
//
//  Biased toward not matching, like every deterministic router here: a miss is
//  one ordinary model turn, a false match rearranges the user's browser. So a
//  start needs a duration *or* the words "focus mode" / "chrome", and the whole
//  utterance has to be the command. A bare "focus mode" is left alone too: it
//  most likely means macOS Focus. "Focus on the search field" (no duration)
//  and "how do I focus on my essay for an hour" (a question) go to the model.
//

import Foundation

nonisolated enum ChromeFocusCommand: Equatable, Sendable {
    /// `topic` may be empty ("focus mode for 30 minutes"): then only allow-listed
    /// sites count as on-task.
    case start(topic: String, minutes: Int)
    case stop
}

nonisolated enum ChromeFocusCommandParser {

    static let defaultMinutes = 45
    static let allowedMinutes = 1...240

    private static let maximumCommandWordCount = 14

    private static let questionOpenings = [
        "how ", "what ", "why ", "when ", "where ", "which ", "who ", "is ", "are ", "can i ", "could i ",
        "should i ", "do i ", "does ", "did ",
    ]

    /// No "turn off focus mode" / "focus mode off": those most likely mean macOS Focus.
    private static let stopPhrases: Set<String> = [
        "stop focus", "stop focus mode", "stop focusing", "end focus", "end focus mode", "exit focus mode",
        "leave focus mode", "cancel focus", "cancel focus mode",
        "stop chrome focus", "end chrome focus", "stop the focus", "end the focus", "stop focus session",
        "end focus session", "i'm done focusing", "im done focusing", "unfocus", "unfocus chrome", "unfocus my tabs",
    ]

    /// Words that end the topic and start the duration: "focus on X *for* 45 minutes".
    private static let numberWords: [String: Int] = [
        "one": 1, "a": 1, "an": 1, "two": 2, "three": 3, "four": 4, "five": 5, "ten": 10, "fifteen": 15,
        "twenty": 20, "twenty five": 25, "thirty": 30, "forty": 40, "forty five": 45, "fifty": 50, "sixty": 60,
        "ninety": 90,
    ]

    static func command(for transcript: String) -> ChromeFocusCommand? {
        let text = normalized(transcript)
        let words = text.split(separator: " ")
        guard !words.isEmpty, words.count <= maximumCommandWordCount else { return nil }
        guard !questionOpenings.contains(where: { text.hasPrefix($0) }) else { return nil }

        if stopPhrases.contains(text) { return .stop }
        return startCommand(in: text)
    }

    private static func startCommand(in text: String) -> ChromeFocusCommand? {
        // "focus on X for N minutes", "start focus mode on X", "focus chrome on X",
        // "focus mode for N minutes", "start a 45 minute focus on X".
        var remainder = text
        for opening in ["start a focus session", "start focus mode", "start a focus", "start focusing", "start focus",
                        "turn on focus mode", "focus mode", "focus chrome", "focus my tabs", "focus my browser",
                        "lets focus", "let's focus", "focus"] where remainder.hasPrefix(opening) {
            remainder = String(remainder.dropFirst(opening.count)).trimmingCharacters(in: .whitespaces)
            let saysFocusMode = opening.contains("focus mode") || opening.contains("session")
            let namesTheBrowser = opening.contains("chrome") || opening.contains("tabs") || opening.contains("browser")
            return parsedStart(afterOpening: remainder, saysFocusModeExplicitly: saysFocusMode, namesTheBrowser: namesTheBrowser)
        }
        // "45 minute focus on my essay", "a 45 minute focus session"
        if let leadingDuration = leadingDurationPhrase(in: text) {
            var afterDuration = String(text.dropFirst(leadingDuration.phraseLength)).trimmingCharacters(in: .whitespaces)
            guard afterDuration.hasPrefix("focus") else { return nil }
            afterDuration = String(afterDuration.dropFirst("focus".count)).trimmingCharacters(in: .whitespaces)
            for filler in ["session", "mode"] where afterDuration.hasPrefix(filler) {
                afterDuration = String(afterDuration.dropFirst(filler.count)).trimmingCharacters(in: .whitespaces)
            }
            guard let topic = topic(fromPhraseAfterOpening: afterDuration) else { return nil }
            return .start(topic: topic, minutes: leadingDuration.minutes)
        }
        return nil
    }

    private static func parsedStart(afterOpening remainder: String, saysFocusModeExplicitly: Bool, namesTheBrowser: Bool) -> ChromeFocusCommand? {
        // Split "on my essay for 45 minutes" into topic text and duration text.
        var topicText = remainder
        var spokenMinutes: Int?
        if let forRange = remainder.range(of: " for ", options: .backwards) ?? (remainder.hasPrefix("for ") ? remainder.range(of: "for ") : nil) {
            let durationText = String(remainder[forRange.upperBound...])
            guard let parsedMinutes = minutes(fromDurationText: durationText) else { return nil }
            spokenMinutes = parsedMinutes
            topicText = String(remainder[..<forRange.lowerBound])
        }
        guard spokenMinutes != nil || saysFocusModeExplicitly || namesTheBrowser else { return nil }
        guard let topic = topic(fromPhraseAfterOpening: topicText) else { return nil }
        // A bare "focus mode" / "turn on focus mode" most likely means macOS Focus (Do Not
        // Disturb), which Wisp doesn't control: leave it to the model unless there's a topic,
        // a length or the browser is named.
        if spokenMinutes == nil && topic.isEmpty && !namesTheBrowser { return nil }
        let resolvedMinutes = spokenMinutes ?? defaultMinutes
        guard allowedMinutes.contains(resolvedMinutes) else { return nil }
        return .start(topic: topic, minutes: resolvedMinutes)
    }

    /// "on my essay" → "my essay"; "" → "". Nil for anything that isn't a topic
    /// ("focus mode is great").
    private static func topic(fromPhraseAfterOpening phrase: String) -> String? {
        var topicText = phrase.trimmingCharacters(in: .whitespaces)
        if topicText.isEmpty { return "" }
        var hadLeadingPreposition = false
        for preposition in ["on ", "for ", "with ", "about "] where topicText.hasPrefix(preposition) {
            topicText = String(topicText.dropFirst(preposition.count))
            hadLeadingPreposition = true
            break
        }
        guard hadLeadingPreposition else { return nil }
        // "on the search field" is about the screen, not a piece of work.
        let screenWords: Set<String> = ["field", "box", "button", "window", "screen", "input", "textbox", "tab", "app"]
        if topicText.split(separator: " ").contains(where: { screenWords.contains(String($0)) }) { return nil }
        return topicText.trimmingCharacters(in: .whitespaces)
    }

    /// "45 minutes", "an hour", "half an hour", "1 hour 30 minutes", "1.5 hours", "two hours".
    static func minutes(fromDurationText durationText: String) -> Int? {
        let text = durationText.trimmingCharacters(in: .whitespaces)
        if ["half an hour", "half hour", "a half hour"].contains(text) { return 30 }
        if ["an hour and a half", "one and a half hours", "1 and a half hours", "an hour and half"].contains(text) { return 90 }

        let pattern = #"^(\d+(?:\.\d+)?|[a-z]+(?: [a-z]+)?) (hours?|hrs?|minutes?|mins?)(?: (?:and )?(\d+) (?:minutes?|mins?))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let amountRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text) else { return nil }
        let amountText = String(text[amountRange])
        guard let amount = Double(amountText) ?? numberWords[amountText].map(Double.init) else { return nil }
        let isHours = text[unitRange].hasPrefix("h")
        var totalMinutes = isHours ? amount * 60 : amount
        if let extraRange = Range(match.range(at: 3), in: text), let extraMinutes = Double(text[extraRange]) {
            guard isHours else { return nil }
            totalMinutes += extraMinutes
        }
        let roundedMinutes = Int(totalMinutes.rounded())
        return allowedMinutes.contains(roundedMinutes) ? roundedMinutes : nil
    }

    /// "45 minute", "a 45 minute", "an hour" at the start of the text.
    private static func leadingDurationPhrase(in text: String) -> (minutes: Int, phraseLength: Int)? {
        let pattern = #"^(?:a |an )?(\d+)[ -](minute|min|hour)s?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let amountRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let amount = Int(text[amountRange]),
              let wholeRange = Range(match.range, in: text) else { return nil }
        let minutes = text[unitRange] == "hour" ? amount * 60 : amount
        guard allowedMinutes.contains(minutes) else { return nil }
        return (minutes, text.distance(from: text.startIndex, to: wholeRange.upperBound))
    }

    private static func normalized(_ transcript: String) -> String {
        var text = transcript
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: ",", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))
        var removedFiller = true
        while removedFiller {
            removedFiller = false
            for leadingFiller in ["hey wisp ", "wisp ", "hey ", "okay ", "ok ", "so ", "please ", "can you ", "could you ", "help me "]
            where text.hasPrefix(leadingFiller) {
                text = String(text.dropFirst(leadingFiller.count))
                removedFiller = true
            }
        }
        for trailingFiller in [" please", " now"] where text.hasSuffix(trailingFiller) {
            text = String(text.dropLast(trailingFiller.count))
        }
        return text
    }
}
