//
//  CalendarEventAddedCardView.swift
//  leanring-buddy
//
//  The Siri-style result card shown after Wisp adds an event: the calendar's
//  colour bar, the title, the day and time range, the place and calendar,
//  then Open in Calendar and Undo. Drawn on the notch's dark palette (DS.*)
//  like the other glance cards.
//
//  The card holds only the event's id (`CalendarEventAddedCardState`). Its
//  state, including whether Undo has run, lives in `CreatedCalendarEventStore`.
//

import SwiftUI

/// Which created event an "Event Added" card shows.
struct CalendarEventAddedCardState: Equatable {
    let eventID: String
}

struct CalendarEventAddedCardView: View {
    let state: CalendarEventAddedCardState

    @ObservedObject private var createdEventStore = CreatedCalendarEventStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let createdEvent = createdEventStore.event(withID: state.eventID) {
                header(for: createdEvent)
                eventSummary(for: createdEvent)
                actionRow(for: createdEvent)
            } else {
                Text("Event unavailable")
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

    private func header(for createdEvent: CreatedCalendarEvent) -> some View {
        let isRemoved = createdEvent.undoStatus == .removed
        return HStack(spacing: 8) {
            Image(systemName: isRemoved ? "calendar.badge.minus" : "calendar.badge.checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isRemoved ? DS.Colors.textSecondary : DS.Colors.accentText)
            Text(isRemoved ? "Event Removed" : "Event Added")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
        }
    }

    private func eventSummary(for createdEvent: CreatedCalendarEvent) -> some View {
        let isRemoved = createdEvent.undoStatus == .removed
        return HStack(alignment: .top, spacing: 10) {
            // Calendar's own colour, as the bar beside an event in Calendar.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color(hex: createdEvent.calendarColorHex ?? "#5B8DEF"))
                .frame(width: 3)
                .opacity(isRemoved ? 0.4 : 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(createdEvent.draft.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isRemoved ? DS.Colors.textTertiary : DS.Colors.textPrimary)
                    .strikethrough(isRemoved)
                    .lineLimit(2)
                Text(Self.whenText(for: createdEvent.draft))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                if let location = createdEvent.draft.location {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                }
                Text(createdEvent.calendarName)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func actionRow(for createdEvent: CreatedCalendarEvent) -> some View {
        switch createdEvent.undoStatus {
        case .added, .removing:
            HStack(spacing: 8) {
                GlanceCardActionButton(title: "Open in Calendar") {
                    createdEventStore.openInCalendar(eventID: createdEvent.id)
                }
                GlanceCardActionButton(
                    title: createdEvent.undoStatus == .removing ? "Undoing…" : "Undo",
                    isEnabled: createdEvent.undoStatus == .added
                ) {
                    createdEventStore.undo(eventID: createdEvent.id)
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
            Text("On this Mac · Calendar")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    /// "Friday, Oct 9 · 1:00 – 2:00 PM", "Friday, Oct 9 · All day", or a range
    /// across days ("Fri, Oct 9, 11:00 PM – Sat, Oct 10, 1:00 AM").
    static func whenText(for draft: CalendarEventDraft) -> String {
        let dayFormatter = DateFormatter()
        dayFormatter.setLocalizedDateFormatFromTemplate("EEEEMMMd")
        let dayText = dayFormatter.string(from: draft.startDate)
        if draft.isAllDay {
            return "\(dayText) · All day"
        }
        let calendar = Calendar.current
        if calendar.isDate(draft.startDate, inSameDayAs: draft.endDate) {
            let intervalFormatter = DateIntervalFormatter()
            intervalFormatter.dateStyle = .none
            intervalFormatter.timeStyle = .short
            return "\(dayText) · \(intervalFormatter.string(from: draft.startDate, to: draft.endDate))"
        }
        let intervalFormatter = DateIntervalFormatter()
        intervalFormatter.dateTemplate = "EEEMMMdjmm"
        return intervalFormatter.string(from: draft.startDate, to: draft.endDate)
    }
}
