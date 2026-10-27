//
//  AutomationMigration.swift
//  leanring-buddy
//
//  The pure planning half of the one-time move from Routines, buddy jobs and Jobs to
//  Automations. It reads nothing and writes nothing: it turns a snapshot of the old data into the
//  automations that should exist. `AutomationMigrationRunner` (the app half) builds the snapshot
//  from the old stores' in-memory arrays and applies the plan.
//
//  Rules (see docs/fun-glass-contracts.md 4.7): old records are never edited or deleted, the plan
//  is incremental by `legacyOrigin` (planning twice gives nothing the second time), and a missing
//  or unreadable old store is simply an empty list.
//
//  Pure (Foundation only).
//

import Foundation

nonisolated struct WispRoutineSnapshot: Equatable, Sendable {
    let id: UUID
    let name: String
    let instruction: String
    let symbolName: String
    let shortcutDigit: Int?
    let lastParameterValues: [String: String]?
}

nonisolated struct WispBuddySnapshot: Equatable, Sendable {
    let id: UUID
    let name: String
    let instruction: String
    let schedule: AutomationLegacyBuddySchedule
    let notifiesWhenFinished: Bool?
}

nonisolated struct AutomationLegacySnapshot: Equatable, Sendable {
    var routines: [WispRoutineSnapshot]
    var buddies: [WispBuddySnapshot]
    /// JobsEngine's Canvas switch (`isCanvasJobEnabled`).
    var jobsCanvasEnabled: Bool
    /// Whether a Canvas link is saved. Without one there is no Canvas job to migrate.
    var jobsCanvasFeedExists: Bool
    /// JobsEngine's checklist switch (`isDailyChecklistEnabled`).
    var jobsDailyChecklistEnabled: Bool
    var alreadyMigrated: Set<AutomationLegacyOrigin>

    init(
        routines: [WispRoutineSnapshot] = [],
        buddies: [WispBuddySnapshot] = [],
        jobsCanvasEnabled: Bool = true,
        jobsCanvasFeedExists: Bool = false,
        jobsDailyChecklistEnabled: Bool = true,
        alreadyMigrated: Set<AutomationLegacyOrigin> = []
    ) {
        self.routines = routines
        self.buddies = buddies
        self.jobsCanvasEnabled = jobsCanvasEnabled
        self.jobsCanvasFeedExists = jobsCanvasFeedExists
        self.jobsDailyChecklistEnabled = jobsDailyChecklistEnabled
        self.alreadyMigrated = alreadyMigrated
    }
}

nonisolated enum AutomationMigrationPlanner {
    /// Legacy snapshot -> automations to add. Skips anything in `alreadyMigrated`.
    static func plan(from snapshot: AutomationLegacySnapshot, plannerBuddyID: UUID, now: Date) -> [Automation] {
        var plannedAutomations: [Automation] = []

        // Routines: manual automations. The owner is left nil so the store picks the day's buddy.
        for routine in snapshot.routines {
            let origin = AutomationLegacyOrigin.routine(routine.id)
            guard !snapshot.alreadyMigrated.contains(origin) else { continue }
            plannedAutomations.append(Automation(
                name: routine.name,
                buddyID: nil,
                trigger: .manual,
                source: .nothing,
                action: .askBuddy(instruction: routine.instruction),
                outputs: [.notchCard],
                notify: .never,
                symbolName: routine.symbolName,
                shortcutDigit: routine.shortcutDigit,
                parameterValues: routine.lastParameterValues,
                createdAt: now,
                legacyOrigin: origin
            ))
        }

        // Buddy jobs: a repeating one becomes a scheduled automation on that buddy; a "once"
        // one (run when asked) becomes manual.
        for buddy in snapshot.buddies {
            let origin = AutomationLegacyOrigin.buddyJob(buddy.id)
            guard !snapshot.alreadyMigrated.contains(origin) else { continue }
            let trigger: AutomationTrigger
            if let schedule = AutomationSchedule(legacy: buddy.schedule) {
                trigger = .schedule(schedule)
            } else {
                trigger = .manual
            }
            plannedAutomations.append(Automation(
                name: buddy.name,
                buddyID: buddy.id,
                trigger: trigger,
                source: .nothing,
                action: .askBuddy(instruction: buddy.instruction),
                outputs: [.buddyThreadMessage, .notchCard],
                notify: buddy.notifiesWhenFinished == false ? .never : .always,
                symbolName: "sparkles",
                createdAt: now,
                legacyOrigin: origin
            ))
        }

        // Jobs: the Planner's two automations. Both are views onto JobsEngine's own timers, so
        // the schedule here is for display only and the engine never schedules them again.
        if snapshot.jobsCanvasFeedExists, !snapshot.alreadyMigrated.contains(.jobsCanvas) {
            plannedAutomations.append(Automation(
                name: "Canvas deadlines",
                buddyID: plannerBuddyID,
                trigger: .schedule(AutomationSchedule(recurrence: .daily, hour: 7, minute: 0)),
                source: .nothing,
                action: .syncCanvas,
                outputs: [.notchCard],
                notify: .onlyWhenSomethingNew,
                isEnabled: snapshot.jobsCanvasEnabled,
                symbolName: "graduationcap",
                createdAt: now,
                legacyOrigin: .jobsCanvas
            ))
        }
        if !snapshot.alreadyMigrated.contains(.jobsDailyChecklist) {
            plannedAutomations.append(Automation(
                name: "Daily checklist",
                buddyID: plannerBuddyID,
                trigger: .schedule(AutomationSchedule(recurrence: .daily, hour: 7, minute: 30)),
                source: .nothing,
                action: .buildDailyChecklist,
                outputs: [.remindersChecklist(listTitle: AutomationOutput.defaultChecklistListTitle)],
                notify: .onlyWhenSomethingNew,
                isEnabled: snapshot.jobsDailyChecklistEnabled,
                symbolName: "checklist",
                createdAt: now,
                legacyOrigin: .jobsDailyChecklist
            ))
        }
        return plannedAutomations
    }
}

/// Which legacy records have been migrated, so a deleted automation does not come back at the
/// next launch. `~/Library/Application Support/Wisp/automation-migration.json`. A missing or
/// unreadable file reads as "nothing migrated yet".
nonisolated struct AutomationMigrationState: Codable, Equatable, Sendable {
    var migratedOrigins: Set<AutomationLegacyOrigin> = []

    static func load(from fileURL: URL) -> AutomationMigrationState {
        guard let fileData = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(AutomationMigrationState.self, from: fileData) else {
            return AutomationMigrationState()
        }
        return state
    }

    func save(to fileURL: URL) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
