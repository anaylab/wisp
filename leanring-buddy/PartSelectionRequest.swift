//
//  PartSelectionRequest.swift
//  leanring-buddy
//
//  Voice selection of a part of the screen: "ask about the third answer",
//  "explain option C", "what does the second line mean", "tell me about step 2",
//  "explain the line \"x = 6\"". The user names the part in words instead of
//  dragging over it with Ask About a Part; Wisp finds it on screen
//  (`PartSelectionResolver`), selects it exactly as the drag would have, and
//  answers the rest of the question about it.
//
//  This file is the pure, testable parser. It is biased toward NOT matching,
//  like `PointingRequestParser`: a miss is one ordinary model turn, while a
//  false match would select a region and rewrite the user's question. So an
//  ordinal or label must sit beside a list-item noun ("third answer", never
//  "third quarter"), and anything that continues into the wider world ("the
//  second step of photosynthesis") is left to the model.
//
//  Tested by `Tests/PartSelection`.
//

import Foundation

/// The kind of thing an ordinal or label refers to ("answer", "step", …).
nonisolated enum PartSelectionNoun: String, Equatable, CaseIterable {
    case answer, option, choice, line, step, bullet, item, row
}

/// Which item of a list an ordinal names.
nonisolated enum PartSelectionPosition: Equatable {
    /// 1-based, counted from the top of the list.
    case index(Int)
    case last
}

/// What on screen the user named.
nonisolated enum PartSelectionTarget: Equatable {
    /// "the third answer", "the last bullet".
    case ordinalItem(position: PartSelectionPosition, noun: PartSelectionNoun)
    /// "option C", "step 2": `label` is lowercase ("c") or digits ("2").
    case labeledItem(label: String, noun: PartSelectionNoun)
    /// Words that are on screen: `"x = 6"`, or "the part that says …".
    case onScreenText(String)
}

nonisolated struct PartSelectionRequest: Equatable {
    let target: PartSelectionTarget
    /// What to ask about the selected part once it is selected.
    let residualQuestion: String
}

nonisolated enum PartSelectionRequestParser {
    /// Asked when the user only named the part ("ask about the third answer").
    static let defaultResidualQuestion = "explain this part"

    /// Longest on-screen text kept when the user spoke it ("the part that says …").
    static let maximumSpokenTextWordCount = 8

    private static let leadingPhrases = [
        "hey wisp ", "wisp ", "okay ", "ok ", "please ", "can you ", "could you ", "would you ", "i want you to ",
    ]

    private static let trailingPhrases = [
        " on the screen", " on my screen", " on screen", " on this page", " on the page",
        " in this app", " in this window", " here", " please", " for me",
    ]

    /// Verbs that introduce a part to talk about; the rest of the sentence
    /// follows the target. Longest first so "ask me about" beats "ask".
    private static let introducingPhrases = [
        "ask you about ", "ask me about ", "ask about ", "tell me about ", "talk about ", "talk to me about ",
        "walk me through ", "go over ", "look at ", "focus on ", "help me with ", "explain ", "describe ",
        "what about ", "how about ",
    ]

    private static let ordinalWords: [String: PartSelectionPosition] = [
        "first": .index(1), "second": .index(2), "third": .index(3), "fourth": .index(4),
        "fifth": .index(5), "sixth": .index(6), "seventh": .index(7), "eighth": .index(8),
        "ninth": .index(9), "tenth": .index(10), "last": .last, "final": .last,
        "1st": .index(1), "2nd": .index(2), "3rd": .index(3), "4th": .index(4), "5th": .index(5),
        "6th": .index(6), "7th": .index(7), "8th": .index(8), "9th": .index(9), "10th": .index(10),
    ]

    private static let numberWords: [String: String] = [
        "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
        "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10",
    ]

    /// Dictation spells letter names out ("option see").
    private static let spokenLetterNames: [String: String] = ["bee": "b", "see": "c", "sea": "c", "dee": "d"]

    private static let nounsBySpokenWord: [String: PartSelectionNoun] = [
        "answer": .answer, "option": .option, "choice": .choice, "line": .line,
        "step": .step, "bullet": .bullet, "item": .item, "row": .row,
    ]

    /// A target followed by one of these is about the wider world, not the
    /// screen ("the second step of photosynthesis", "option C for dinner").
    private static let worldContinuationWords: Set<String> = [
        "of", "in", "for", "to", "from", "about", "with", "at", "on", "by", "into", "during", "after", "before",
    ]

    private static let residualConjunctions: Set<String> = ["and", "then", "also", "so", "but"]

    private static let textNounWords: Set<String> = [
        "line", "text", "part", "phrase", "word", "equation", "sentence", "bit", "section",
    ]

    // MARK: Parsing

    static func request(from transcript: String) -> PartSelectionRequest? {
        var normalized = transcript.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: ",", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let lastCharacter = normalized.last, ".?!".contains(lastCharacter) {
            normalized.removeLast()
        }
        normalized = collapsedWhitespace(normalized)

        var didStripLeadIn = true
        while didStripLeadIn {
            didStripLeadIn = false
            for leadingPhrase in leadingPhrases where normalized.hasPrefix(leadingPhrase) {
                normalized.removeFirst(leadingPhrase.count)
                didStripLeadIn = true
            }
        }
        var didStripTrailing = true
        while didStripTrailing {
            didStripTrailing = false
            for trailingPhrase in trailingPhrases where normalized.hasSuffix(trailingPhrase) {
                normalized.removeLast(trailingPhrase.count)
                didStripTrailing = true
            }
        }

        if let questionRequest = requestFromQuestionShape(normalized) { return questionRequest }

        for introducingPhrase in introducingPhrases where normalized.hasPrefix(introducingPhrase) {
            let afterVerb = String(normalized.dropFirst(introducingPhrase.count))
            guard let parsedTarget = parseTargetPhrase(afterVerb) else { return nil }
            return PartSelectionRequest(
                target: parsedTarget.target,
                residualQuestion: residualQuestion(fromRemainder: parsedTarget.remainderWords) ?? defaultResidualQuestion
            )
        }
        return nil
    }

    /// "what does the second line mean", "what is step 2", "why is option C wrong".
    private static func requestFromQuestionShape(_ normalized: String) -> PartSelectionRequest? {
        // (opening words, builds the residual question from the target's remainder)
        let questionOpenings: [(opening: String, residualFromRemainder: ([String]) -> String?)] = [
            ("what does ", { remainder in
                guard let verb = remainder.first, ["mean", "say", "show", "represent"].contains(verb),
                      remainder.count == 1 else { return nil }
                return "what does this part \(verb)"
            }),
            ("what do ", { remainder in
                guard let verb = remainder.first, ["mean", "say", "show", "represent"].contains(verb),
                      remainder.count == 1 else { return nil }
                return "what do these \(verb)"
            }),
            ("what is ", { remainder in remainder.isEmpty ? "what is this part" : nil }),
            ("what's ", { remainder in remainder.isEmpty ? "what is this part" : nil }),
            ("why is ", { remainder in
                guard remainder.count == 1, judgmentWords.contains(remainder[0]) else { return nil }
                return "why is this part \(remainder[0])"
            }),
            ("is ", { remainder in
                guard remainder.count == 1, judgmentWords.contains(remainder[0]) else { return nil }
                return "is this part \(remainder[0])"
            }),
        ]
        for (opening, residualFromRemainder) in questionOpenings where normalized.hasPrefix(opening) {
            let afterOpening = String(normalized.dropFirst(opening.count))
            guard let parsedTarget = parseTargetPhrase(afterOpening),
                  let residualQuestion = residualFromRemainder(parsedTarget.remainderWords) else { return nil }
            return PartSelectionRequest(target: parsedTarget.target, residualQuestion: residualQuestion)
        }
        return nil
    }

    private static let judgmentWords: Set<String> = [
        "correct", "right", "wrong", "incorrect", "true", "false", "good", "bad",
    ]

    private struct ParsedTargetPhrase {
        let target: PartSelectionTarget
        let remainderWords: [String]
    }

    /// Reads a target from the start of `text` and returns the words after it.
    /// Nil when the start isn't a recognised target, or when the words after it
    /// carry on into the wider world.
    private static func parseTargetPhrase(_ text: String) -> ParsedTargetPhrase? {
        if let quotedPhrase = parseQuotedPhrase(text) { return quotedPhrase }

        var words = text.split(separator: " ").map(String.init)
        if words.first == "the" || words.first == "this" { words.removeFirst() }
        guard let firstWord = words.first else { return nil }

        // "the part that says x equals six" — the rest of the sentence is the text.
        if textNounWords.contains(firstWord), words.count >= 3 {
            let sayingIntroducers: [[String]] = [["that", "says"], ["where", "it", "says"], ["that", "reads"], ["saying"]]
            for introducer in sayingIntroducers where Array(words.dropFirst().prefix(introducer.count)) == introducer {
                let spokenWords = Array(words.dropFirst(1 + introducer.count))
                guard !spokenWords.isEmpty, spokenWords.count <= maximumSpokenTextWordCount else { return nil }
                return ParsedTargetPhrase(target: .onScreenText(spokenWords.joined(separator: " ")), remainderWords: [])
            }
        }

        var target: PartSelectionTarget?
        var wordsConsumed = 0

        if let position = ordinalWords[firstWord], words.count >= 2, let noun = nounsBySpokenWord[words[1]] {
            // "third answer" — but "third quarter" and "third answers" are not.
            target = .ordinalItem(position: position, noun: noun)
            wordsConsumed = 2
        } else if let noun = nounsBySpokenWord[firstWord], words.count >= 2 {
            // "option c", "step 2", "step number two".
            var labelWordIndex = 1
            if words[labelWordIndex] == "number", words.count > 2 { labelWordIndex = 2 }
            if let label = parseLabel(words[labelWordIndex]) {
                target = .labeledItem(label: label, noun: noun)
                wordsConsumed = labelWordIndex + 1
            }
        }

        guard let resolvedTarget = target else { return nil }
        let remainderWords = Array(words.dropFirst(wordsConsumed))

        // "option a question": a lone "a" is an article far more often than a label.
        if case .labeledItem(let label, _) = resolvedTarget, label == "a", !remainderWords.isEmpty { return nil }
        if let firstRemainderWord = remainderWords.first, worldContinuationWords.contains(firstRemainderWord) {
            return nil
        }
        return ParsedTargetPhrase(target: resolvedTarget, remainderWords: remainderWords)
    }

    /// `"x = 6"` or `'x = 6'`, optionally after "the line" / "the part".
    private static func parseQuotedPhrase(_ text: String) -> ParsedTargetPhrase? {
        let pattern = #"^(?:the |this )?(?:(?:line|text|part|phrase|word|equation|sentence|bit|section) )?(?:"|“|')(.+?)(?:"|”|')(?: (.*))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let quotedRange = Range(match.range(at: 1), in: text) else { return nil }
        let quotedText = String(text[quotedRange]).trimmingCharacters(in: .whitespaces)
        guard !quotedText.isEmpty, quotedText.count <= 80 else { return nil }
        var remainderWords: [String] = []
        if match.range(at: 2).location != NSNotFound, let remainderRange = Range(match.range(at: 2), in: text) {
            remainderWords = text[remainderRange].split(separator: " ").map(String.init)
        }
        if let firstRemainderWord = remainderWords.first, worldContinuationWords.contains(firstRemainderWord) {
            return nil
        }
        return ParsedTargetPhrase(target: .onScreenText(quotedText), remainderWords: remainderWords)
    }

    /// "c" / "see" → "c"; "2" / "two" → "2"; anything else nil.
    private static func parseLabel(_ word: String) -> String? {
        if let letterName = spokenLetterNames[word] { return letterName }
        if let numberFromWord = numberWords[word] { return numberFromWord }
        if word.count == 1, let onlyCharacter = word.first, ("a"..."h").contains(onlyCharacter) {
            return word
        }
        if let number = Int(word), (1...99).contains(number) { return String(number) }
        return nil
    }

    /// The question left after the target, with a leading "and"/"then" dropped.
    private static func residualQuestion(fromRemainder remainderWords: [String]) -> String? {
        var words = remainderWords
        while let firstWord = words.first, residualConjunctions.contains(firstWord) {
            words.removeFirst()
        }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    private static func collapsedWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
