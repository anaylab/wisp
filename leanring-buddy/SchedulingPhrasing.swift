//
//  SchedulingPhrasing.swift
//  leanring-buddy
//
//  How the Siri-style calendar and reminder flows say *when* and *what was
//  done*, in one place, so the notch line, the spoken reply and the cards all
//  agree: "Friday at 1 PM", "tomorrow at 9:30 AM", "Added “Lunch with Sam” to
//  your calendar for Friday at 1 PM.", "Okay, I'll remind you tomorrow at
//  9 AM." Sentence case and ordinary punctuation, because the same line is
//  spoken aloud — no "·" separators, no ISO dates, no all-lowercase.
//
//  Pure: every function takes `now` and a calendar, so it is tested by
//  `Tests/CalendarEventCommand` without a clock.
//

import Foundation

nonisolated enum SchedulingPhrasing {

    // MARK: - When

    /// "today at 1 PM", "tomorrow at 9:30 AM", "Friday at 1 PM" (within the
    /// coming week), "Mon, Oct 19 at 1 PM" further out. Day-only dates drop
    /// the time: "tomorrow", "Friday", "Mon, Oct 19".
    static func whenPhrase(
        for date: Date,
        includesTimeOfDay: Bool,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let dayPhrase = dayPhrase(for: date, now: now, calendar: calendar, locale: locale)
        guard includesTimeOfDay else { return dayPhrase }
        return "\(dayPhrase) at \(clockTimeText(for: date, calendar: calendar, locale: locale))"
    }

    /// "today", "tomorrow", a weekday name within the next six days, or a
    /// short date ("Mon, Oct 19") beyond that or in the past.
    static func dayPhrase(for date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfDate = calendar.startOfDay(for: date)
        let dayOffset = calendar.dateComponents([.day], from: startOfToday, to: startOfDate).day ?? 0

        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.locale = locale
        dayFormatter.timeZone = calendar.timeZone
        switch dayOffset {
        case 0:
            return "today"
        case 1:
            return "tomorrow"
        case 2...6:
            dayFormatter.setLocalizedDateFormatFromTemplate("EEEE")
        default:
            dayFormatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
        }
        return plainSpaced(dayFormatter.string(from: date))
    }

    /// "1 PM" on the hour, "1:30 PM" otherwise (or the locale's 24-hour form).
    static func clockTimeText(for date: Date, calendar: Calendar, locale: Locale) -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.calendar = calendar
        timeFormatter.locale = locale
        timeFormatter.timeZone = calendar.timeZone
        let isOnTheHour = calendar.component(.minute, from: date) == 0
        timeFormatter.setLocalizedDateFormatFromTemplate(isOnTheHour ? "j" : "jmm")
        return plainSpaced(timeFormatter.string(from: date))
    }

    /// "1:00 – 2:00 PM" for a timed event on one day; "All day" for an
    /// all-day one; with the day spelled out when it ends on another day.
    static func timeRangeText(
        start startDate: Date,
        end endDate: Date,
        isAllDay: Bool,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        if isAllDay { return "All day" }
        let intervalFormatter = DateIntervalFormatter()
        intervalFormatter.calendar = calendar
        intervalFormatter.locale = locale
        intervalFormatter.timeZone = calendar.timeZone
        if calendar.isDate(startDate, inSameDayAs: endDate) {
            intervalFormatter.dateStyle = .none
            intervalFormatter.timeStyle = .short
        } else {
            intervalFormatter.dateTemplate = "EEEMMMdjmm"
        }
        return plainSpaced(intervalFormatter.string(from: startDate, to: endDate))
    }

    /// The full day for a card's subtitle: "Friday, October 9".
    static func fullDayText(for date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.locale = locale
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        return plainSpaced(dayFormatter.string(from: date))
    }

    // MARK: - What was done

    /// "Added “Lunch with Sam” to your calendar for Friday at 1 PM."
    static func eventAddedReply(
        title: String,
        startDate: Date,
        isAllDay: Bool,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let when = whenPhrase(for: startDate, includesTimeOfDay: !isAllDay, now: now, calendar: calendar, locale: locale)
        return "Added “\(title)” to your calendar for \(when)."
    }

    /// "Okay, I'll remind you tomorrow at 9 AM." for a timed reminder (the
    /// card shows what); "Added “Milk” to Shopping." when there's no time;
    /// "… for tomorrow." for a day with no time. When the named list didn't
    /// exist, says where it went instead.
    static func reminderAddedReply(
        title: String,
        dueDate: Date?,
        dueDateIncludesTimeOfDay: Bool,
        savedListName: String,
        missingListName: String?,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        if let missingListName {
            return "Added “\(title)” to \(savedListName) — you don't have a \(missingListName) list."
        }
        guard let dueDate else {
            return "Added “\(title)” to \(savedListName)."
        }
        let when = whenPhrase(for: dueDate, includesTimeOfDay: dueDateIncludesTimeOfDay, now: now, calendar: calendar, locale: locale)
        if dueDateIncludesTimeOfDay {
            return "Okay, I'll remind you \(when)."
        }
        return "Added “\(title)” to \(savedListName) for \(when)."
    }

    /// After Undo: "Removed “Lunch with Sam” from your calendar."
    static func eventRemovedReply(title: String) -> String {
        "Removed “\(title)” from your calendar."
    }

    /// After Undo: "Removed “Call the bank” from Reminders."
    static func reminderRemovedReply(title: String) -> String {
        "Removed “\(title)” from Reminders."
    }

    /// Formatters put thin and narrow no-break spaces around the dash and
    /// before AM/PM. They're correct, but some fonts and the speech voice
    /// handle a plain space more predictably.
    static func plainSpaced(_ formattedText: String) -> String {
        formattedText
            .replacingOccurrences(of: "\u{2009}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }
}
