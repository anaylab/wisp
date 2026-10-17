//
//  WispTodayReminders.swift
//  leanring-buddy
//
//  Thin EventKit layer for Job 2. Owns one Reminders list, "Wisp Today", and
//  never touches any other list or any reminder in it that Wisp did not create.
//  What to add / update / remove is decided by the pure
//  `JobsEventKitPlanning.reminderRebuildPlan`.
//
//  Reminders is the source of truth for ticks: `rebuild` leaves a kept
//  reminder's completion alone, and `readBackCompletion` reports it.
//
//  Permission is never requested implicitly; only `requestAccessIfNeeded()`.
//

import EventKit
import Foundation

actor WispTodayReminders {

    static let shared = WispTodayReminders()
    static let listTitle = "Wisp Today"

    private let eventStore = EKEventStore()
    private let reminderMapFileURL = JobsPrivateJSONFile.fileURL(named: "jobs-reminder-map.json")

    // MARK: Authorization

    func authorizationState() -> JobsAccessState {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func requestAccessIfNeeded() async throws {
        switch authorizationState() {
        case .granted: return
        case .denied: throw WispEventKitError.accessDenied
        case .notDetermined:
            let wasGranted = try await eventStore.requestFullAccessToReminders()
            if !wasGranted { throw WispEventKitError.accessDenied }
        }
    }

    // MARK: Rebuild

    /// Makes the list match `items`. Idempotent: running it twice with the same items
    /// finds every reminder current and writes nothing the second time.
    func rebuild(with items: [ChecklistItem]) async throws {
        let wispList = try wispTodayList(creatingIfMissing: true)
        let existingReminders = await fetchSnapshots(in: wispList)
        let storedMapping: [String: String] = JobsPrivateJSONFile.load([String: String].self, from: reminderMapFileURL) ?? [:]

        let rebuildPlan = JobsEventKitPlanning.reminderRebuildPlan(
            items: items,
            itemIDToReminderIdentifier: storedMapping,
            existingReminders: existingReminders.map { $0.snapshot }
        )

        var newMapping = rebuildPlan.retainedItemIDToReminderIdentifier
        var addedItemIDsToReminders: [(itemID: String, reminder: EKReminder)] = []

        for operation in rebuildPlan.operations {
            switch operation {
            case .add(let item):
                let newReminder = EKReminder(eventStore: eventStore)
                newReminder.calendar = wispList
                fill(newReminder, from: item)
                if item.isCompleted {
                    newReminder.isCompleted = true
                    newReminder.completionDate = item.completionDate ?? Date()
                }
                try eventStore.save(newReminder, commit: false)
                addedItemIDsToReminders.append((item.id, newReminder))
            case .update(let reminderIdentifier, let item):
                guard let existingReminder = eventStore.calendarItem(withIdentifier: reminderIdentifier) as? EKReminder else {
                    throw WispEventKitError.itemMissing
                }
                fill(existingReminder, from: item)
                try eventStore.save(existingReminder, commit: false)
            case .remove(let reminderIdentifier):
                if let existingReminder = eventStore.calendarItem(withIdentifier: reminderIdentifier) as? EKReminder {
                    try eventStore.remove(existingReminder, commit: false)
                }
            }
        }
        if !rebuildPlan.operations.isEmpty { try eventStore.commit() }

        for added in addedItemIDsToReminders { newMapping[added.itemID] = added.reminder.calendarItemIdentifier }
        try JobsPrivateJSONFile.save(newMapping, to: reminderMapFileURL)
    }

    private func fill(_ reminder: EKReminder, from item: ChecklistItem) {
        reminder.title = item.title
        reminder.notes = JobsEventKitPlanning.reminderNotes(for: item)
        if let dueDate = item.dueDate {
            let currentCalendar = Calendar.current
            let isMidnight = currentCalendar.startOfDay(for: dueDate) == dueDate
            // A midnight due date means "due that day" (an all-day Canvas item), so it
            // gets date-only components rather than a time that would read as 12:00 AM.
            let componentSet: Set<Calendar.Component> = isMidnight
                ? [.year, .month, .day]
                : [.year, .month, .day, .hour, .minute]
            reminder.dueDateComponents = currentCalendar.dateComponents(componentSet, from: dueDate)
        } else {
            reminder.dueDateComponents = nil
        }
    }

    // MARK: Completion

    /// Reads isCompleted and completionDate for every item we mapped.
    func readBackCompletion() async throws -> [String: (isCompleted: Bool, completionDate: Date?)] {
        let wispList = try wispTodayList(creatingIfMissing: false)
        let storedMapping: [String: String] = JobsPrivateJSONFile.load([String: String].self, from: reminderMapFileURL) ?? [:]
        let fetchedReminders = await fetchSnapshots(in: wispList)
        let snapshotsByIdentifier = Dictionary(
            fetchedReminders.map { ($0.snapshot.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var completionByItemID: [String: (isCompleted: Bool, completionDate: Date?)] = [:]
        for (itemID, reminderIdentifier) in storedMapping {
            guard let fetched = snapshotsByIdentifier[reminderIdentifier] else { continue }
            completionByItemID[itemID] = (fetched.isCompleted, fetched.completionDate)
        }
        return completionByItemID
    }

    /// A tick in the notch. Throws `itemMissing` when the reminder is gone, so the
    /// engine can revert its optimistic UI.
    func setCompleted(itemID: String, isCompleted: Bool) async throws {
        try requireGrantedAccess()
        let storedMapping: [String: String] = JobsPrivateJSONFile.load([String: String].self, from: reminderMapFileURL) ?? [:]
        guard let reminderIdentifier = storedMapping[itemID],
              let reminder = eventStore.calendarItem(withIdentifier: reminderIdentifier) as? EKReminder else {
            throw WispEventKitError.itemMissing
        }
        reminder.isCompleted = isCompleted
        if !isCompleted { reminder.completionDate = nil }
        try eventStore.save(reminder, commit: true)
    }

    // MARK: The "Wisp Today" list

    private func requireGrantedAccess() throws {
        guard authorizationState() == .granted else { throw WispEventKitError.accessDenied }
    }

    private func wispTodayList(creatingIfMissing: Bool) throws -> EKCalendar {
        try requireGrantedAccess()
        if let existingList = eventStore.calendars(for: .reminder).first(where: {
            $0.title == Self.listTitle && $0.allowsContentModifications
        }) {
            return existingList
        }
        guard creatingIfMissing else { throw WispEventKitError.calendarMissing }

        let newList = EKCalendar(for: .reminder, eventStore: eventStore)
        newList.title = Self.listTitle
        // Same account as the user's default list so it syncs with their other devices.
        guard let writableSource = eventStore.defaultCalendarForNewReminders()?.source
                ?? eventStore.sources.first(where: { $0.sourceType == .local }) else {
            throw WispEventKitError.noWritableSource
        }
        newList.source = writableSource
        try eventStore.saveCalendar(newList, commit: true)
        return newList
    }

    private struct FetchedReminder: Sendable {
        let snapshot: ExistingReminderSnapshot
        let isCompleted: Bool
        let completionDate: Date?
    }

    /// EKReminder is not Sendable, so the callback copies what it needs into value
    /// types before resuming.
    private func fetchSnapshots(in list: EKCalendar) async -> [FetchedReminder] {
        let predicate = eventStore.predicateForReminders(in: [list])
        let eventStoreForFetch = eventStore
        return await withCheckedContinuation { (continuation: CheckedContinuation<[FetchedReminder], Never>) in
            eventStoreForFetch.fetchReminders(matching: predicate) { fetchedReminders in
                let copiedReminders = (fetchedReminders ?? []).map { reminder -> FetchedReminder in
                    let dueDate = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
                    return FetchedReminder(
                        snapshot: ExistingReminderSnapshot(
                            identifier: reminder.calendarItemIdentifier,
                            title: reminder.title ?? "",
                            dueDate: dueDate,
                            stampedItemID: JobsEventKitPlanning.itemID(fromReminderNotes: reminder.notes),
                            notes: reminder.notes
                        ),
                        isCompleted: reminder.isCompleted,
                        completionDate: reminder.completionDate
                    )
                }
                continuation.resume(returning: copiedReminders)
            }
        }
    }
}
