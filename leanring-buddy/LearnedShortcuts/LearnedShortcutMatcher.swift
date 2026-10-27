//
//  LearnedShortcutMatcher.swift
//  leanring-buddy
//
//  Pure: decides whether a request is one of the user's learned shortcuts, and what the blanks
//  were. Whole-utterance, exact-template-or-nothing — no prefix, substring or similarity
//  matching. When anything is unclear (two shortcuts fit, or one fits two ways) it answers
//  `.ambiguous` and the request goes to the model as it always did.
//

import Foundation

enum LearnedShortcutMatchResult: Equatable, Sendable {
    case noMatch
    /// More than one shortcut fits, or one fits in more than one way. Treated as no match by
    /// the caller; kept distinct so tests (and later the UI) can tell the cases apart.
    case ambiguous
    case matched(LearnedShortcut, slotValues: [String: String])
}

enum LearnedShortcutMatcher {
    /// - Parameter applicationNameResolver: turns what the user said for an `.applicationName`
    ///   slot into the one running app it means, or nil when it means none or several. The
    ///   default accepts any words; the real caller passes the window-layout app matcher.
    static func match(
        transcript: String,
        among shortcuts: [LearnedShortcut],
        applicationNameResolver: (String) -> String? = { $0 }
    ) -> LearnedShortcutMatchResult {
        let utteranceTokens = LearnedShortcutTokenizer.tokens(from: transcript)
        guard !utteranceTokens.isEmpty else { return .noMatch }

        var matchedShortcuts: [(shortcut: LearnedShortcut, slotValueOptions: [[String: String]])] = []
        for shortcut in shortcuts where shortcut.isEnabled {
            guard let template = shortcut.parsedPhraseTemplate,
                  Set(template.slotNames) == Set(shortcut.slots.map(\.name)) else { continue }
            let distinctSlotValueOptions = distinctCaptures(
                of: template,
                slots: shortcut.slots,
                in: utteranceTokens,
                applicationNameResolver: applicationNameResolver
            )
            if !distinctSlotValueOptions.isEmpty {
                matchedShortcuts.append((shortcut, distinctSlotValueOptions))
            }
        }

        guard let onlyMatch = matchedShortcuts.first else { return .noMatch }
        guard matchedShortcuts.count == 1, onlyMatch.slotValueOptions.count == 1 else { return .ambiguous }
        return .matched(onlyMatch.shortcut, slotValues: onlyMatch.slotValueOptions[0])
    }

    // MARK: - Private

    /// Every different way the template fits the words. Usually zero or one.
    private static func distinctCaptures(
        of template: LearnedShortcutPhraseTemplate,
        slots: [LearnedShortcutSlot],
        in utteranceTokens: [LearnedShortcutToken],
        applicationNameResolver: (String) -> String?
    ) -> [[String: String]] {
        var allCaptures: [[String: String]] = []

        func extend(elementIndex: Int, tokenIndex: Int, capturedSoFar: [String: String]) {
            if elementIndex == template.elements.count {
                if tokenIndex == utteranceTokens.count { allCaptures.append(capturedSoFar) }
                return
            }
            switch template.elements[elementIndex] {
            case .word(let expectedWord):
                guard tokenIndex < utteranceTokens.count,
                      utteranceTokens[tokenIndex].normalizedText == expectedWord else { return }
                extend(elementIndex: elementIndex + 1, tokenIndex: tokenIndex + 1, capturedSoFar: capturedSoFar)
            case .slot(let slotName):
                guard let slot = slots.first(where: { $0.name == slotName }) else { return }
                let longestCapture = min(slot.kind.maximumWordCount, utteranceTokens.count - tokenIndex)
                guard longestCapture >= 1 else { return }
                for captureLength in 1...longestCapture {
                    let capturedText = utteranceTokens[tokenIndex..<(tokenIndex + captureLength)]
                        .map(\.originalText)
                        .joined(separator: " ")
                    var valueToUse = capturedText
                    if slot.kind == .applicationName {
                        guard let resolvedApplicationName = applicationNameResolver(capturedText) else { continue }
                        valueToUse = resolvedApplicationName
                    }
                    var capturedWithThisSlot = capturedSoFar
                    capturedWithThisSlot[slotName] = valueToUse
                    extend(
                        elementIndex: elementIndex + 1,
                        tokenIndex: tokenIndex + captureLength,
                        capturedSoFar: capturedWithThisSlot
                    )
                }
            }
        }

        extend(elementIndex: 0, tokenIndex: 0, capturedSoFar: [:])

        var distinctCaptures: [[String: String]] = []
        for capture in allCaptures where !distinctCaptures.contains(capture) {
            distinctCaptures.append(capture)
        }
        return distinctCaptures
    }
}
