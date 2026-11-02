import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("FAIL: \(message)") }
}

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 10, minute: 0))!
func at(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    let base = calendar.date(byAdding: .day, value: dayOffset, to: now)!
    return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base)!
}
let ownedBuddy = UUID()
let freeBuddy = UUID()
func item(_ id: String, _ source: WispScheduledSource, _ buddy: UUID?, _ run: Date) -> WispScheduledItem {
    WispScheduledItem(id: id, source: source, title: id, buddyID: buddy, nextRun: run)
}

// Merge: sorted soonest first; a buddy owned by an automation is dropped, a free one stays.
let merged = WispScheduledPolicy.merged(
    automationItems: [item("automation-brief", .automation, ownedBuddy, at(1, 8))],
    buddyItems: [item("buddy-owned", .buddy, ownedBuddy, at(0, 12)), item("buddy-free", .buddy, freeBuddy, at(0, 15))],
    workflowItems: [item("workflow-weekly", .workflow, nil, at(0, 11))],
    buddyIDsOwnedByAutomations: [ownedBuddy]
).map(\.id)
check(merged == ["workflow-weekly", "buddy-free", "automation-brief"], "merged was \(merged)")

// Ties break by id.
let tied = WispScheduledPolicy.merged(
    automationItems: [item("b", .automation, nil, at(0, 12)), item("a", .automation, nil, at(0, 12))],
    buddyItems: [], workflowItems: [], buddyIDsOwnedByAutomations: []
).map(\.id)
check(tied == ["a", "b"], "tie was \(tied)")

// Grouping: Today / Tomorrow / Later, empty groups skipped.
let groups = WispScheduledPolicy.grouped([
    item("t", .automation, nil, at(0, 11)),
    item("m", .automation, nil, at(1, 9)),
    item("l", .automation, nil, at(5, 9)),
], now: now, calendar: calendar)
check(groups.map(\.day) == [.today, .tomorrow, .later], "days were \(groups.map(\.day))")
let noTomorrow = WispScheduledPolicy.grouped([item("t", .automation, nil, at(0, 11)), item("l", .automation, nil, at(3, 9))], now: now, calendar: calendar)
check(noTomorrow.map(\.day) == [.today, .later], "skip empty was \(noTomorrow.map(\.day))")
check(WispScheduledPolicy.grouped([], now: now, calendar: calendar).isEmpty, "empty")

// Workflow time: later today if still ahead, otherwise tomorrow; garbage is nil.
check(WispScheduledPolicy.nextDailyRun(timeText: "15:30", after: now, calendar: calendar) == at(0, 15, 30), "15:30 later today")
check(WispScheduledPolicy.nextDailyRun(timeText: "09:00", after: now, calendar: calendar) == at(1, 9), "09:00 tomorrow")
check(WispScheduledPolicy.nextDailyRun(timeText: "10:00", after: now, calendar: calendar) == at(1, 10), "same minute is strictly after")
check(WispScheduledPolicy.nextDailyRun(timeText: "25:00", after: now, calendar: calendar) == nil, "bad hour")
check(WispScheduledPolicy.nextDailyRun(timeText: "soon", after: now, calendar: calendar) == nil, "bad text")

if failures == 0 { print("WispScheduled: all checks passed") } else { exit(1) }
