//
//  CalendarSnapshot.swift
//  leanring-buddy
//
//  The resolved data behind a calendar glance card — the user's next few
//  events, read on-device through EventKit by `CalendarDataProvider`. Nothing
//  here comes from the model: a `[CARD:{"kind":"calendar"}]` intent carries no
//  fields, and Wisp reads the events itself. Because the read is local (never a
//  network call), it is not gated by the live-card-data network setting; the
//  user's macOS Calendar permission is the control.
//

import Foundation

/// One upcoming event, already flattened from EventKit into a value type so the
/// card renderer never touches a non-Sendable `EKEvent`.
struct CalendarGlanceEvent: Equatable, Identifiable {
    /// EventKit's stable identifier, used only so SwiftUI can key the list.
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let location: String?
    /// The owning calendar's colour as a hex string (e.g. "#FF3B30"), so the
    /// card can show the coloured dot Calendar uses without importing AppKit
    /// into the view.
    let calendarColorHex: String?
}

/// Everything a calendar card renders: the upcoming events and when they were
/// read (so the card can show a relative "in 20 min" using a stable clock).
struct CalendarSnapshot: Equatable {
    let events: [CalendarGlanceEvent]
    let generatedAt: Date
}
