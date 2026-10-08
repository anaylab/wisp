//
//  CalendarEventCommand.swift
//  leanring-buddy
//
//  Pure side of the Siri-style calendar fast path: recognising a spoken
//  scheduling request ("add lunch with Sam friday at 1 at Tartine", "schedule
//  the dentist thursday at 3pm for an hour") and turning it into an event
//  draft — title, start, end, all-day or not, location — with no model call.
//
//  Dates are never left to a language model. `CalendarEventWhenResolver`
//  reads the time phrase with `NSDataDetector` plus two deterministic rules
//  the detector misses (a bare "at 6", "in 2 hours"), and knows whether a time
//  of day was actually said, so "october 12" is an all-day event rather than
//  one at noon.
//
//  Biased toward not matching, like the other fast paths: only scheduling
//  phrasing is recognised, recurring requests ("every monday") are declined,
//  and a request that is clearly about the calendar but whose words can't be
//  split confidently comes back as `.needsExtraction`. CompanionManager then
//  tries Apple's on-device model (`CalendarEventDraftExtractor`), whose answer
//  is checked by `draft(fromExtractedTitle:…)` here, and otherwise sends it to
//  the ordinary model turn. Tested by `Tests/CalendarEventCommand`.
//

import Foundation

/// An event ready to be put on the confirmation card and created.
nonisolated struct CalendarEventDraft: Sendable, Equatable {
    let title: String
    let startDate: Date
    /// For an all-day event, the same day as `startDate` (the convention
    /// `create_calendar_event` already uses).
    let endDate: Date
    let isAllDay: Bool
    let location: String?
}

nonisolated enum CalendarEventCommandParseOutcome: Sendable, Equatable {
    /// Not a scheduling request — the turn goes on down the usual routes.
    case notACalendarCommand
    /// Parsed completely, deterministically.
    case draft(CalendarEventDraft)
    /// Clearly a scheduling request ("schedule call with mom at six-ish") but
    /// title, place and time couldn't be told apart with confidence.
    /// `requestBody` is what follows the command words.
    case needsExtraction(requestBody: String)
}

nonisolated enum CalendarEventCommandParser {

    /// Events with no stated length are an hour, like Calendar's default.
    static let defaultEventDurationSeconds: TimeInterval = 60 * 60

    /// A title longer than this is more likely a mis-split sentence than a
    /// calendar title, so it goes to extraction instead.
    static let maximumDeterministicTitleWordCount = 8

    static func parse(
        _ transcript: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> CalendarEventCommandParseOutcome {
        let normalizedTranscript = normalizedCommandText(transcript)
        guard let requestBody = requestBodyAfterCommandWords(in: normalizedTranscript) else {
            return .notACalendarCommand
        }
        guard !requestBody.isEmpty else { return .notACalendarCommand }

        // A repeating event needs a recurrence rule, which neither this path
        // nor the `create_calendar_event` tool offers. The model says so.
        let requestBodyWords = Set(lowercasedWords(in: requestBody))
        guard requestBodyWords.isDisjoint(with: recurrenceWords) else { return .notACalendarCommand }

        let (bodyWithoutDuration, statedDurationSeconds) = removingDurationPhrase(from: requestBody)
        guard let resolvedWhen = CalendarEventWhenResolver.resolve(bodyWithoutDuration, now: now, calendar: calendar) else {
            return .needsExtraction(requestBody: requestBody)
        }

        let textOutsideTimePhrase = textReplacingTimePhrase(
            in: bodyWithoutDuration,
            timePhraseRange: resolvedWhen.matchedRange
        )
        let (rawTitle, rawLocation) = splitTitleAndLocation(textOutsideTimePhrase)
        let cleanedTitle = cleanedTitleText(rawTitle)
        guard !cleanedTitle.isEmpty,
              lowercasedWords(in: cleanedTitle).count <= maximumDeterministicTitleWordCount else {
            return .needsExtraction(requestBody: requestBody)
        }

        return .draft(makeDraft(
            title: cleanedTitle,
            location: rawLocation.map(cleanedLocationText).flatMap { $0.isEmpty ? nil : $0 },
            resolvedWhen: resolvedWhen,
            statedDurationSeconds: statedDurationSeconds
        ))
    }

    /// Builds a draft from what Apple's on-device model picked out of a
    /// request the parser handed to extraction — only if it holds up. The time
    /// phrase must be the user's own words and is resolved here, never by the
    /// model; the title must be made of words the user said, so a model that
    /// invents one ("Team Sync") is rejected rather than shown on the card.
    static func draft(
        fromExtractedTitle extractedTitle: String,
        extractedLocation: String?,
        extractedWhenPhrase: String,
        requestBody: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> CalendarEventDraft? {
        let requestBodyLowercased = requestBody.lowercased()
        let whenPhrase = extractedWhenPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !whenPhrase.isEmpty,
              requestBodyLowercased.contains(whenPhrase.lowercased()),
              let resolvedWhen = CalendarEventWhenResolver.resolve(whenPhrase, now: now, calendar: calendar) else {
            return nil
        }

        let requestBodyWords = Set(lowercasedWords(in: requestBody))
        let cleanedTitle = cleanedTitleText(extractedTitle)
        let titleWords = lowercasedWords(in: cleanedTitle)
        guard !titleWords.isEmpty,
              titleWords.allSatisfy({ requestBodyWords.contains($0) }) else {
            return nil
        }

        var cleanedLocation: String?
        if let extractedLocation {
            let candidateLocation = cleanedLocationText(extractedLocation)
            let locationWords = lowercasedWords(in: candidateLocation)
            // A place the user didn't say is dropped rather than failing the
            // whole draft — the event is still right without it. So is one
            // made only of time words: the model was seen putting "next
            // wednesday afternoon" there.
            if !locationWords.isEmpty,
               locationWords.allSatisfy({ requestBodyWords.contains($0) }),
               !locationWords.allSatisfy(isTemporalWord) {
                cleanedLocation = candidateLocation
            }
        }

        return makeDraft(
            title: cleanedTitle,
            location: cleanedLocation,
            resolvedWhen: resolvedWhen,
            statedDurationSeconds: removingDurationPhrase(from: requestBody).durationSeconds
        )
    }

    // MARK: - Recognising the command

    /// Lowercase-insensitive matching happens on this; it keeps the user's
    /// casing for the title. Commas and a trailing full stop from dictation
    /// are dropped, runs of spaces collapsed.
    static func normalizedCommandText(_ transcript: String) -> String {
        var text = transcript.replacingOccurrences(of: ",", with: " ")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " .!?\n\t"))
        return text.split(whereSeparator: { $0 == " " }).joined(separator: " ")
    }

    /// What follows the scheduling words, with any "to my calendar" removed,
    /// or nil when the sentence isn't a scheduling request at all.
    private static func requestBodyAfterCommandWords(in normalizedTranscript: String) -> String? {
        var remainingText = removingPolitenessPrefix(from: normalizedTranscript)

        // "… to my calendar" / "… on my calendar" can close any form, and is
        // what makes plain "add"/"put" a calendar request.
        let calendarDestinationPattern = #"\s+(?:to|on|in|into|onto)\s+(?:my|the)\s+calendar\b"#
        var mentionsMyCalendar = false
        if let calendarDestinationRange = remainingText.range(of: calendarDestinationPattern, options: [.regularExpression, .caseInsensitive]) {
            mentionsMyCalendar = true
            remainingText.replaceSubrange(calendarDestinationRange, with: "")
            remainingText = normalizedCommandText(remainingText)
        }

        // "create an event called design review …", "new meeting with sam …".
        // "event" itself never belongs in the title; "meeting"/"appointment"
        // do ("Meeting with Sam") unless a name follows "called".
        let eventNounPattern = #"^(?:create|make|add|set\s+up|schedule|book|new)\s+(?:a\s+|an\s+)?(?:new\s+)?(?:calendar\s+)?(event|meeting|appointment)\b(?:\s+(called|named|titled))?\s*"#
        if let eventNounMatch = firstMatch(of: eventNounPattern, in: remainingText) {
            let eventNoun = substring(of: remainingText, capturedBy: eventNounMatch, groupIndex: 1)?.lowercased() ?? "event"
            let hasNamingWord = eventNounMatch.range(at: 2).location != NSNotFound
            let textAfterMatch = String(remainingText[Range(eventNounMatch.range, in: remainingText)!.upperBound...])
            if eventNoun == "event" || hasNamingWord {
                return textAfterMatch
            }
            let keptNoun = substring(of: remainingText, capturedBy: eventNounMatch, groupIndex: 1) ?? eventNoun
            return normalizedCommandText(keptNoun + " " + textAfterMatch)
        }

        // "schedule lunch with sam friday at noon".
        if let textAfterSchedule = removingLeadingMatch(of: #"^schedule\s+"#, from: remainingText) {
            let firstWord = lowercasedWords(in: textAfterSchedule).first ?? ""
            // "schedule an email/a post/a text" is a send, not an event.
            let wordsAfterArticle = lowercasedWords(in: textAfterSchedule).drop(while: { $0 == "a" || $0 == "an" })
            if nonEventScheduleObjects.contains(firstWord) || nonEventScheduleObjects.contains(wordsAfterArticle.first ?? "") {
                return nil
            }
            return textAfterSchedule
        }

        // "add/put/create lunch with sam friday at 1 to my calendar".
        if mentionsMyCalendar,
           let textAfterVerb = removingLeadingMatch(of: #"^(?:add|put|create|make|set\s+up|book|stick|throw)\s+"#, from: remainingText) {
            return textAfterVerb
        }
        return nil
    }

    /// Drops "can you", "please", "hey wisp" from the front — shared with
    /// the reminder parser.
    static func removingPolitenessPrefix(from normalizedText: String) -> String {
        removingLeadingMatch(of: politenessPrefixPattern, from: normalizedText) ?? normalizedText
    }

    private static let politenessPrefixPattern = #"^(?:hey\s+wisp\s+)?(?:please\s+)?(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?=\S)"#

    /// Things one schedules that aren't calendar events.
    private static let nonEventScheduleObjects: Set<String> = [
        "email", "emails", "message", "messages", "text", "texts", "post", "posts",
        "tweet", "tweets", "send", "reminder", "reminders", "timer", "alarm"
    ]

    private static let recurrenceWords: Set<String> = [
        "every", "each", "daily", "weekly", "monthly", "yearly", "annually", "weekdays", "fortnightly", "biweekly"
    ]

    // MARK: - Duration

    /// Pulls a stated length ("for an hour", "for 30 minutes", "for half an
    /// hour", "for 1.5 hours") out of the text.
    static func removingDurationPhrase(from text: String) -> (text: String, durationSeconds: TimeInterval?) {
        let durationPattern = #"\s*\bfor\s+(half\s+an|an|a|one|two|three|four|\d+(?:\.\d+)?)\s+(hours?|hrs?|minutes?|mins?)\b"#
        guard let durationMatch = firstMatch(of: durationPattern, in: text),
              let amountText = substring(of: text, capturedBy: durationMatch, groupIndex: 1)?.lowercased(),
              let unitText = substring(of: text, capturedBy: durationMatch, groupIndex: 2)?.lowercased() else {
            return (text, nil)
        }

        let wordAmounts: [String: Double] = ["half an": 0.5, "an": 1, "a": 1, "one": 1, "two": 2, "three": 3, "four": 4]
        guard let amount = wordAmounts[amountText] ?? Double(amountText), amount > 0 else { return (text, nil) }
        let secondsPerUnit: Double = unitText.hasPrefix("h") ? 3600 : 60
        // "half an minute" is not a real length; only "half an hour" is.
        if amountText == "half an" && secondsPerUnit != 3600 { return (text, nil) }

        var textWithoutDuration = text
        textWithoutDuration.replaceSubrange(Range(durationMatch.range, in: text)!, with: " ")
        return (normalizedCommandText(textWithoutDuration), amount * secondsPerUnit)
    }

    // MARK: - Title and place

    /// The text with the time phrase taken out — except words in it that
    /// aren't about time. The detector sometimes swallows the noun in front
    /// ("dinner tonight at 7"), which is the title.
    static func textReplacingTimePhrase(in text: String, timePhraseRange: NSRange) -> String {
        guard let swiftRange = Range(timePhraseRange, in: text) else { return text }
        let timePhraseWords = text[swiftRange].split(separator: " ").map(String.init)
        let keptNonTemporalWords = timePhraseWords.filter { !isTemporalWord($0) }
        let replacementText = keptNonTemporalWords.isEmpty ? " " : " " + keptNonTemporalWords.joined(separator: " ") + " "
        var replacedText = text
        replacedText.replaceSubrange(swiftRange, with: replacementText)
        return normalizedCommandText(replacedText)
    }

    /// Splits "lunch with sam at tartine" into title + place. The last " at "
    /// followed by a word (not a number — that would be a time) starts the
    /// place; a trailing "with …" after the place belongs to the title.
    static func splitTitleAndLocation(_ text: String) -> (title: String, location: String?) {
        let locationPattern = #"\s+(?:at|@)\s+(?![0-9])(\S.*)$"#
        guard let locationMatch = lastMatch(of: locationPattern, in: text),
              var locationText = substring(of: text, capturedBy: locationMatch, groupIndex: 1) else {
            return (text, nil)
        }
        var titleText = String(text[..<Range(locationMatch.range, in: text)!.lowerBound])

        if let withRange = locationText.range(of: #"\s+with\s+.+$"#, options: [.regularExpression, .caseInsensitive]) {
            titleText += String(locationText[withRange])
            locationText = String(locationText[..<withRange.lowerBound])
        }
        // "at the end of the day" style leftovers aren't a place.
        let locationWords = lowercasedWords(in: locationText)
        if locationWords.isEmpty || locationWords.allSatisfy(isTemporalWord) {
            return (text, nil)
        }
        return (titleText, locationText)
    }

    /// Trims connector words left at either end ("lunch with sam on" →
    /// "lunch with sam"), a leading article or "my", and capitalises the first
    /// letter, as a calendar title reads.
    static func cleanedTitleText(_ rawTitle: String) -> String {
        var titleWords = normalizedCommandText(rawTitle).split(separator: " ").map(String.init)
        let leadingFillerWords: Set<String> = ["a", "an", "the", "my", "for", "to", "on", "at", "in", "and"]
        let trailingConnectorWords: Set<String> = ["on", "at", "for", "from", "to", "and", "in", "the", "by", "around", "this", "next"]
        while let firstWord = titleWords.first, leadingFillerWords.contains(firstWord.lowercased()) {
            titleWords.removeFirst()
        }
        while let lastWord = titleWords.last, trailingConnectorWords.contains(lastWord.lowercased()) {
            titleWords.removeLast()
        }
        return capitalizedFirstLetter(titleWords.joined(separator: " "))
    }

    static func cleanedLocationText(_ rawLocation: String) -> String {
        var locationWords = normalizedCommandText(rawLocation).split(separator: " ").map(String.init)
        let trailingConnectorWords: Set<String> = ["on", "at", "for", "from", "to", "and", "in", "by"]
        while let lastWord = locationWords.last, trailingConnectorWords.contains(lastWord.lowercased()) {
            locationWords.removeLast()
        }
        return capitalizedFirstLetter(locationWords.joined(separator: " "))
    }

    // MARK: - Draft

    private static func makeDraft(
        title: String,
        location: String?,
        resolvedWhen: CalendarEventWhenResolver.ResolvedWhen,
        statedDurationSeconds: TimeInterval?
    ) -> CalendarEventDraft {
        if !resolvedWhen.includesTimeOfDay {
            return CalendarEventDraft(
                title: title,
                startDate: resolvedWhen.startDate,
                endDate: resolvedWhen.startDate,
                isAllDay: true,
                location: location
            )
        }
        // A spoken length wins over a range's ("from 2 to 3 for an hour" is
        // unusual enough that the explicit "for" is the better guess).
        let durationSeconds = statedDurationSeconds ?? resolvedWhen.durationSeconds ?? defaultEventDurationSeconds
        return CalendarEventDraft(
            title: title,
            startDate: resolvedWhen.startDate,
            endDate: resolvedWhen.startDate.addingTimeInterval(durationSeconds),
            isAllDay: false,
            location: location
        )
    }

    // MARK: - Words

    /// Words that only say *when*: dropped from the time phrase's span.
    static func isTemporalWord(_ rawWord: String) -> Bool {
        let word = rawWord.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: ":")))
        if word.isEmpty { return true }
        if temporalVocabulary.contains(word) { return true }
        // 3, 3pm, 3:30, 3:30pm, 2-4pm, 12th, 10/12.
        return word.range(of: #"^[0-9][0-9:./\-]*(?:am|pm|a\.m|p\.m|st|nd|rd|th)?$"#, options: .regularExpression) != nil
    }

    private static let temporalVocabulary: Set<String> = [
        "today", "tonight", "tomorrow", "yesterday", "morning", "afternoon", "evening", "night", "noon",
        "midday", "midnight", "o'clock", "oclock", "am", "pm", "a.m", "p.m",
        "at", "on", "from", "to", "until", "till", "til", "next", "this", "coming", "the", "of", "by",
        "around", "about", "between", "and", "in", "hour", "hours", "minute", "minutes", "week", "day",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "mon", "tue", "tues", "wed", "thu", "thur", "thurs", "fri", "sat", "sun",
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "half", "past", "quarter"
    ]

    static func lowercasedWords(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }

    static func capitalizedFirstLetter(_ text: String) -> String {
        guard let firstCharacter = text.first else { return text }
        return firstCharacter.uppercased() + text.dropFirst()
    }

    // MARK: - Regex helpers

    static func firstMatch(of pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let regularExpression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        return regularExpression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    fileprivate static func lastMatch(of pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let regularExpression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        return regularExpression.matches(in: text, range: NSRange(text.startIndex..., in: text)).last
    }

    static func substring(of text: String, capturedBy match: NSTextCheckingResult, groupIndex: Int) -> String? {
        guard match.range(at: groupIndex).location != NSNotFound,
              let capturedRange = Range(match.range(at: groupIndex), in: text) else { return nil }
        return String(text[capturedRange])
    }

    static func removingLeadingMatch(of pattern: String, from text: String) -> String? {
        guard let leadingMatch = firstMatch(of: pattern, in: text),
              leadingMatch.range.location == 0,
              let matchedRange = Range(leadingMatch.range, in: text) else { return nil }
        return String(text[matchedRange.upperBound...])
    }
}

// MARK: - When

/// Reads a time phrase into a start date, deterministically.
nonisolated enum CalendarEventWhenResolver {
    struct ResolvedWhen: Sendable, Equatable {
        let startDate: Date
        /// False for "friday" or "october 12": the event is all-day.
        let includesTimeOfDay: Bool
        /// "from 2 to 3:30" carries its own length.
        let durationSeconds: TimeInterval?
        /// Where the phrase sits in the text it was read from.
        let matchedRange: NSRange
    }

    static func resolve(_ text: String, now: Date, calendar: Calendar) -> ResolvedWhen? {
        if let detectedWhen = resolveWithDataDetector(text, now: now, calendar: calendar) {
            return detectedWhen
        }
        if let relativeWhen = resolveRelativeOffset(text, now: now) {
            return relativeWhen
        }
        return resolveBareClockTime(text, now: now, calendar: calendar)
    }

    /// `NSDataDetector` handles weekdays, dates, "tomorrow at 3", ranges. More
    /// than one date in the sentence is ambiguous and declined.
    private static func resolveWithDataDetector(_ text: String, now: Date, calendar: Calendar) -> ResolvedWhen? {
        guard let dateDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let dateMatches = dateDetector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard dateMatches.count == 1,
              let dateMatch = dateMatches.first,
              let detectedDate = dateMatch.date,
              let matchedRange = Range(dateMatch.range, in: text) else { return nil }

        let matchedPhrase = String(text[matchedRange])
        let includesTimeOfDay = phraseStatesTimeOfDay(matchedPhrase)
        let startDate = includesTimeOfDay ? detectedDate : calendar.startOfDay(for: detectedDate)
        return ResolvedWhen(
            startDate: startDate,
            includesTimeOfDay: includesTimeOfDay,
            durationSeconds: dateMatch.duration > 0 ? dateMatch.duration : nil,
            matchedRange: dateMatch.range
        )
    }

    /// "in 2 hours", "in 30 minutes", "in an hour".
    private static func resolveRelativeOffset(_ text: String, now: Date) -> ResolvedWhen? {
        let relativeOffsetPattern = #"\bin\s+(an|a|one|two|three|\d+)\s+(hours?|minutes?|mins?)\b"#
        guard let offsetMatch = CalendarEventCommandParser.firstMatch(of: relativeOffsetPattern, in: text),
              let amountText = CalendarEventCommandParser.substring(of: text, capturedBy: offsetMatch, groupIndex: 1)?.lowercased(),
              let unitText = CalendarEventCommandParser.substring(of: text, capturedBy: offsetMatch, groupIndex: 2)?.lowercased() else {
            return nil
        }
        let wordAmounts: [String: Double] = ["an": 1, "a": 1, "one": 1, "two": 2, "three": 3]
        guard let amount = wordAmounts[amountText] ?? Double(amountText), amount > 0 else { return nil }
        let offsetSeconds = amount * (unitText.hasPrefix("h") ? 3600 : 60)
        return ResolvedWhen(
            startDate: now.addingTimeInterval(offsetSeconds),
            includesTimeOfDay: true,
            durationSeconds: nil,
            matchedRange: offsetMatch.range
        )
    }

    /// "at 6", "at 6:30", "at 9pm" with no day, which the detector misses.
    /// Today if that time is still ahead, otherwise tomorrow. Without am/pm,
    /// 1–6 means afternoon (nobody books lunch at 1am), and 7–11 the next one
    /// coming up.
    private static func resolveBareClockTime(_ text: String, now: Date, calendar: Calendar) -> ResolvedWhen? {
        let clockTimePattern = #"\b(?:at|@)\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?(?![0-9])"#
        guard let clockMatch = CalendarEventCommandParser.firstMatch(of: clockTimePattern, in: text),
              let hourText = CalendarEventCommandParser.substring(of: text, capturedBy: clockMatch, groupIndex: 1),
              let spokenHour = Int(hourText), (1...12).contains(spokenHour) else { return nil }
        let minute = CalendarEventCommandParser.substring(of: text, capturedBy: clockMatch, groupIndex: 2).flatMap(Int.init) ?? 0
        guard (0...59).contains(minute) else { return nil }
        let meridiem = CalendarEventCommandParser.substring(of: text, capturedBy: clockMatch, groupIndex: 3)?.lowercased()

        let candidateHours: [Int]
        switch meridiem {
        case let meridiem? where meridiem.hasPrefix("a"):
            candidateHours = [spokenHour % 12]
        case _? :
            candidateHours = [spokenHour % 12 + 12]
        case nil where (1...6).contains(spokenHour):
            candidateHours = [spokenHour + 12]
        case nil where spokenHour == 12:
            candidateHours = [12]
        case nil:
            candidateHours = [spokenHour, spokenHour + 12]
        }

        let startOfToday = calendar.startOfDay(for: now)
        let candidateStartDates = [0, 1].flatMap { dayOffset in
            candidateHours.compactMap { hour -> Date? in
                guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday) else { return nil }
                return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
            }
        }
        guard let nextStartDate = candidateStartDates.filter({ $0 > now }).min() else { return nil }
        return ResolvedWhen(
            startDate: nextStartDate,
            includesTimeOfDay: true,
            durationSeconds: nil,
            matchedRange: clockMatch.range
        )
    }

    /// Whether a detected phrase names a time of day, as opposed to only a
    /// day — the detector puts "october 12" at noon either way.
    static func phraseStatesTimeOfDay(_ phrase: String) -> Bool {
        let timeOfDayPatterns = [
            #"\d\s*(?:am|pm|a\.m\.?|p\.m\.?)\b"#,
            #"\d{1,2}:\d{2}"#,
            #"\b(?:at|from|by|around|@)\s+\d{1,2}\b"#,
            #"\d{1,2}\s*-\s*\d{1,2}"#,
            #"\b(?:noon|midday|midnight|o'?clock|tonight|morning|afternoon|evening)\b"#
        ]
        return timeOfDayPatterns.contains { pattern in
            phrase.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
}
