//
//  AppActionMatching.swift
//  leanring-buddy
//
//  Pure side of Phase 5 of `docs/siri-style-plan.md`: doing things in other
//  apps through the user's Shortcuts.
//
//  macOS doesn't let an app call another app's App Intents directly — Siri
//  and Shortcuts can, Wisp can't. But apps that support Shortcuts ship their
//  actions as metadata inside the bundle
//  (`Contents/Resources/Metadata.appintents/extract.actionsdata`), so Wisp
//  can *read* what each app can do. When the user asks an app for something
//  Wisp has no tool for ("add a sticky note to my Freeform board saying buy
//  milk"), Wisp shows which of that app's actions would do it and suggests a
//  shortcut name; once the user has built a shortcut with that name, the same
//  kind of request runs it (`ShortcutRunRequestMatcher`), through the Run
//  Shortcut confirmation that always asks first.
//
//  This file holds the deterministic parts — reading the metadata, picking
//  the app and actions out of a request, naming the shortcut, and pulling the
//  input text out of a run request. Tested by `Tests/AppActions`.
//

import Foundation

/// One action another app offers to Shortcuts.
nonisolated struct InstalledAppAction: Sendable, Equatable, Identifiable {
    /// The App Intent's identifier, e.g. "AddStickyNoteToBoardIntent".
    let id: String
    /// What Shortcuts calls it: "Add Sticky Note to Board".
    let title: String
    /// Shortcuts' one-line explanation, when the app gives one.
    let descriptionText: String?
    /// The action's inputs, by title: "Board", "Text".
    let parameterTitles: [String]
}

/// An installed app and the actions it offers to Shortcuts.
nonisolated struct InstalledApplicationActions: Sendable, Equatable, Identifiable {
    let applicationName: String
    let bundleIdentifier: String
    let applicationPath: String
    let actions: [InstalledAppAction]

    var id: String { bundleIdentifier }
}

// MARK: - Reading an app's metadata

nonisolated enum AppIntentsMetadataParser {

    /// The discoverable actions in an app's `extract.actionsdata`, with titles
    /// resolved through `localizedString` (the app's own strings), falling
    /// back to a readable form of the key.
    static func actions(
        fromActionsData actionsData: Data,
        localizedString: (String) -> String?
    ) -> [InstalledAppAction] {
        guard let metadata = try? JSONSerialization.jsonObject(with: actionsData) as? [String: Any],
              let actionsByIdentifier = metadata["actions"] as? [String: Any] else { return [] }

        var parsedActions: [InstalledAppAction] = []
        for (actionIdentifier, rawAction) in actionsByIdentifier {
            guard let action = rawAction as? [String: Any] else { continue }
            // Hidden from people (only for Siri's own use, or not discoverable).
            if let visibility = action["visibilityMetadata"] as? [String: Any] {
                if visibility["assistantOnly"] as? Bool == true { continue }
                if visibility["isDiscoverable"] as? Bool == false { continue }
            }
            if action["isDiscoverable"] as? Bool == false { continue }

            guard let titleKey = (action["title"] as? [String: Any])?["key"] as? String,
                  let title = resolvedText(forKey: titleKey, localizedString: localizedString),
                  !isInternalTitle(title) else { continue }

            let descriptionKey = (((action["descriptionMetadata"] as? [String: Any])?["descriptionText"]) as? [String: Any])?["key"] as? String
            let descriptionText = descriptionKey.flatMap { resolvedLocalizedTextOnly(forKey: $0, localizedString: localizedString) }

            let parameterTitles = (action["parameters"] as? [[String: Any]] ?? []).compactMap { parameter -> String? in
                guard let parameterTitleKey = (parameter["title"] as? [String: Any])?["key"] as? String else { return nil }
                return resolvedText(forKey: parameterTitleKey, localizedString: localizedString)
            }
            parsedActions.append(InstalledAppAction(
                id: actionIdentifier,
                title: title,
                descriptionText: descriptionText,
                parameterTitles: parameterTitles
            ))
        }
        return parsedActions.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Titles meant for developers rather than people: Apple's own test
    /// actions ("Test: Drive to Apple Park") and generated entity-setting
    /// titles ("Update a BookSettings AppEntity's …").
    static func isInternalTitle(_ title: String) -> Bool {
        title.hasPrefix("Test:") || title.contains("AppEntity")
    }

    /// The localized text for a key, or a readable form of the key itself.
    /// Nil for keys that are empty or a placeholder.
    static func resolvedText(forKey key: String, localizedString: (String) -> String?) -> String? {
        if let localizedText = resolvedLocalizedTextOnly(forKey: key, localizedString: localizedString) {
            return localizedText
        }
        return AppActionTitleHumanizer.readableTitle(fromKey: key)
    }

    private static func resolvedLocalizedTextOnly(forKey key: String, localizedString: (String) -> String?) -> String? {
        guard let localizedText = localizedString(key)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !localizedText.isEmpty, localizedText != key else { return nil }
        return localizedText
    }
}

/// Turns a string key into words when the app's strings can't be read:
/// "PlayMusicItemSiriIntent_Title" → "Play Music Item",
/// "CREATE_FOLDER_INTENT_TITLE" → "Create Folder".
nonisolated enum AppActionTitleHumanizer {
    private static let trailingNoiseWords: Set<String> = ["title", "intent", "siri", "app", "action", "name"]

    static func readableTitle(fromKey key: String) -> String? {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        // A key that already reads as words ("Add Sticky Note") is the title.
        if trimmedKey.contains(" ") { return trimmedKey.isEmpty ? nil : trimmedKey }
        guard trimmedKey.count > 1, trimmedKey != "?" else { return nil }

        var words: [String] = []
        for underscoreSeparatedPart in trimmedKey.split(separator: "_") {
            words.append(contentsOf: splitCamelCase(String(underscoreSeparatedPart)))
        }
        var lowercasedWords = words.map { $0.lowercased() }
        while let lastWord = lowercasedWords.last, trailingNoiseWords.contains(lastWord) {
            lowercasedWords.removeLast()
        }
        guard !lowercasedWords.isEmpty else { return nil }
        return lowercasedWords.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// "PlayMusicItem" → ["Play", "Music", "Item"]; "URLLink" → ["URL", "Link"];
    /// an all-caps word stays whole.
    private static func splitCamelCase(_ text: String) -> [String] {
        guard text != text.uppercased() else { return [text] }
        var words: [String] = []
        var currentWord = ""
        let characters = Array(text)
        for (characterIndex, character) in characters.enumerated() {
            let startsNewWord = character.isUppercase && !currentWord.isEmpty && (
                !(characters[characterIndex - 1].isUppercase)
                    || (characterIndex + 1 < characters.count && characters[characterIndex + 1].isLowercase)
            )
            if startsNewWord {
                words.append(currentWord)
                currentWord = ""
            }
            currentWord.append(character)
        }
        if !currentWord.isEmpty { words.append(currentWord) }
        return words
    }
}

// MARK: - Shared word handling

nonisolated enum AppActionWords {
    /// Lowercased words of letters and digits; apostrophes dropped, as
    /// `ShortcutNameMatcher` does, so names compare the same way.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// Equal, or equal once a plural "s" is dropped.
    static func wordsMatch(_ firstWord: String, _ secondWord: String) -> Bool {
        if firstWord == secondWord { return true }
        guard firstWord.count >= 4, secondWord.count >= 4 else { return false }
        return firstWord == secondWord + "s" || secondWord == firstWord + "s"
    }

    /// Grammar, not subject.
    static let fillerWords: Set<String> = [
        "a", "an", "the", "to", "in", "on", "of", "for", "with", "and", "or", "my", "me", "your", "into",
        "using", "from", "via", "at", "by", "please", "can", "could", "would", "you", "it", "this", "that",
        "app", "application", "hey", "wisp", "just", "now", "some", "new",
    ]
}

// MARK: - Suggesting a shortcut

/// What to show when the user asked another app for something Wisp can only
/// reach through a shortcut.
nonisolated struct AppActionSuggestion: Sendable, Equatable {
    let application: InstalledApplicationActions
    /// The app's actions that fit the request, best first (at most three).
    let matchedActions: [InstalledAppAction]
    /// The name to give the shortcut, so the next request runs it.
    let suggestedShortcutName: String
}

nonisolated enum AppActionRequestMatcher {

    /// Verbs that start a request for an app to *do* something.
    private static let actionVerbs: Set<String> = [
        "add", "create", "make", "start", "stop", "pause", "resume", "play", "open", "show", "schedule",
        "set", "change", "turn", "toggle", "log", "send", "record", "take", "append", "export", "convert",
        "save", "new", "begin", "end", "skip", "delete", "archive", "share", "put", "post", "write", "search",
    ]

    /// Prepositions that put an app's name in a request: "in Freeform",
    /// "to Word". App names are often ordinary words (Teams, Word, Flow), so a
    /// name only counts right after the verb, after one of these, or after
    /// "my" in either place ("pause my flow session", "to my Freeform board")
    /// — "change the teams status page" is about a page, not the app.
    private static let prepositionsBeforeApplicationName: Set<String> = [
        "in", "to", "on", "into", "with", "using", "from", "via",
    ]

    private static let vendorPrefixes = ["microsoft ", "google ", "adobe ", "apple "]

    /// A suggestion when `request` asks one of `installedApplications` (named
    /// in it) to do something one of its actions does; nil otherwise —
    /// including questions ("how do I…") and requests no action fits.
    static func suggestion(
        forRequest request: String,
        installedApplications: [InstalledApplicationActions]
    ) -> AppActionSuggestion? {
        var requestWords = AppActionWords.words(request)
        for politeWord in ["please", "can", "could", "you", "hey", "wisp"] {
            while requestWords.first == politeWord { requestWords.removeFirst() }
        }
        guard let firstWord = requestWords.first, actionVerbs.contains(firstWord) else { return nil }

        guard let (application, applicationNameWords) = namedApplication(in: requestWords, among: installedApplications) else {
            return nil
        }
        let applicationNameWordSet = Set(applicationNameWords)
        let subjectWords = requestWords.filter { !AppActionWords.fillerWords.contains($0) && !applicationNameWordSet.contains($0) }
        guard !subjectWords.isEmpty else { return nil }

        let scoredActions: [(action: InstalledAppAction, score: Int)] = application.actions.compactMap { action in
            let titleWords = AppActionWords.words(action.title)
                .filter { !AppActionWords.fillerWords.contains($0) && !applicationNameWordSet.contains($0) }
            let matchedTitleWordCount = titleWords.filter { titleWord in
                subjectWords.contains { AppActionWords.wordsMatch($0, titleWord) }
            }.count
            guard matchedTitleWordCount > 0 else { return nil }
            // A request that only shares its verb with an action ("open") is
            // too thin a match on its own; it needs a word of substance too.
            let matchedNonVerbWordCount = titleWords.filter { titleWord in
                !actionVerbs.contains(titleWord) && subjectWords.contains { AppActionWords.wordsMatch($0, titleWord) }
            }.count
            guard matchedNonVerbWordCount > 0 else { return nil }
            let descriptionWords = Set(AppActionWords.words(action.descriptionText ?? ""))
            let matchedDescriptionWordCount = subjectWords.filter { descriptionWords.contains($0) }.count
            let titleStartsWithRequestVerb = titleWords.first.map { AppActionWords.wordsMatch($0, firstWord) } ?? false
            let score = matchedTitleWordCount * 10 + matchedDescriptionWordCount + (titleStartsWithRequestVerb ? 5 : 0)
            return (action, score)
        }
        let rankedActions = scoredActions
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.action.title < $1.action.title }
            .prefix(3)
            .map(\.action)
        guard let bestAction = rankedActions.first else { return nil }

        return AppActionSuggestion(
            application: application,
            matchedActions: rankedActions,
            suggestedShortcutName: suggestedShortcutName(for: bestAction, in: application)
        )
    }

    /// "Add Sticky Note to Board" in Freeform → "Add Sticky Note to Board in
    /// Freeform"; a title that already names the app keeps its own wording.
    static func suggestedShortcutName(for action: InstalledAppAction, in application: InstalledApplicationActions) -> String {
        let titleWords = Set(AppActionWords.words(action.title))
        let shortApplicationName = shortName(of: application.applicationName)
        let shortNameWords = AppActionWords.words(shortApplicationName)
        if !shortNameWords.isEmpty && shortNameWords.allSatisfy(titleWords.contains) {
            return action.title
        }
        return "\(action.title) in \(shortApplicationName)"
    }

    /// "Microsoft Teams" → "Teams"; other names unchanged.
    static func shortName(of applicationName: String) -> String {
        let lowercasedName = applicationName.lowercased()
        for vendorPrefix in vendorPrefixes where lowercasedName.hasPrefix(vendorPrefix) {
            return String(applicationName.dropFirst(vendorPrefix.count))
        }
        return applicationName
    }

    /// Whether a name starting at `startIndex` is placed like an app's name.
    private static func isApplicationNamePosition(_ startIndex: Int, in requestWords: [String]) -> Bool {
        let previousWord = requestWords[startIndex - 1]
        if startIndex == 1 || prepositionsBeforeApplicationName.contains(previousWord) { return true }
        guard previousWord == "my" else { return false }
        let wordBeforeMy = startIndex - 2
        return wordBeforeMy == 0 || prepositionsBeforeApplicationName.contains(requestWords[wordBeforeMy])
    }

    /// The app the request names: its full or short name as a run of words,
    /// right after the verb or after a word like "in"/"to"/"my". The longest
    /// name wins ("Microsoft Teams" over "Teams"-anything).
    private static func namedApplication(
        in requestWords: [String],
        among installedApplications: [InstalledApplicationActions]
    ) -> (InstalledApplicationActions, [String])? {
        var bestMatch: (application: InstalledApplicationActions, nameWords: [String])?
        for application in installedApplications where !application.actions.isEmpty {
            let candidateNames = [application.applicationName, shortName(of: application.applicationName)]
            for candidateName in candidateNames {
                let nameWords = AppActionWords.words(candidateName)
                // The verb comes first, so the name has to fit after it.
                guard !nameWords.isEmpty, nameWords.count < requestWords.count else { continue }
                for startIndex in 1...(requestWords.count - nameWords.count) {
                    guard Array(requestWords[startIndex..<(startIndex + nameWords.count)]) == nameWords else { continue }
                    guard isApplicationNamePosition(startIndex, in: requestWords) else { continue }
                    if bestMatch == nil || nameWords.count > bestMatch!.nameWords.count {
                        bestMatch = (application, nameWords)
                    }
                }
            }
        }
        return bestMatch.map { ($0.application, $0.nameWords) }
    }
}

// MARK: - Running the shortcut next time

/// A request that names one of the user's shortcuts strongly enough to run it
/// without the model choosing to, and the text to hand it.
nonisolated struct ShortcutRunRequest: Sendable, Equatable {
    let shortcutName: String
    /// The request's own content ("buy milk"), or nil when there's none.
    let textInput: String?
}

nonisolated enum ShortcutRunRequestMatcher {

    private static let runCueWords: Set<String> = ["run", "trigger", "launch", "execute"]
    /// Words after which the rest of the request is the input: "saying buy milk".
    private static let inputIntroducingWords: Set<String> = ["saying", "says", "called", "named", "titled"]

    /// A run request when every meaningful word of a shortcut's name (at
    /// least two) is in the request and the request starts with the name's
    /// first word or "run". The best-covered name wins. Run Shortcut always
    /// asks before running, so a near miss costs a Cancel, never an action.
    static func runRequest(forRequest request: String, shortcutNames: [String]) -> ShortcutRunRequest? {
        var requestWords = AppActionWords.words(request)
        for politeWord in ["please", "can", "could", "you", "hey", "wisp"] {
            while requestWords.first == politeWord { requestWords.removeFirst() }
        }
        guard let firstRequestWord = requestWords.first else { return nil }

        var bestShortcutName: String?
        var bestMeaningfulWordCount = 0
        for shortcutName in shortcutNames {
            let meaningfulNameWords = AppActionWords.words(shortcutName).filter { !AppActionWords.fillerWords.contains($0) }
            guard meaningfulNameWords.count >= 2 else { continue }
            let everyWordPresent = meaningfulNameWords.allSatisfy { nameWord in
                requestWords.contains { AppActionWords.wordsMatch($0, nameWord) }
            }
            let startsLikeTheName = AppActionWords.wordsMatch(firstRequestWord, meaningfulNameWords[0]) || runCueWords.contains(firstRequestWord)
            guard everyWordPresent, startsLikeTheName, meaningfulNameWords.count > bestMeaningfulWordCount else { continue }
            bestShortcutName = shortcutName
            bestMeaningfulWordCount = meaningfulNameWords.count
        }
        guard let bestShortcutName else { return nil }
        return ShortcutRunRequest(shortcutName: bestShortcutName, textInput: textInput(fromRequest: request, shortcutName: bestShortcutName))
    }

    /// What to pass the shortcut: quoted text if there is any; otherwise what
    /// follows "saying"/"called"/":"; otherwise the request without the
    /// shortcut's own words and grammar. Keeps the user's casing.
    static func textInput(fromRequest request: String, shortcutName: String) -> String? {
        for quoteCharacters in [("\"", "\""), ("“", "”")] {
            if let openingRange = request.range(of: quoteCharacters.0),
               let closingRange = request.range(of: quoteCharacters.1, range: openingRange.upperBound..<request.endIndex) {
                let quotedText = request[openingRange.upperBound..<closingRange.lowerBound].trimmingCharacters(in: .whitespaces)
                if !quotedText.isEmpty { return quotedText }
            }
        }
        if let colonRange = request.range(of: ":") {
            let textAfterColon = request[colonRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !textAfterColon.isEmpty { return textAfterColon }
        }

        let originalWords = request.split(separator: " ").map(String.init)
        for (wordIndex, originalWord) in originalWords.enumerated() {
            let normalizedWord = AppActionWords.words(originalWord).first ?? ""
            if inputIntroducingWords.contains(normalizedWord), wordIndex + 1 < originalWords.count {
                let followingText = originalWords[(wordIndex + 1)...].joined(separator: " ")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))
                if !followingText.isEmpty { return followingText }
            }
        }

        let shortcutNameWords = AppActionWords.words(shortcutName)
        let remainingWords = originalWords.filter { originalWord in
            guard let normalizedWord = AppActionWords.words(originalWord).first else { return false }
            if AppActionWords.fillerWords.contains(normalizedWord) || runCueWords.contains(normalizedWord) { return false }
            if normalizedWord == "shortcut" || inputIntroducingWords.contains(normalizedWord) { return false }
            return !shortcutNameWords.contains { AppActionWords.wordsMatch($0, normalizedWord) }
        }
        let remainingText = remainingWords.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))
        return remainingText.isEmpty ? nil : remainingText
    }
}
