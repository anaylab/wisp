import Foundation

// MARK: - Tiny harness

var failureCount = 0
var passCount = 0

func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition { passCount += 1; print("PASS  \(name)") }
    else { failureCount += 1; print("FAIL  \(name) \(detail())") }
}

// MARK: - Fixtures

var newYorkCalendar = Calendar(identifier: .gregorian)
newYorkCalendar.timeZone = TimeZone(identifier: "America/New_York")!

func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, calendar: Calendar = newYorkCalendar) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

let utcCalendar: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }()
let now = date(2026, 10, 19, 10, 0)   // Monday 10:00 New York

/// A realistic Canvas feed: CRLF, folded lines, escapes, VALARM, X-ALT-DESC, an all-day event,
/// a quiz, a calendar event, a malformed event and an HTML-looking junk event with no UID.
let canvasSampleICS = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//Instructure//Canvas//EN",
    "BEGIN:VEVENT",
    "UID:event-assignment-123",
    "DTSTART:20261020T235900Z",
    "DTEND:20261020T235900Z",
    "SUMMARY:Essay [draft] 2 [ENGL101]",
    "DESCRIPTION:Write 5 pages\\, double spaced\\nInclude sources\\; cite them \\\\ ok. Th",
    " is line was folded by the exporter.",
    "X-ALT-DESC;FMTTYPE=text/html:<p>ignore me</p>",
    "LOCATION:Room 4\\, Hall B",
    "URL:https://school.instructure.com/calendar?event_id=123",
    "BEGIN:VALARM",
    "DESCRIPTION:alarm text must not leak",
    "END:VALARM",
    "END:VEVENT",
    "BEGIN:VEVENT",
    "UID:event-calendar-event-2",
    "DTSTART;VALUE=DATE:20261021",
    "SUMMARY:Career fair [BUS200]",
    "END:VEVENT",
    "BEGIN:VEVENT",
    "UID:event-quiz-9",
    "DTSTART;TZID=America/New_York:20261022T090000",
    "DTEND;TZID=America/New_York:20261022T101500",
    "SUMMARY:Quiz 3",
    "END:VEVENT",
    "BEGIN:VEVENT",
    "UID:something-else-5",
    "DTSTART:20261023T120000Z",
    "SUMMARY:Mystery\twith\ttabs [X1]",
    "END:VEVENT",
    "BEGIN:VEVENT",
    "SUMMARY:No UID so skipped",
    "DTSTART:20261024T120000Z",
    "END:VEVENT",
    "BEGIN:VEVENT",
    "UID:event-assignment-bad",
    "SUMMARY:No start",
    "END:VEVENT",
    "END:VCALENDAR",
    ""
].joined(separator: "\r\n")

let parsedSample = CanvasFeedParser.parseReportingSkips(icsText: canvasSampleICS, now: now, calendar: newYorkCalendar)
func sampleItem(_ uid: String) -> CanvasItem? { parsedSample.items.first { $0.uid == uid } }

// MARK: - Parser

check("1 parses 4 valid events, skips 2 malformed", parsedSample.items.count == 4 && parsedSample.skippedEventCount == 2,
      "items=\(parsedSample.items.count) skipped=\(parsedSample.skippedEventCount)")

let foldedItem = sampleItem("event-assignment-123")
check("1 folded line is rejoined", foldedItem?.descriptionText?.hasSuffix("Th" + "is line was folded by the exporter.") == true, foldedItem?.descriptionText ?? "nil")

check("2 UTC DTSTART becomes the absolute instant",
      foldedItem?.startDate == date(2026, 10, 20, 23, 59, calendar: utcCalendar), "\(String(describing: foldedItem?.startDate))")

let quizItem = sampleItem("event-quiz-9")
check("3 TZID DTSTART honoured", quizItem?.startDate == date(2026, 10, 22, 9, 0) && quizItem?.endDate == date(2026, 10, 22, 10, 15))
let allDayItem = sampleItem("event-calendar-event-2")
check("3 VALUE=DATE is all-day at local midnight, no end",
      allDayItem?.isAllDay == true && allDayItem?.startDate == date(2026, 10, 21) && allDayItem?.endDate == nil)

check("4 trailing [CODE] split, inner brackets kept", foldedItem?.title == "Essay [draft] 2" && foldedItem?.courseCode == "ENGL101",
      "\(String(describing: foldedItem?.title)) \(String(describing: foldedItem?.courseCode))")
let noCodeEvents = CanvasFeedParser.parse(icsText: "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:u1\nDTSTART:20261020T100000Z\nSUMMARY:Plain title\nEND:VEVENT\nEND:VCALENDAR", now: now, calendar: newYorkCalendar)
check("4 no trailing bracket gives nil course code", noCodeEvents.first?.courseCode == nil && noCodeEvents.first?.title == "Plain title")

check("5 kinds from UID prefix",
      foldedItem?.kind == .assignment && allDayItem?.kind == .calendarEvent && quizItem?.kind == .quiz && sampleItem("something-else-5")?.kind == .other)

check("6 escapes decoded in description", foldedItem?.descriptionText?.hasPrefix("Write 5 pages, double spaced\nInclude sources; cite them \\ ok.") == true, foldedItem?.descriptionText ?? "nil")
check("6 escapes decoded in location", foldedItem?.location == "Room 4, Hall B", foldedItem?.location ?? "nil")
check("6 X-ALT-DESC and VALARM text ignored", foldedItem?.descriptionText?.contains("ignore me") == false && foldedItem?.descriptionText?.contains("alarm") == false)

check("7 events without UID or DTSTART skipped, others survive", sampleItem("event-assignment-bad") == nil && parsedSample.items.count == 4)
check("8 DTEND equal to DTSTART gives nil end", foldedItem?.endDate == nil)
check("8 empty and HTML input give []",
      CanvasFeedParser.parse(icsText: "", now: now, calendar: newYorkCalendar).isEmpty &&
      CanvasFeedParser.parse(icsText: "<html><body>Please log in</body></html>", now: now, calendar: newYorkCalendar).isEmpty)

let reparsed = CanvasFeedParser.parse(icsText: canvasSampleICS, now: now, calendar: newYorkCalendar)
check("9 fingerprint stable across runs", reparsed == parsedSample.items)
func fingerprintAfterEditing(_ find: String, _ replace: String) -> String? {
    CanvasFeedParser.parse(icsText: canvasSampleICS.replacingOccurrences(of: find, with: replace), now: now, calendar: newYorkCalendar)
        .first { $0.uid == "event-quiz-9" }?.contentFingerprint
}
let baseQuizFingerprint = quizItem?.contentFingerprint
check("9 fingerprint changes with title/time",
      fingerprintAfterEditing("SUMMARY:Quiz 3", "SUMMARY:Quiz 4") != baseQuizFingerprint &&
      fingerprintAfterEditing("T090000", "T093000") != baseQuizFingerprint)
check("9 fingerprint changes with location/description",
      fingerprintAfterEditing("SUMMARY:Quiz 3", "SUMMARY:Quiz 3\r\nLOCATION:Lab") != baseQuizFingerprint &&
      fingerprintAfterEditing("SUMMARY:Quiz 3", "SUMMARY:Quiz 3\r\nDESCRIPTION:Chapter 4") != baseQuizFingerprint)

let duplicateUIDResult = CanvasFeedParser.parseReportingSkips(
    icsText: "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:dup\nDTSTART:20261020T100000Z\nSUMMARY:First\nEND:VEVENT\nBEGIN:VEVENT\nUID:dup\nDTSTART:20261020T110000Z\nSUMMARY:Second\nEND:VEVENT\nEND:VCALENDAR",
    now: now, calendar: newYorkCalendar)
check("10 duplicate UID keeps the last and reports one skipped", duplicateUIDResult.items.count == 1 && duplicateUIDResult.items[0].title == "Second" && duplicateUIDResult.skippedEventCount == 1)

// MARK: - Planner (diff)

func makeItem(_ uid: String, title: String = "T", start: Date = date(2026, 10, 21, 12), end: Date? = nil, location: String? = nil, description: String? = nil, allDay: Bool = false, kind: CanvasItem.Kind = .assignment, code: String? = "C1") -> CanvasItem {
    CanvasItem(uid: uid, title: title, courseCode: code, kind: kind, startDate: start, endDate: end, isAllDay: allDay, location: location, descriptionText: description, linkURLString: nil,
               contentFingerprint: "\(title)|\(start.timeIntervalSince1970)|\(end?.timeIntervalSince1970 ?? 0)|\(allDay)|\(location ?? "")|\(description ?? "")")
}

let itemA = makeItem("a", title: "A")
let itemB = makeItem("b", title: "B", start: date(2026, 10, 22, 12))
let itemC = makeItem("c", title: "C", start: date(2026, 10, 23, 12))

let firstSyncDiff = CanvasSyncPlanner.diff(previous: nil, current: [itemB, itemA])
check("11 nil previous: all added, first sync, sorted", firstSyncDiff.isFirstSync && firstSyncDiff.added == [itemA, itemB] && firstSyncDiff.changed.isEmpty && firstSyncDiff.removed.isEmpty)
check("11 identical lists give empty diff", CanvasSyncPlanner.diff(previous: [itemA, itemB], current: [itemA, itemB]).isEmpty)

let titleChange = CanvasSyncPlanner.diff(previous: [itemA], current: [makeItem("a", title: "A2")])
check("12 title change", titleChange.changed.count == 1 && titleChange.changed[0].changedFields == [.title])
let timeChange = CanvasSyncPlanner.diff(previous: [itemA], current: [makeItem("a", title: "A", start: date(2026, 10, 21, 15))])
check("12 time change is [start]", timeChange.changed.first?.changedFields == [.start])
let multiChange = CanvasSyncPlanner.diff(previous: [itemA], current: [makeItem("a", title: "Z", start: date(2026, 10, 21, 15), end: date(2026, 10, 21, 16), location: "L", description: "D", allDay: true)])
check("12 multiple fields sorted by raw value", multiChange.changed.first?.changedFields == [.allDay, .description, .end, .location, .start, .title],
      "\(String(describing: multiChange.changed.first?.changedFields))")

let mixedDiff = CanvasSyncPlanner.diff(previous: [itemA, itemB, itemC], current: [makeItem("a", title: "A edited"), itemB, makeItem("d", title: "D", start: date(2026, 10, 24, 12)), makeItem("e", title: "E", start: date(2026, 10, 25, 12))])
check("13 removed and added by UID", mixedDiff.removed == [itemC] && mixedDiff.added.map(\.uid) == ["d", "e"])
check("13 reordered list gives empty diff", CanvasSyncPlanner.diff(previous: [itemA, itemB, itemC], current: [itemC, itemA, itemB]).isEmpty)
check("14 unchangedCount and summaryLine", mixedDiff.unchangedCount == 1 && mixedDiff.summaryLine == "2 new, 1 changed, 1 removed", mixedDiff.summaryLine)
check("14 empty summary", CanvasSyncPlanner.diff(previous: [itemA], current: [itemA]).summaryLine == "No changes")

// MARK: - Study blocks

func busy(_ start: Date, _ end: Date) -> BusyInterval { BusyInterval(start: start, end: end) }
let settings = StudyBlockSettings.default
func propose(_ items: [CanvasItem], busy: [BusyInterval] = [], already: Set<String> = [], settings: StudyBlockSettings = settings, now: Date = now, calendar: Calendar = newYorkCalendar) -> [StudyBlockProposal] {
    StudyBlockPlanner.propose(items: items, busyIntervals: busy, alreadyProposedOrCreatedIDs: already, settings: settings, now: now, calendar: calendar)
}
func minuteOfDay(_ d: Date, _ calendar: Calendar = newYorkCalendar) -> Int {
    let c = calendar.dateComponents([.hour, .minute], from: d); return c.hour! * 60 + c.minute!
}
let essayDueInThreeDays = makeItem("a1", title: "Essay", start: date(2026, 10, 22, 23, 59))

let emptyCalendarBlocks = propose([essayDueInThreeDays])
check("15 one block of configured length, in working hours, before due",
      emptyCalendarBlocks.count == 1 && emptyCalendarBlocks[0].end.timeIntervalSince(emptyCalendarBlocks[0].start) == 90 * 60 &&
      minuteOfDay(emptyCalendarBlocks[0].start) >= 540 && minuteOfDay(emptyCalendarBlocks[0].end) <= 1260 &&
      emptyCalendarBlocks[0].end <= essayDueInThreeDays.startDate && emptyCalendarBlocks[0].start >= now &&
      emptyCalendarBlocks[0].title == "Study: Essay" && emptyCalendarBlocks[0].forItemUID == "a1",
      "\(emptyCalendarBlocks)")

// Block everything except 15:00-17:30 on Monday and nothing on later days: the block must land clear of busy+buffer.
let mondayBusy = [busy(date(2026, 10, 19, 9), date(2026, 10, 19, 13)), busy(date(2026, 10, 19, 18), date(2026, 10, 19, 22))]
let bufferedBlocks = propose([essayDueInThreeDays], busy: mondayBusy)
if let block = bufferedBlocks.first {
    let clearOfBusy = mondayBusy.allSatisfy { block.end + 15 * 60 <= $0.start || block.start >= $0.end + 15 * 60 }
    check("16 block avoids busy intervals and keeps the 15 minute buffer", clearOfBusy, "\(block)")
} else { check("16 block avoids busy intervals and keeps the 15 minute buffer", false, "no block") }

// A busy event across the whole workday on all days until due leaves nothing.
let allDaysBusy = (19...22).map { busy(date(2026, 10, $0, 8), date(2026, 10, $0, 22)) }
check("16 no block when every day is full", propose([essayDueInThreeDays], busy: allDaysBusy).isEmpty)

// Free gap 13:00-14:45 shrinks to 75 minutes after buffers, below the 100 minute minimum.
let shortGapBusy = (19...22).flatMap { day in [busy(date(2026, 10, day, 8), date(2026, 10, day, 13)), busy(date(2026, 10, day, 14, 45), date(2026, 10, day, 22))] }
check("17 gap shorter than the minimum is skipped", propose([essayDueInThreeDays], busy: shortGapBusy).isEmpty)

let manyAssignments = (1...6).map { makeItem("m\($0)", title: "HW\($0)", start: date(2026, 10, 20, 23, 0)) }
let capped = propose(manyAssignments)
check("17 maximumBlocksPerDay honoured", Dictionary(grouping: capped) { newYorkCalendar.startOfDay(for: $0.start) }.values.allSatisfy { $0.count <= 2 } && capped.count >= 1, "\(capped.count)")
let noOverlap = zip(capped, capped.dropFirst()).allSatisfy { $0.end <= $1.start }
check("17 proposals never overlap each other", noOverlap)

check("18 deterministic output", propose(manyAssignments) == propose(manyAssignments.reversed()))
let excludedID = emptyCalendarBlocks[0].id
check("18 id format", excludedID.hasPrefix("study-a1-") && excludedID.hasSuffix("-0") && excludedID.count == "study-a1-20261019-0".count, excludedID)
check("18 already proposed ids excluded", propose([essayDueInThreeDays], already: [excludedID]).isEmpty)

var disabledSettings = settings; disabledSettings.isEnabled = false
check("19 disabled settings give []", propose([essayDueInThreeDays], settings: disabledSettings).isEmpty)
check("19 no assignments gives []", propose([makeItem("e1", kind: .calendarEvent, code: nil)]).isEmpty)
check("19 past and beyond-lookahead give []",
      propose([makeItem("p", start: date(2026, 10, 18, 12)), makeItem("f", start: date(2026, 11, 20, 12))]).isEmpty)
let lateNow = date(2026, 10, 19, 20, 50)
let lateBlocks = propose([makeItem("l", start: date(2026, 10, 21, 12))], now: lateNow)
check("19 blocks never start in the past or in sleeping hours", lateBlocks.allSatisfy { $0.start >= lateNow && minuteOfDay($0.start) >= 540 && minuteOfDay($0.end) <= 1260 })
check("19 now rounds up to a quarter hour", propose([essayDueInThreeDays], now: date(2026, 10, 19, 10, 1)).first.map { minuteOfDay($0.start) % 15 == 0 && $0.start >= date(2026, 10, 19, 10, 15) } == true)

// DST: fall back on 2026-11-01 in New York.
let dstNow = date(2026, 10, 31, 8)
let dstBlocks = propose([makeItem("dst", start: date(2026, 11, 1, 18)), makeItem("dst2", start: date(2026, 11, 1, 19))], now: dstNow)
check("20 DST day keeps wall-clock workday", !dstBlocks.isEmpty && dstBlocks.allSatisfy { minuteOfDay($0.start) >= 540 && minuteOfDay($0.end) <= 1260 }, "\(dstBlocks)")
var tokyoCalendar = Calendar(identifier: .gregorian); tokyoCalendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
let tokyoBlocks = propose([makeItem("t", start: date(2026, 10, 22, 12, calendar: tokyoCalendar))], now: date(2026, 10, 19, 8, calendar: tokyoCalendar), calendar: tokyoCalendar)
check("20 uses the Calendar passed in", tokyoBlocks.first.map { minuteOfDay($0.start, tokyoCalendar) >= 540 } == true)

// MARK: - URL validator

func validate(_ raw: String) -> Result<URL, CanvasFeedURLValidationError> { CanvasFeedURLValidator.validate(raw) }
if case .success(let url) = validate("  https://school.instructure.com/feeds/calendars/user_AbC123.ics \n") {
    check("21 https passes and is trimmed", url.host == "school.instructure.com")
} else { check("21 https passes and is trimmed", false) }
if case .success(let url) = validate("webcal://school.instructure.com/feeds/calendars/user_AbC123.ics") {
    check("21 webcal rewritten to https", url.scheme == "https" && url.host == "school.instructure.com")
} else { check("21 webcal rewritten to https", false) }
func failure(_ raw: String) -> CanvasFeedURLValidationError? { if case .failure(let e) = validate(raw) { return e }; return nil }
check("21 http rejected", failure("http://school.instructure.com/feeds/x.ics") == .notHTTPS)
check("21 file: rejected", failure("file:///etc/passwd") == .notHTTPS || failure("file:///etc/passwd") == .notAURL)
check("21 javascript: rejected", failure("javascript:alert(1)") == .notAURL)
check("21 empty and spaces rejected", failure("") == .empty && failure("   \n ") == .empty)
check("21 bare host rejected", failure("school.instructure.com/feeds/x.ics") == .notAURL)
check("21 garbage with spaces rejected", failure("not a url at all") == .notAURL)
check("21 userinfo rejected", failure("https://user:pw@school.instructure.com/x.ics") == .containsCredentials)
check("21 no host rejected", failure("https:///feeds/x.ics") == .missingHost || failure("https:///feeds/x.ics") == .notAURL)

let secretURL = URL(string: "https://school.instructure.com/feeds/calendars/user_SECRETTOKEN.ics?x=1")!
let maskedText = CanvasFeedURLValidator.maskedDisplay(for: secretURL)
check("22 masked display has host only", maskedText.contains("school.instructure.com") && !maskedText.contains("SECRETTOKEN") && !maskedText.contains("feeds") && !maskedText.contains("x=1"), maskedText)
let allErrorText = [CanvasFeedURLValidationError.empty, .notAURL, .notHTTPS, .missingHost, .containsCredentials].map { $0.localizedDescription }
    + [CanvasFeedFetchError.noFeedConfigured, .offline, .httpStatus(404), .notICS, .tooLarge, .timedOut].map { $0.localizedDescription }
check("22 error descriptions never contain a URL", allErrorText.allSatisfy { !$0.contains("instructure") && !$0.contains("://") && !$0.contains("SECRET") })

// MARK: - Snapshot store (temp dir, no Keychain, no network)

let snapshotDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("canvas-sync-test-\(UUID().uuidString)")
let snapshotFile = snapshotDirectory.appendingPathComponent("nested/snapshot.json")
let store = CanvasFeedStore(feedURLProvider: { nil }, snapshotFileURL: snapshotFile)
let snapshot = CanvasSnapshot(fetchedAt: Date(timeIntervalSince1970: 1_800_000_000), items: parsedSample.items)

do {
    check("23 no snapshot initially", await store.loadSnapshot() == nil)
    do { try await store.saveSnapshot(snapshot); try await store.saveSnapshot(snapshot) } catch { check("23 snapshot saves twice", false, "\(error)") }
    check("23 snapshot round-trips", await store.loadSnapshot() == snapshot)
    let permissions = (try? FileManager.default.attributesOfItem(atPath: snapshotFile.path)[.posixPermissions] as? NSNumber)?.intValue
    check("23 snapshot file is 0600", permissions == 0o600, "\(String(describing: permissions))")
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: snapshotFile.deletingLastPathComponent().path)) ?? []
    check("23 no temp files left behind", leftovers == ["snapshot.json"], "\(leftovers)")
    await store.clearSnapshot()
    check("23 clearSnapshot removes it", await store.loadSnapshot() == nil)
    do { _ = try await store.fetchCurrentItems(now: now, calendar: newYorkCalendar); check("23 fetch without feed throws", false) }
    catch { check("23 fetch without feed throws noFeedConfigured", (error as? CanvasFeedFetchError) == .noFeedConfigured) }
}
try? FileManager.default.removeItem(at: snapshotDirectory)

print("\n\(passCount) passed, \(failureCount) failed")
exit(failureCount == 0 ? 0 : 1)
