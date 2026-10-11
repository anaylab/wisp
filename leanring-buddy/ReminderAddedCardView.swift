//
//  ReminderAddedCardView.swift
//  leanring-buddy
//
//  The Siri-style result card shown in the notch after Wisp adds a reminder:
//  "Added to Reminders", then the reminder as Reminders would show it — a ring
//  in the list's colour, the title, when it's due — with Open Reminders and
//  Undo. The reminders counterpart of `CalendarEventAddedCardView`, sharing
//  its header, actions and island surface; state lives in `CreatedReminderStore`.
//

import SwiftUI

/// Which created reminder a "Reminder Added" card shows.
struct ReminderAddedCardState: Equatable {
    let reminderID: String
}

struct ReminderAddedCardView: View {
    let state: ReminderAddedCardState

    @ObservedObject private var createdReminderStore = CreatedReminderStore.shared

    var body: some View {
        Group {
            if let createdReminder = createdReminderStore.reminder(withID: state.reminderID) {
                VStack(alignment: .leading, spacing: 12) {
                    SchedulingResultHeader(
                        isRemoved: createdReminder.undoStatus == .removed,
                        addedTitle: "Added to Reminders",
                        removedTitle: "Removed from Reminders",
                        trailingText: createdReminder.listName,
                        trailingColorHex: createdReminder.listColorHex
                    )
                    reminderSummary(for: createdReminder)
                    SchedulingResultActions(
                        undoStatus: createdReminder.undoStatus,
                        openTitle: "Open Reminders",
                        onOpen: { createdReminderStore.openReminders() },
                        onUndo: { createdReminderStore.undo(reminderID: createdReminder.id) }
                    )
                }
            } else {
                Text("Reminder unavailable")
                    .font(.system(size: 12))
                    .foregroundColor(WispColor.Island.textSecondary)
            }
        }
        .schedulingResultCardSurface()
    }

    private func reminderSummary(for createdReminder: CreatedReminder) -> some View {
        let isRemoved = createdReminder.undoStatus == .removed
        let listColor = Color(hex: createdReminder.listColorHex ?? "#0A84FF")
        return HStack(alignment: .top, spacing: 10) {
            ReminderCheckRing(color: listColor, diameter: 18)
                .padding(.top, 1)
                .opacity(isRemoved ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(createdReminder.draft.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isRemoved ? WispColor.Island.textTertiary : WispColor.Island.textPrimary)
                    .strikethrough(isRemoved)
                    .lineLimit(2)
                if let dueText = Self.dueText(for: createdReminder.draft) {
                    HStack(spacing: 4) {
                        Image(systemName: createdReminder.draft.dueDateIncludesTimeOfDay ? "bell.fill" : "calendar")
                            .font(.system(size: 10, weight: .medium))
                        Text(dueText)
                            .lineLimit(1)
                    }
                    .font(.system(size: 12))
                    .foregroundColor(WispColor.Island.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "Tomorrow at 9 AM", "Friday", or nil for an undated reminder.
    static func dueText(for draft: ReminderDraft) -> String? {
        guard let dueDate = draft.dueDate else { return nil }
        let whenPhrase = SchedulingPhrasing.whenPhrase(for: dueDate, includesTimeOfDay: draft.dueDateIncludesTimeOfDay)
        guard let firstCharacter = whenPhrase.first else { return whenPhrase }
        return firstCharacter.uppercased() + whenPhrase.dropFirst()
    }
}
