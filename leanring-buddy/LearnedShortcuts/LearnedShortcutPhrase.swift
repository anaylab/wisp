//
//  LearnedShortcutPhrase.swift
//  leanring-buddy
//
//  Pure: how a spoken or typed request is turned into comparable words, and the
//  "phrase template" a learned shortcut is matched against ("put {app} on the left").
//
//  Matching is exact-template-or-nothing, with the same bias as `FastCommandRouter`:
//  toward *not* matching. A miss costs the user one ordinary model turn; a false
//  positive silently runs a saved action they did not ask for.
//
//  Two views of every word are kept. The normalised form (lowercase, accents folded,
//  "two" -> "2") is what gets compared. The original text is what a slot captures, so a
//  reminder title keeps its capital letters.
//

import Foundation

struct LearnedShortcutToken: Equatable, Sendable {
    /// The word as the user said it, without surrounding punctuation.
    let originalText: String
    /// The word as it is compared.
    let normalizedText: String
}

enum LearnedShortcutTokenizer {
    /// Splits a request into comparable words and drops courtesy ("hey wisp, could you … please").
    static func tokens(from utterance: String) -> [LearnedShortcutToken] {
        var allTokens: [LearnedShortcutToken] = []
        for rawPiece in utterance.split(whereSeparator: { $0.isWhitespace }) {
            let trimmedPiece = trimmedOfSurroundingPunctuation(String(rawPiece))
            guard !trimmedPiece.isEmpty else { continue }
            allTokens.append(LearnedShortcutToken(
                originalText: trimmedPiece,
                normalizedText: normalizedWord(trimmedPiece)
            ))
        }
        return withoutCourtesy(allTokens)
    }

    /// One word in the form it is compared in.
    static func normalizedWord(_ word: String) -> String {
        let foldedWord = word
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "\u{2019}", with: "'")
        return spokenNumberDigits[foldedWord] ?? foldedWord
    }

    // MARK: - Private

    /// "Eight" and "8" are the same request. Applied to the saved phrase and to the new
    /// utterance alike, so both sides agree whichever way the recogniser wrote it.
    private static let spokenNumberDigits: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
        "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10",
    ]

    private static let leadingCourtesyPhrases: [[String]] = [
        ["hey", "wisp"], ["ok", "wisp"], ["okay", "wisp"], ["wisp"],
        ["can", "you"], ["could", "you"], ["would", "you"], ["will", "you"],
    ]

    private static let trailingCourtesyPhrases: [[String]] = [
        ["for", "me"], ["thank", "you"], ["thanks"],
    ]

    private static func trimmedOfSurroundingPunctuation(_ piece: String) -> String {
        let keptCharacters = CharacterSet.alphanumerics
        var scalars = Array(piece.unicodeScalars)
        while let firstScalar = scalars.first, !keptCharacters.contains(firstScalar) { scalars.removeFirst() }
        while let lastScalar = scalars.last, !keptCharacters.contains(lastScalar) { scalars.removeLast() }
        var trimmed = String.UnicodeScalarView()
        trimmed.append(contentsOf: scalars)
        return String(trimmed)
    }

    private static func withoutCourtesy(_ tokens: [LearnedShortcutToken]) -> [LearnedShortcutToken] {
        var remainingTokens = tokens.filter { $0.normalizedText != "please" }

        var strippedSomething = true
        while strippedSomething {
            strippedSomething = false
            for courtesyPhrase in leadingCourtesyPhrases
            where remainingTokens.count > courtesyPhrase.count
                && remainingTokens.prefix(courtesyPhrase.count).map(\.normalizedText) == courtesyPhrase {
                remainingTokens.removeFirst(courtesyPhrase.count)
                strippedSomething = true
                break
            }
            for courtesyPhrase in trailingCourtesyPhrases
            where remainingTokens.count > courtesyPhrase.count
                && remainingTokens.suffix(courtesyPhrase.count).map(\.normalizedText) == courtesyPhrase {
                remainingTokens.removeLast(courtesyPhrase.count)
                strippedSomething = true
                break
            }
        }
        return remainingTokens
    }
}

/// "put {app} on the left": fixed words with named blanks.
struct LearnedShortcutPhraseTemplate: Equatable, Sendable {
    enum Element: Equatable, Sendable {
        case word(String)
        case slot(String)
    }

    static let maximumElementCount = 12

    let elements: [Element]

    var slotNames: [String] {
        elements.compactMap { element in
            if case .slot(let slotName) = element { return slotName }
            return nil
        }
    }

    /// The template as text, words normalised: the form two templates are compared in.
    var canonicalText: String {
        elements.map { element in
            switch element {
            case .word(let word): return word
            case .slot(let slotName): return "{\(slotName)}"
            }
        }
        .joined(separator: " ")
    }

    /// Nil unless the text is a template that can be matched safely: at least one fixed word
    /// (an all-blank template would match anything), no two blanks side by side (where one
    /// ends would be a guess), each blank named once, and a sensible length.
    static func parse(_ text: String) -> LearnedShortcutPhraseTemplate? {
        var parsedElements: [Element] = []
        var slotNamesSeen = Set<String>()

        for rawPiece in text.split(whereSeparator: { $0.isWhitespace }) {
            let piece = String(rawPiece)
            if piece.hasPrefix("{") && piece.hasSuffix("}") {
                let slotName = String(piece.dropFirst().dropLast())
                guard isValidSlotName(slotName), slotNamesSeen.insert(slotName).inserted else { return nil }
                if case .slot? = parsedElements.last { return nil }
                parsedElements.append(.slot(slotName))
            } else {
                // A stray brace is a malformed blank, not a word: the tokenizer would strip it.
                guard !piece.contains("{"), !piece.contains("}") else { return nil }
                // A literal word goes through the tokenizer so "Eight," and "8" are one word.
                let literalWords = LearnedShortcutTokenizer.tokens(from: piece).map(\.normalizedText)
                guard literalWords.count == 1, let literalWord = literalWords.first else { return nil }
                parsedElements.append(.word(literalWord))
            }
        }

        guard parsedElements.contains(where: { if case .word = $0 { return true } else { return false } }),
              parsedElements.count <= maximumElementCount else { return nil }
        return LearnedShortcutPhraseTemplate(elements: parsedElements)
    }

    static func isValidSlotName(_ slotName: String) -> Bool {
        guard let firstCharacter = slotName.first, firstCharacter.isLetter else { return false }
        return slotName.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
