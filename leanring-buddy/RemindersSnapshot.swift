//
//  RemindersSnapshot.swift
//  leanring-buddy
//
//  The resolved data behind a reminders glance card — the user's incomplete
//  reminders, read on-device through EventKit by `RemindersDataProvider`. The
//  model only names *which* reminders it wants (an optional list and a
//  today/overdue/all filter); Wisp reads the reminders itself. Because the read
//  is local, it is not gated by the live-card-data network setting; the user's
//  macOS Reminders permission is the control.
//
//  Also holds `RemindersSelection`, the pure "which reminders, in what order"
//  logic, kept apart from EventKit so it can be unit-tested with plain values.
//
//  Everything here is `nonisolated` because the provider actor builds and
//  filters these values off the main actor.
//

import Foundation

/// Which slice of the user's incomplete reminders a card shows.
nonisolated enum RemindersFilter: String, Equatable {
    /// Due today, plus anything already overdue — what Reminders' own Today
    /// list shows, so the card matches the user's mental model.
    case today
    /// Past due and not completed.
    case overdue
    /// Every incomplete reminder, dated first.
    case all

    /// Reads the model's filter word forgivingly: case and whitespace are
    /// ignored, and anything missing or unrecognised means `.all` — the least
    /// surprising thing to show when the model was vague.
    init(lenientRawValue: String?) {
        let normalizedRawValue = lenientRawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        self = RemindersFilter(rawValue: normalizedRawValue) ?? .all
    }
}

/// One incomplete reminder, flattened from EventKit into a value type so the
/// card renderer never touches a non-Sendable `EKReminder`.
nonisolated struct RemindersGlanceReminder: Equatable, Identifiable {
    /// EventKit's `calendarItemIdentifier`, used so SwiftUI can key the list.
    let id: String
    let title: String
    /// When it is due, or nil for an undated reminder.
    let dueDate: Date?
    /// True when the due date is a day with no time ("due Tuesday"), so it is
    /// only overdue once that whole day has passed, not from midnight.
    let isDueDateAllDay: Bool
    /// The owning list's name ("Groceries").
    let listName: String
    /// The owning list's colour as a "#RRGGBB" string, for the Reminders-style
    /// dot, or nil if it could not be read.
    let listColorHex: String?
}

/// Everything a reminders card renders.
nonisolated struct RemindersSnapshot: Equatable {
    /// Already filtered, ordered and capped by `RemindersSelection`.
    let reminders: [RemindersGlanceReminder]
    let filter: RemindersFilter
    /// The matched list's real name when the card is for one list (so the card
    /// shows "Groceries" even if the model wrote "groceries"), or nil for all.
    let listName: String?
    /// When the reminders were read, so overdue/today labels use a stable clock.
    let generatedAt: Date
}

/// The pure selection rules for a reminders card: which reminders count as
/// overdue or due today, which a filter keeps, and in what order they show.
nonisolated enum RemindersSelection {

    /// Whether a reminder is past due at `now`. A dated-only reminder is
    /// overdue from the start of the *next* day; a timed one from its time.
    static func isOverdue(
        _ reminder: RemindersGlanceReminder,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard let dueDate = reminder.dueDate else { return false }
        if reminder.isDueDateAllDay {
            return dueDate < calendar.startOfDay(for: now)
        }
        return dueDate < now
    }

    /// Whether a reminder falls on the same calendar day as `now` (whether or
    /// not its time has passed yet).
    static func isDueToday(
        _ reminder: RemindersGlanceReminder,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard let dueDate = reminder.dueDate else { return false }
        return calendar.isDate(dueDate, inSameDayAs: now)
    }

    /// Applies a filter, orders the result, and caps it.
    ///
    /// Ordering: dated reminders first, earliest due first (so overdue ones
    /// lead), then undated ones; ties break on title so the order is stable
    /// between reads.
    static func selectReminders(
        from reminders: [RemindersGlanceReminder],
        filter: RemindersFilter,
        now: Date,
        maximumCount: Int,
        calendar: Calendar = .current
    ) -> [RemindersGlanceReminder] {
        let keptReminders = reminders.filter { reminder in
            switch filter {
            case .all:
                return true
            case .overdue:
                return isOverdue(reminder, now: now, calendar: calendar)
            case .today:
                return isOverdue(reminder, now: now, calendar: calendar)
                    || isDueToday(reminder, now: now, calendar: calendar)
            }
        }

        let orderedReminders = keptReminders.sorted { firstReminder, secondReminder in
            switch (firstReminder.dueDate, secondReminder.dueDate) {
            case let (firstDueDate?, secondDueDate?):
                if firstDueDate != secondDueDate {
                    return firstDueDate < secondDueDate
                }
                return firstReminder.title.localizedCaseInsensitiveCompare(secondReminder.title) == .orderedAscending
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return firstReminder.title.localizedCaseInsensitiveCompare(secondReminder.title) == .orderedAscending
            }
        }

        return Array(orderedReminders.prefix(max(0, maximumCount)))
    }

    /// Whether a Reminders list's name matches the name the model or user gave.
    /// Case-, diacritic- and surrounding-whitespace-insensitive, since the
    /// name arrives through speech and a small model.
    static func listName(_ actualListName: String, matchesRequestedName requestedListName: String) -> Bool {
        let trimmedActualName = actualListName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRequestedName = requestedListName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRequestedName.isEmpty else { return false }
        return trimmedActualName.compare(
            trimmedRequestedName,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame
    }
}

/// Turns the due date the model passes to `create_reminder` into a date.
///
/// ISO 8601 was asked for, but a local model writes several near-variants, so
/// this accepts: a full timestamp with a zone ("2026-09-25T15:00:00Z",
/// "…+02:00"), one without a zone or seconds ("2026-09-25T15:00", read in the
/// user's time zone — what the user meant when they said "3pm"), and a bare
/// date ("2026-09-25", which makes an all-day reminder).
enum ReminderDueDateParser {
    struct ParsedDueDate: Equatable {
        let date: Date
        /// False for a bare date, so the reminder is created as all-day with no
        /// timed alarm.
        let includesTimeOfDay: Bool
    }

    static func parse(_ rawDueDateText: String, timeZone: TimeZone = .current) -> ParsedDueDate? {
        let dueDateText = rawDueDateText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dueDateText.isEmpty else { return nil }

        // With an explicit zone (Z or ±hh:mm), with or without fractional seconds.
        let zonedFormatter = ISO8601DateFormatter()
        zonedFormatter.formatOptions = [.withInternetDateTime]
        if let zonedDate = zonedFormatter.date(from: dueDateText) {
            return ParsedDueDate(date: zonedDate, includesTimeOfDay: true)
        }
        zonedFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let zonedDate = zonedFormatter.date(from: dueDateText) {
            return ParsedDueDate(date: zonedDate, includesTimeOfDay: true)
        }

        // Without a zone: read as local wall-clock time.
        let localFormatter = DateFormatter()
        localFormatter.locale = Locale(identifier: "en_US_POSIX")
        localFormatter.timeZone = timeZone
        for localTimestampFormat in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            localFormatter.dateFormat = localTimestampFormat
            if let localDate = localFormatter.date(from: dueDateText) {
                return ParsedDueDate(date: localDate, includesTimeOfDay: true)
            }
        }

        // A bare date: an all-day reminder on that day.
        localFormatter.dateFormat = "yyyy-MM-dd"
        if let dayDate = localFormatter.date(from: dueDateText) {
            return ParsedDueDate(date: dayDate, includesTimeOfDay: false)
        }

        return nil
    }
}
