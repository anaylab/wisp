//
//  CreatedReminderStore.swift
//  leanring-buddy
//
//  Every reminder Wisp creates this session, whether from the reminders fast
//  path or the agent's `create_reminder` tool, so the notch can show the
//  Siri-style "Reminder Added" card with Undo. The reminders counterpart of
//  `CreatedCalendarEventStore`, with the same narrow Undo: it can only remove
//  a reminder recorded here, and the record is in memory only.
//

import AppKit
import Combine
import Foundation

struct CreatedReminder: Identifiable, Equatable {
    /// EventKit's `calendarItemIdentifier`.
    let id: String
    let draft: ReminderDraft
    /// The list it actually landed in (the default when none was named).
    let listName: String
    let listColorHex: String?
    let createdAt: Date
    var undoStatus: CreatedCalendarEvent.UndoStatus
}

@MainActor
final class CreatedReminderStore: ObservableObject {
    static let shared = CreatedReminderStore()

    @Published private(set) var createdRemindersByID: [String: CreatedReminder] = [:]

    /// Called once an Undo has removed a reminder, with what it was, so the
    /// reply line above the card can stop saying "Added …".
    var onUndoCompleted: ((CreatedReminder) -> Void)?

    func record(
        createdReminderDetails: RemindersDataProvider.CreatedReminderDetails,
        draft: ReminderDraft,
        createdAt: Date = Date()
    ) {
        guard !createdReminderDetails.reminderIdentifier.isEmpty else { return }
        createdRemindersByID[createdReminderDetails.reminderIdentifier] = CreatedReminder(
            id: createdReminderDetails.reminderIdentifier,
            draft: draft,
            listName: createdReminderDetails.listName,
            listColorHex: createdReminderDetails.listColorHex,
            createdAt: createdAt,
            undoStatus: .added
        )
    }

    func reminder(withID reminderID: String) -> CreatedReminder? {
        createdRemindersByID[reminderID]
    }

    /// The newest reminder created at or after `date`, for showing the result
    /// card after an agent turn whose tool call made one.
    func mostRecentReminder(createdSince date: Date) -> CreatedReminder? {
        createdRemindersByID.values
            .filter { $0.createdAt >= date }
            .max { $0.createdAt < $1.createdAt }
    }

    /// Removes the reminder again. Only reminders recorded here can be undone.
    func undo(reminderID: String) {
        guard var createdReminder = createdRemindersByID[reminderID], createdReminder.undoStatus == .added else { return }
        createdReminder.undoStatus = .removing
        createdRemindersByID[reminderID] = createdReminder

        Task { [weak self] in
            let finalStatus: CreatedCalendarEvent.UndoStatus
            do {
                // False means it was already deleted in Reminders, which counts
                // as undone too: either way it is gone.
                _ = try await RemindersDataProvider.shared.removeReminder(withIdentifier: reminderID)
                finalStatus = .removed
            } catch RemindersDataProvider.RemindersDataError.accessDenied {
                finalStatus = .removeFailed(reason: "Reminders access was turned off.")
            } catch {
                finalStatus = .removeFailed(reason: "Couldn't remove it — try in Reminders.")
            }
            guard let self, var updatedReminder = self.createdRemindersByID[reminderID] else { return }
            updatedReminder.undoStatus = finalStatus
            self.createdRemindersByID[reminderID] = updatedReminder
            if finalStatus == .removed { self.onUndoCompleted?(updatedReminder) }
        }
    }

    /// Opens the Reminders app. (It has no documented link to one reminder.)
    func openReminders() {
        guard let remindersApplicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") else { return }
        NSWorkspace.shared.openApplication(at: remindersApplicationURL, configuration: NSWorkspace.OpenConfiguration())
    }
}
