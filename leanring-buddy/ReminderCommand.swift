//
//  ReminderCommand.swift
//  leanring-buddy
//
//  Pure side of the Siri-style reminders fast path (Phase 2 of
//  `docs/siri-style-plan.md`): "remind me to call the bank tomorrow at 9",
//  "remind me in 20 minutes to stretch", "add milk to my shopping list",
//  "create a reminder to renew my passport" become a reminder draft with no
//  model call.
//
//  Built on the calendar fast path's pieces. The time phrase is read by
//  `CalendarEventWhenResolver`, so a model never computes a date. Unlike an
//  event, a reminder doesn't need a time, so a request with no time phrase is
//  an undated reminder rather than a miss.
//
//  Biased toward not matching: questions ("remind me what time the meeting
//  is") and recurring requests ("remind me every day") are declined, and so
//  is "add this page to my reading list", which is Safari's, not Reminders'.
//  A request that is clearly a reminder but whose words can't be split comes
//  back as `.needsExtraction` for Apple's on-device model
//  (`ReminderDraftExtractor`), whose answer `draft(fromExtractedTitle:…)`
//  checks. Tested by `Tests/ReminderCommand`.
//

import Foundation

/// A reminder ready for the confirmation card.
nonisolated struct ReminderDraft: Sendable, Equatable {
    let title: String
    /// Nil for an undated reminder.
    let dueDate: Date?
    /// False for a day with no time ("tomorrow"): due that day, no alarm.
    let dueDateIncludesTimeOfDay: Bool
    /// The list the user named ("my shopping list" → "shopping"), matched
    /// against Reminders' lists when saving; nil uses the default list.
    let listName: String?
}

nonisolated enum ReminderCommandParseOutcome: Sendable, Equatable {
    case notAReminderCommand
    case draft(ReminderDraft)
    /// Clearly a reminder, but what and when couldn't be told apart.
    case needsExtraction(requestBody: String, listName: String?)
}

nonisolated enum ReminderCommandParser {

    /// A title longer than this is more likely a mis-split sentence.
    static let maximumDeterministicTitleWordCount = 12

    static func parse(
        _ transcript: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ReminderCommandParseOutcome {
        let normalizedTranscript = CalendarEventCommandParser.normalizedCommandText(transcript)
        let commandText = CalendarEventCommandParser.removingPolitenessPrefix(from: normalizedTranscript)
        guard let recognizedRequest = recognizedReminderRequest(in: commandText) else {
            return .notAReminderCommand
        }
        let requestBody = recognizedRequest.requestBody
        let requestBodyWords = CalendarEventCommandParser.lowercasedWords(in: requestBody)
        guard !requestBodyWords.isEmpty else { return .notAReminderCommand }

        // A repeating reminder needs a recurrence rule, which this path and
        // the `create_reminder` tool don't offer.
        guard Set(requestBodyWords).isDisjoint(with: recurrenceWords) else { return .notAReminderCommand }

        let titleSourceText: String
        let resolvedWhen = CalendarEventWhenResolver.resolve(requestBody, now: now, calendar: calendar)
        if let resolvedWhen {
            titleSourceText = CalendarEventCommandParser.textReplacingTimePhrase(
                in: requestBody,
                timePhraseRange: resolvedWhen.matchedRange
            )
        } else if mentionsTime(requestBody) {
            // Something about time was said that the resolver couldn't read
            // ("by the end of next week") — not a reminder to save undated.
            return .needsExtraction(requestBody: requestBody, listName: recognizedRequest.listName)
        } else {
            titleSourceText = requestBody
        }

        let cleanedTitle = cleanedReminderTitle(titleSourceText)
        let titleWords = CalendarEventCommandParser.lowercasedWords(in: cleanedTitle)
        guard !titleWords.isEmpty,
              titleWords.count <= maximumDeterministicTitleWordCount,
              !titleWords.allSatisfy(CalendarEventCommandParser.isTemporalWord) else {
            return .needsExtraction(requestBody: requestBody, listName: recognizedRequest.listName)
        }

        return .draft(ReminderDraft(
            title: cleanedTitle,
            dueDate: resolvedWhen?.startDate,
            dueDateIncludesTimeOfDay: resolvedWhen?.includesTimeOfDay ?? false,
            listName: recognizedRequest.listName
        ))
    }

    /// Builds a draft from what Apple's on-device model picked out of a
    /// request handed to extraction — only if it holds up: the title must be
    /// the user's own words (and not only time words), and a time phrase, if
    /// any, must be words the user said, resolved here rather than by the model.
    static func draft(
        fromExtractedTitle extractedTitle: String,
        extractedWhenPhrase: String,
        requestBody: String,
        listName: String?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ReminderDraft? {
        let requestBodyWords = Set(CalendarEventCommandParser.lowercasedWords(in: requestBody))
        let cleanedTitle = cleanedReminderTitle(extractedTitle)
        let titleWords = CalendarEventCommandParser.lowercasedWords(in: cleanedTitle)
        guard !titleWords.isEmpty,
              titleWords.allSatisfy({ requestBodyWords.contains($0) }),
              !titleWords.allSatisfy(CalendarEventCommandParser.isTemporalWord) else {
            return nil
        }

        let whenPhrase = extractedWhenPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !whenPhrase.isEmpty else {
            // No time is fine for a reminder — unless the user plainly said one
            // and the model lost it.
            guard !mentionsTime(requestBody) else { return nil }
            return ReminderDraft(title: cleanedTitle, dueDate: nil, dueDateIncludesTimeOfDay: false, listName: listName)
        }
        guard requestBody.lowercased().contains(whenPhrase.lowercased()),
              let resolvedWhen = CalendarEventWhenResolver.resolve(whenPhrase, now: now, calendar: calendar) else {
            return nil
        }
        return ReminderDraft(
            title: cleanedTitle,
            dueDate: resolvedWhen.startDate,
            dueDateIncludesTimeOfDay: resolvedWhen.includesTimeOfDay,
            listName: listName
        )
    }

    // MARK: - Recognising the command

    private struct RecognizedReminderRequest {
        let requestBody: String
        let listName: String?
    }

    private static func recognizedReminderRequest(in commandText: String) -> RecognizedReminderRequest? {
        // "remind me to …", "remind me at 5 to …", "remind me tomorrow …".
        if let textAfterRemindMe = CalendarEventCommandParser.removingLeadingMatch(of: #"^remind\s+me\b\s*"#, from: commandText) {
            let firstWord = CalendarEventCommandParser.lowercasedWords(in: textAfterRemindMe).first ?? ""
            // "remind me what time the meeting is" asks for information.
            guard !questionWords.contains(firstWord) else { return nil }
            return RecognizedReminderRequest(requestBody: textAfterRemindMe, listName: nil)
        }

        // "create a reminder to renew my passport", "new reminder call mom".
        let reminderNounPattern = #"^(?:create|make|add|set|set\s+up|new)\s+(?:a\s+|an\s+)?(?:new\s+)?reminder\b\s*(?:(?:to|about|for|called|named|titled|that)\b\s*)?"#
        if let textAfterReminderNoun = CalendarEventCommandParser.removingLeadingMatch(of: reminderNounPattern, from: commandText) {
            return RecognizedReminderRequest(requestBody: textAfterReminderNoun, listName: nil)
        }

        // "add milk to my shopping list", "put call mom on my to-do list",
        // "add renew passport to my reminders".
        let listDestinationPattern = #"^(?:add|put)\s+(.+?)\s+(?:to|on|onto|in|into)\s+my\s+(?:(reminders)|(.+?)\s+list)$"#
        if let listMatch = CalendarEventCommandParser.firstMatch(of: listDestinationPattern, in: commandText),
           let itemText = CalendarEventCommandParser.substring(of: commandText, capturedBy: listMatch, groupIndex: 1) {
            let itemWords = CalendarEventCommandParser.lowercasedWords(in: itemText)
            // "add this page to my reading list" is Safari's reading list,
            // and "this"/"it" is something on screen the parser can't see.
            guard let firstItemWord = itemWords.first, !deicticWords.contains(firstItemWord) else { return nil }
            let spokenListName = CalendarEventCommandParser.substring(of: commandText, capturedBy: listMatch, groupIndex: 3)
            if let spokenListName, nonReminderListNames.contains(spokenListName.lowercased()) { return nil }
            return RecognizedReminderRequest(requestBody: itemText, listName: reminderListName(fromSpokenListName: spokenListName))
        }
        return nil
    }

    /// "to-do" and its spellings mean the default list; any other name is
    /// looked up in Reminders when saving.
    static func reminderListName(fromSpokenListName spokenListName: String?) -> String? {
        guard let spokenListName else { return nil }
        let compactListName = spokenListName.lowercased().filter { $0.isLetter }
        if ["todo", "todos", "reminder", "reminders", "task", "tasks"].contains(compactListName) { return nil }
        return CalendarEventCommandParser.capitalizedFirstLetter(spokenListName)
    }

    private static let questionWords: Set<String> = [
        "what", "what's", "whats", "how", "who", "when", "where", "why", "which", "if", "whether", "of"
    ]

    private static let deicticWords: Set<String> = ["this", "that", "it", "these", "those", "them"]

    /// Lists that belong to other apps.
    private static let nonReminderListNames: Set<String> = ["reading", "play", "watch", "wish"]

    private static let recurrenceWords: Set<String> = [
        "every", "each", "daily", "weekly", "monthly", "yearly", "annually", "weekdays", "fortnightly", "biweekly"
    ]

    // MARK: - Title

    /// Drops the "to"/"about"/"that" joining the time to the task, trailing
    /// connectors left by the removed time phrase ("call mom at" → "call
    /// mom"), and capitalises the first letter. Unlike an event title, words
    /// like "this" and "next" are kept: "finish this" is a real reminder.
    static func cleanedReminderTitle(_ rawTitle: String) -> String {
        var titleWords = CalendarEventCommandParser.normalizedCommandText(rawTitle).split(separator: " ").map(String.init)
        let leadingConnectorWords: Set<String> = ["to", "about", "that", "and", "then"]
        let trailingConnectorWords: Set<String> = ["on", "at", "by", "around", "in", "from", "until", "and"]
        while let firstWord = titleWords.first, leadingConnectorWords.contains(firstWord.lowercased()) {
            titleWords.removeFirst()
        }
        while let lastWord = titleWords.last, trailingConnectorWords.contains(lastWord.lowercased()) {
            titleWords.removeLast()
        }
        return CalendarEventCommandParser.capitalizedFirstLetter(titleWords.joined(separator: " "))
    }

    /// Whether the text says something about time, even if it couldn't be
    /// resolved: a digit, or a day/part-of-day word.
    static func mentionsTime(_ text: String) -> Bool {
        let words = CalendarEventCommandParser.lowercasedWords(in: text)
        return words.contains { word in
            word.contains(where: \.isNumber) || timeMentionWords.contains(word)
        }
    }

    private static let timeMentionWords: Set<String> = [
        "today", "tonight", "tomorrow", "morning", "afternoon", "evening", "noon", "midnight", "weekend",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "june", "july", "august",
        "september", "october", "november", "december", "minutes", "hours", "week", "month", "o'clock"
    ]
}
