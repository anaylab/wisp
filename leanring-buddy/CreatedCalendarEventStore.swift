//
//  CreatedCalendarEventStore.swift
//  leanring-buddy
//
//  Every event Wisp creates this session, whether from the calendar fast path
//  or the agent's `create_calendar_event` tool, so the notch can show a
//  Siri-style "Event Added" result card with Undo and Open in Calendar.
//
//  Like `WispTimerStore`, the card holds only an id and reads the live state
//  here, so Undo's progress survives the card being re-rendered.
//
//  Undo is deliberately narrow: it can only remove an event recorded here,
//  which is to say one Wisp itself made since launch. The record is in memory
//  only; after a relaunch, older events are the user's to manage in Calendar.
//

import AppKit
import Combine
import Foundation

struct CreatedCalendarEvent: Identifiable, Equatable {
    enum UndoStatus: Equatable {
        case added
        case removing
        case removed
        case removeFailed(reason: String)
    }

    /// EventKit's event identifier.
    let id: String
    let draft: CalendarEventDraft
    let calendarName: String
    let calendarColorHex: String?
    let createdAt: Date
    var undoStatus: UndoStatus
}

@MainActor
final class CreatedCalendarEventStore: ObservableObject {
    static let shared = CreatedCalendarEventStore()

    @Published private(set) var createdEventsByID: [String: CreatedCalendarEvent] = [:]

    /// Called once an Undo has removed an event, with what it was, so the
    /// reply line above the card can stop saying "Added …".
    var onUndoCompleted: ((CreatedCalendarEvent) -> Void)?

    func record(
        createdEventDetails: CalendarDataProvider.CreatedEventDetails,
        draft: CalendarEventDraft,
        createdAt: Date = Date()
    ) {
        // EventKit leaves the identifier empty only if the save didn't stick;
        // such an event can't be shown or undone.
        guard !createdEventDetails.eventIdentifier.isEmpty else { return }
        createdEventsByID[createdEventDetails.eventIdentifier] = CreatedCalendarEvent(
            id: createdEventDetails.eventIdentifier,
            draft: draft,
            calendarName: createdEventDetails.calendarName,
            calendarColorHex: createdEventDetails.calendarColorHex,
            createdAt: createdAt,
            undoStatus: .added
        )
    }

    func event(withID eventID: String) -> CreatedCalendarEvent? {
        createdEventsByID[eventID]
    }

    /// The newest event created at or after `date`, for showing the result
    /// card after an agent turn whose tool call made one.
    func mostRecentEvent(createdSince date: Date) -> CreatedCalendarEvent? {
        createdEventsByID.values
            .filter { $0.createdAt >= date }
            .max { $0.createdAt < $1.createdAt }
    }

    /// Removes the event again. Only events recorded here can be undone.
    func undo(eventID: String) {
        guard var createdEvent = createdEventsByID[eventID], createdEvent.undoStatus == .added else { return }
        createdEvent.undoStatus = .removing
        createdEventsByID[eventID] = createdEvent

        Task { [weak self] in
            let finalStatus: CreatedCalendarEvent.UndoStatus
            do {
                // False means it was already deleted in Calendar, which counts
                // as undone too: either way the event is gone.
                _ = try await CalendarDataProvider.shared.removeEvent(withIdentifier: eventID)
                finalStatus = .removed
            } catch CalendarDataProvider.CalendarDataError.accessDenied {
                finalStatus = .removeFailed(reason: "Calendar access was turned off.")
            } catch {
                finalStatus = .removeFailed(reason: "Couldn't remove it — try in Calendar.")
            }
            guard let self, var updatedEvent = self.createdEventsByID[eventID] else { return }
            updatedEvent.undoStatus = finalStatus
            self.createdEventsByID[eventID] = updatedEvent
            if finalStatus == .removed { self.onUndoCompleted?(updatedEvent) }
        }
    }

    /// Opens Calendar on the event. Calendar's `ical://ekevent/` URL shows a
    /// specific event; if it won't open, Calendar itself opens instead.
    func openInCalendar(eventID: String) {
        let allowedCharacters = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        if let encodedEventID = eventID.addingPercentEncoding(withAllowedCharacters: allowedCharacters),
           let eventURL = URL(string: "ical://ekevent/\(encodedEventID)?method=show&options=more"),
           NSWorkspace.shared.open(eventURL) {
            return
        }
        if let calendarApplicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: calendarApplicationURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
