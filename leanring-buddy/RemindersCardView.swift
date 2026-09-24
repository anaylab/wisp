//
//  RemindersCardView.swift
//  leanring-buddy
//
//  The reminders glance card, drawn on the notch's dark palette (DS.*) in a
//  Reminders-like list: each incomplete reminder as its list's coloured dot, its
//  title, and when it is due — overdue ones in the bad tone. It is fed a
//  `RemindersSnapshot` that Wisp reads on-device (`RemindersDataProvider`), so
//  nothing here comes from the model.
//
//  Each row is tappable and opens Reminders.app, so the card is a jumping-off
//  point the way the places card opens Maps. Rows show a pointer cursor and a
//  hover highlight, per the project's interaction conventions.
//
//  Five states, so the card can appear the instant a turn asks for it: loading,
//  loaded (which handles the empty "all done" case), failed, access-denied (a
//  clear prompt to grant Reminders access rather than a misleading empty list),
//  and list-not-found (the model or user named a list that does not exist).
//

import AppKit
import SwiftUI

/// What the reminders card is showing right now.
enum RemindersCardState: Equatable {
    case loading
    case failed
    case accessDenied
    case listNotFound(listName: String)
    case loaded(RemindersSnapshot)
}

struct RemindersCardView: View {
    let state: RemindersCardState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
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

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.accentText)
            Text(headerTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
        }
    }

    /// Names the slice being shown: "Due Today", "Overdue", the list's own name,
    /// or plain "Reminders".
    private var headerTitle: String {
        guard case let .loaded(snapshot) = state else { return "Reminders" }
        switch snapshot.filter {
        case .today:
            return snapshot.listName.map { "\($0) · Today" } ?? "Due Today"
        case .overdue:
            return snapshot.listName.map { "\($0) · Overdue" } ?? "Overdue"
        case .all:
            return snapshot.listName ?? "Reminders"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            placeholder("Reading your reminders…")
        case .failed:
            placeholder("Reminders unavailable")
        case .accessDenied:
            placeholder("Grant Reminders access in System Settings to see them here.")
        case let .listNotFound(listName):
            placeholder("No Reminders list called “\(listName)”.")
        case let .loaded(snapshot):
            if snapshot.reminders.isEmpty {
                placeholder(emptyMessage(for: snapshot.filter))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(snapshot.reminders) { reminder in
                        ReminderRow(reminder: reminder, now: snapshot.generatedAt)
                    }
                }
            }
        }
    }

    private func emptyMessage(for filter: RemindersFilter) -> String {
        switch filter {
        case .today: return "Nothing due today."
        case .overdue: return "Nothing overdue."
        case .all: return "All done — no open reminders."
        }
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundColor(DS.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// On-device, so it is labelled as local rather than "Live · <network>".
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
}

// MARK: - Row

/// One reminder. A button that opens Reminders.app, with a pointer cursor and a
/// hover highlight so its clickability reads.
private struct ReminderRow: View {
    let reminder: RemindersGlanceReminder
    /// The snapshot's read time, so "overdue" and "today" use one stable clock.
    let now: Date

    @State private var isHovered = false

    private static let remindersAppBundleIdentifier = "com.apple.reminders"

    var body: some View {
        Button(action: openRemindersApp) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(listDotColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(reminder.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(reminder.listName)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if let dueLabel {
                    Text(dueLabel)
                        .font(.system(size: 11, weight: .medium))
                        // Overdue reads in the same "bad" tone the generic card
                        // uses, so the meaning is consistent across cards.
                        .foregroundColor(isOverdue ? DS.Colors.destructiveText : DS.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(isHovered ? DS.Colors.surface3 : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var isOverdue: Bool {
        RemindersSelection.isOverdue(reminder, now: now)
    }

    /// The list's own colour when EventKit gave one, otherwise a neutral token.
    private var listDotColor: Color {
        guard let listColorHex = reminder.listColorHex else { return DS.Colors.textTertiary }
        return Color(hex: listColorHex)
    }

    /// A compact "when": "Today", "Today 3:00 PM", "Tomorrow", "Yesterday",
    /// a weekday within the week, or a short date further out. Nil when the
    /// reminder has no due date.
    private var dueLabel: String? {
        guard let dueDate = reminder.dueDate else { return nil }
        let calendar = Calendar.current

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        let timeSuffix = reminder.isDueDateAllDay ? "" : " " + timeFormatter.string(from: dueDate)

        if calendar.isDate(dueDate, inSameDayAs: now) {
            return "Today" + timeSuffix
        }
        if calendar.isDateInTomorrow(dueDate) {
            return "Tomorrow" + timeSuffix
        }
        if calendar.isDateInYesterday(dueDate) {
            return "Yesterday"
        }

        let dayFormatter = DateFormatter()
        let daysFromNow = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: dueDate)
        ).day ?? 0
        dayFormatter.dateFormat = (daysFromNow > 0 && daysFromNow < 7) ? "EEE" : "MMM d"
        return dayFormatter.string(from: dueDate)
    }

    /// Opens Reminders.app. EventKit gives no supported deep link to a single
    /// reminder, so the app itself is the destination.
    private func openRemindersApp() {
        guard let remindersAppURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: Self.remindersAppBundleIdentifier
        ) else { return }
        NSWorkspace.shared.openApplication(
            at: remindersAppURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}
