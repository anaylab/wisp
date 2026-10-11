//
//  CalendarEventAddedCardView.swift
//  leanring-buddy
//
//  The Siri-style result card shown in the notch after Wisp adds an event:
//  "Added to Calendar", then the event as Calendar would show it — a date
//  tile, the title, the day and time range, the place — with Open in Calendar
//  and Undo. Drawn in the island's own palette (`WispColor.Island`: true
//  black, white text, flat fills) so it reads as part of the notch rather than
//  a grey panel dropped into it, and matches the confirmation panel's layout
//  (`SchedulingConfirmationView`) so asking and confirming look like one thing.
//
//  The card holds only the event's id (`CalendarEventAddedCardState`). Its
//  details and Undo progress live in `CreatedCalendarEventStore`.
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
        Group {
            if let createdEvent = createdEventStore.event(withID: state.eventID) {
                VStack(alignment: .leading, spacing: 12) {
                    SchedulingResultHeader(
                        isRemoved: createdEvent.undoStatus == .removed,
                        addedTitle: "Added to Calendar",
                        removedTitle: "Removed from Calendar",
                        trailingText: createdEvent.calendarName,
                        trailingColorHex: createdEvent.calendarColorHex
                    )
                    eventSummary(for: createdEvent)
                    SchedulingResultActions(
                        undoStatus: createdEvent.undoStatus,
                        openTitle: "Open in Calendar",
                        onOpen: { createdEventStore.openInCalendar(eventID: createdEvent.id) },
                        onUndo: { createdEventStore.undo(eventID: createdEvent.id) }
                    )
                }
            } else {
                Text("Event unavailable")
                    .font(.system(size: 12))
                    .foregroundColor(WispColor.Island.textSecondary)
            }
        }
        .schedulingResultCardSurface()
    }

    private func eventSummary(for createdEvent: CreatedCalendarEvent) -> some View {
        let isRemoved = createdEvent.undoStatus == .removed
        let draft = createdEvent.draft
        return HStack(alignment: .top, spacing: 12) {
            CalendarDateTile(date: draft.startDate, size: 46)
                .opacity(isRemoved ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(draft.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isRemoved ? WispColor.Island.textTertiary : WispColor.Island.textPrimary)
                    .strikethrough(isRemoved)
                    .lineLimit(2)
                Text(SchedulingPhrasing.fullDayText(for: draft.startDate))
                    .font(.system(size: 12))
                    .foregroundColor(WispColor.Island.textSecondary)
                    .lineLimit(1)
                Text(SchedulingPhrasing.timeRangeText(start: draft.startDate, end: draft.endDate, isAllDay: draft.isAllDay))
                    .font(.system(size: 12))
                    .foregroundColor(WispColor.Island.textSecondary)
                    .lineLimit(1)
                if let location = draft.location {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 10, weight: .medium))
                        Text(location)
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
}

// MARK: - Shared result-card pieces

/// "✓ Added to Calendar ……… Home" — what happened, and where it landed.
struct SchedulingResultHeader: View {
    let isRemoved: Bool
    let addedTitle: String
    let removedTitle: String
    let trailingText: String
    let trailingColorHex: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isRemoved ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isRemoved ? WispColor.Island.textTertiary : WispColor.success)
            Text(isRemoved ? removedTitle : addedTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(WispColor.Island.textSecondary)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Circle()
                    .fill(Color(hex: trailingColorHex ?? "#8E8E93"))
                    .frame(width: 6, height: 6)
                Text(trailingText)
                    .font(.system(size: 11))
                    .foregroundColor(WispColor.Island.textTertiary)
                    .lineLimit(1)
            }
        }
    }
}

/// Open … / Undo, or why Undo failed, or nothing once it's undone.
struct SchedulingResultActions: View {
    let undoStatus: CreatedCalendarEvent.UndoStatus
    let openTitle: String
    let onOpen: () -> Void
    let onUndo: () -> Void

    var body: some View {
        switch undoStatus {
        case .added, .removing:
            HStack(spacing: 8) {
                GlanceCardActionButton(title: openTitle, action: onOpen)
                Spacer(minLength: 0)
                GlanceCardActionButton(
                    title: undoStatus == .removing ? "Undoing…" : "Undo",
                    isEnabled: undoStatus == .added,
                    action: onUndo
                )
            }
        case .removed:
            EmptyView()
        case let .removeFailed(reason):
            Text(reason)
                .font(.system(size: 11))
                .foregroundColor(WispColor.destructiveText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension View {
    /// The result cards' surface on the island: a flat, barely-lifted fill
    /// on the black, no border — the island's own control language.
    func schedulingResultCardSurface() -> some View {
        self
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )
    }
}
