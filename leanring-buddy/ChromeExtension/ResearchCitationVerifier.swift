//
//  ResearchCitationVerifier.swift
//  leanring-buddy
//
//  Research mode's honesty check (phase 11). Every claim in a research answer
//  names a source and carries a quote the model says it copied from that
//  source. Models paraphrase, misremember and — on a hostile page — invent, so
//  a quote is kept only when it really is in the text Wisp read from that tab:
//  the same words in the same order, after folding whitespace, letter case,
//  curly quotes and dashes. A claim whose quote isn't there is dropped, not
//  shown uncited.
//
//  Also here: numbering the claims and sources in the order they're cited,
//  and the text-fragment address (`#:~:text=`) that opens a source at its quote.
//
//  The folding mirrors content/quote-highlight.js, which finds the same quote
//  in the live page when the user clicks a citation.
//
//  Pure (Foundation only), tested by `Tests/ChromeExtResearch`.
//

import Foundation

// MARK: - Folding text for comparison

nonisolated enum ResearchTextFolding {

    /// One character as compared: lowercased, typographic quotes and dashes
    /// made plain. Whitespace is handled by the caller.
    static func foldedCharacters(_ character: Character) -> String {
        switch character {
        case "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}", "\u{2032}", "`":
            return "'"
        case "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{2033}":
            return "\""
        case "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}", "\u{2212}":
            return "-"
        case "\u{2026}":
            return "..."
        default:
            return String(character).lowercased()
        }
    }

    /// The text as compared — folded, whitespace runs as one space, trimmed —
    /// and, for each character of it, where in `text` it came from.
    static func folded(_ text: String) -> (characters: [Character], sourceIndexes: [String.Index]) {
        var foldedCharacterList: [Character] = []
        var sourceIndexes: [String.Index] = []
        var previousWasSpace = true
        var currentIndex = text.startIndex
        while currentIndex < text.endIndex {
            let character = text[currentIndex]
            if character.isWhitespace {
                if !previousWasSpace {
                    foldedCharacterList.append(" ")
                    sourceIndexes.append(currentIndex)
                    previousWasSpace = true
                }
            } else {
                for foldedCharacter in foldedCharacters(character) {
                    foldedCharacterList.append(foldedCharacter)
                    sourceIndexes.append(currentIndex)
                }
                previousWasSpace = false
            }
            currentIndex = text.index(after: currentIndex)
        }
        if foldedCharacterList.last == " " {
            foldedCharacterList.removeLast()
            sourceIndexes.removeLast()
        }
        return (foldedCharacterList, sourceIndexes)
    }

    static func foldedString(_ text: String) -> String {
        String(folded(text).characters)
    }
}

// MARK: - Checking a quote

nonisolated enum ResearchCitationVerifier {

    /// A quote is a phrase, not a page: past this it isn't a quote any more.
    static let maximumQuoteWords = 25
    /// "the" or "and it" would be found anywhere and supports nothing.
    static let minimumQuoteWords = 3

    /// The model's quote as it may be compared: the quotation marks and
    /// ellipses it wrapped around the words removed.
    static func trimmedModelQuote(_ modelQuote: String) -> String {
        var quote = modelQuote.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrappingCharacters = CharacterSet(charactersIn: "\"'“”‘’«»`")
        var didTrim = true
        while didTrim && !quote.isEmpty {
            didTrim = false
            for ellipsis in ["...", "…"] {
                if quote.hasPrefix(ellipsis) { quote.removeFirst(ellipsis.count); didTrim = true }
                if quote.hasSuffix(ellipsis) { quote.removeLast(ellipsis.count); didTrim = true }
            }
            let trimmedOfMarks = quote.trimmingCharacters(in: wrappingCharacters.union(.whitespaces))
            if trimmedOfMarks != quote { quote = trimmedOfMarks; didTrim = true }
        }
        return quote
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// The quote exactly as it appears in `sourceText` (its own casing and
    /// punctuation, whitespace collapsed), or nil when it isn't there or isn't
    /// a quote-sized phrase.
    static func verifiedQuote(_ modelQuote: String, inSourceText sourceText: String) -> String? {
        let quote = trimmedModelQuote(modelQuote)
        let quoteWordCount = wordCount(quote)
        guard quoteWordCount >= minimumQuoteWords, quoteWordCount <= maximumQuoteWords else { return nil }

        let foldedQuote = ResearchTextFolding.folded(quote).characters
        let foldedSource = ResearchTextFolding.folded(sourceText)
        guard !foldedQuote.isEmpty, let matchStart = firstOccurrence(of: foldedQuote, in: foldedSource.characters) else {
            return nil
        }
        let matchEnd = matchStart + foldedQuote.count - 1
        let sourceStartIndex = foldedSource.sourceIndexes[matchStart]
        let sourceEndIndex = sourceText.index(after: foldedSource.sourceIndexes[matchEnd])
        return String(sourceText[sourceStartIndex..<sourceEndIndex])
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func firstOccurrence(of needle: [Character], in haystack: [Character]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        let lastStart = haystack.count - needle.count
        var candidateStart = 0
        while candidateStart <= lastStart {
            if haystack[candidateStart] == needle[0] {
                var matchedCount = 1
                while matchedCount < needle.count && haystack[candidateStart + matchedCount] == needle[matchedCount] {
                    matchedCount += 1
                }
                if matchedCount == needle.count { return candidateStart }
            }
            candidateStart += 1
        }
        return nil
    }
}

// MARK: - Opening a source at its quote

nonisolated enum ResearchTextFragmentURL {

    /// Past this many words the fragment names the quote's first and last few
    /// words (`start,end`) instead of all of it: shorter, and it still matches
    /// when the page wraps a word differently in the middle.
    static let maximumWordsForWholeQuoteFragment = 8
    static let wordsAtEachEndOfRangeFragment = 4

    /// Characters a text directive may carry unescaped. Everything else is
    /// percent-encoded, including `-`, `,` and `&`, which the syntax uses.
    private static let unescapedCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.~"
    )

    /// The source's address with a `#:~:text=` directive for the quote, in
    /// place of any fragment the address had. Nil for anything but http(s).
    static func url(forSourceURLString sourceURLString: String, quote: String) -> URL? {
        guard var components = URLComponents(string: sourceURLString),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        let words = quote.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return nil }

        let directive: String
        if words.count <= maximumWordsForWholeQuoteFragment {
            directive = encoded(words.joined(separator: " "))
        } else {
            let startText = words.prefix(wordsAtEachEndOfRangeFragment).joined(separator: " ")
            let endText = words.suffix(wordsAtEachEndOfRangeFragment).joined(separator: " ")
            directive = encoded(startText) + "," + encoded(endText)
        }
        components.fragment = nil
        guard let addressWithoutFragment = components.string else { return nil }
        return URL(string: addressWithoutFragment + "#:~:text=" + directive)
    }

    private static func encoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unescapedCharacters) ?? ""
    }
}
