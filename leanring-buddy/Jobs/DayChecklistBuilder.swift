//
//  DayChecklistBuilder.swift
//  leanring-buddy
//
//  Pure decision logic for Job 2 (daily checklist) and for the two EventKit
//  writers. No EventKit, no UI, no clocks: every date comes in as an argument
//  so Tests/DayChecklist can pin them.
//
//  Two enums live here:
//   - `DayChecklistBuilder` turns Canvas items, today's calendar events,
//     approved study blocks and yesterday's checklist into today's list.
//   - `JobsEventKitPlanning` decides what the EventKit actors should write
//     (create / update / delete) so the actors stay thin and idempotency is
//     testable without a calendar.
//

import Foundation

// MARK: - Checklist builder

nonisolated enum DayChecklistBuilder {

    /// Default cap for the notch list; callers pass it explicitly.
    static let defaultMaximumItems = 12

    /// After this many carries an item is shown as "overdue Nd" instead of a gentle carry-over.
    static let rolloverCountThatMarksOverdue = 3

    /// "yyyy-MM-dd" in the calendar's own time zone. Built from date components
    /// (not a DateFormatter) so it cannot drift with the device locale or calendar system.
    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// Pure. `previousChecklist` is yesterday's list with Reminders completion already
    /// merged in (see `applyingCompletion`). Pass yesterday's list only when building
    /// for a new day; passing today's own list would roll its items a second time.
    static func build(day: Date,
                      canvasItems: [CanvasItem],
                      calendarEvents: [ChecklistCalendarEvent],
                      approvedStudyBlocks: [StudyBlockProposal],
                      previousChecklist: [ChecklistItem],
                      completedRolledOverItemsToKeep: [ChecklistItem] = [],
                      canvasItemsAddedToToday: [CanvasItem] = [],
                      maximumItems: Int,
                      now: Date,
                      calendar: Calendar) -> [ChecklistItem] {
        guard maximumItems > 0 else { return [] }
        let startOfDay = calendar.startOfDay(for: day)
        guard let startOfNextDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return [] }
        let compactDayText = compactDayText(for: startOfDay, calendar: calendar)
        let isOnThisDay: (Date) -> Bool = { $0 >= startOfDay && $0 < startOfNextDay }

        let previousItemsByID = Dictionary(previousChecklist.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // 1. Rolled-over items: unfinished work from before today. Calendar events and
        // study blocks are tied to a time slot that has passed, so they are not carried.
        let canvasItemsBySourceKey = Dictionary(canvasItems.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        var rolledOverItems: [ChecklistItem] = []
        var rolledOverSourceKeys = Set<String>()
        for previousItem in previousChecklist {
            guard !previousItem.isCompleted else { continue }
            guard previousItem.origin == .canvasDue || previousItem.origin == .rolledOver else { continue }
            if let previousDueDate = previousItem.dueDate, previousDueDate >= startOfDay { continue }
            let previousSourceKey = sourceKey(fromItemID: previousItem.id)
            guard rolledOverSourceKeys.insert(previousSourceKey).inserted else { continue }

            let newRolloverCount = previousItem.rolloverCount + 1
            let courseCode = canvasItemsBySourceKey[previousSourceKey]?.courseCode
                ?? leadingCourseText(fromSubtitle: previousItem.subtitle)
            rolledOverItems.append(ChecklistItem(
                // Keeping the previous id keeps the Reminders map entry, so the reminder
                // is updated in place instead of being deleted and re-added.
                id: previousItem.id,
                title: previousItem.title,
                subtitle: rolledOverSubtitle(courseCode: courseCode,
                                             dueDate: previousItem.dueDate,
                                             rolloverCount: newRolloverCount,
                                             startOfDay: startOfDay,
                                             calendar: calendar),
                dueDate: previousItem.dueDate,
                origin: .rolledOver,
                rolloverCount: newRolloverCount,
                isCompleted: false,
                completionDate: nil
            ))
        }

        // 1b. Rolled-over items the user already ticked earlier today. A same-day rebuild
        // keeps them as they are (still ticked, rollover count untouched) and claims their
        // source key so the Canvas pass below does not list the assignment a second time.
        var keptCompletedRolledOverItems: [ChecklistItem] = []
        for completedItem in completedRolledOverItemsToKeep where completedItem.isCompleted {
            guard rolledOverSourceKeys.insert(sourceKey(fromItemID: completedItem.id)).inserted else { continue }
            keptCompletedRolledOverItems.append(completedItem)
        }
        rolledOverItems.append(contentsOf: keptCompletedRolledOverItems)

        // 2. Canvas items due today. An item already rolled over wins, so one assignment
        // never shows twice (the stable source key is what merges them).
        var canvasDueItems: [ChecklistItem] = []
        var canvasTitlesDueToday = Set<String>()
        for canvasItem in canvasItems.sorted(by: { ($0.startDate, $0.uid) < ($1.startDate, $1.uid) }) {
            guard isOnThisDay(canvasItem.startDate) else { continue }
            canvasTitlesDueToday.insert(normalizedTitle(canvasItem.title))
            guard canvasItem.kind != .calendarEvent else { continue } // an event, not a task: the calendar events cover it
            guard !rolledOverSourceKeys.contains(canvasItem.uid) else { continue }
            let itemID = "canvasDue:\(canvasItem.uid):\(compactDayText)"
            guard !canvasDueItems.contains(where: { $0.id == itemID }) else { continue }
            let carriedCompletion = previousItemsByID[itemID].flatMap { $0.isCompleted ? $0 : nil }
            canvasDueItems.append(ChecklistItem(
                id: itemID,
                title: canvasItem.title,
                subtitle: joinedSubtitle([canvasItem.courseCode,
                                          canvasItem.isAllDay ? "due today" : "due \(timeText(canvasItem.startDate, calendar: calendar))"]),
                dueDate: canvasItem.startDate,
                origin: .canvasDue,
                rolloverCount: 0,
                isCompleted: carriedCompletion != nil,
                completionDate: carriedCompletion?.completionDate
            ))
        }

        // 2b. Canvas items the user added to today themselves ("add to today" on the
        // assignment page), whatever day they are due. Same id shape as a due-today item,
        // so one that is also due today is listed once.
        for addedItem in canvasItemsAddedToToday.sorted(by: { ($0.startDate, $0.uid) < ($1.startDate, $1.uid) }) {
            guard !rolledOverSourceKeys.contains(addedItem.uid) else { continue }
            let itemID = "canvasDue:\(addedItem.uid):\(compactDayText)"
            guard !canvasDueItems.contains(where: { $0.id == itemID }) else { continue }
            let carriedCompletion = previousItemsByID[itemID].flatMap { $0.isCompleted ? $0 : nil }
            let dueText: String
            if isOnThisDay(addedItem.startDate) {
                dueText = addedItem.isAllDay ? "due today" : "due \(timeText(addedItem.startDate, calendar: calendar))"
            } else {
                dueText = "due \(dayText(addedItem.startDate, calendar: calendar))"
            }
            canvasDueItems.append(ChecklistItem(
                id: itemID,
                title: addedItem.title,
                subtitle: joinedSubtitle([addedItem.courseCode, dueText]),
                dueDate: addedItem.startDate,
                origin: .canvasDue,
                rolloverCount: 0,
                isCompleted: carriedCompletion != nil,
                completionDate: carriedCompletion?.completionDate
            ))
        }

        // 3. Approved study blocks that start today.
        var studyBlockItems: [ChecklistItem] = []
        var studyTitlesToday = Set<String>()
        for studyBlock in approvedStudyBlocks.sorted(by: { ($0.start, $0.id) < ($1.start, $1.id) }) {
            guard isOnThisDay(studyBlock.start) else { continue }
            let itemID = "studyBlock:\(studyBlock.id):\(compactDayText)"
            guard !studyBlockItems.contains(where: { $0.id == itemID }) else { continue }
            studyTitlesToday.insert(normalizedTitle(studyBlock.title))
            let carriedCompletion = previousItemsByID[itemID].flatMap { $0.isCompleted ? $0 : nil }
            studyBlockItems.append(ChecklistItem(
                id: itemID,
                title: studyBlock.title,
                subtitle: joinedSubtitle([studyBlock.courseCode,
                                          timeRangeText(start: studyBlock.start, end: studyBlock.end, calendar: calendar)]),
                dueDate: studyBlock.start,
                origin: .studyBlock,
                rolloverCount: 0,
                isCompleted: carriedCompletion != nil,
                completionDate: carriedCompletion?.completionDate
            ))
        }

        // 4. Today's calendar events, minus copies of things already listed. Canvas
        // assignments are mirrored into the "Wisp" calendar and study blocks are written
        // there on approval, so the same item can arrive both ways.
        let allCanvasTitles = Set(canvasItems.map { normalizedTitle($0.title) })
        var calendarEventItems: [ChecklistItem] = []
        for calendarEvent in calendarEvents.sorted(by: { ($0.start, $0.id) < ($1.start, $1.id) }) {
            let eventTitle = normalizedTitle(calendarEvent.title)
            if canvasTitlesDueToday.contains(eventTitle) || studyTitlesToday.contains(eventTitle) { continue }
            if calendarEvent.isAllDay && allCanvasTitles.contains(eventTitle) { continue }
            let itemID = "calendarEvent:\(calendarEvent.id):\(compactDayText)"
            guard !calendarEventItems.contains(where: { $0.id == itemID }) else { continue }
            let carriedCompletion = previousItemsByID[itemID].flatMap { $0.isCompleted ? $0 : nil }
            calendarEventItems.append(ChecklistItem(
                id: itemID,
                title: calendarEvent.title,
                subtitle: calendarEvent.isAllDay
                    ? "All day"
                    : timeRangeText(start: calendarEvent.start, end: calendarEvent.end, calendar: calendar),
                dueDate: calendarEvent.start,
                origin: .calendarEvent,
                rolloverCount: 0,
                isCompleted: carriedCompletion != nil,
                completionDate: carriedCompletion?.completionDate
            ))
        }

        // 5. Cap. Rollovers survive first, then Canvas work, then study blocks, then
        // plain calendar events; within a tier the soonest due wins.
        let everyCandidate = rolledOverItems + canvasDueItems + studyBlockItems + calendarEventItems
        let keptItems = everyCandidate
            .sorted { lhs, rhs in
                (capPriority(lhs.origin), lhs.dueDate ?? .distantFuture, lhs.id)
                    < (capPriority(rhs.origin), rhs.dueDate ?? .distantFuture, rhs.id)
            }
            .prefix(maximumItems)

        // 6. Display order: rollovers first (oldest due first), then everything by time.
        return keptItems.sorted { lhs, rhs in
            let lhsIsRolledOver = lhs.origin == .rolledOver
            let rhsIsRolledOver = rhs.origin == .rolledOver
            if lhsIsRolledOver != rhsIsRolledOver { return lhsIsRolledOver }
            return (lhs.dueDate ?? .distantFuture, capPriority(lhs.origin), lhs.id)
                < (rhs.dueDate ?? .distantFuture, capPriority(rhs.origin), rhs.id)
        }
    }

    /// Merges what Reminders reports back into a list. Reminders is the source of
    /// truth, so a reopened reminder reopens the item too. Ids Reminders did not
    /// report are left as they are.
    static func applyingCompletion(_ completionByItemID: [String: (isCompleted: Bool, completionDate: Date?)],
                                   to checklistItems: [ChecklistItem]) -> [ChecklistItem] {
        checklistItems.map { checklistItem in
            guard let readBack = completionByItemID[checklistItem.id] else { return checklistItem }
            var updatedItem = checklistItem
            updatedItem.isCompleted = readBack.isCompleted
            updatedItem.completionDate = readBack.isCompleted ? readBack.completionDate : nil
            return updatedItem
        }
    }

    /// "<origin>:<sourceUID>:<yyyyMMdd>" -> "<sourceUID>". The UID may itself contain
    /// colons, so only the first and last components are dropped.
    static func sourceKey(fromItemID itemID: String) -> String {
        let components = itemID.components(separatedBy: ":")
        guard components.count >= 3 else { return itemID }
        return components.dropFirst().dropLast().joined(separator: ":")
    }

    // MARK: Private helpers

    private static func capPriority(_ origin: ChecklistItem.Origin) -> Int {
        switch origin {
        case .rolledOver: return 0
        case .canvasDue: return 1
        case .studyBlock: return 2
        case .calendarEvent: return 3
        }
    }

    private static func compactDayText(for date: Date, calendar: Calendar) -> String {
        dayKey(for: date, calendar: calendar).replacingOccurrences(of: "-", with: "")
    }

    /// Lowercased, whitespace-collapsed, without a trailing "[COURSE]" so the Canvas
    /// title and its calendar copy compare equal.
    private static func normalizedTitle(_ title: String) -> String {
        var workingTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if workingTitle.hasSuffix("]"), let openingBracketRange = workingTitle.range(of: "[", options: .backwards) {
            workingTitle = String(workingTitle[..<openingBracketRange.lowerBound])
        }
        return workingTitle
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func joinedSubtitle(_ parts: [String?]) -> String? {
        let presentParts = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return presentParts.isEmpty ? nil : presentParts.joined(separator: " · ")
    }

    /// The course text we wrote in front of " · " last time, if any. A subtitle
    /// that starts with a due/overdue phrase has no course in it.
    private static func leadingCourseText(fromSubtitle subtitle: String?) -> String? {
        guard let subtitle, let separatorRange = subtitle.range(of: " · ") else { return nil }
        let leadingText = String(subtitle[..<separatorRange.lowerBound])
        let isDuePhrase = leadingText.hasPrefix("due ") || leadingText.hasPrefix("overdue ") || leadingText == "carried over"
        return isDuePhrase ? nil : leadingText
    }

    private static func rolledOverSubtitle(courseCode: String?,
                                           dueDate: Date?,
                                           rolloverCount: Int,
                                           startOfDay: Date,
                                           calendar: Calendar) -> String? {
        var statusText = "carried over"
        if rolloverCount >= rolloverCountThatMarksOverdue, let dueDate {
            let dueDayStart = calendar.startOfDay(for: dueDate)
            let daysOverdue = max(1, calendar.dateComponents([.day], from: dueDayStart, to: startOfDay).day ?? 1)
            statusText = "overdue \(daysOverdue)d"
        }
        return joinedSubtitle([courseCode, statusText])
    }

    private static func timeText(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    /// "Oct 25", for an item added to today that is due another day.
    private static func dayText(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    private static func timeRangeText(start: Date, end: Date, calendar: Calendar) -> String {
        "\(timeText(start, calendar: calendar)) – \(timeText(end, calendar: calendar))"
    }
}

// MARK: - EventKit write planning

/// What the "Wisp" calendar map remembers about one Canvas item: where its event
/// lives and which content version was last written, so a repeat sync writes nothing.
nonisolated struct WispEventMapEntry: Codable, Equatable, Sendable {
    let eventIdentifier: String
    let contentFingerprint: String
}

nonisolated enum CalendarWriteOperation: Equatable, Sendable {
    case create(item: CanvasItem)
    case update(eventIdentifier: String, item: CanvasItem)
    case delete(eventIdentifier: String, uid: String)
}

nonisolated struct CalendarWritePlan: Equatable, Sendable {
    let operations: [CalendarWriteOperation]
    /// Map entries that are valid after this plan without a new identifier (kept,
    /// repaired from notes, or updated in place). Creates add their entry once saved.
    let retainedMapEntries: [String: WispEventMapEntry]
    /// UIDs whose entries must be dropped (their event was deleted).
    let uidsToUnmap: [String]
}

nonisolated struct ExistingReminderSnapshot: Equatable, Sendable {
    let identifier: String
    let title: String
    let dueDate: Date?
    /// The item id stamped into the reminder's notes, if it is one of ours.
    let stampedItemID: String?
    /// The reminder's notes, when known. Nil means "not reported": the notes are then
    /// not compared, so a snapshot built without them never causes an update.
    var notes: String? = nil
}

nonisolated enum ReminderWriteOperation: Equatable, Sendable {
    case add(item: ChecklistItem)
    case update(reminderIdentifier: String, item: ChecklistItem)
    case remove(reminderIdentifier: String)
}

nonisolated struct ReminderRebuildPlan: Equatable, Sendable {
    let operations: [ReminderWriteOperation]
    /// Item id -> reminder identifier for every item that already has a reminder.
    /// Adds get their identifier once saved.
    let retainedItemIDToReminderIdentifier: [String: String]
}

nonisolated enum JobsEventKitPlanning {

    static let calendarUIDStampPrefix = "wisp-canvas-uid:"
    static let calendarFingerprintStampPrefix = "wisp-canvas-fp:"
    static let reminderItemStampPrefix = "wisp-item:"

    // MARK: Calendar

    /// Event notes: the Canvas description, then a stamp so the UID -> event map can be
    /// rebuilt from the calendar itself if the map file is lost.
    static func eventNotes(for item: CanvasItem) -> String {
        let stampLines = "\(calendarUIDStampPrefix) \(item.uid)\n\(calendarFingerprintStampPrefix) \(item.contentFingerprint)"
        guard let descriptionText = item.descriptionText, !descriptionText.isEmpty else { return stampLines }
        return "\(descriptionText)\n\n\(stampLines)"
    }

    /// Reads the stamp back out of event notes. Nil when the event is not one of ours.
    static func stamp(fromEventNotes notes: String?) -> (uid: String, contentFingerprint: String?)? {
        guard let notes else { return nil }
        var foundUID: String?
        var foundFingerprint: String?
        for line in notes.components(separatedBy: .newlines) {
            if line.hasPrefix(calendarUIDStampPrefix) {
                foundUID = String(line.dropFirst(calendarUIDStampPrefix.count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix(calendarFingerprintStampPrefix) {
                foundFingerprint = String(line.dropFirst(calendarFingerprintStampPrefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let foundUID, !foundUID.isEmpty else { return nil }
        return (foundUID, foundFingerprint)
    }

    /// Decides the writes for a diff. `eventMap` is the persisted map; `stampedEvents`
    /// is what a scan of the "Wisp" calendar found (the repair path), keyed by UID.
    /// A map entry whose event no longer exists in the calendar is ignored, so a user
    /// deleting an event by hand makes the next sync recreate it.
    static func calendarWritePlan(for diff: CanvasDiff,
                                  eventMap: [String: WispEventMapEntry],
                                  stampedEvents: [String: WispEventMapEntry],
                                  existingEventIdentifiers: Set<String>) -> CalendarWritePlan {
        func resolvedEntry(forUID uid: String) -> WispEventMapEntry? {
            if let mappedEntry = eventMap[uid], existingEventIdentifiers.contains(mappedEntry.eventIdentifier) {
                return mappedEntry
            }
            return stampedEvents[uid]
        }

        var operations: [CalendarWriteOperation] = []
        var retainedMapEntries: [String: WispEventMapEntry] = [:]
        var uidsToUnmap: [String] = []

        let itemsToUpsert = (diff.added + diff.changed.map { $0.after }).sorted { $0.uid < $1.uid }
        for item in itemsToUpsert {
            guard let existingEntry = resolvedEntry(forUID: item.uid) else {
                operations.append(.create(item: item))
                continue
            }
            if existingEntry.contentFingerprint == item.contentFingerprint {
                retainedMapEntries[item.uid] = existingEntry
            } else {
                operations.append(.update(eventIdentifier: existingEntry.eventIdentifier, item: item))
                retainedMapEntries[item.uid] = WispEventMapEntry(eventIdentifier: existingEntry.eventIdentifier,
                                                                 contentFingerprint: item.contentFingerprint)
            }
        }

        for removedItem in diff.removed.sorted(by: { $0.uid < $1.uid }) {
            uidsToUnmap.append(removedItem.uid)
            if let existingEntry = resolvedEntry(forUID: removedItem.uid) {
                operations.append(.delete(eventIdentifier: existingEntry.eventIdentifier, uid: removedItem.uid))
            }
        }

        return CalendarWritePlan(operations: operations,
                                 retainedMapEntries: retainedMapEntries,
                                 uidsToUnmap: uidsToUnmap)
    }

    // MARK: Reminders

    static func reminderNotes(forItemID itemID: String) -> String {
        "\(reminderItemStampPrefix) \(itemID)"
    }

    /// The full notes text of an item's reminder: the subtitle (carried over, overdue Nd)
    /// above the id stamp. One place builds it so the writer and the update check agree.
    static func reminderNotes(for item: ChecklistItem) -> String {
        [item.subtitle, reminderNotes(forItemID: item.id)]
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    static func itemID(fromReminderNotes notes: String?) -> String? {
        guard let notes else { return nil }
        for line in notes.components(separatedBy: .newlines) where line.hasPrefix(reminderItemStampPrefix) {
            let stampedID = String(line.dropFirst(reminderItemStampPrefix.count)).trimmingCharacters(in: .whitespaces)
            return stampedID.isEmpty ? nil : stampedID
        }
        return nil
    }

    /// Decides the writes that turn the "Wisp Today" list into `items`. Reminders the
    /// user added by hand (no map entry, no stamp) are never touched. A kept reminder's
    /// completion is left alone: Reminders is the source of truth for ticks.
    static func reminderRebuildPlan(items: [ChecklistItem],
                                    itemIDToReminderIdentifier: [String: String],
                                    existingReminders: [ExistingReminderSnapshot]) -> ReminderRebuildPlan {
        let existingByIdentifier = Dictionary(existingReminders.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        var identifierByStampedItemID: [String: String] = [:]
        for existingReminder in existingReminders {
            if let stampedItemID = existingReminder.stampedItemID, identifierByStampedItemID[stampedItemID] == nil {
                identifierByStampedItemID[stampedItemID] = existingReminder.identifier
            }
        }
        let identifiersWeOwn = Set(itemIDToReminderIdentifier.values.filter { existingByIdentifier[$0] != nil })
            .union(existingReminders.filter { $0.stampedItemID != nil }.map { $0.identifier })

        var operations: [ReminderWriteOperation] = []
        var retainedMapping: [String: String] = [:]
        var claimedIdentifiers = Set<String>()

        for item in items {
            var resolvedIdentifier: String?
            if let mappedIdentifier = itemIDToReminderIdentifier[item.id], existingByIdentifier[mappedIdentifier] != nil {
                resolvedIdentifier = mappedIdentifier
            } else if let stampedIdentifier = identifierByStampedItemID[item.id] {
                resolvedIdentifier = stampedIdentifier
            }
            guard let resolvedIdentifier, !claimedIdentifiers.contains(resolvedIdentifier),
                  let existingReminder = existingByIdentifier[resolvedIdentifier] else {
                operations.append(.add(item: item))
                continue
            }
            claimedIdentifiers.insert(resolvedIdentifier)
            retainedMapping[item.id] = resolvedIdentifier
            // The notes carry the subtitle, which changes while title and due date do not
            // (a task rolling over another day), so they are compared too.
            let notesAreStale = existingReminder.notes.map { $0 != reminderNotes(for: item) } ?? false
            if existingReminder.title != item.title || !sameMinute(existingReminder.dueDate, item.dueDate) || notesAreStale {
                operations.append(.update(reminderIdentifier: resolvedIdentifier, item: item))
            }
        }

        for existingReminder in existingReminders where identifiersWeOwn.contains(existingReminder.identifier)
            && !claimedIdentifiers.contains(existingReminder.identifier) {
            operations.append(.remove(reminderIdentifier: existingReminder.identifier))
        }

        return ReminderRebuildPlan(operations: operations, retainedItemIDToReminderIdentifier: retainedMapping)
    }

    /// Reminders stores due dates as date components, which have no seconds.
    private static func sameMinute(_ first: Date?, _ second: Date?) -> Bool {
        switch (first, second) {
        case (nil, nil): return true
        case let (firstDate?, secondDate?):
            return Int(firstDate.timeIntervalSince1970 / 60) == Int(secondDate.timeIntervalSince1970 / 60)
        default: return false
        }
    }
}
