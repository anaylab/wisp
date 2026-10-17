//
//  Tests/JobsEngine/main.swift
//
//  Drives JobsEngine end to end with fakes. See run.sh.
//

import Foundation

var failureCount = 0
func check(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { print("FAIL \(name)"); failureCount += 1 }
}

// MARK: - Fakes

nonisolated final class FakeWorld: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [CanvasItem] = []
    private var _snapshot: CanvasSnapshot?
    private var _fetchError: Error?
    private var _applyCalls = 0
    private var _studyWrites = 0
    private var _announcements: [String] = []
    private var _calendarAccess: JobsAccessState = .granted
    private var _remindersAccess: JobsAccessState = .granted
    private var _approves = true
    private var _setCompletedFails = false
    private var _reminderCompletion: [String: (isCompleted: Bool, completionDate: Date?)] = [:]
    private var _rebuiltItems: [ChecklistItem] = []
    private var _hasFeed = true
    private var _savedURLCount = 0
    private var _rebuildFails = false
    private var _fetchDelayNanoseconds: UInt64 = 0

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var items: [CanvasItem] { get { locked { _items } } set { locked { _items = newValue } } }
    var snapshot: CanvasSnapshot? { get { locked { _snapshot } } set { locked { _snapshot = newValue } } }
    var fetchError: Error? { get { locked { _fetchError } } set { locked { _fetchError = newValue } } }
    var applyCalls: Int { get { locked { _applyCalls } } set { locked { _applyCalls = newValue } } }
    var studyWrites: Int { get { locked { _studyWrites } } set { locked { _studyWrites = newValue } } }
    var announcements: [String] { get { locked { _announcements } } set { locked { _announcements = newValue } } }
    var calendarAccess: JobsAccessState { get { locked { _calendarAccess } } set { locked { _calendarAccess = newValue } } }
    var remindersAccess: JobsAccessState { get { locked { _remindersAccess } } set { locked { _remindersAccess = newValue } } }
    var approves: Bool { get { locked { _approves } } set { locked { _approves = newValue } } }
    var setCompletedFails: Bool { get { locked { _setCompletedFails } } set { locked { _setCompletedFails = newValue } } }
    var reminderCompletion: [String: (isCompleted: Bool, completionDate: Date?)] { get { locked { _reminderCompletion } } set { locked { _reminderCompletion = newValue } } }
    var rebuiltItems: [ChecklistItem] { get { locked { _rebuiltItems } } set { locked { _rebuiltItems = newValue } } }
    var hasFeed: Bool { get { locked { _hasFeed } } set { locked { _hasFeed = newValue } } }
    var rebuildFails: Bool { get { locked { _rebuildFails } } set { locked { _rebuildFails = newValue } } }
    var fetchDelayNanoseconds: UInt64 { get { locked { _fetchDelayNanoseconds } } set { locked { _fetchDelayNanoseconds = newValue } } }
    var savedURLCount: Int { get { locked { _savedURLCount } } set { locked { _savedURLCount = newValue } } }
}

nonisolated struct FakeFeed: JobsFeedProviding {
    let world: FakeWorld
    func fetchCurrentItems(now: Date, calendar: Calendar) async throws -> [CanvasItem] {
        if let error = world.fetchError { throw error }
        let itemsAtFetchTime = world.items
        if world.fetchDelayNanoseconds > 0 { try? await Task.sleep(nanoseconds: world.fetchDelayNanoseconds) }
        return itemsAtFetchTime
    }
    func loadSnapshot() async -> CanvasSnapshot? { world.snapshot }
    func saveSnapshot(_ snapshot: CanvasSnapshot) async throws { world.snapshot = snapshot }
    func clearSnapshot() async { world.snapshot = nil }
}

nonisolated struct FakeFeedConfiguration: JobsFeedConfiguring {
    let world: FakeWorld
    func hasFeedURL() -> Bool { world.hasFeed }
    func saveFeedURL(_ feedURL: URL) throws { world.hasFeed = true; world.savedURLCount += 1 }
    func deleteFeedURL() { world.hasFeed = false }
}

nonisolated struct FakeCalendarWriter: JobsCalendarWriting {
    let world: FakeWorld
    func authorizationState() async -> JobsAccessState { world.calendarAccess }
    func requestAccessIfNeeded() async throws {}
    func ensureWispCalendarExists() async throws {}
    func apply(diff: CanvasDiff) async throws -> (created: Int, updated: Int, deleted: Int) {
        world.applyCalls += 1
        return (diff.added.count, diff.changed.count, diff.removed.count)
    }
    func writeStudyBlocks(_ proposals: [StudyBlockProposal]) async throws -> Int {
        world.studyWrites += proposals.count
        return proposals.count
    }
    func busyIntervals(from startDate: Date, to endDate: Date) async throws -> [BusyInterval] { [] }
    func calendarEvents(onDay day: Date, calendar: Calendar) async throws -> [ChecklistCalendarEvent] { [] }
}

nonisolated struct FakeReminders: JobsReminderWriting {
    let world: FakeWorld
    func authorizationState() async -> JobsAccessState { world.remindersAccess }
    func requestAccessIfNeeded() async throws {}
    func rebuild(with items: [ChecklistItem]) async throws {
        if world.rebuildFails { throw WispEventKitError.calendarMissing }
        world.rebuiltItems = items
    }
    func readBackCompletion() async throws -> [String: (isCompleted: Bool, completionDate: Date?)] { world.reminderCompletion }
    func setCompleted(itemID: String, isCompleted: Bool) async throws {
        if world.setCompletedFails { throw WispEventKitError.itemMissing }
        world.reminderCompletion[itemID] = (isCompleted, isCompleted ? Date() : nil)
    }
}

nonisolated struct FakeApprover: JobsStudyBlockApproving {
    let world: FakeWorld
    func askToWriteStudyBlocks(_ proposals: [StudyBlockProposal]) async -> Bool { world.approves }
}

nonisolated struct FakeAnnouncer: JobsChangeAnnouncing {
    let world: FakeWorld
    func announceCanvasChange(title: String, body: String) async { world.announcements.append(body) }
}

nonisolated final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
}

// MARK: - Fixtures

var utcCalendar = Calendar(identifier: .gregorian)
utcCalendar.timeZone = TimeZone(identifier: "UTC")!
let morningStart = utcCalendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 9))!

func makeItem(_ uid: String, title: String, due: Date, kind: CanvasItem.Kind = .assignment) -> CanvasItem {
    CanvasItem(uid: uid, title: title, courseCode: "ENGL101", kind: kind, startDate: due, endDate: nil,
               isAllDay: false, location: nil, descriptionText: nil, linkURLString: nil,
               contentFingerprint: "\(uid)|\(title)|\(due.timeIntervalSince1970)")
}

@MainActor
func makeEngine(world: FakeWorld, clock: ClockBox) -> JobsEngine {
    let suiteName = "wisp.jobs.tests.\(UUID().uuidString)"
    let stateFile = FileManager.default.temporaryDirectory.appendingPathComponent("jobs-engine-test-\(UUID().uuidString).json")
    return JobsEngine(dependencies: JobsEngineDependencies(
        feed: FakeFeed(world: world),
        feedConfiguration: FakeFeedConfiguration(world: world),
        calendarWriter: FakeCalendarWriter(world: world),
        reminders: FakeReminders(world: world),
        studyBlockApprover: FakeApprover(world: world),
        announcer: FakeAnnouncer(world: world),
        userDefaults: UserDefaults(suiteName: suiteName)!,
        stateFileURL: stateFile,
        now: { clock.now },
        calendar: utcCalendar
    ))
}

let dueToday = makeItem("event-assignment-1", title: "Essay draft", due: morningStart.addingTimeInterval(3 * 3600))
let dueInThreeDays = makeItem("event-assignment-2", title: "Lab report", due: morningStart.addingTimeInterval(3 * 86400))

// MARK: - Cases

@MainActor
func runAllCases() async {
    // 1. First sync: one summary, one apply call, snapshot saved.
    do {
        let world = FakeWorld(); world.items = [dueToday, dueInThreeDays]
        let clock = ClockBox(morningStart)
        let engine = makeEngine(world: world, clock: clock)
        await engine.syncNow()
        check(world.applyCalls == 1, "first sync writes the calendar once")
        check(world.announcements == ["Added 2 Canvas items to Wisp"], "first sync presents one summary")
        check(world.snapshot?.items.count == 2, "first sync saves the snapshot")
        check(engine.latestDiff?.isFirstSync == true, "first sync publishes the diff")
        check(engine.syncState == .idle && engine.itemCountInFeed == 2, "state idle with item count")

        // 2. Same feed an hour later: zero writes, zero announcements, no new card.
        engine.dismissLatestDiff()
        clock.advance(seconds: 3600)
        await engine.syncNow()
        check(world.applyCalls == 1, "second identical sync makes zero calendar writes")
        check(world.announcements.count == 1, "empty diff is silent")
        check(engine.latestDiff == nil, "empty diff leaves no card")

        // 2b. Sync now inside 15 minutes is ignored.
        let renamed = makeItem("event-assignment-1", title: "Essay draft v2", due: dueToday.startDate)
        world.items = [renamed, dueInThreeDays]
        clock.advance(seconds: 5 * 60)
        await engine.syncNow()
        check(world.applyCalls == 1, "sync inside 15 minutes is throttled")

        // 3. After the floor a change is written and announced as a summary line.
        clock.advance(seconds: 20 * 60)
        await engine.syncNow()
        check(world.applyCalls == 2 && world.announcements.last == "1 changed", "a change is applied and announced")
    }

    // 4. Failure keeps the previous snapshot and never leaks a URL.
    do {
        let world = FakeWorld(); world.items = [dueToday]
        let clock = ClockBox(morningStart)
        let engine = makeEngine(world: world, clock: clock)
        await engine.syncNow()
        let snapshotBefore = world.snapshot
        world.fetchError = CanvasFeedFetchError.offline
        clock.advance(seconds: 3600)
        await engine.syncNow()
        check(world.snapshot == snapshotBefore, "failed sync keeps the previous snapshot")
        if case .failed(let message) = engine.syncState {
            check(!message.contains("http"), "failure message has no URL")
        } else { check(false, "failed sync sets failed state") }
        // A failed attempt may be retried at once.
        world.fetchError = nil
        await engine.syncNow()
        check(engine.syncState == .idle, "retry after a failure is allowed immediately")
    }

    // 5. No calendar access: nothing written, no snapshot, no card.
    do {
        let world = FakeWorld(); world.items = [dueToday]; world.calendarAccess = .denied
        let engine = makeEngine(world: world, clock: ClockBox(morningStart))
        await engine.syncNow()
        check(world.applyCalls == 0 && world.snapshot == nil && engine.latestDiff == nil, "denied calendar writes and saves nothing")
        check(engine.itemCountInFeed == 1, "item count still reported without access")
    }

    // 6. Study blocks: decline keeps them, approve writes once, dismiss is remembered.
    do {
        let world = FakeWorld(); world.items = [dueInThreeDays]
        let clock = ClockBox(morningStart)
        let engine = makeEngine(world: world, clock: clock)
        await engine.syncNow()
        check(!engine.pendingStudyBlocks.isEmpty, "a study block is proposed for a far-off assignment")
        world.approves = false
        await engine.approvePendingStudyBlocks()
        check(world.studyWrites == 0 && !engine.pendingStudyBlocks.isEmpty, "declined card writes nothing and keeps the proposal")
        world.approves = true
        let proposedCount = engine.pendingStudyBlocks.count
        await engine.approvePendingStudyBlocks()
        check(world.studyWrites == proposedCount && engine.pendingStudyBlocks.isEmpty, "approved card writes the batch once")
        clock.advance(seconds: 3600)
        await engine.syncNow()
        check(engine.pendingStudyBlocks.isEmpty, "approved blocks are not proposed again")
    }
    do {
        let world = FakeWorld(); world.items = [dueInThreeDays]
        let clock = ClockBox(morningStart)
        let engine = makeEngine(world: world, clock: clock)
        await engine.syncNow()
        engine.dismissPendingStudyBlocks()
        clock.advance(seconds: 3600)
        await engine.syncNow()
        check(engine.pendingStudyBlocks.isEmpty && world.studyWrites == 0, "dismissed blocks are not re-proposed")
    }

    // 7. Checklist: built once in the morning, ticks write Reminders, failures revert.
    do {
        let world = FakeWorld(); world.items = [dueToday]
        let clock = ClockBox(morningStart)
        let engine = makeEngine(world: world, clock: clock)
        await engine.syncNow()
        await engine.buildChecklistIfDue()
        check(engine.hasChecklist && engine.todayChecklist.count == 1, "morning checklist is built from Canvas")
        check(world.rebuiltItems.count == 1, "checklist is written to Reminders")
        let firstItemID = engine.todayChecklist[0].id
        await engine.setChecklistItem(id: firstItemID, isCompleted: true)
        check(engine.todayChecklist[0].isCompleted && world.reminderCompletion[firstItemID]?.isCompleted == true, "tick writes Reminders")
        world.setCompletedFails = true
        world.rebuildFails = true
        await engine.setChecklistItem(id: firstItemID, isCompleted: false)
        check(engine.todayChecklist[0].isCompleted, "failed Reminders write reverts the tick")
        // The reminder is gone but the list can be recreated: the tick sticks.
        world.rebuildFails = false
        world.rebuiltItems = []
        await engine.setChecklistItem(id: firstItemID, isCompleted: false)
        check(!engine.todayChecklist[0].isCompleted && world.rebuiltItems.count == 1,
              "missing reminder is recreated and the tick kept")
        await engine.setChecklistItem(id: firstItemID, isCompleted: true)
        world.setCompletedFails = false
        world.reminderCompletion[firstItemID] = (false, nil)
        await engine.refreshChecklistCompletion()
        check(!engine.todayChecklist[0].isCompleted, "untick in Reminders is read back")

        // Built once per day: a second call the same morning does nothing.
        world.rebuiltItems = []
        await engine.buildChecklistIfDue()
        check(world.rebuiltItems.isEmpty, "checklist is not rebuilt twice in a day")
    }
    do {
        let world = FakeWorld(); world.items = [dueToday]
        let evening = utcCalendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 20))!
        let engine = makeEngine(world: world, clock: ClockBox(evening))
        await engine.syncNow()
        await engine.buildChecklistIfDue()
        check(!engine.hasChecklist, "no automatic build outside the morning window")
        await engine.rebuildChecklistNow()
        check(engine.todayChecklist.count == 1, "Rebuild today works any time")
    }

    // 7b. A rolled-over item ticked today survives a same-day rebuild.
    do {
        let yesterdayMorning = utcCalendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 9))!
        let dueYesterday = makeItem("event-assignment-9", title: "Old essay", due: yesterdayMorning.addingTimeInterval(3 * 3600))
        let world = FakeWorld(); world.items = [dueYesterday]
        let clock = ClockBox(yesterdayMorning)
        let engine = makeEngine(world: world, clock: clock)
        await engine.syncNow()
        await engine.buildChecklistIfDue()
        clock.advance(seconds: 24 * 3600)
        await engine.buildChecklistIfDue()
        let rolledOverID = engine.todayChecklist.first?.id ?? ""
        check(engine.todayChecklist.first?.origin == .rolledOver, "unfinished item rolls over")
        await engine.setChecklistItem(id: rolledOverID, isCompleted: true)
        await engine.rebuildChecklistNow()
        check(engine.todayChecklist.count == 1 && engine.todayChecklist[0].isCompleted
              && engine.todayChecklist[0].rolloverCount == 1,
              "same-day rebuild keeps a ticked rolled-over item ticked and counted once")
    }

    // 7c. Approved study blocks are busy time for later proposals.
    do {
        let world = FakeWorld()
        let itemA = makeItem("event-assignment-a", title: "Paper A", due: morningStart.addingTimeInterval(2 * 86400))
        let itemB = makeItem("event-assignment-b", title: "Paper B", due: morningStart.addingTimeInterval(2 * 86400 + 60))
        world.items = [itemA]
        let clock = ClockBox(morningStart)
        let engine = makeEngine(world: world, clock: clock)
        await engine.syncNow()
        let firstBlocks = engine.pendingStudyBlocks
        await engine.approvePendingStudyBlocks()
        world.items = [itemA, itemB]
        clock.advance(seconds: 3600)
        await engine.syncNow()
        let overlapsAnApprovedBlock = engine.pendingStudyBlocks.contains { pending in
            firstBlocks.contains { pending.start < $0.end && $0.start < pending.end }
        }
        check(!firstBlocks.isEmpty && !engine.pendingStudyBlocks.isEmpty && !overlapsAnApprovedBlock,
              "a new proposal never overlaps an approved study block")
    }

    // 7d. An empty feed over an existing snapshot is refused, not applied as "all removed".
    do {
        let world = FakeWorld(); world.items = [dueToday, dueInThreeDays]
        let clock = ClockBox(morningStart)
        let engine = makeEngine(world: world, clock: clock)
        await engine.syncNow()
        world.items = []
        clock.advance(seconds: 3600)
        let applyCallsBefore = world.applyCalls
        await engine.syncNow()
        check(world.applyCalls == applyCallsBefore && world.snapshot?.items.count == 2, "empty feed leaves the calendar and snapshot alone")
        if case .failed = engine.syncState { check(true, "empty feed reports a problem") } else { check(false, "empty feed reports a problem") }
    }

    // 7e. Removing the feed during a sync leaves no snapshot behind.
    do {
        let world = FakeWorld(); world.items = [dueToday]
        world.fetchDelayNanoseconds = 300_000_000
        let engine = makeEngine(world: world, clock: ClockBox(morningStart))
        let runningSync = Task { @MainActor in await engine.syncNow() }
        try? await Task.sleep(nanoseconds: 80_000_000)
        engine.removeCanvasFeed()
        await runningSync.value
        check(world.snapshot == nil && engine.syncState == .notConfigured && engine.lastSyncedAt == nil,
              "remove during a sync discards the in-flight result")
    }

    // 8. Setup: invalid links are rejected before anything is stored.
    do {
        let world = FakeWorld(); world.hasFeed = false
        let engine = makeEngine(world: world, clock: ClockBox(morningStart))
        check(engine.syncState == .notConfigured && !engine.hasCanvasFeed, "no feed means notConfigured")
        if case .failure(let error) = engine.saveCanvasFeed(urlText: "http://school.example/feed.ics") {
            check(error == .notHTTPS && world.savedURLCount == 0, "http link rejected and not stored")
        } else { check(false, "http link must be rejected") }
        if case .success = engine.saveCanvasFeed(urlText: "webcal://school.example/feeds/abc.ics") {
            check(world.savedURLCount == 1 && engine.syncState != .notConfigured, "valid link stored")
        } else { check(false, "valid link accepted") }
        engine.removeCanvasFeed()
        check(engine.syncState == .notConfigured && !world.hasFeed, "remove returns to notConfigured")
    }
}

await runAllCases()
print(failureCount == 0 ? "All JobsEngine checks passed" : "\(failureCount) JobsEngine check(s) FAILED")
exit(failureCount == 0 ? 0 : 1)
