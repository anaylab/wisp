//
//  WispCalendarWriter.swift
//  leanring-buddy
//
//  Thin EventKit layer for Job 1. Writes ONLY to a dedicated calendar titled
//  "Wisp"; every other calendar is read-only here (busy time, today's events).
//  What to write is decided by the pure `JobsEventKitPlanning` so this actor
//  stays glue.
//
//  Permission is never requested implicitly: only `requestAccessIfNeeded()`
//  prompts, and the Jobs setup button is its only caller.
//

import EventKit
import Foundation

actor WispCalendarWriter {

    static let shared = WispCalendarWriter()
    static let calendarTitle = "Wisp"

    /// Assignments and quizzes are due at a moment. Starting the event this long
    /// before the due time makes it end at the deadline and never spill past midnight.
    private static let leadInMinutesForInstantItems = 30
    /// Fallback span for a timed non-instant item that has no end.
    private static let defaultTimedEventMinutes = 60
    /// EventKit predicates cover at most four years; this window is wide enough
    /// to find every event Wisp ever wrote.
    private static let repairScanYearsEachWay = 1

    private let eventStore = EKEventStore()
    private let eventMapFileURL = JobsPrivateJSONFile.fileURL(named: "jobs-event-map.json")

    // MARK: Authorization

    func authorizationState() -> JobsAccessState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied // write-only cannot read busy time, so it counts as denied
        }
    }

    /// Prompts the first time only. Throws `accessDenied` if the user (or policy) says no.
    func requestAccessIfNeeded() async throws {
        switch authorizationState() {
        case .granted: return
        case .denied: throw WispEventKitError.accessDenied
        case .notDetermined:
            let wasGranted = try await eventStore.requestFullAccessToEvents()
            if !wasGranted { throw WispEventKitError.accessDenied }
        }
    }

    // MARK: The "Wisp" calendar

    /// Finds the "Wisp" calendar or creates it. Never prompts.
    func ensureWispCalendarExists() async throws {
        _ = try wispCalendar(creatingIfMissing: true)
    }

    private func requireGrantedAccess() throws {
        guard authorizationState() == .granted else { throw WispEventKitError.accessDenied }
    }

    private func wispCalendar(creatingIfMissing: Bool) throws -> EKCalendar {
        try requireGrantedAccess()
        if let existingCalendar = eventStore.calendars(for: .event).first(where: {
            $0.title == Self.calendarTitle && $0.allowsContentModifications
        }) {
            return existingCalendar
        }
        guard creatingIfMissing else { throw WispEventKitError.calendarMissing }

        let newCalendar = EKCalendar(for: .event, eventStore: eventStore)
        newCalendar.title = Self.calendarTitle
        guard let writableSource = writableCalendarSource() else { throw WispEventKitError.noWritableSource }
        newCalendar.source = writableSource
        try eventStore.saveCalendar(newCalendar, commit: true)
        return newCalendar
    }

    /// Prefers the on-device source so Canvas titles and study blocks stay on this Mac.
    /// Only when there is none does it fall back to the account the user's default
    /// calendar lives in, which syncs the "Wisp" calendar to that provider (the
    /// calendar permission text says so).
    private func writableCalendarSource() -> EKSource? {
        if let localSource = eventStore.sources.first(where: { $0.sourceType == .local }) {
            return localSource
        }
        if let defaultCalendarSource = eventStore.defaultCalendarForNewEvents?.source,
           defaultCalendarSource.sourceType != .subscribed, defaultCalendarSource.sourceType != .birthdays {
            return defaultCalendarSource
        }
        return nil
    }

    // MARK: Canvas diff

    /// Idempotent: a second call with the same diff finds every item already current
    /// and writes nothing. Returns the number of EventKit writes actually made.
    func apply(diff: CanvasDiff) async throws -> (created: Int, updated: Int, deleted: Int) {
        let calendarForWrites = try wispCalendar(creatingIfMissing: true)
        let storedEventMap: [String: WispEventMapEntry] = JobsPrivateJSONFile.load([String: WispEventMapEntry].self,
                                                                                    from: eventMapFileURL) ?? [:]
        let stampedEvents = stampedEventsInWispCalendar(calendarForWrites)
        let existingEventIdentifiers = Set(stampedEvents.values.map { $0.eventIdentifier })
            .union(storedEventMap.values.map { $0.eventIdentifier }.filter { eventStore.event(withIdentifier: $0) != nil })

        let writePlan = JobsEventKitPlanning.calendarWritePlan(for: diff,
                                                              eventMap: storedEventMap,
                                                              stampedEvents: stampedEvents,
                                                              existingEventIdentifiers: existingEventIdentifiers)

        var newEventMap = storedEventMap
        // Entries not in this diff stay as they were. Retained ones are refreshed
        // (this is also the repair path when the map file was lost).
        for (uid, retainedEntry) in writePlan.retainedMapEntries { newEventMap[uid] = retainedEntry }
        for uidToUnmap in writePlan.uidsToUnmap { newEventMap[uidToUnmap] = nil }

        var createdCount = 0
        var updatedCount = 0
        var deletedCount = 0
        for operation in writePlan.operations {
            switch operation {
            case .create(let item):
                let newEvent = EKEvent(eventStore: eventStore)
                newEvent.calendar = calendarForWrites
                fill(newEvent, from: item)
                try eventStore.save(newEvent, span: .thisEvent, commit: false)
                // The identifier is only reliable after the commit below; record the
                // item now and patch the identifier in afterwards.
                createdCount += 1
                newEventMap[item.uid] = WispEventMapEntry(eventIdentifier: newEvent.eventIdentifier ?? "",
                                                          contentFingerprint: item.contentFingerprint)
            case .update(let eventIdentifier, let item):
                guard let existingEvent = eventStore.event(withIdentifier: eventIdentifier) else {
                    throw WispEventKitError.itemMissing
                }
                fill(existingEvent, from: item)
                try eventStore.save(existingEvent, span: .thisEvent, commit: false)
                updatedCount += 1
            case .delete(let eventIdentifier, _):
                if let existingEvent = eventStore.event(withIdentifier: eventIdentifier) {
                    try eventStore.remove(existingEvent, span: .thisEvent, commit: false)
                    deletedCount += 1
                }
            }
        }
        if !writePlan.operations.isEmpty { try eventStore.commit() }

        // Re-read identifiers for the new events: they can change when a store commits.
        if createdCount > 0 {
            let refreshedStamps = stampedEventsInWispCalendar(calendarForWrites)
            for (uid, refreshedEntry) in refreshedStamps where newEventMap[uid] != nil {
                newEventMap[uid] = refreshedEntry
            }
        }
        newEventMap = newEventMap.filter { !$0.value.eventIdentifier.isEmpty }
        try JobsPrivateJSONFile.save(newEventMap, to: eventMapFileURL)
        return (createdCount, updatedCount, deletedCount)
    }

    private func fill(_ event: EKEvent, from item: CanvasItem) {
        event.title = item.courseCode.map { "\(item.title) [\($0)]" } ?? item.title
        event.location = item.location
        event.notes = JobsEventKitPlanning.eventNotes(for: item)
        // Only https links from the feed are kept: the event syncs to other devices and
        // Calendar shows its URL as a tappable link.
        event.url = item.linkURLString
            .flatMap { URL(string: $0) }
            .flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil }
        event.isAllDay = item.isAllDay
        if item.isAllDay {
            event.startDate = item.startDate
            // The parsed end is the feed's exclusive DTEND, but EventKit treats an
            // all-day end as the last covered day, so step back one day.
            if let exclusiveEndDate = item.endDate,
               let lastCoveredDay = Calendar.current.date(byAdding: .day, value: -1, to: exclusiveEndDate) {
                event.endDate = max(lastCoveredDay, item.startDate)
            } else {
                event.endDate = item.startDate
            }
        } else if let explicitEndDate = item.endDate {
            event.startDate = item.startDate
            event.endDate = explicitEndDate
        } else if item.kind == .assignment || item.kind == .quiz {
            event.startDate = item.startDate.addingTimeInterval(-Double(Self.leadInMinutesForInstantItems) * 60)
            event.endDate = item.startDate
        } else {
            event.startDate = item.startDate
            event.endDate = item.startDate.addingTimeInterval(Double(Self.defaultTimedEventMinutes) * 60)
        }
    }

    /// Every event in "Wisp" that carries our UID stamp, keyed by UID.
    private func stampedEventsInWispCalendar(_ wispCalendar: EKCalendar) -> [String: WispEventMapEntry] {
        let now = Date()
        guard let scanStart = Calendar.current.date(byAdding: .year, value: -Self.repairScanYearsEachWay, to: now),
              let scanEnd = Calendar.current.date(byAdding: .year, value: Self.repairScanYearsEachWay, to: now) else { return [:] }
        let predicate = eventStore.predicateForEvents(withStart: scanStart, end: scanEnd, calendars: [wispCalendar])
        var stampedEvents: [String: WispEventMapEntry] = [:]
        for event in eventStore.events(matching: predicate) {
            guard let stamp = JobsEventKitPlanning.stamp(fromEventNotes: event.notes),
                  let eventIdentifier = event.eventIdentifier else { continue }
            stampedEvents[stamp.uid] = WispEventMapEntry(eventIdentifier: eventIdentifier,
                                                         contentFingerprint: stamp.contentFingerprint ?? "")
        }
        return stampedEvents
    }

    // MARK: Study blocks

    /// Writes approved study blocks to "Wisp" only. Skips blocks already written
    /// (same proposal id), so approving twice is harmless. Returns blocks written.
    func writeStudyBlocks(_ proposals: [StudyBlockProposal]) async throws -> Int {
        let calendarForWrites = try wispCalendar(creatingIfMissing: true)
        let alreadyWrittenIDs = Set(studyBlockStamps(in: calendarForWrites))
        var writtenCount = 0
        for proposal in proposals where !alreadyWrittenIDs.contains(proposal.id) {
            let studyEvent = EKEvent(eventStore: eventStore)
            studyEvent.calendar = calendarForWrites
            studyEvent.title = proposal.title
            studyEvent.startDate = proposal.start
            studyEvent.endDate = proposal.end
            studyEvent.notes = "\(Self.studyBlockStampPrefix) \(proposal.id)"
            try eventStore.save(studyEvent, span: .thisEvent, commit: false)
            writtenCount += 1
        }
        if writtenCount > 0 { try eventStore.commit() }
        return writtenCount
    }

    private static let studyBlockStampPrefix = "wisp-study-block:"

    private func studyBlockStamps(in wispCalendar: EKCalendar) -> [String] {
        let now = Date()
        guard let scanStart = Calendar.current.date(byAdding: .year, value: -Self.repairScanYearsEachWay, to: now),
              let scanEnd = Calendar.current.date(byAdding: .year, value: Self.repairScanYearsEachWay, to: now) else { return [] }
        let predicate = eventStore.predicateForEvents(withStart: scanStart, end: scanEnd, calendars: [wispCalendar])
        return eventStore.events(matching: predicate).compactMap { event -> String? in
            guard let notes = event.notes else { return nil }
            for line in notes.components(separatedBy: .newlines) where line.hasPrefix(Self.studyBlockStampPrefix) {
                return String(line.dropFirst(Self.studyBlockStampPrefix.count)).trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
    }

    // MARK: Reads (every calendar except Wisp's own)

    /// Busy time for study-block planning. Excludes the "Wisp" calendar so mirrored
    /// assignments and earlier study blocks do not block their own gaps.
    func busyIntervals(from: Date, to: Date) async throws -> [BusyInterval] {
        try requireGrantedAccess()
        let otherCalendars = eventStore.calendars(for: .event).filter { $0.title != Self.calendarTitle }
        guard !otherCalendars.isEmpty else { return [] }
        let predicate = eventStore.predicateForEvents(withStart: from, end: to, calendars: otherCalendars)
        return eventStore.events(matching: predicate)
            .filter { !$0.isAllDay && $0.availability != .free }
            .map { BusyInterval(start: $0.startDate, end: $0.endDate) }
            .sorted { $0.start < $1.start }
    }

    /// Today's events for the checklist, excluding "Wisp" (Canvas items and study
    /// blocks reach the checklist through their own paths).
    func calendarEvents(onDay day: Date, calendar: Calendar) async throws -> [ChecklistCalendarEvent] {
        try requireGrantedAccess()
        let startOfDay = calendar.startOfDay(for: day)
        guard let startOfNextDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return [] }
        let otherCalendars = eventStore.calendars(for: .event).filter { $0.title != Self.calendarTitle }
        guard !otherCalendars.isEmpty else { return [] }
        let predicate = eventStore.predicateForEvents(withStart: startOfDay, end: startOfNextDay, calendars: otherCalendars)
        return eventStore.events(matching: predicate)
            .compactMap { event -> ChecklistCalendarEvent? in
                guard let title = event.title, !title.isEmpty else { return nil }
                let eventKey = event.calendarItemIdentifier + ":" + String(Int(event.startDate.timeIntervalSince1970))
                return ChecklistCalendarEvent(id: eventKey, title: title, start: event.startDate,
                                              end: event.endDate, isAllDay: event.isAllDay)
            }
            .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }
}
