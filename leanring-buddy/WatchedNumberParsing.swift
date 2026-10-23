//
//  WatchedNumberParsing.swift
//  leanring-buddy
//
//  Numbers as people and pages write them — "$1,299.99", "1.299,99 €",
//  "79,99", "CHF 1'299.50" — for "tell me when the price drops below $80".
//  Used by the screen watcher's number condition (on OCR lines) and by the
//  spoken-request parser for the threshold. The page watcher in the Chrome
//  extension (content/page-watch.js) applies the same rules in the tab, and
//  both suites check the same examples.
//
//  Pure Foundation, so `Tests/ScreenWatcher` and `Tests/ChromeExtPageWatchers`
//  compile it on its own.
//

import Foundation

nonisolated enum WatchedNumberParsing {
    /// A number found in some text: its value and the text it was written as.
    struct FoundNumber: Equatable, Sendable {
        let value: Double
        let writtenText: String
        /// The line (or line pair) it was found on, for the notification.
        let lineText: String
    }

    /// Lines after the one naming the number that may still hold it ("Price"
    /// on one line, "$79.99" on the next).
    static let followingLinesToSearch = 2

    /// Grouped thousands first ("1,299.99", "1 299"), else plain digits with an
    /// optional decimal part. Currency signs are simply not part of it.
    private static let numberTokenPattern = try! NSRegularExpression(
        pattern: #"[-−]?(?:\d{1,3}(?:[,.'   ]\d{3})+(?:[.,]\d+)?|\d+(?:[.,]\d+)?)"#
    )

    /// "$1,299.99" → 1299.99, "1.299,99 €" → 1299.99, "79,99" → 79.99,
    /// "1,299" → 1299 (three digits after a lone separator are a group).
    static func parseNumber(_ numberText: String) -> Double? {
        guard let firstToken = numberTokens(in: numberText).first else { return nil }
        return value(ofToken: firstToken)
    }

    /// The first number in `text`, or nil.
    static func firstNumber(in text: String) -> (value: Double, writtenText: String)? {
        for token in numberTokens(in: text) {
            if let tokenValue = value(ofToken: token) {
                return (tokenValue, token.trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// The number "near" a label in reading order: after the label on the
    /// first line naming it (whole words, like the watcher's text matching),
    /// else anywhere on that line, else on one of the next two lines.
    static func number(nearText labelText: String, inLines lines: [String]) -> FoundNumber? {
        let trimmedLabel = labelText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ScreenWatchTextMatching.normalizedText(trimmedLabel).isEmpty else { return nil }

        for (lineIndex, lineText) in lines.enumerated() {
            guard ScreenWatchTextMatching.screenLine(lineText, containsTargetText: trimmedLabel) else { continue }

            var textAfterLabel = ""
            if let labelRange = lineText.range(of: trimmedLabel, options: [.caseInsensitive, .diacriticInsensitive]) {
                textAfterLabel = String(lineText[labelRange.upperBound...])
            }
            if let numberOnLine = firstNumber(in: textAfterLabel) ?? firstNumber(in: lineText) {
                return FoundNumber(value: numberOnLine.value, writtenText: numberOnLine.writtenText, lineText: lineText)
            }

            let lastFollowingIndex = min(lines.count - 1, lineIndex + followingLinesToSearch)
            if lineIndex + 1 <= lastFollowingIndex {
                for followingIndex in (lineIndex + 1)...lastFollowingIndex {
                    if let numberOnFollowingLine = firstNumber(in: lines[followingIndex]) {
                        return FoundNumber(
                            value: numberOnFollowingLine.value,
                            writtenText: numberOnFollowingLine.writtenText,
                            lineText: "\(lineText) \(lines[followingIndex])"
                        )
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Tokens

    private static func numberTokens(in text: String) -> [String] {
        let fullRange = NSRange(text.startIndex..., in: text)
        return numberTokenPattern.matches(in: text, range: fullRange).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private static func value(ofToken token: String) -> Double? {
        var digitsText = token
            .replacingOccurrences(of: "\u{2212}", with: "-")
            .filter { !["'", "\u{00a0}", "\u{202f}", " "].contains($0) }

        let lastCommaIndex = digitsText.lastIndex(of: ",")
        let lastDotIndex = digitsText.lastIndex(of: ".")
        if let lastCommaIndex, let lastDotIndex {
            // Both kinds: whichever comes last is the decimal point.
            let decimalSeparator: Character = lastCommaIndex > lastDotIndex ? "," : "."
            let groupingSeparator: Character = decimalSeparator == "," ? "." : ","
            digitsText = String(digitsText.filter { $0 != groupingSeparator })
                .replacingOccurrences(of: String(decimalSeparator), with: ".")
        } else if lastCommaIndex != nil || lastDotIndex != nil {
            let separator: Character = lastCommaIndex != nil ? "," : "."
            let parts = digitsText.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
            let integerPart = parts[0].replacingOccurrences(of: "-", with: "")
            let isGrouping = parts.count > 2 || (parts[1].count == 3 && integerPart != "0")
            digitsText = isGrouping ? parts.joined() : "\(parts[0]).\(parts[1])"
        }
        guard let parsedValue = Double(digitsText), parsedValue.isFinite else { return nil }
        return parsedValue
    }
}
