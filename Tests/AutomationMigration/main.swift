//
//  Automation migration suite: what the old Routines, buddy jobs and Jobs become, that planning
//  is incremental (no doubles), and that a missing or unreadable old file is just "nothing".
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

let now = Date(timeIntervalSince1970: 1_800_000_000)
let plannerBuddyID = UUID()

let routine = WispRoutineSnapshot(
    id: UUID(), name: "Summarize this page", instruction: "Summarize the page on my screen.",
    symbolName: "text.alignleft", shortcutDigit: 1, lastParameterValues: ["topic": "ai"]
)
let dailyBuddy = WispBuddySnapshot(id: UUID(), name: "Gmail Digest", instruction: "Summarize my Gmail every morning", schedule: .daily(hour: 9, minute: 0), notifiesWhenFinished: nil)
let weeklyBuddy = WispBuddySnapshot(id: UUID(), name: "Weekly Scout", instruction: "Find what's new", schedule: .weekly(weekday: 2, hour: 8, minute: 30), notifiesWhenFinished: false)
let onceBuddy = WispBuddySnapshot(id: UUID(), name: "Research Helper", instruction: "Look into X", schedule: .once, notifiesWhenFinished: true)

let snapshot = AutomationLegacySnapshot(
    routines: [routine],
    buddies: [dailyBuddy, weeklyBuddy, onceBuddy],
    jobsCanvasEnabled: true,
    jobsCanvasFeedExists: true,
    jobsDailyChecklistEnabled: false
)
let planned = AutomationMigrationPlanner.plan(from: snapshot, plannerBuddyID: plannerBuddyID, now: now)
check(planned.count == 6, "one automation per routine, per buddy, plus the two Jobs (got \(planned.count))")

func plannedAutomation(_ origin: AutomationLegacyOrigin) -> Automation? { planned.first { $0.legacyOrigin == origin } }

if let migratedRoutine = plannedAutomation(.routine(routine.id)) {
    check(migratedRoutine.trigger == .manual, "routine -> manual trigger")
    check(migratedRoutine.action == .askBuddy(instruction: routine.instruction), "routine -> askBuddy with its instruction")
    check(migratedRoutine.buddyID == nil, "routine -> no owner yet (the store assigns the day's buddy)")
    check(migratedRoutine.shortcutDigit == 1, "routine keeps its digit (informational)")
    check(migratedRoutine.parameterValues == ["topic": "ai"], "routine keeps its remembered blanks")
    check(migratedRoutine.outputs == [.notchCard] && migratedRoutine.notify == .never, "routine -> notch card, no notification")
    check(migratedRoutine.symbolName == "text.alignleft", "routine keeps its symbol")
    check(migratedRoutine.isValid, "migrated routine is valid")
} else {
    check(false, "routine should migrate")
}

if let migratedDaily = plannedAutomation(.buddyJob(dailyBuddy.id)) {
    check(migratedDaily.trigger == .schedule(AutomationSchedule(recurrence: .daily, hour: 9, minute: 0)), "daily buddy -> daily schedule")
    check(migratedDaily.buddyID == dailyBuddy.id, "buddy job stays on that buddy")
    check(migratedDaily.outputs == [.buddyThreadMessage, .notchCard], "buddy job -> thread message + notch card")
    check(migratedDaily.notify == .always, "notify default is always")
    check(migratedDaily.action == .askBuddy(instruction: dailyBuddy.instruction), "buddy job keeps its instruction")
} else {
    check(false, "daily buddy should migrate")
}
check(plannedAutomation(.buddyJob(weeklyBuddy.id))?.trigger == .schedule(AutomationSchedule(recurrence: .weekly(weekday: 2), hour: 8, minute: 30)), "weekly buddy -> weekly schedule")
check(plannedAutomation(.buddyJob(weeklyBuddy.id))?.notify == .never, "a buddy that did not notify stays quiet")
check(plannedAutomation(.buddyJob(onceBuddy.id))?.trigger == .manual, "once buddy -> manual")

if let canvas = plannedAutomation(.jobsCanvas) {
    check(canvas.action == .syncCanvas && canvas.buddyID == plannerBuddyID, "Canvas -> the Planner's syncCanvas")
    check(canvas.isEnabled, "Canvas mirrors the on switch")
    check(canvas.isDrivenByJobsEngine, "Canvas is driven by JobsEngine, never double scheduled")
} else {
    check(false, "Canvas should migrate when a feed exists")
}
if let checklist = plannedAutomation(.jobsDailyChecklist) {
    check(checklist.action == .buildDailyChecklist && checklist.buddyID == plannerBuddyID, "checklist -> the Planner's buildDailyChecklist")
    check(!checklist.isEnabled, "checklist mirrors the off switch")
    check(checklist.outputs == [.remindersChecklist(listTitle: "Wisp Today")], "checklist goes to Wisp Today")
    check(checklist.isDrivenByJobsEngine, "checklist is driven by JobsEngine")
} else {
    check(false, "checklist should migrate")
}
check(planned.allSatisfy { $0.isValid }, "every migrated automation is valid")

// No Canvas feed -> no Canvas automation.
let noFeedPlan = AutomationMigrationPlanner.plan(
    from: AutomationLegacySnapshot(jobsCanvasEnabled: true, jobsCanvasFeedExists: false),
    plannerBuddyID: plannerBuddyID, now: now
)
check(noFeedPlan.contains { $0.legacyOrigin == .jobsCanvas } == false, "no Canvas link: no Canvas automation")
check(noFeedPlan.contains { $0.legacyOrigin == .jobsDailyChecklist }, "the checklist job exists regardless")

// A paused Canvas job migrates paused.
let pausedCanvas = AutomationMigrationPlanner.plan(
    from: AutomationLegacySnapshot(jobsCanvasEnabled: false, jobsCanvasFeedExists: true),
    plannerBuddyID: plannerBuddyID, now: now
)
check(pausedCanvas.first { $0.legacyOrigin == .jobsCanvas }?.isEnabled == false, "a paused Canvas job migrates paused")

// MARK: - Round trip: plan, encode, decode, plan again = nothing

let encodedPlan = try! JSONEncoder().encode(planned)
let decodedPlan = try! JSONDecoder().decode([Automation].self, from: encodedPlan)
check(decodedPlan == planned, "the plan survives JSON")
var secondSnapshot = snapshot
secondSnapshot.alreadyMigrated = Set(decodedPlan.compactMap(\.legacyOrigin))
check(AutomationMigrationPlanner.plan(from: secondSnapshot, plannerBuddyID: plannerBuddyID, now: now).isEmpty, "planning again after migrating gives nothing")

// Incremental: a routine added later migrates alone.
let laterRoutine = WispRoutineSnapshot(id: UUID(), name: "Later", instruction: "Do later", symbolName: "bolt", shortcutDigit: nil, lastParameterValues: nil)
secondSnapshot.routines.append(laterRoutine)
let incrementalPlan = AutomationMigrationPlanner.plan(from: secondSnapshot, plannerBuddyID: plannerBuddyID, now: now)
check(incrementalPlan.count == 1 && incrementalPlan.first?.legacyOrigin == .routine(laterRoutine.id), "only the new routine migrates next time")

// MARK: - Missing or corrupt old data

check(AutomationMigrationPlanner.plan(from: AutomationLegacySnapshot(jobsDailyChecklistEnabled: true, alreadyMigrated: [.jobsDailyChecklist]), plannerBuddyID: plannerBuddyID, now: now).isEmpty, "an empty old world (missing files) plans nothing")

let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("automation-migration-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
let stateURL = temporaryDirectory.appendingPathComponent("automation-migration.json")

check(AutomationMigrationState.load(from: stateURL).migratedOrigins.isEmpty, "a missing state file reads as nothing migrated")
try! "{ this is not json".write(to: stateURL, atomically: true, encoding: .utf8)
check(AutomationMigrationState.load(from: stateURL).migratedOrigins.isEmpty, "a corrupt state file reads as nothing migrated, without crashing")

let savedState = AutomationMigrationState(migratedOrigins: [.routine(routine.id), .jobsCanvas, .buddyJob(dailyBuddy.id)])
try! savedState.save(to: stateURL)
check(AutomationMigrationState.load(from: stateURL) == savedState, "the migration state survives a save and load")
let stateAttributes = try! FileManager.default.attributesOfItem(atPath: stateURL.path)
check((stateAttributes[.posixPermissions] as? Int) == 0o600, "the state file is owner-only")

// The migrated data never holds a Canvas link or a secret.
let planText = String(data: encodedPlan, encoding: .utf8) ?? ""
check(!planText.lowercased().contains("http") && !planText.lowercased().contains("webcal"), "migrated automations never hold a link")

print("\(checkCount - failureCount)/\(checkCount) checks passed")
if failureCount > 0 {
    print("\(failureCount) FAILED")
    exit(1)
}
