//
//  ShortcutsAgentTools.swift
//  leanring-buddy
//
//  The `list_shortcuts` / `run_shortcut` agent tools, and how a request finds
//  the right shortcut by name.
//
//  Routing choice, and why: the obvious way to let "run my morning routine"
//  reach a shortcut called "Morning Routine" is to put every shortcut name in
//  `run_shortcut`'s description. That costs tokens on every turn the tool is
//  shown, grows with the user's library, and hands a small model a long list
//  to pick from. Instead the request is matched against the cached names
//  deterministically (`ShortcutNameMatcher`), and only when something matches
//  are those few names (at most three) appended to `run_shortcut`'s
//  description *for that turn* — and the tool is boosted so the router shows
//  it. A request that merely says "shortcut" gets both tools boosted and
//  relies on `list_shortcuts` to discover names. A request that matches
//  nothing pays nothing.
//

import Foundation

// MARK: - Matching a request to shortcut names

nonisolated enum ShortcutNameMatcher {

    /// Words that carry no signal for which shortcut is meant — the request's
    /// grammar ("run my … please") rather than its subject.
    private static let ignoredWords: Set<String> = [
        "the", "a", "an", "and", "or", "to", "of", "in", "on", "for", "my", "me",
        "please", "can", "could", "would", "you", "it", "this", "that", "with",
        "run", "shortcut", "shortcuts", "wisp", "hey", "now", "just",
        // Question words and contraction fragments ("what's" → what, s): a
        // shortcut named "What's a shortcut?" must not match "what's the
        // weather" on grammar alone — measured against a real library.
        "what", "whats", "how", "why", "when", "where", "who", "is", "are",
        "be", "i", "s", "t", "d", "ll", "re", "ve", "m", "get", "your",
    ]

    /// Words that say the user wants something *run*. A one-word shortcut
    /// name ("Weather") only matches when one of these is present, so an
    /// ordinary question that happens to share a word with a shortcut does
    /// not offer to run it.
    private static let invocationCueWords: Set<String> = [
        "run", "start", "trigger", "launch", "do", "execute", "kick", "fire",
        "shortcut", "shortcuts", "activate", "begin",
    ]

    /// How many matching names are offered to the model at once.
    static let maximumMatchingNames = 3

    /// Lowercase words of letters and digits; punctuation and emoji fall away.
    /// Apostrophes are removed first so "Mom's" reads as one word, "moms",
    /// whether the user or the model typed a straight or curly one.
    static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    static func normalizedName(_ shortcutName: String) -> String {
        normalizedWords(shortcutName).joined(separator: " ")
    }

    /// The shortcut the model named, or nil when there is no exact match.
    ///
    /// Exact name first, then identifier, then a case- and punctuation-
    /// insensitive match — but only when that is unique. Never fuzzier than
    /// that: the user approved a specific name on the confirmation card.
    static func resolveShortcut(named requestedShortcutName: String, among shortcutEntries: [AppleShortcutEntry]) -> AppleShortcutEntry? {
        let trimmedRequestedName = requestedShortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRequestedName.isEmpty else { return nil }

        if let exactMatch = shortcutEntries.first(where: { $0.name == trimmedRequestedName }) {
            return exactMatch
        }
        if let identifierMatch = shortcutEntries.first(where: {
            $0.identifier?.caseInsensitiveCompare(trimmedRequestedName) == .orderedSame
        }) {
            return identifierMatch
        }
        let requestedNormalizedName = normalizedName(trimmedRequestedName)
        guard !requestedNormalizedName.isEmpty else { return nil }
        let normalizedMatches = shortcutEntries.filter { normalizedName($0.name) == requestedNormalizedName }
        return normalizedMatches.count == 1 ? normalizedMatches.first : nil
    }

    /// Shortcut names the request plausibly refers to, best first.
    ///
    /// A name matches when every one of its meaningful words appears in the
    /// request ("run my morning routine" → "Morning Routine"), or when at
    /// least two of them do and the request asks for something to be run.
    /// The whole name appearing as a phrase ranks highest.
    ///
    /// - Parameter requiresInvocationCue: When true (routing), a one-word name
    ///   needs a "run"-like word in the request. When false (suggesting
    ///   alternatives for a name the model got wrong), the request *is* a
    ///   shortcut name, so no cue is needed.
    static func matchingShortcutNames(
        forRequest requestText: String,
        among shortcutNames: [String],
        requiresInvocationCue: Bool = true
    ) -> [String] {
        let requestWords = normalizedWords(requestText)
        guard !requestWords.isEmpty else { return [] }
        let requestWordSet = Set(requestWords)
        let paddedNormalizedRequest = " " + requestWords.joined(separator: " ") + " "
        let requestHasInvocationCue = !requiresInvocationCue || !requestWordSet.isDisjoint(with: invocationCueWords)

        var scoredNames: [(shortcutName: String, score: Int)] = []
        for shortcutName in shortcutNames {
            let meaningfulNameWords = normalizedWords(shortcutName).filter { !ignoredWords.contains($0) }
            guard !meaningfulNameWords.isEmpty else { continue }

            let matchedWordCount = meaningfulNameWords.filter { nameWord in
                requestWordSet.contains { requestWord in wordsMatch(requestWord, nameWord) }
            }.count
            let everyWordMatched = matchedWordCount == meaningfulNameWords.count

            if meaningfulNameWords.count == 1 {
                guard everyWordMatched, requestHasInvocationCue else { continue }
            } else if !everyWordMatched {
                guard matchedWordCount >= 2, requestHasInvocationCue else { continue }
            }

            var score = matchedWordCount * 10
            if everyWordMatched { score += 50 }
            let paddedNormalizedName = " " + normalizedName(shortcutName) + " "
            if paddedNormalizedRequest.contains(paddedNormalizedName) { score += 100 }
            scoredNames.append((shortcutName, score))
        }

        scoredNames.sort { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.shortcutName < rhs.shortcutName
        }
        return scoredNames.prefix(maximumMatchingNames).map(\.shortcutName)
    }

    /// Equal, or equal once a plural "s" is dropped ("routines" / "routine").
    private static func wordsMatch(_ requestWord: String, _ nameWord: String) -> Bool {
        if requestWord == nameWord { return true }
        guard requestWord.count >= 4, nameWord.count >= 4 else { return false }
        return requestWord == nameWord + "s" || nameWord == requestWord + "s"
    }
}

// MARK: - Routing hints

enum ShortcutsToolRouting {
    static let listShortcutsToolName = "list_shortcuts"
    static let runShortcutToolName = "run_shortcut"

    /// What the per-turn router should do differently for this request.
    struct RoutingHints: Equatable {
        /// Tools to rank as if they belonged to the request's scope.
        let boostedToolNames: Set<String>
        /// Shortcut names to name in `run_shortcut`'s description this turn.
        let matchingShortcutNames: [String]
    }

    /// Whether the request is about Apple Shortcuts rather than Wisp's own
    /// keyboard shortcuts (the Shortcuts tab), which share the word.
    static func mentionsAppleShortcuts(_ requestText: String) -> Bool {
        let lowercasedRequest = requestText.lowercased()
        let keyboardShortcutPhrases = ["keyboard shortcut", "hotkey", "push to talk", "push-to-talk", "key binding", "keybinding"]
        if keyboardShortcutPhrases.contains(where: { lowercasedRequest.contains($0) }) { return false }
        let requestWords = Set(ShortcutNameMatcher.normalizedWords(requestText))
        return requestWords.contains("shortcut") || requestWords.contains("shortcuts")
    }

    static func routingHints(forRequest requestText: String, knownShortcutNames: [String]) -> RoutingHints {
        let matchingShortcutNames = ShortcutNameMatcher.matchingShortcutNames(
            forRequest: requestText,
            among: knownShortcutNames
        )
        var boostedToolNames: Set<String> = []
        if mentionsAppleShortcuts(requestText) {
            boostedToolNames.insert(listShortcutsToolName)
            boostedToolNames.insert(runShortcutToolName)
        }
        if !matchingShortcutNames.isEmpty {
            boostedToolNames.insert(runShortcutToolName)
        }
        return RoutingHints(boostedToolNames: boostedToolNames, matchingShortcutNames: matchingShortcutNames)
    }

    // MARK: Definitions

    static let listShortcutsDefinition = BuddyToolDefinition(
        name: listShortcutsToolName,
        description: "List the names of the user's Apple Shortcuts (the Shortcuts app). Use to find the exact name before run_shortcut.",
        inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
        metadata: .reading(.localMachine)
    )

    static let runShortcutBaseDescription = "Run one of the user's Apple Shortcuts by its exact name, optionally passing text as its input, and get back its output. Use when the user asks to run a shortcut or an automation they have set up."

    /// `run_shortcut`, optionally naming the shortcuts this request matched.
    static func runShortcutDefinition(matchingShortcutNames: [String] = []) -> BuddyToolDefinition {
        var description = runShortcutBaseDescription
        if !matchingShortcutNames.isEmpty {
            let quotedNames = matchingShortcutNames.map { "\"\($0)\"" }.joined(separator: ", ")
            description += " Shortcuts matching this request: \(quotedNames)."
        }
        return BuddyToolDefinition(
            name: runShortcutToolName,
            description: description,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("The shortcut's exact name, e.g. \"Morning Routine\"")
                    ]),
                    "input": .object([
                        "type": .string("string"),
                        "description": .string("Optional text to hand the shortcut as its input.")
                    ])
                ]),
                "required": .array([.string("name")])
            ]),
            // What a shortcut does is opaque — it can send messages, change
            // settings, delete files. So it is described with the worst-case
            // facts, and `ToolCallSafety` asks about it even under session
            // auto-approve.
            metadata: ToolMetadata(readOnly: false, destructive: true, externalSideEffect: true, dataSource: .localMachine)
        )
    }

    /// Replaces `run_shortcut` in a routed selection with the version that
    /// names this turn's matching shortcuts. Everything else passes through.
    static func applyingMatchingShortcutNames(
        _ matchingShortcutNames: [String],
        to selectedDefinitions: [BuddyToolDefinition]
    ) -> [BuddyToolDefinition] {
        guard !matchingShortcutNames.isEmpty else { return selectedDefinitions }
        return selectedDefinitions.map { selectedDefinition in
            selectedDefinition.name == runShortcutToolName
                ? runShortcutDefinition(matchingShortcutNames: matchingShortcutNames)
                : selectedDefinition
        }
    }
}

// MARK: - Registration

extension AgentToolRegistry {

    /// Registers `list_shortcuts` and `run_shortcut`, and warms the name cache
    /// so the very first request can already be matched to a shortcut.
    func registerShortcutsTools() {
        register(ShortcutsToolRouting.listShortcutsDefinition) { _ in
            let shortcutsBridge = ShortcutsBridge.shared
            await shortcutsBridge.refreshIfStale()
            if case .unavailable(let reason) = shortcutsBridge.availability {
                return "shortcuts aren't available: \(reason)"
            }
            let shortcutNames = shortcutsBridge.cachedShortcutNames
            guard !shortcutNames.isEmpty else { return "the user has no shortcuts." }
            return ShortcutRunResultFormatter.capped(shortcutNames.joined(separator: "\n"))
        }

        register(ShortcutsToolRouting.runShortcutDefinition()) { input in
            guard case .object(let arguments) = input,
                  case .string(let rawShortcutName)? = arguments["name"],
                  !rawShortcutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "i need the name of the shortcut to run."
            }
            var textInput: String?
            if case .string(let rawTextInput)? = arguments["input"],
               !rawTextInput.isEmpty {
                textInput = rawTextInput
            }
            return await ShortcutsBridge.shared.runShortcut(named: rawShortcutName, textInput: textInput)
        }

        ShortcutsBridge.shared.refreshInBackgroundIfStale()
    }
}
