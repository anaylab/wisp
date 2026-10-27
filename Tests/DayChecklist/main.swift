//
//  Daily checklist suite: DayChecklistBuilder and the pure EventKit write planning.
//

import Foundation

var failureCount = 0
var checkCount = 0

func check(_ condition: Bool, _ description: String) {
    checkCount += 1
    if !condition {
        failureCount += 1
        print("FAIL: \(description)")
    }
}

var utcCalendar = Calendar(identifier: .gregorian)
utcCalendar.timeZone = TimeZone(identifier: "UTC")!
var newYorkCalendar = Calendar(identifier: .gregorian)
newYorkCalendar.timeZone = TimeZone(identifier: "America/New_York")!

func makeDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0,
              calendar: Calendar = utcCalendar) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

let today = makeDate(2026, 10, 21)
let now = makeDate(2026, 10, 21, 7, 30)

func canvasItem(_ uid: String, _ title: String, due: Date, course: String? = "ENGL101",
                kind: CanvasItem.Kind = .assignment, allDay: Bool = false) -> CanvasItem {
    CanvasItem(uid: uid, title: title, courseCode: course, kind: kind, startDate: due, endDate: nil,
               isAllDay: allDay, location: nil, descriptionText: nil, linkURLString: nil,
               contentFingerprint: "fp-\(uid)-\(Int(due.timeIntervalSince1970))")
}

func build(canvas: [CanvasItem] = [], events: [ChecklistCalendarEvent] = [], study: [StudyBlockProposal] = [],
           previous: [ChecklistItem] = [], max: Int = 12, day: Date = today) -> [ChecklistItem] {
    DayChecklistBuilder.build(day: day, canvasItems: canvas, calendarEvents: events, approvedStudyBlocks: study,
                              previousChecklist: previous, maximumItems: max, now: now, calendar: utcCalendar)
}

// 1. Canvas item due today becomes a canvasDue row; later days are excluded.
do {
    let essay = canvasItem("event-assignment-1", "Essay 2", due: makeDate(2026, 10, 21, 23, 59))
    let tomorrow = canvasItem("event-assignment-2", "Lab", due: makeDate(2026, 10, 22, 12, 0))
    let result = build(canvas: [essay, tomorrow])
    check(result.count == 1, "only today's Canvas item is listed")
    check(result.first?.origin == .canvasDue, "origin is canvasDue")
    check(result.first?.id == "canvasDue:event-assignment-1:20261021", "canvas id is stable and day-stamped")
    check(result.first?.subtitle == "ENGL101 · due 11:59 PM", "subtitle has course and due time, got \(result.first?.subtitle ?? "nil")")
    let allDay = canvasItem("event-assignment-3", "Reading", due: today, allDay: true)
    check(build(canvas: [allDay]).first?.subtitle == "ENGL101 · due today", "all-day item reads 'due today'")
}

// 2. Calendar events ordered by time; Canvas duplicates by title excluded.
do {
    let late = ChecklistCalendarEvent(id: "e2", title: "Club", start: makeDate(2026, 10, 21, 18), end: makeDate(2026, 10, 21, 19), isAllDay: false)
    let early = ChecklistCalendarEvent(id: "e1", title: "Lecture", start: makeDate(2026, 10, 21, 9), end: makeDate(2026, 10, 21, 10), isAllDay: false)
    let duplicateOfCanvas = ChecklistCalendarEvent(id: "e3", title: "Essay 2 [ENGL101]", start: makeDate(2026, 10, 21, 23, 30), end: makeDate(2026, 10, 21, 23, 59), isAllDay: false)
    let allDayDuplicate = ChecklistCalendarEvent(id: "e4", title: "Quiz 1", start: today, end: makeDate(2026, 10, 22), isAllDay: true)
    let essay = canvasItem("event-assignment-1", "Essay 2", due: makeDate(2026, 10, 21, 23, 59))
    let quizElsewhere = canvasItem("event-quiz-9", "Quiz 1", due: makeDate(2026, 10, 25, 9), kind: .quiz)
    let result = build(canvas: [essay, quizElsewhere], events: [late, early, duplicateOfCanvas, allDayDuplicate])
    let eventIDs = result.filter { $0.origin == .calendarEvent }.map { $0.id }
    check(eventIDs == ["calendarEvent:e1:20261021", "calendarEvent:e2:20261021"], "events ordered by time without duplicates, got \(eventIDs)")
    check(result.first?.title == "Lecture", "lecture (9am) sorts before club (6pm) and the 11:59 PM essay")
}

// 3. Rollover: unfinished first, count + 1; completed dropped.
let yesterdayUnfinished = ChecklistItem(id: "canvasDue:event-assignment-7:20261020", title: "Problem set", subtitle: "MATH200 · due 11:59 PM",
                                        dueDate: makeDate(2026, 10, 20, 23, 59), origin: .canvasDue, rolloverCount: 0,
                                        isCompleted: false, completionDate: nil)
let yesterdayDone = ChecklistItem(id: "canvasDue:event-assignment-8:20261020", title: "Quiz prep", subtitle: nil,
                                  dueDate: makeDate(2026, 10, 20, 20), origin: .canvasDue, rolloverCount: 0,
                                  isCompleted: true, completionDate: makeDate(2026, 10, 20, 19))
do {
    let todayItem = canvasItem("event-assignment-1", "Essay 2", due: makeDate(2026, 10, 21, 8))
    let result = build(canvas: [todayItem], previous: [yesterdayDone, yesterdayUnfinished])
    check(result.count == 2, "completed yesterday dropped, unfinished kept")
    check(result.first?.origin == .rolledOver, "rolled-over item comes first")
    check(result.first?.rolloverCount == 1, "rolloverCount incremented")
    check(result.first?.id == yesterdayUnfinished.id, "rolled item keeps its id so the reminder is reused")
    check(result.first?.dueDate == yesterdayUnfinished.dueDate, "rolled item keeps its original due date")
    check(result.first?.subtitle == "MATH200 · carried over", "carry subtitle, got \(result.first?.subtitle ?? "nil")")
}

// 4. Overdue at 3 rollovers; rolled item also in today's Canvas list is not duplicated.
do {
    var thirdRollover = yesterdayUnfinished
    thirdRollover = ChecklistItem(id: "canvasDue:event-assignment-7:20261018", title: "Problem set", subtitle: "carried over",
                                  dueDate: makeDate(2026, 10, 18, 23, 59), origin: .rolledOver, rolloverCount: 2,
                                  isCompleted: false, completionDate: nil)
    let sameAssignmentAgain = canvasItem("event-assignment-7", "Problem set", due: makeDate(2026, 10, 21, 23, 59), course: "MATH200")
    let result = build(canvas: [sameAssignmentAgain], previous: [thirdRollover])
    check(result.count == 1, "stable source key merges rolled item with today's Canvas copy")
    check(result.first?.rolloverCount == 3, "third carry counted")
    check(result.first?.subtitle == "MATH200 · overdue 3d", "overdue marker from the original due date, got \(result.first?.subtitle ?? "nil")")
}

// 5. Cap keeps rollovers and soonest due first, drops calendar events first.
do {
    let events = (0..<5).map { index in
        ChecklistCalendarEvent(id: "ev\(index)", title: "Event \(index)", start: makeDate(2026, 10, 21, 8 + index),
                               end: makeDate(2026, 10, 21, 9 + index), isAllDay: false)
    }
    let canvas = [canvasItem("a1", "Late work", due: makeDate(2026, 10, 21, 22)),
                  canvasItem("a2", "Early work", due: makeDate(2026, 10, 21, 12))]
    let result = build(canvas: canvas, events: events, previous: [yesterdayUnfinished], max: 4)
    check(result.count == 4, "cap respected")
    check(result.contains { $0.origin == .rolledOver }, "rollover survives the cap")
    check(result.filter { $0.origin == .canvasDue }.count == 2, "canvas work survives the cap")
    check(result.filter { $0.origin == .calendarEvent }.count == 1, "only the soonest event survives")
    check(result.last(where: { $0.origin == .calendarEvent })?.id == "calendarEvent:ev0:20261021", "the surviving event is the soonest")
    check(build(canvas: canvas, max: 0).isEmpty, "zero cap gives an empty list")
}

// 6. Approved study blocks for today appear; other days do not.
do {
    let blockToday = StudyBlockProposal(id: "study-a1-20261021-0", forItemUID: "a1", title: "Study: Essay 2", courseCode: "ENGL101",
                                        start: makeDate(2026, 10, 21, 16), end: makeDate(2026, 10, 21, 17, 30))
    let blockLater = StudyBlockProposal(id: "study-a1-20261022-0", forItemUID: "a1", title: "Study: Essay 2", courseCode: "ENGL101",
                                        start: makeDate(2026, 10, 22, 16), end: makeDate(2026, 10, 22, 17, 30))
    let mirroredEvent = ChecklistCalendarEvent(id: "m1", title: "Study: Essay 2", start: blockToday.start, end: blockToday.end, isAllDay: false)
    let result = build(events: [mirroredEvent], study: [blockToday, blockLater])
    check(result.count == 1 && result.first?.origin == .studyBlock, "only today's study block, mirrored event deduped")
    check(result.first?.subtitle == "ENGL101 · 4:00 PM – 5:30 PM", "study subtitle, got \(result.first?.subtitle ?? "nil")")
}

// 7. Stable ids across two builds; reordered input gives the same output.
do {
    let canvas = [canvasItem("a1", "One", due: makeDate(2026, 10, 21, 10)), canvasItem("a2", "Two", due: makeDate(2026, 10, 21, 12))]
    let first = build(canvas: canvas, previous: [yesterdayUnfinished])
    let second = build(canvas: canvas.reversed(), previous: [yesterdayUnfinished])
    check(first == second, "two builds from the same input are identical")
    check(Set(first.map { $0.id }).count == first.count, "ids are unique")
}

// 8. dayKey in the calendar's own zone, near midnight and across DST.
do {
    let lateNewYorkEvening = makeDate(2026, 10, 21, 23, 30, calendar: newYorkCalendar) // 03:30 UTC next day
    check(DayChecklistBuilder.dayKey(for: lateNewYorkEvening, calendar: newYorkCalendar) == "2026-10-21", "New York evening stays on its own day")
    check(DayChecklistBuilder.dayKey(for: lateNewYorkEvening, calendar: utcCalendar) == "2026-10-22", "same instant is the next day in UTC")
    let dstEndDay = makeDate(2026, 11, 1, 12, calendar: newYorkCalendar)
    check(DayChecklistBuilder.dayKey(for: dstEndDay, calendar: newYorkCalendar) == "2026-11-01", "DST change day key")
    let dstResult = DayChecklistBuilder.build(day: dstEndDay,
        canvasItems: [canvasItem("d1", "Due on DST day", due: makeDate(2026, 11, 1, 23, 0, calendar: newYorkCalendar))],
        calendarEvents: [], approvedStudyBlocks: [], previousChecklist: [], maximumItems: 12, now: dstEndDay, calendar: newYorkCalendar)
    check(dstResult.count == 1 && dstResult.first?.id == "canvasDue:d1:20261101", "25-hour DST day still contains its late item")
}

// 9. Empty input; Codable round trip; completion read-back merge.
do {
    check(build().isEmpty, "empty input gives an empty list")
    let item = ChecklistItem(id: "canvasDue:x:20261021", title: "X", subtitle: "s", dueDate: makeDate(2026, 10, 21, 9),
                             origin: .rolledOver, rolloverCount: 2, isCompleted: true, completionDate: makeDate(2026, 10, 21, 10))
    let decoded = try! JSONDecoder().decode([ChecklistItem].self, from: JSONEncoder().encode([item]))
    check(decoded == [item], "Codable round trip keeps completion and rollover")

    let open = ChecklistItem(id: "canvasDue:y:20261021", title: "Y", subtitle: nil, dueDate: nil, origin: .canvasDue,
                             rolloverCount: 0, isCompleted: false, completionDate: nil)
    let tickTime = makeDate(2026, 10, 21, 11)
    let merged = DayChecklistBuilder.applyingCompletion(["canvasDue:y:20261021": (true, tickTime), "canvasDue:x:20261021": (false, nil)], to: [open, item])
    check(merged[0].isCompleted && merged[0].completionDate == tickTime, "tick in Reminders completes the item")
    check(!merged[1].isCompleted && merged[1].completionDate == nil, "reopened reminder reopens the item")
    check(DayChecklistBuilder.applyingCompletion([:], to: [open]) == [open], "unreported ids are unchanged")
}

// Same-day rebuild keeps today's tick.
do {
    let done = ChecklistItem(id: "canvasDue:a1:20261021", title: "One", subtitle: nil, dueDate: makeDate(2026, 10, 21, 10),
                             origin: .canvasDue, rolloverCount: 0, isCompleted: true, completionDate: makeDate(2026, 10, 21, 9))
    let result = build(canvas: [canvasItem("a1", "One", due: makeDate(2026, 10, 21, 10))], previous: [done])
    check(result.count == 1 && result[0].isCompleted, "rebuild on the same day preserves a completed tick")
}

// sourceKey with colons in the UID.
check(DayChecklistBuilder.sourceKey(fromItemID: "canvasDue:uid:with:colons:20261021") == "uid:with:colons", "source key keeps inner colons")

// MARK: EventKit planning

func diff(added: [CanvasItem] = [], changed: [CanvasItemChange] = [], removed: [CanvasItem] = []) -> CanvasDiff {
    CanvasDiff(added: added, changed: changed, removed: removed, unchangedCount: 0, isFirstSync: false)
}

do {
    let itemA = canvasItem("event-assignment-1", "A", due: makeDate(2026, 10, 21, 9))
    let itemB = canvasItem("event-assignment-2", "B", due: makeDate(2026, 10, 22, 9))
    let firstPlan = JobsEventKitPlanning.calendarWritePlan(for: diff(added: [itemB, itemA]), eventMap: [:], stampedEvents: [:], existingEventIdentifiers: [])
    check(firstPlan.operations == [.create(item: itemA), .create(item: itemB)], "diff to write operations: creates, sorted by uid")

    // Second run: map is complete and fingerprints match -> nothing to write.
    let fullMap = [itemA.uid: WispEventMapEntry(eventIdentifier: "EA", contentFingerprint: itemA.contentFingerprint),
                   itemB.uid: WispEventMapEntry(eventIdentifier: "EB", contentFingerprint: itemB.contentFingerprint)]
    let secondPlan = JobsEventKitPlanning.calendarWritePlan(for: diff(added: [itemA, itemB]), eventMap: fullMap, stampedEvents: [:], existingEventIdentifiers: ["EA", "EB"])
    check(secondPlan.operations.isEmpty, "same diff twice makes zero writes")
    check(secondPlan.retainedMapEntries.count == 2, "entries retained")

    // Changed item updates in place.
    let changedA = canvasItem("event-assignment-1", "A v2", due: makeDate(2026, 10, 21, 10))
    let change = CanvasItemChange(before: itemA, after: changedA, changedFields: [.start, .title])
    let updatePlan = JobsEventKitPlanning.calendarWritePlan(for: diff(changed: [change]), eventMap: fullMap, stampedEvents: [:], existingEventIdentifiers: ["EA", "EB"])
    check(updatePlan.operations == [.update(eventIdentifier: "EA", item: changedA)], "changed item updates the mapped event")
    check(updatePlan.retainedMapEntries[itemA.uid]?.contentFingerprint == changedA.contentFingerprint, "map fingerprint advances")

    // Removed item deletes; unknown removed does nothing; both unmap.
    let ghost = canvasItem("event-assignment-99", "Ghost", due: makeDate(2026, 10, 30, 9))
    let removePlan = JobsEventKitPlanning.calendarWritePlan(for: diff(removed: [itemB, ghost]), eventMap: fullMap, stampedEvents: [:], existingEventIdentifiers: ["EA", "EB"])
    check(removePlan.operations == [.delete(eventIdentifier: "EB", uid: itemB.uid)], "removed item deletes its event only")
    check(removePlan.uidsToUnmap.sorted() == [itemB.uid, ghost.uid].sorted(), "removed uids are unmapped")

    // Map lost: repair from notes stamps, no duplicate creates.
    let stamped = [itemA.uid: WispEventMapEntry(eventIdentifier: "EA", contentFingerprint: itemA.contentFingerprint)]
    let repairPlan = JobsEventKitPlanning.calendarWritePlan(for: diff(added: [itemA]), eventMap: [:], stampedEvents: stamped, existingEventIdentifiers: ["EA"])
    check(repairPlan.operations.isEmpty && repairPlan.retainedMapEntries[itemA.uid]?.eventIdentifier == "EA", "map repair from notes UID avoids duplicates")

    // User deleted the event by hand: stale map entry is ignored, event recreated.
    let staleMapPlan = JobsEventKitPlanning.calendarWritePlan(for: diff(added: [itemA]), eventMap: fullMap, stampedEvents: [:], existingEventIdentifiers: [])
    check(staleMapPlan.operations == [.create(item: itemA)], "event deleted by hand is recreated")

    // Notes stamp round trip.
    let withDescription = CanvasItem(uid: "u1", title: "T", courseCode: nil, kind: .other, startDate: today, endDate: nil, isAllDay: false,
                                     location: nil, descriptionText: "Read chapter 3", linkURLString: nil, contentFingerprint: "abc123")
    let notes = JobsEventKitPlanning.eventNotes(for: withDescription)
    let stamp = JobsEventKitPlanning.stamp(fromEventNotes: notes)
    check(stamp?.uid == "u1" && stamp?.contentFingerprint == "abc123", "stamp round-trips through notes")
    check(notes.hasPrefix("Read chapter 3"), "description stays above the stamp")
    check(JobsEventKitPlanning.stamp(fromEventNotes: "just a note") == nil, "unstamped notes are not ours")
}

do {
    func item(_ id: String, _ title: String, due: Date?) -> ChecklistItem {
        ChecklistItem(id: id, title: title, subtitle: nil, dueDate: due, origin: .canvasDue, rolloverCount: 0, isCompleted: false, completionDate: nil)
    }
    let keep = item("k", "Keep", due: makeDate(2026, 10, 21, 9))
    let rename = item("r", "Renamed", due: makeDate(2026, 10, 21, 10))
    let add = item("n", "New", due: nil)
    let existing = [
        ExistingReminderSnapshot(identifier: "R1", title: "Keep", dueDate: makeDate(2026, 10, 21, 9), stampedItemID: "k"),
        ExistingReminderSnapshot(identifier: "R2", title: "Old name", dueDate: makeDate(2026, 10, 21, 10), stampedItemID: "r"),
        ExistingReminderSnapshot(identifier: "R3", title: "Gone", dueDate: nil, stampedItemID: "gone"),
        ExistingReminderSnapshot(identifier: "R4", title: "User's own", dueDate: nil, stampedItemID: nil),
    ]
    let plan = JobsEventKitPlanning.reminderRebuildPlan(items: [keep, rename, add], itemIDToReminderIdentifier: ["k": "R1", "r": "R2"], existingReminders: existing)
    check(plan.operations.contains(.add(item: add)), "rebuild plan adds new items")
    check(plan.operations.contains(.update(reminderIdentifier: "R2", item: rename)), "rebuild plan updates a renamed item")
    check(!plan.operations.contains(where: { if case .update(let identifier, _) = $0 { return identifier == "R1" } else { return false } }), "unchanged item is kept without a write")
    check(plan.operations.contains(.remove(reminderIdentifier: "R3")), "rebuild plan removes our reminder that left the list")
    check(!plan.operations.contains(.remove(reminderIdentifier: "R4")), "user's own reminder is never removed")
    check(plan.retainedItemIDToReminderIdentifier == ["k": "R1", "r": "R2"], "retained mapping")

    // A rolled-over item keeps id, title and due date but its subtitle changes: notes refresh.
    let aging = ChecklistItem(id: "g", title: "Essay", subtitle: "overdue 3d", dueDate: nil, origin: .rolledOver, rolloverCount: 3, isCompleted: false, completionDate: nil)
    let staleNotesPlan = JobsEventKitPlanning.reminderRebuildPlan(
        items: [aging], itemIDToReminderIdentifier: ["g": "R9"],
        existingReminders: [ExistingReminderSnapshot(identifier: "R9", title: "Essay", dueDate: nil, stampedItemID: "g",
                                                     notes: "carried over\n" + JobsEventKitPlanning.reminderNotes(forItemID: "g"))])
    check(staleNotesPlan.operations == [.update(reminderIdentifier: "R9", item: aging)], "changed subtitle refreshes the reminder notes")
    let freshNotesPlan = JobsEventKitPlanning.reminderRebuildPlan(
        items: [aging], itemIDToReminderIdentifier: ["g": "R9"],
        existingReminders: [ExistingReminderSnapshot(identifier: "R9", title: "Essay", dueDate: nil, stampedItemID: "g",
                                                     notes: JobsEventKitPlanning.reminderNotes(for: aging))])
    check(freshNotesPlan.operations.isEmpty, "matching notes cause no write")

    // Rebuild twice with the same items and a repaired (empty) map: zero writes.
    let settled = [
        ExistingReminderSnapshot(identifier: "R1", title: "Keep", dueDate: makeDate(2026, 10, 21, 9), stampedItemID: "k"),
        ExistingReminderSnapshot(identifier: "R2", title: "Renamed", dueDate: makeDate(2026, 10, 21, 10), stampedItemID: "r"),
        ExistingReminderSnapshot(identifier: "R5", title: "New", dueDate: nil, stampedItemID: "n"),
    ]
    let repeatPlan = JobsEventKitPlanning.reminderRebuildPlan(items: [keep, rename, add], itemIDToReminderIdentifier: [:], existingReminders: settled)
    check(repeatPlan.operations.isEmpty, "second rebuild (map repaired from notes) writes nothing")
    check(JobsEventKitPlanning.itemID(fromReminderNotes: JobsEventKitPlanning.reminderNotes(forItemID: "canvasDue:u:20261021")) == "canvasDue:u:20261021", "reminder stamp round trip")
}

if failureCount > 0 {
    print("\(failureCount) of \(checkCount) checks FAILED")
    exit(1)
}
print("PASS: all \(checkCount) checks")
