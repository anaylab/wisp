//
//  RemindersDataProvider.swift
//  leanring-buddy
//
//  Reads the user's incomplete reminders on-device through EventKit and maps
//  them into a `RemindersSnapshot` for the reminders glance card, and creates a
//  reminder for the `create_reminder` agent tool. Everything stays on this Mac,
//  so unlike the weather and REST sources it is not gated by the live-card-data
//  network setting; the user's macOS Reminders permission is the gate. When
//  access has never been requested, the first use triggers the system prompt;
//  when it is denied, the card says so rather than showing an empty list.
//
//  An `actor` (like `CalendarDataProvider`) so the EventKit store is touched
//  from one place off the main actor; every `EKReminder` is flattened into a
//  Sendable `RemindersGlanceReminder` before it leaves EventKit's callback.
//

import EventKit
import Foundation

actor RemindersDataProvider: GlanceCardDataProvider {
    static let shared = RemindersDataProvider()

    enum RemindersDataError: LocalizedError, Equatable {
        /// The user has not granted (or has denied) full Reminders access.
        case accessDenied
        /// A list was named but none of the user's lists has that name.
        case listNotFound(listName: String)
        /// No list was named and Reminders has no default list to add to.
        case noDefaultList

        // Worded for the model to relay: a tool error's description is what
        // the model reads back, so it should say what happened plainly.
        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "wisp doesn't have access to Reminders. the user can grant it in System Settings › Privacy & Security › Reminders."
            case let .listNotFound(listName):
                return "there is no Reminders list called \"\(listName)\"."
            case .noDefaultList:
                return "Reminders has no default list to add to."
            }
        }
    }

    private let eventStore = EKEventStore()

    /// The most reminders a card shows — enough to be useful, few enough to fit
    /// the notch without scrolling.
    private let maximumRemindersOnCard = 5

    // MARK: - Reading

    /// Reads the user's incomplete reminders, narrowed to one list and a filter.
    ///
    /// Requests Reminders access if it has not been decided yet; throws
    /// `accessDenied` if the user has refused, and `listNotFound` if a list was
    /// named that does not exist, so the card can say which rather than show a
    /// misleading empty list.
    func snapshot(
        listName requestedListName: String?,
        filter: RemindersFilter,
        now: Date = Date()
    ) async throws -> RemindersSnapshot {
        try await ensureAccess()

        let reminderListsToRead = try reminderLists(matchingRequestedName: requestedListName)
        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: reminderListsToRead
        )
        let allIncompleteReminders = await fetchFlattenedReminders(matching: predicate)

        let selectedReminders = RemindersSelection.selectReminders(
            from: allIncompleteReminders,
            filter: filter,
            now: now,
            maximumCount: maximumRemindersOnCard
        )

        return RemindersSnapshot(
            reminders: selectedReminders,
            filter: filter,
            // Title the card with the list's real spelling, not the model's.
            listName: requestedListName == nil ? nil : reminderListsToRead?.first?.title,
            generatedAt: now
        )
    }

    // MARK: - Creating

    /// Adds a reminder, returning the name of the list it went into.
    ///
    /// A due date with a time of day also gets an alarm at that time, which is
    /// what "remind me at 3" means — Reminders does not alert on a due date
    /// alone. A bare-date due date makes an all-day reminder with no alarm.
    func createReminder(
        title: String,
        dueDate: Date?,
        dueDateIncludesTimeOfDay: Bool,
        listName requestedListName: String?
    ) async throws -> CreatedReminderDetails {
        try await ensureAccess()

        let targetReminderList: EKCalendar
        if let matchedReminderList = try reminderLists(matchingRequestedName: requestedListName)?.first {
            targetReminderList = matchedReminderList
        } else if let defaultReminderList = eventStore.defaultCalendarForNewReminders() {
            targetReminderList = defaultReminderList
        } else {
            throw RemindersDataError.noDefaultList
        }

        let newReminder = EKReminder(eventStore: eventStore)
        newReminder.title = title
        newReminder.calendar = targetReminderList

        if let dueDate {
            let dueDateComponentSet: Set<Calendar.Component> = dueDateIncludesTimeOfDay
                ? [.year, .month, .day, .hour, .minute]
                : [.year, .month, .day]
            newReminder.dueDateComponents = Calendar.current.dateComponents(dueDateComponentSet, from: dueDate)
            if dueDateIncludesTimeOfDay {
                newReminder.addAlarm(EKAlarm(absoluteDate: dueDate))
            }
        }

        try eventStore.save(newReminder, commit: true)
        return CreatedReminderDetails(
            reminderIdentifier: newReminder.calendarItemIdentifier,
            listName: targetReminderList.title,
            listColorHex: targetReminderList.cgColor.flatMap(Self.hexString(from:))
        )
    }

    /// What `createReminder` made: enough for the "Reminder Added" card and
    /// to undo it.
    struct CreatedReminderDetails: Sendable, Equatable {
        let reminderIdentifier: String
        let listName: String
        let listColorHex: String?
    }

    /// Removes one reminder by identifier — the result card's Undo. Only
    /// `CreatedReminderStore` calls this, with a reminder Wisp created itself
    /// this session. Returns false when it is already gone.
    func removeReminder(withIdentifier reminderIdentifier: String) async throws -> Bool {
        try await ensureAccess()
        guard let existingReminder = eventStore.calendarItem(withIdentifier: reminderIdentifier) as? EKReminder else {
            return false
        }
        try eventStore.remove(existingReminder, commit: true)
        return true
    }

    // MARK: - Helpers

    /// The reminder lists to read or write: nil (meaning every list) when no
    /// name was given, otherwise the lists whose name matches. Throws
    /// `listNotFound` when a name was given and nothing matches, rather than
    /// silently widening to every list.
    private func reminderLists(matchingRequestedName requestedListName: String?) throws -> [EKCalendar]? {
        guard let requestedListName,
              !requestedListName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let matchingReminderLists = eventStore.calendars(for: .reminder).filter { reminderList in
            RemindersSelection.listName(reminderList.title, matchesRequestedName: requestedListName)
        }
        guard !matchingReminderLists.isEmpty else {
            throw RemindersDataError.listNotFound(listName: requestedListName)
        }
        return matchingReminderLists
    }

    /// Bridges EventKit's callback-based fetch to async/await. The callback
    /// arrives on an EventKit queue, so the non-Sendable `EKReminder`s are
    /// flattened right there and only value types cross back.
    private func fetchFlattenedReminders(matching predicate: NSPredicate) async -> [RemindersGlanceReminder] {
        await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { fetchedReminders in
                let flattenedReminders = (fetchedReminders ?? []).map(Self.flattenedReminder(from:))
                continuation.resume(returning: flattenedReminders)
            }
        }
    }

    /// Copies what the card needs out of an `EKReminder`.
    private static func flattenedReminder(from reminder: EKReminder) -> RemindersGlanceReminder {
        let dueDateComponents = reminder.dueDateComponents
        let dueDate = dueDateComponents.flatMap { components in
            // Components from EventKit may carry their own calendar; fall back
            // to the user's when they don't.
            (components.calendar ?? Calendar.current).date(from: components)
        }
        // A due date with no hour is a day-only ("due Tuesday") reminder.
        let isDueDateAllDay = dueDateComponents != nil && dueDateComponents?.hour == nil

        let trimmedTitle = reminder.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return RemindersGlanceReminder(
            id: reminder.calendarItemIdentifier,
            title: trimmedTitle.isEmpty ? "(untitled)" : trimmedTitle,
            dueDate: dueDate,
            isDueDateAllDay: isDueDateAllDay,
            listName: reminder.calendar?.title ?? "Reminders",
            listColorHex: reminder.calendar?.cgColor.flatMap(hexString(from:))
        )
    }

    /// A "#RRGGBB" string for a list colour, or nil if it cannot be read in RGB.
    private static func hexString(from color: CGColor) -> String? {
        guard let components = color.components, components.count >= 3 else { return nil }
        let red = Int((components[0] * 255).rounded())
        let green = Int((components[1] * 255).rounded())
        let blue = Int((components[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    /// Ensures the app can read and write reminders, requesting full access on
    /// first use. Write-only access is not enough: the card has to read.
    private func ensureAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            return
        case .notDetermined:
            let granted = (try? await eventStore.requestFullAccessToReminders()) ?? false
            if !granted {
                throw RemindersDataError.accessDenied
            }
        default:
            // .denied, .restricted, or .writeOnly.
            throw RemindersDataError.accessDenied
        }
    }
}
