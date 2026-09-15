//
//  CalendarCardView.swift
//  leanring-buddy
//
//  The calendar glance card, drawn on the notch's dark palette (DS.*) in a
//  Calendar-like "up next" layout: each upcoming event as a coloured dot, its
//  title, and when it starts. It is fed a `CalendarSnapshot` that Wisp reads
//  on-device (`CalendarDataProvider`), so nothing here comes from the model.
//
//  Four states, so the card can appear the instant a turn asks for it: loading,
//  loaded (which itself handles the empty "nothing coming up" case), failed, and
//  access-denied (a clear prompt to grant Calendar access rather than a
//  misleading empty list).
//

import SwiftUI

/// What the calendar card is showing right now.
enum CalendarCardState: Equatable {
    case loading
    case failed
    case accessDenied
    case loaded(CalendarSnapshot)
}

struct CalendarCardView: View {
    let state: CalendarCardState

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
            Image(systemName: "calendar")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.accentText)
            Text("Up Next")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            placeholder("Reading your calendar…")
        case .failed:
            placeholder("Calendar unavailable")
        case .accessDenied:
            placeholder("Grant Calendar access in System Settings to see events here.")
        case let .loaded(snapshot):
            if snapshot.events.isEmpty {
                placeholder("Nothing coming up.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(snapshot.events) { event in
                        eventRow(event, now: snapshot.generatedAt)
                    }
                }
            }
        }
    }

    private func eventRow(_ event: CalendarGlanceEvent, now: Date) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color(hex: event.calendarColorHex ?? "#5B8DEF"))
                .frame(width: 8, height: 8)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                if let location = event.location {
                    Text(location)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Text(startLabel(for: event, now: now))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)
        }
    }

    /// A compact, human "when": "All day", "in 20 min", "3:30 PM", or a weekday
    /// for events further out.
    private func startLabel(for event: CalendarGlanceEvent, now: Date) -> String {
        if event.isAllDay {
            return "All day"
        }

        let secondsUntilStart = event.startDate.timeIntervalSince(now)
        if secondsUntilStart > 0 && secondsUntilStart < 60 * 60 {
            let minutes = max(1, Int((secondsUntilStart / 60).rounded()))
            return "in \(minutes) min"
        }

        let calendar = Calendar.current
        let formatter = DateFormatter()
        if calendar.isDate(event.startDate, inSameDayAs: now) {
            formatter.dateFormat = "h:mm a"
        } else {
            formatter.dateFormat = "EEE h:mm a"
        }
        return formatter.string(from: event.startDate)
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
            Text("On this Mac · Calendar")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }
}
