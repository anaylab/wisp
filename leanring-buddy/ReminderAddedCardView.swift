//
//  ReminderAddedCardView.swift
//  leanring-buddy
//
//  The Siri-style result card shown after Wisp adds a reminder: a ring in the
//  list's colour (Reminders' own checkbox), the title, when it's due, the
//  list, then Open Reminders and Undo. The reminders counterpart of
//  `CalendarEventAddedCardView`; state lives in `CreatedReminderStore`.
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
        VStack(alignment: .leading, spacing: 10) {
            if let createdReminder = createdReminderStore.reminder(withID: state.reminderID) {
                header(for: createdReminder)
                reminderSummary(for: createdReminder)
                actionRow(for: createdReminder)
            } else {
                Text("Reminder unavailable")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            attribution
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    private func header(for createdReminder: CreatedReminder) -> some View {
        let isRemoved = createdReminder.undoStatus == .removed
        return HStack(spacing: 8) {
            Image(systemName: isRemoved ? "checklist.unchecked" : "checklist")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isRemoved ? DS.Colors.textSecondary : DS.Colors.accentText)
            Text(isRemoved ? "Reminder Removed" : "Reminder Added")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
        }
    }

    private func reminderSummary(for createdReminder: CreatedReminder) -> some View {
        let isRemoved = createdReminder.undoStatus == .removed
        let listColor = Color(hex: createdReminder.listColorHex ?? "#5B8DEF")
        return HStack(alignment: .top, spacing: 10) {
            // The empty ring Reminders draws as each item's checkbox.
            Circle()
                .strokeBorder(listColor, lineWidth: 1.5)
                .frame(width: 14, height: 14)
                .padding(.top, 1)
                .opacity(isRemoved ? 0.4 : 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(createdReminder.draft.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isRemoved ? DS.Colors.textTertiary : DS.Colors.textPrimary)
                    .strikethrough(isRemoved)
                    .lineLimit(2)
                if let dueText = Self.dueText(for: createdReminder.draft) {
                    Label(dueText, systemImage: createdReminder.draft.dueDateIncludesTimeOfDay ? "bell" : "calendar")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                }
                Text(createdReminder.listName)
                    .font(.system(size: 11))
                    .foregroundColor(listColor.opacity(isRemoved ? 0.5 : 0.9))
                    .lineLimit(1)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func actionRow(for createdReminder: CreatedReminder) -> some View {
        switch createdReminder.undoStatus {
        case .added, .removing:
            HStack(spacing: 8) {
                GlanceCardActionButton(title: "Open Reminders") {
                    createdReminderStore.openReminders()
                }
                GlanceCardActionButton(
                    title: createdReminder.undoStatus == .removing ? "Undoing…" : "Undo",
                    isEnabled: createdReminder.undoStatus == .added
                ) {
                    createdReminderStore.undo(reminderID: createdReminder.id)
                }
            }
        case .removed:
            EmptyView()
        case let .removeFailed(reason):
            Text(reason)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.destructiveText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var attribution: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(DS.Colors.textTertiary)
                .frame(width: 5, height: 5)
            Text("On this Mac · Reminders")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    /// "Tomorrow, 9:00 AM", "Friday, Oct 9", or nil for an undated reminder.
    static func dueText(for draft: ReminderDraft) -> String? {
        guard let dueDate = draft.dueDate else { return nil }
        let dueDateFormatter = DateFormatter()
        dueDateFormatter.doesRelativeDateFormatting = true
        dueDateFormatter.dateStyle = .full
        dueDateFormatter.timeStyle = draft.dueDateIncludesTimeOfDay ? .short : .none
        // `.full` spells the year out; drop it for this year, as Reminders does.
        let currentYearText = String(Calendar.current.component(.year, from: Date()))
        return dueDateFormatter.string(from: dueDate)
            .replacingOccurrences(of: ", \(currentYearText)", with: "")
    }
}
