//
//  ChromeTabLifeCommand.swift
//  leanring-buddy
//
//  Pure recognition of the tab-life commands (phase 04): save / restore / list
//  tab sessions, "clean up old tabs", and "triage my tabs".
//
//  Checked by `ChromeTabCommandRouter` before its own phrases, because "clean
//  up old tabs" would otherwise read as "organize my tabs" ("clean up" is one
//  of its verbs). Like every deterministic router here it is biased toward not
//  matching: a miss is an ordinary model turn (which has the same abilities as
//  tools), a false match opens or closes tabs the user didn't ask about.
//

import Foundation

nonisolated enum ChromeTabLifeCommand: Equatable, Sendable {
    enum SaveScope: Equatable, Sendable {
        case focusedWindow
        case allWindows
    }

    /// `sessionName` nil → a dated name ("Tabs Oct 22").
    case saveSession(sessionName: String?, scope: SaveScope)
    case restoreSession(spokenName: String)
    case listSessions
    case closeStaleTabs(ChromeStaleTabRules)
    case triage(ChromeStaleTabRules)
}

nonisolated enum ChromeTabLifeCommandRouter {

    private static let maximumCommandWordCount = 14

    private static let questionOpenings = [
        "how ", "why ", "when ", "where ", "who ", "is there ", "are there ",
        "can i ", "could i ", "should i ", "do i ", "does ", "did ",
    ]

    /// The command a transcript plainly asks for, or nil.
    ///
    /// - Parameter savedSessionNames: lets "reopen thesis research" through
    ///   without the word "session" — but only when that names a saved one.
    static func command(for transcript: String, savedSessionNames: [String]) -> ChromeTabLifeCommand? {
        let text = normalized(transcript)
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty, words.count <= maximumCommandWordCount else { return nil }

        if let listCommand = listCommand(in: text) { return listCommand }
        guard !questionOpenings.contains(where: { text.hasPrefix($0) }) else { return nil }
        if text.hasPrefix("what ") || text.hasPrefix("which ") { return nil }

        if let triageCommand = triageCommand(in: text) { return triageCommand }
        if let staleCommand = closeStaleCommand(in: text) { return staleCommand }
        if let saveCommand = saveCommand(in: text) { return saveCommand }
        if let restoreCommand = restoreCommand(in: text, savedSessionNames: savedSessionNames) { return restoreCommand }
        return nil
    }

    // MARK: List

    /// "what tab sessions do i have", "list my tab sessions", "show my saved tabs".
    private static func listCommand(in text: String) -> ChromeTabLifeCommand? {
        let namesSessions = containsWholePhrase("tab sessions", in: text)
            || containsWholePhrase("tab session", in: text)
            || containsWholePhrase("saved tabs", in: text)
            || containsWholePhrase("saved sessions", in: text)
            || containsWholePhrase("saved tab sessions", in: text)
        guard namesSessions else { return nil }
        let asksForList = ["what ", "which ", "list ", "show ", "show me ", "tell me "].contains { text.hasPrefix($0) }
            || text.hasPrefix("what're ")
        // "what's in my thesis tab session" is about one session; leave it to the model.
        guard asksForList, !text.contains(" in my "), !text.contains(" in the ") else { return nil }
        return .listSessions
    }

    // MARK: Triage

    /// "triage my tabs", "triage chrome".
    private static func triageCommand(in text: String) -> ChromeTabLifeCommand? {
        guard text.hasPrefix("triage ") else { return nil }
        let rest = String(text.dropFirst("triage ".count))
        let acceptedObjects = [
            "my tabs", "tabs", "the tabs", "all my tabs", "my chrome tabs", "chrome tabs", "chrome", "my chrome",
            "my browser", "my browser tabs", "my open tabs",
        ]
        let (objectText, rules, _) = splitStaleOptions(from: rest)
        guard acceptedObjects.contains(objectText) else { return nil }
        return .triage(rules)
    }

    // MARK: Clean up old tabs

    private static let staleVerbs = ["clean up", "cleanup", "clean out", "close", "clear", "clear out", "sweep", "get rid of", "tidy", "tidy up", "remove", "prune"]
    private static let staleWords = ["old", "stale", "unused", "inactive", "forgotten", "abandoned", "ancient"]

    /// "clean up old tabs", "close tabs i haven't used in 2 weeks",
    /// "close stale tabs including chrome pages".
    private static func closeStaleCommand(in text: String) -> ChromeTabLifeCommand? {
        guard let verb = staleVerbs.first(where: { text.hasPrefix($0 + " ") }) else { return nil }
        let rest = String(text.dropFirst(verb.count + 1))
        let (objectText, rules, namedAnAge) = splitStaleOptions(from: rest)

        // The object must be stale tabs, said one of a few ways.
        let objectWords = objectText.split(separator: " ").map(String.init).filter { !["my", "the", "all", "any", "chrome", "browser"].contains($0) }
        guard let tabWordIndex = objectWords.firstIndex(where: { $0 == "tabs" || $0 == "tab" }) else { return nil }
        let wordsBeforeTabs = objectWords[..<tabWordIndex]
        let wordsAfterTabs = Array(objectWords[(tabWordIndex + 1)...])

        let saysStaleBeforeTabs = !wordsBeforeTabs.isEmpty && wordsBeforeTabs.allSatisfy { staleWords.contains($0) }
        let saysUnusedAfterTabs = isUnusedClause(wordsAfterTabs.joined(separator: " "))
        let saysNothingAfterTabs = wordsAfterTabs.isEmpty
        // "tabs older than 30 days" says stale by naming the age.
        let saysOnlyTabsWithAnAge = wordsBeforeTabs.isEmpty && saysNothingAfterTabs && namedAnAge
        guard (saysStaleBeforeTabs && (saysNothingAfterTabs || saysUnusedAfterTabs))
                || (wordsBeforeTabs.isEmpty && saysUnusedAfterTabs)
                || saysOnlyTabsWithAnAge else { return nil }
        return .closeStaleTabs(rules)
    }

    /// "i haven't used", "i havent looked at", "nobody's opened", "not used".
    private static func isUnusedClause(_ clause: String) -> Bool {
        let unusedClauses = [
            "i haven't used", "i havent used", "i have not used", "i haven't opened", "i havent opened",
            "i haven't looked at", "i havent looked at", "i haven't touched", "i havent touched",
            "i don't use", "i dont use", "not used", "i'm not using", "im not using", "i forgot about",
            "that are old", "that are stale", "that i haven't used", "that i havent used",
            "i haven't used in a while", "i havent used in a while", "i haven't opened in a while",
            "i havent opened in a while", "i haven't looked at in a while", "i havent looked at in a while",
        ]
        return unusedClauses.contains(clause)
    }

    /// Pulls "older than 7 days" / "in 2 weeks" / "for a month" and "including
    /// chrome pages" off the end, returning what's left and the rules.
    static func splitStaleOptions(from rawText: String) -> (remainingText: String, rules: ChromeStaleTabRules, namedAnAge: Bool) {
        var text = rawText
        var includesChromePages = false
        for chromePagesPhrase in [" including chrome pages", " and chrome pages", " including chrome tabs", " including settings pages"]
        where text.hasSuffix(chromePagesPhrase) {
            includesChromePages = true
            text = String(text.dropLast(chromePagesPhrase.count))
            break
        }

        var minimumDaysUnused = ChromeStaleTabRules.defaultMinimumDaysUnused
        var namedAnAge = false
        let durationLeadIns = [" older than ", " in over ", " in more than ", " in the last ", " in the past ", " for over ", " for more than ", " in ", " for ", " over ", " from the last ", " since "]
        for leadIn in durationLeadIns {
            guard let leadInRange = text.range(of: leadIn, options: .backwards) else { continue }
            let durationText = String(text[leadInRange.upperBound...])
            guard let parsedDays = days(inDurationText: durationText) else { continue }
            minimumDaysUnused = parsedDays
            // Only an age ("older than 30 days") makes bare "tabs" mean old
            // tabs; "close tabs in 2 weeks" is about when, not which.
            namedAnAge = [" older than ", " over ", " in over ", " in more than ", " for over ", " for more than "].contains(leadIn)
            text = String(text[..<leadInRange.lowerBound])
            break
        }
        return (
            text.trimmingCharacters(in: .whitespaces),
            ChromeStaleTabRules(minimumDaysUnused: minimumDaysUnused, includesChromePages: includesChromePages),
            namedAnAge
        )
    }

    private static let numberWords: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "fourteen": 14, "thirty": 30, "a couple": 2, "a few": 3,
    ]

    /// "2 weeks" → 14, "a month" → 30, "10 days" → 10. Nil unless the whole
    /// text is a duration.
    static func days(inDurationText durationText: String) -> Int? {
        let unitDays: [(unit: String, days: Int)] = [
            ("days", 1), ("day", 1), ("weeks", 7), ("week", 7), ("months", 30), ("month", 30),
        ]
        for (unitName, daysPerUnit) in unitDays where durationText.hasSuffix(" " + unitName) || durationText == unitName {
            let countText = durationText == unitName ? "a" : String(durationText.dropLast(unitName.count + 1))
            let count: Int?
            if let numericCount = Int(countText) { count = numericCount } else { count = numberWords[countText] }
            guard let count, count > 0 else { return nil }
            return count * daysPerUnit
        }
        return nil
    }

    // MARK: Save

    /// "save these tabs as thesis research", "save this window", "save all my tabs as backup".
    private static func saveCommand(in text: String) -> ChromeTabLifeCommand? {
        guard let saveVerb = ["save", "snapshot", "stash"].first(where: { text.hasPrefix($0 + " ") }) else { return nil }
        let rest = String(text.dropFirst(saveVerb.count + 1))

        let focusedWindowObjects = [
            "these tabs", "this window", "my tabs", "the tabs", "tabs", "this window's tabs", "the tabs in this window",
            "my open tabs", "open tabs", "these", "my window", "this browser window", "my chrome tabs", "these chrome tabs",
        ]
        let allWindowObjects = ["all my tabs", "all tabs", "all the tabs", "every tab", "all my windows", "all windows", "all my chrome tabs", "everything in chrome"]

        var objectText = rest
        var sessionName: String?
        for nameLeadIn in [" as ", " called ", " named ", " under "] {
            guard let leadInRange = rest.range(of: nameLeadIn) else { continue }
            objectText = String(rest[..<leadInRange.lowerBound])
            let nameText = String(rest[leadInRange.upperBound...])
            let cleanedSessionName = ChromeTabSessionBuilder.cleanedName(nameText)
            guard !ChromeTabSessionNameMatcher.normalizedName(cleanedSessionName).isEmpty,
                  cleanedSessionName.split(separator: " ").count <= 8 else { return nil }
            sessionName = cleanedSessionName
            break
        }
        // A bare "save these" needs the name to make it about tabs.
        if objectText == "these" && sessionName == nil { return nil }
        if objectText.hasSuffix(" for later") { objectText = String(objectText.dropLast(" for later".count)) }

        if focusedWindowObjects.contains(objectText) { return .saveSession(sessionName: sessionName, scope: .focusedWindow) }
        if allWindowObjects.contains(objectText) { return .saveSession(sessionName: sessionName, scope: .allWindows) }
        return nil
    }

    // MARK: Restore

    /// "restore thesis research", "reopen my thesis research tabs",
    /// "bring back the thesis research session", "open my tab session thesis research".
    private static func restoreCommand(in text: String, savedSessionNames: [String]) -> ChromeTabLifeCommand? {
        let restoreVerbs = ["restore", "reopen", "re-open", "bring back", "open up", "open"]
        guard let verb = restoreVerbs.first(where: { text.hasPrefix($0 + " ") }) else { return nil }
        var spokenName = String(text.dropFirst(verb.count + 1))
        for lead in ["my tab session ", "the tab session ", "tab session ", "my session ", "the session ", "session "] where spokenName.hasPrefix(lead) {
            spokenName = String(spokenName.dropFirst(lead.count))
            break
        }
        guard !spokenName.isEmpty else { return nil }

        let namesASavedSession = ChromeTabSessionNameMatcher.phraseNamesASavedSession(spokenName, savedSessionNames: savedSessionNames)
        let saysSession = containsWholePhrase("session", in: text)
        if verb == "open" || verb == "open up" {
            // "open gmail" opens a site, even if a session happens to be called
            // "gmail"; only "open my gmail tabs" / "open the gmail session" restores.
            let saysTabsOrSession = saysSession || text.hasSuffix(" tabs")
            guard namesASavedSession && saysTabsOrSession else { return nil }
            return .restoreSession(spokenName: spokenName)
        }
        // Without a saved name to anchor it, only "… session" counts:
        // "reopen the last closed tab" is a tab command, not a session.
        guard namesASavedSession || saysSession else { return nil }
        return .restoreSession(spokenName: spokenName)
    }

    // MARK: Helpers

    static func normalized(_ transcript: String) -> String {
        var text = transcript
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: ",", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))
        for leadingFiller in ["hey wisp ", "wisp ", "hey ", "okay ", "ok ", "so ", "please ", "can you ", "could you ", "would you "] where text.hasPrefix(leadingFiller) {
            text = String(text.dropFirst(leadingFiller.count))
        }
        for leadingFiller in ["please "] where text.hasPrefix(leadingFiller) {
            text = String(text.dropFirst(leadingFiller.count))
        }
        for trailingFiller in [" please", " for me"] where text.hasSuffix(trailingFiller) {
            text = String(text.dropLast(trailingFiller.count))
        }
        return text
    }

    private static func containsWholePhrase(_ phrase: String, in text: String) -> Bool {
        (" " + text + " ").contains(" " + phrase + " ")
    }
}
