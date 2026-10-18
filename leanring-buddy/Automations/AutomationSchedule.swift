//
//  AutomationSchedule.swift
//  leanring-buddy
//
//  When a scheduled automation runs: once, daily, weekdays, weekly or monthly, at a
//  wall-clock time in a zone. Pure (Foundation only) and time-injected so the DST and
//  month-end rules are tested without the app.
//
//  Rules worth knowing:
//  - `nextRunDate` is built on `Calendar.nextDate(... .nextTime)`, so a time that falls in a
//    spring-forward gap runs at the next valid time, and a time that repeats on a fall-back
//    night runs once.
//  - `missedRunDate` answers "was a slot skipped while the Mac slept?" with the LATEST skipped
//    slot only, so the engine runs it once, never once per missed day.
//

import Foundation

/// A buddy schedule from before automations, as plain values. `BuddySchedule` lives in
/// `BuddyStore.swift` (main-actor, Combine) and cannot compile into the pure suites, so the
/// live wiring converts into this mirror first.
nonisolated enum AutomationLegacyBuddySchedule: Codable, Equatable, Sendable {
    case once
    case daily(hour: Int, minute: Int)
    /// 1 = Sunday ... 7 = Saturday, as `Calendar`.
    case weekly(weekday: Int, hour: Int, minute: Int)
}

nonisolated struct AutomationSchedule: Codable, Equatable, Sendable {
    enum Recurrence: Codable, Equatable, Sendable {
        case once(Date)
        case daily
        /// Monday to Friday.
        case weekdays
        /// 1 = Sunday ... 7 = Saturday, as `Calendar`.
        case weekly(weekday: Int)
        /// 1...31; a short month runs on its last day.
        case monthly(dayOfMonth: Int)
    }

    var recurrence: Recurrence
    /// 0...23, wall-clock in the zone below.
    var hour: Int
    /// 0...59.
    var minute: Int
    /// Nil = the Mac's current zone at evaluation time (so travel moves the run). A set
    /// identifier pins it.
    var timeZoneIdentifier: String?

    init(recurrence: Recurrence, hour: Int, minute: Int, timeZoneIdentifier: String? = nil) {
        self.recurrence = recurrence
        self.hour = hour
        self.minute = minute
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    /// Daily and weekly buddy jobs map across. `.once` is not a schedule (the caller makes it
    /// `.manual`), so it returns nil.
    init?(legacy legacySchedule: AutomationLegacyBuddySchedule) {
        switch legacySchedule {
        case .once:
            return nil
        case .daily(let hour, let minute):
            self.init(recurrence: .daily, hour: hour, minute: minute)
        case .weekly(let weekday, let hour, let minute):
            self.init(recurrence: .weekly(weekday: weekday), hour: hour, minute: minute)
        }
    }

    // MARK: - Validation

    func validationProblems() -> [String] {
        var problems: [String] = []
        if !(0...23).contains(hour) || !(0...59).contains(minute) {
            problems.append("That time of day is not valid.")
        }
        switch recurrence {
        case .weekly(let weekday):
            if !(1...7).contains(weekday) { problems.append("Pick a day of the week.") }
        case .monthly(let dayOfMonth):
            if !(1...31).contains(dayOfMonth) { problems.append("Pick a day of the month from 1 to 31.") }
        case .once, .daily, .weekdays:
            break
        }
        if let timeZoneIdentifier, TimeZone(identifier: timeZoneIdentifier) == nil {
            problems.append("Unknown time zone.")
        }
        return problems
    }

    // MARK: - Next run

    private func calendarInScheduleZone(_ calendar: Calendar) -> Calendar {
        var zonedCalendar = calendar
        if let timeZoneIdentifier, let pinnedZone = TimeZone(identifier: timeZoneIdentifier) {
            zonedCalendar.timeZone = pinnedZone
        }
        return zonedCalendar
    }

    /// First run strictly after `date`; nil for a past `.once`.
    func nextRunDate(after date: Date, calendar: Calendar) -> Date? {
        guard validationProblems().isEmpty else { return nil }
        let zonedCalendar = calendarInScheduleZone(calendar)
        let timeComponents = DateComponents(hour: hour, minute: minute, second: 0)

        switch recurrence {
        case .once(let runDate):
            return runDate > date ? runDate : nil

        case .daily:
            return zonedCalendar.nextDate(after: date, matching: timeComponents, matchingPolicy: .nextTime)

        case .weekdays:
            var searchStartDate = date
            // A week and a day is enough to cross any weekend.
            for _ in 0..<8 {
                guard let candidateDate = zonedCalendar.nextDate(
                    after: searchStartDate,
                    matching: timeComponents,
                    matchingPolicy: .nextTime
                ) else { return nil }
                let candidateWeekday = zonedCalendar.component(.weekday, from: candidateDate)
                if (2...6).contains(candidateWeekday) { return candidateDate }
                searchStartDate = candidateDate
            }
            return nil

        case .weekly(let weekday):
            return zonedCalendar.nextDate(
                after: date,
                matching: DateComponents(hour: hour, minute: minute, second: 0, weekday: weekday),
                matchingPolicy: .nextTime
            )

        case .monthly(let dayOfMonth):
            return nextMonthlyRunDate(after: date, dayOfMonth: dayOfMonth, calendar: zonedCalendar)
        }
    }

    private func nextMonthlyRunDate(after date: Date, dayOfMonth: Int, calendar zonedCalendar: Calendar) -> Date? {
        let timeComponents = DateComponents(hour: hour, minute: minute, second: 0)
        guard let startOfCurrentMonth = zonedCalendar.dateInterval(of: .month, for: date)?.start else { return nil }

        // 14 months always contains a month whose slot is after `date`.
        for monthOffset in 0..<14 {
            guard let monthStart = zonedCalendar.date(byAdding: .month, value: monthOffset, to: startOfCurrentMonth),
                  let daysInMonth = zonedCalendar.range(of: .day, in: .month, for: monthStart)?.count else { continue }

            // A short month runs on its last day ("the 31st" in April is April 30th).
            let clampedDay = min(dayOfMonth, daysInMonth)
            var dayComponents = zonedCalendar.dateComponents([.year, .month], from: monthStart)
            dayComponents.day = clampedDay
            guard let dayDate = zonedCalendar.date(from: dayComponents) else { continue }
            let startOfDay = zonedCalendar.startOfDay(for: dayDate)

            guard let slotDate = zonedCalendar.nextDate(
                after: startOfDay.addingTimeInterval(-1),
                matching: timeComponents,
                matchingPolicy: .nextTime
            ), zonedCalendar.isDate(slotDate, inSameDayAs: startOfDay) else { continue }

            if slotDate > date { return slotDate }
        }
        return nil
    }

    // MARK: - Missed runs

    /// The latest scheduled slot in (`lastRunAt`, `now`], or nil. The engine runs a missed slot
    /// ONCE, never once per missed day. `lastRunAt == nil` uses `createdAt`.
    func missedRunDate(lastRunAt: Date?, createdAt: Date, now: Date, calendar: Calendar) -> Date? {
        let baselineDate = lastRunAt ?? createdAt
        guard baselineDate < now else { return nil }

        if case .once(let runDate) = recurrence {
            return (runDate > baselineDate && runDate <= now) ? runDate : nil
        }

        // A machine asleep for months shouldn't walk thousands of slots; only the latest
        // matters, so start no earlier than ~two months back.
        let earliestUsefulBaseline = now.addingTimeInterval(-62 * 24 * 60 * 60)
        var searchStartDate = max(baselineDate, earliestUsefulBaseline)
        var latestSlotInWindow: Date?

        for _ in 0..<200 {
            guard let slotDate = nextRunDate(after: searchStartDate, calendar: calendar), slotDate <= now else { break }
            latestSlotInWindow = slotDate
            searchStartDate = slotDate
        }
        return latestSlotInWindow
    }

    // MARK: - Words

    /// "Every weekday at 8:00 AM", "Every Monday at 9:00 AM", "On the 1st at 7:00 PM",
    /// "Once, Fri 3:00 PM".
    func summary(calendar: Calendar) -> String {
        let timeText = AutomationTimeText.string(hour: hour, minute: minute)
        switch recurrence {
        case .once(let runDate):
            let zonedCalendar = calendarInScheduleZone(calendar)
            let weekday = zonedCalendar.component(.weekday, from: runDate)
            let runHour = zonedCalendar.component(.hour, from: runDate)
            let runMinute = zonedCalendar.component(.minute, from: runDate)
            return "Once, \(AutomationTimeText.shortWeekdayName(weekday)) \(AutomationTimeText.string(hour: runHour, minute: runMinute))"
        case .daily:
            return "Every day at \(timeText)"
        case .weekdays:
            return "Every weekday at \(timeText)"
        case .weekly(let weekday):
            return "Every \(AutomationTimeText.weekdayName(weekday)) at \(timeText)"
        case .monthly(let dayOfMonth):
            return "On the \(AutomationTimeText.ordinal(dayOfMonth)) at \(timeText)"
        }
    }

    var isRepeating: Bool {
        if case .once = recurrence { return false }
        return true
    }
}

/// Fixed English wording so summaries do not depend on the Mac's language and are testable.
nonisolated enum AutomationTimeText {
    static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    static func weekdayName(_ weekday: Int) -> String {
        weekdayNames[((weekday - 1) % 7 + 7) % 7]
    }

    static func shortWeekdayName(_ weekday: Int) -> String {
        String(weekdayName(weekday).prefix(3))
    }

    /// "8:00 AM", "12:30 PM", "12:00 AM".
    static func string(hour: Int, minute: Int) -> String {
        let hourOnTwelveHourClock = hour % 12 == 0 ? 12 : hour % 12
        let meridiem = hour < 12 ? "AM" : "PM"
        return "\(hourOnTwelveHourClock):" + (minute < 10 ? "0\(minute)" : "\(minute)") + " \(meridiem)"
    }

    /// 1 -> "1st", 22 -> "22nd", 11 -> "11th".
    static func ordinal(_ number: Int) -> String {
        let lastTwoDigits = number % 100
        let suffix: String
        if (11...13).contains(lastTwoDigits) {
            suffix = "th"
        } else {
            switch number % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(number)\(suffix)"
    }
}

// MARK: - Inference from words

/// What a sentence says about *when*, before a full schedule can be built. Kept separate so the
/// draft parser can tell "every day" (recurrence known, time missing) from "every morning at 8".
nonisolated struct AutomationScheduleInference: Equatable, Sendable {
    enum RecurrenceKind: Equatable, Sendable {
        case daily
        case weekdays
        case weekly(weekday: Int)
        case monthly(dayOfMonth: Int)
        /// A single run on a specific local day (start of that day).
        case onceOnDay(Date)
    }

    var recurrence: RecurrenceKind
    var hour: Int?
    var minute: Int?
    /// Plain-words things the parser assumed ("6:00 PM for evening"). Non-empty = a soft guess.
    var assumptions: [String]

    var hasTime: Bool { hour != nil && minute != nil }

    func makeSchedule(calendar: Calendar) -> AutomationSchedule? {
        guard let hour, let minute else { return nil }
        switch recurrence {
        case .daily:
            return AutomationSchedule(recurrence: .daily, hour: hour, minute: minute)
        case .weekdays:
            return AutomationSchedule(recurrence: .weekdays, hour: hour, minute: minute)
        case .weekly(let weekday):
            return AutomationSchedule(recurrence: .weekly(weekday: weekday), hour: hour, minute: minute)
        case .monthly(let dayOfMonth):
            return AutomationSchedule(recurrence: .monthly(dayOfMonth: dayOfMonth), hour: hour, minute: minute)
        case .onceOnDay(let dayStart):
            guard let runDate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: dayStart) else { return nil }
            return AutomationSchedule(recurrence: .once(runDate), hour: hour, minute: minute)
        }
    }

    // MARK: Inference

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let weekdayWordPattern = "(sunday|monday|tuesday|wednesday|thursday|friday|saturday)s?"
    private static let weekdayNamesLowercased = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    private static let weekdaysRangePattern = regex(#"\bweekdays?\b|\b(mon(day)?\s*(-|to|through|thru)\s*fri(day)?)\b"#)
    private static let everyWeekdayNamePattern = regex(#"\b(?:every|each)\s+(?:other\s+)?"# + weekdayWordPattern + #"\b|\bon\s+"# + "(sundays|mondays|tuesdays|wednesdays|thursdays|fridays|saturdays)" + #"\b"#)
    private static let everyOtherPattern = regex(#"\b(?:every|each)\s+other\b"#)
    private static let morningWordPattern = regex(#"\bmorning\b"#)
    private static let afternoonOrEveningWordPattern = regex(#"\b(?:afternoon|evening|night|tonight)\b"#)
    private static let monthlyPattern = regex(#"\b(?:every|each)\s+month\b|\bmonthly\b"#)
    private static let dayOfMonthPattern = regex(#"\b(?:on\s+)?the\s+(\d{1,2})(?:st|nd|rd|th)\b"#)
    private static let dailyPattern = regex(#"\b(?:every|each)\s+(?:day|morning|afternoon|evening|night)\b|\bdaily\b|\bnightly\b"#)
    private static let weeklyGenericPattern = regex(#"\b(?:every|each)\s+week\b|\bweekly\b"#)
    private static let tomorrowPattern = regex(#"\btomorrow\b"#)
    private static let tonightPattern = regex(#"\btonight\b"#)
    private static let todayPattern = regex(#"\btoday\b"#)
    private static let onWeekdayPattern = regex(#"\b(?:on|next|this)\s+"# + weekdayWordPattern + #"\b"#)

    private static let colonTimePattern = regex(#"\b(\d{1,2}):(\d{2})\s*(a\.?m\.?|p\.?m\.?)?"#)
    private static let atHourPattern = regex(#"\bat\s+(\d{1,2})\s*(a\.?m\.?|p\.?m\.?)?(?![\d:])"#)
    private static let bareMeridiemHourPattern = regex(#"\b(\d{1,2})\s*(a\.?m\.?|p\.?m\.?)(?![a-z])"#)
    private static let noonPattern = regex(#"\bnoon\b"#)
    private static let midnightPattern = regex(#"\bmidnight\b"#)

    private static func firstMatch(of pattern: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func capturedText(_ match: NSTextCheckingResult, group: Int, in text: String) -> String? {
        guard match.range(at: group).location != NSNotFound, let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }

    static func infer(fromText text: String, now: Date, calendar: Calendar) -> AutomationScheduleInference? {
        let lowercasedText = text.lowercased()
        var assumptions: [String] = []

        // --- Recurrence ---
        var recurrence: RecurrenceKind?
        if firstMatch(of: weekdaysRangePattern, in: lowercasedText) != nil {
            recurrence = .weekdays
        } else if let weekdayMatch = firstMatch(of: everyWeekdayNamePattern, in: lowercasedText) {
            let matchedWeekdayWord = (1...2).lazy.compactMap { capturedText(weekdayMatch, group: $0, in: lowercasedText) }.first
                ?? weekdayNamesLowercased.first { lowercasedText.contains($0) }
            if let matchedWeekdayWord,
               let weekdayIndex = weekdayNamesLowercased.firstIndex(where: { matchedWeekdayWord.hasPrefix($0) }) {
                recurrence = .weekly(weekday: weekdayIndex + 1)
                // There is no every-other-week recurrence, so say plainly that it runs weekly.
                if firstMatch(of: everyOtherPattern, in: lowercasedText) != nil {
                    assumptions.append("every week, since every other week isn't supported yet")
                }
            }
        } else if firstMatch(of: monthlyPattern, in: lowercasedText) != nil {
            if let dayMatch = firstMatch(of: dayOfMonthPattern, in: lowercasedText),
               let dayText = capturedText(dayMatch, group: 1, in: lowercasedText),
               let dayOfMonth = Int(dayText), (1...31).contains(dayOfMonth) {
                recurrence = .monthly(dayOfMonth: dayOfMonth)
            } else {
                recurrence = .monthly(dayOfMonth: 1)
                assumptions.append("the 1st of the month")
            }
        } else if firstMatch(of: dailyPattern, in: lowercasedText) != nil {
            recurrence = .daily
        } else if firstMatch(of: weeklyGenericPattern, in: lowercasedText) != nil {
            recurrence = .weekly(weekday: 2)
            assumptions.append("Monday")
        } else if firstMatch(of: tomorrowPattern, in: lowercasedText) != nil {
            recurrence = .onceOnDay(calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now) ?? now))
        } else if firstMatch(of: tonightPattern, in: lowercasedText) != nil
                    || firstMatch(of: todayPattern, in: lowercasedText) != nil {
            recurrence = .onceOnDay(calendar.startOfDay(for: now))
        } else if let onWeekdayMatch = firstMatch(of: onWeekdayPattern, in: lowercasedText),
                  let weekdayWord = capturedText(onWeekdayMatch, group: 1, in: lowercasedText),
                  let weekdayIndex = weekdayNamesLowercased.firstIndex(of: weekdayWord),
                  let nextOccurrence = calendar.nextDate(
                    after: now,
                    matching: DateComponents(hour: 0, minute: 0, second: 0, weekday: weekdayIndex + 1),
                    matchingPolicy: .nextTime
                  ) {
            recurrence = .onceOnDay(calendar.startOfDay(for: nextOccurrence))
        }

        // --- Time of day ---
        var hour: Int?
        var minute: Int?

        // "at 6" next to "morning" means 6 AM; next to "evening"/"tonight" it means 6 PM.
        let mentionsMorning = firstMatch(of: morningWordPattern, in: lowercasedText) != nil
        let mentionsAfternoonOrEvening = firstMatch(of: afternoonOrEveningWordPattern, in: lowercasedText) != nil

        func resolveClockHour(_ statedHour: Int, meridiemText: String?) -> Int? {
            guard (0...23).contains(statedHour) else { return nil }
            if let meridiemText {
                guard (1...12).contains(statedHour) else { return nil }
                let isPM = meridiemText.lowercased().hasPrefix("p")
                if statedHour == 12 { return isPM ? 12 : 0 }
                return isPM ? statedHour + 12 : statedHour
            }
            // A part of the day beside the hour settles am/pm; when both are named, don't guess from it.
            if (1...11).contains(statedHour), mentionsMorning != mentionsAfternoonOrEvening {
                return mentionsMorning ? statedHour : statedHour + 12
            }
            // No am/pm: 13+ is already 24-hour; 1...6 reads as afternoon, 7...11 as morning.
            if statedHour >= 13 || statedHour == 0 || statedHour == 12 { return statedHour }
            return statedHour <= 6 ? statedHour + 12 : statedHour
        }

        if let colonMatch = firstMatch(of: colonTimePattern, in: lowercasedText),
           let hourText = capturedText(colonMatch, group: 1, in: lowercasedText),
           let minuteText = capturedText(colonMatch, group: 2, in: lowercasedText),
           let statedHour = Int(hourText), let statedMinute = Int(minuteText), (0...59).contains(statedMinute),
           let resolvedHour = resolveClockHour(statedHour, meridiemText: capturedText(colonMatch, group: 3, in: lowercasedText)) {
            hour = resolvedHour
            minute = statedMinute
        } else if let atMatch = firstMatch(of: atHourPattern, in: lowercasedText),
                  let hourText = capturedText(atMatch, group: 1, in: lowercasedText),
                  let statedHour = Int(hourText),
                  let resolvedHour = resolveClockHour(statedHour, meridiemText: capturedText(atMatch, group: 2, in: lowercasedText)) {
            hour = resolvedHour
            minute = 0
        } else if let meridiemMatch = firstMatch(of: bareMeridiemHourPattern, in: lowercasedText),
                  let hourText = capturedText(meridiemMatch, group: 1, in: lowercasedText),
                  let statedHour = Int(hourText),
                  let resolvedHour = resolveClockHour(statedHour, meridiemText: capturedText(meridiemMatch, group: 2, in: lowercasedText)) {
            hour = resolvedHour
            minute = 0
        } else if firstMatch(of: noonPattern, in: lowercasedText) != nil {
            hour = 12
            minute = 0
        } else if firstMatch(of: midnightPattern, in: lowercasedText) != nil {
            hour = 0
            minute = 0
        } else {
            // A part of the day with no clock time is a soft guess the user can change.
            let dayPartGuesses: [(word: String, hour: Int, name: String)] = [
                ("tonight", 21, "9:00 PM for tonight"),
                ("morning", 9, "9:00 AM for morning"),
                ("afternoon", 15, "3:00 PM for afternoon"),
                ("evening", 18, "6:00 PM for evening"),
                ("night", 21, "9:00 PM for night"),
            ]
            if let guess = dayPartGuesses.first(where: { lowercasedText.range(of: "\\b\($0.word)\\b", options: .regularExpression) != nil }) {
                hour = guess.hour
                minute = 0
                assumptions.append(guess.name)
            }
        }

        // "remind me at 5pm to call mom" names a time but no day: today.
        if recurrence == nil, hour != nil, assumptions.isEmpty, lowercasedText.contains("remind me") {
            recurrence = .onceOnDay(calendar.startOfDay(for: now))
        }

        guard let recurrence else {
            return nil
        }
        return AutomationScheduleInference(
            recurrence: recurrence,
            hour: hour,
            minute: minute,
            assumptions: assumptions
        )
    }
}

nonisolated extension AutomationSchedule {
    /// Words in -> schedule, deterministic. Knows daily, weekdays, weekly ("every Monday"),
    /// monthly ("on the 1st of each month"), "at 8", "at 3:30pm", "tomorrow", "tonight" and
    /// parts of the day. Nil when the text names no time at all ("every day" alone is not a
    /// schedule: nobody said when).
    static func inferred(fromText text: String, now: Date, calendar: Calendar) -> AutomationSchedule? {
        AutomationScheduleInference.infer(fromText: text, now: now, calendar: calendar)?
            .makeSchedule(calendar: calendar)
    }
}
