//
//  CalendarDataProvider.swift
//  leanring-buddy
//
//  Reads the user's upcoming events on-device through EventKit and maps them
//  into a `CalendarSnapshot` for the calendar glance card. This is a local read
//  — nothing leaves the machine — so unlike the weather and REST sources it is
//  not gated by the live-card-data network setting; the user's macOS Calendar
//  permission is the gate. When access has never been requested, the first card
//  triggers the system permission prompt; when it is denied, the card says so
//  rather than showing an empty list.
//
//  An `actor` so the EventKit store is touched from one place off the main
//  actor; every `EKEvent` is flattened into a Sendable `CalendarGlanceEvent`
//  before it leaves this actor.
//

import EventKit
import Foundation

actor CalendarDataProvider: GlanceCardDataProvider {
    static let shared = CalendarDataProvider()

    enum CalendarDataError: Error, Equatable {
        /// The user has not granted (or has denied) Calendar access.
        case accessDenied
        /// No calendar on this Mac accepts new events.
        case noWritableCalendar
    }

    private let eventStore = EKEventStore()

    /// How far ahead to look for upcoming events, and the most to show.
    private let lookAheadInterval: TimeInterval = 60 * 60 * 24 * 7
    private let maximumEvents = 4

    /// Reads the next few upcoming events.
    ///
    /// Requests Calendar access if it has not been decided yet; throws
    /// `accessDenied` if the user has refused, so the card can show a clear
    /// "grant access" state instead of a misleading empty list.
    func snapshot(now: Date = Date()) async throws -> CalendarSnapshot {
        try await ensureAccess()

        // Look from now to a week ahead across every calendar the user has.
        let endDate = now.addingTimeInterval(lookAheadInterval)
        let predicate = eventStore.predicateForEvents(
            withStart: now,
            end: endDate,
            calendars: nil
        )

        let upcomingEvents = eventStore.events(matching: predicate)
            // An all-day event earlier today can come back with a start before
            // `now`; keep anything that has not yet ended.
            .filter { $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(maximumEvents)
            .map { event in
                CalendarGlanceEvent(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title ?? "(no title)",
                    startDate: event.startDate,
                    endDate: event.endDate,
                    isAllDay: event.isAllDay,
                    location: event.location?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil,
                    calendarColorHex: event.calendar?.cgColor?.hexString
                )
            }

        return CalendarSnapshot(events: Array(upcomingEvents), generatedAt: now)
    }

    /// The next timed (not all-day) event starting within `lookAheadInterval`,
    /// or one that started less than `recentlyStartedInterval` ago. For the
    /// notch's ambient "next meeting" countdown.
    ///
    /// Unlike `snapshot`, this never requests access: it runs on a timer with
    /// nobody having asked for anything, so a permission prompt would appear out
    /// of nowhere. Without full access it simply returns nil.
    func imminentTimedEventIfAuthorized(
        now: Date = Date(),
        lookAheadInterval: TimeInterval,
        recentlyStartedInterval: TimeInterval
    ) -> CalendarGlanceEvent? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }

        let predicate = eventStore.predicateForEvents(
            withStart: now.addingTimeInterval(-recentlyStartedInterval),
            end: now.addingTimeInterval(lookAheadInterval),
            calendars: nil
        )
        let earliestEvent = eventStore.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate >= now.addingTimeInterval(-recentlyStartedInterval) }
            .min { $0.startDate < $1.startDate }
        guard let earliestEvent else { return nil }

        return CalendarGlanceEvent(
            id: earliestEvent.eventIdentifier ?? UUID().uuidString,
            title: earliestEvent.title ?? "(no title)",
            startDate: earliestEvent.startDate,
            endDate: earliestEvent.endDate,
            isAllDay: false,
            location: earliestEvent.location?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil,
            calendarColorHex: earliestEvent.calendar?.cgColor?.hexString
        )
    }

    /// How many timed (not all-day) events are still to start today, or nil
    /// without Calendar access. For the morning suggestions banner; like
    /// `imminentTimedEventIfAuthorized`, never prompts.
    func remainingTimedEventCountTodayIfAuthorized(now: Date = Date()) -> Int? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        guard let startOfTomorrow = Calendar.current.date(
            byAdding: .day,
            value: 1,
            to: Calendar.current.startOfDay(for: now)
        ) else { return nil }

        let predicate = eventStore.predicateForEvents(withStart: now, end: startOfTomorrow, calendars: nil)
        return eventStore.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate >= now }
            .count
    }

    /// Events overlapping `rangeStartDate`…`rangeEndDate`, soonest first, across
    /// every calendar. For the agent's `get_calendar_events` tool, which can be
    /// asked about any day ("what's on friday"), unlike `snapshot`'s fixed week.
    func events(
        from rangeStartDate: Date,
        to rangeEndDate: Date,
        maximumEventCount: Int
    ) async throws -> [CalendarGlanceEvent] {
        try await ensureAccess()

        let predicate = eventStore.predicateForEvents(
            withStart: rangeStartDate,
            end: rangeEndDate,
            calendars: nil
        )
        return eventStore.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(maximumEventCount)
            .map { event in
                CalendarGlanceEvent(
                    id: event.eventIdentifier ?? UUID().uuidString,
                    title: event.title ?? "(no title)",
                    startDate: event.startDate,
                    endDate: event.endDate,
                    isAllDay: event.isAllDay,
                    location: event.location?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyOrNil,
                    calendarColorHex: event.calendar?.cgColor?.hexString
                )
            }
    }

    /// Adds an event to the user's calendar and returns the name of the
    /// calendar it landed in. `requestedCalendarName` picks a writable calendar
    /// by name; nil (or no match) uses the default calendar for new events.
    func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        location: String?,
        requestedCalendarName: String?
    ) async throws -> String {
        try await ensureAccess()

        let writableCalendars = eventStore.calendars(for: .event).filter { $0.allowsContentModifications }
        let requestedCalendar = requestedCalendarName.flatMap { requestedName in
            writableCalendars.first { $0.title.caseInsensitiveCompare(requestedName) == .orderedSame }
        }
        guard let targetCalendar = requestedCalendar ?? eventStore.defaultCalendarForNewEvents else {
            throw CalendarDataError.noWritableCalendar
        }

        let newEvent = EKEvent(eventStore: eventStore)
        newEvent.title = title
        newEvent.calendar = targetCalendar
        newEvent.isAllDay = isAllDay
        newEvent.startDate = startDate
        newEvent.endDate = endDate
        newEvent.location = location
        try eventStore.save(newEvent, span: .thisEvent, commit: true)
        return targetCalendar.title
    }

    /// Ensures the app can read events, requesting access on first use.
    private func ensureAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return
        case .notDetermined:
            let granted = (try? await eventStore.requestFullAccessToEvents()) ?? false
            if !granted {
                throw CalendarDataError.accessDenied
            }
        default:
            // .denied, .restricted, or the read-insufficient .writeOnly.
            throw CalendarDataError.accessDenied
        }
    }
}

private extension String {
    /// Nil when the string is empty, so an empty location becomes no location.
    var nonEmptyOrNil: String? { isEmpty ? nil : self }
}

private extension CGColor {
    /// A "#RRGGBB" string for this colour, or nil if it cannot be read in RGB.
    var hexString: String? {
        guard let components = components, components.count >= 3 else { return nil }
        let red = Int((components[0] * 255).rounded())
        let green = Int((components[1] * 255).rounded())
        let blue = Int((components[2] * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
