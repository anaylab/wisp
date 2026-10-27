//
//  AutomationMigrationRunner.swift
//  leanring-buddy
//
//  The app half of the Routines / buddy jobs / Jobs -> Automations move. It builds a snapshot
//  from the old stores' in-memory arrays, asks `AutomationMigrationPlanner` what should exist,
//  and adds that to `AutomationStore`.
//
//  Read-only on the old data: it never edits or deletes a routine, a buddy or a Jobs setting,
//  and never touches their files (the starter buddies are seeded only when a Jobs automation is
//  planned, because the Planner buddy must exist to own it). Incremental by `legacyOrigin` (and by
//  `automation-migration.json`, so an automation the user deleted does not come back), and safe
//  to run at every launch.
//
//  One side effect on purpose: a buddy whose job is now an automation is listed in
//  `BuddyStore.buddyIDsWhoseSchedulesAreOwnedByAutomations`, so the old minute scheduler stops
//  running that job a second time.
//

import Foundation

@MainActor
enum AutomationMigrationRunner {
    static let stateFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Wisp/automation-migration.json")

    static func migrateIfNeeded(
        automationStore: AutomationStore? = nil,
        routineStore: RoutineStore? = nil,
        buddyStore: BuddyStore? = nil,
        jobsEngine: JobsEngine? = nil,
        stateFileURL: URL? = nil,
        now: Date = Date()
    ) {
        let automationStore = automationStore ?? AutomationStore.shared
        let routineStore = routineStore ?? RoutineStore.shared
        let buddyStore = buddyStore ?? BuddyStore.shared
        let jobsEngine = jobsEngine ?? JobsEngine.shared
        let stateFileURL = stateFileURL ?? Self.stateFileURL

        var migrationState = AutomationMigrationState.load(from: stateFileURL)
        let originsAlreadyInStore = Set(automationStore.automations.compactMap(\.legacyOrigin))

        let snapshot = AutomationLegacySnapshot(
            routines: routineStore.routines.map { routine in
                WispRoutineSnapshot(
                    id: routine.id,
                    name: routine.name,
                    instruction: routine.instruction,
                    symbolName: routine.symbolName,
                    shortcutDigit: routine.shortcutDigit,
                    lastParameterValues: routine.lastParameterValues
                )
            },
            // The three starter buddies' job text is a description, not a standing job.
            buddies: buddyStore.buddies.filter { $0.starterKind == nil }.map { buddy in
                WispBuddySnapshot(
                    id: buddy.id,
                    name: buddy.name,
                    instruction: buddy.instruction,
                    schedule: AutomationLegacyBuddySchedule(buddy.schedule),
                    notifiesWhenFinished: buddy.notifiesWhenFinished
                )
            },
            jobsCanvasEnabled: jobsEngine.isCanvasJobEnabled,
            jobsCanvasFeedExists: jobsEngine.hasCanvasFeed,
            jobsDailyChecklistEnabled: jobsEngine.isDailyChecklistEnabled,
            alreadyMigrated: migrationState.migratedOrigins.union(originsAlreadyInStore)
        )

        let plannedAutomations = AutomationMigrationPlanner.plan(
            from: snapshot,
            plannerBuddyID: StarterBuddyDefinition.plannerBuddyID,
            now: now
        )
        // The Planner owns the two Jobs automations, so it must exist before they are added. Seeding
        // the starter buddies rewrites buddies.json, so do it only when one of them is actually planned.
        if plannedAutomations.contains(where: { $0.buddyID == StarterBuddyDefinition.plannerBuddyID }) {
            buddyStore.ensureStarterBuddies()
        }
        for plannedAutomation in plannedAutomations {
            automationStore.add(plannedAutomation)
            if let legacyOrigin = plannedAutomation.legacyOrigin {
                migrationState.migratedOrigins.insert(legacyOrigin)
            }
        }
        if !plannedAutomations.isEmpty {
            do {
                try migrationState.save(to: stateFileURL)
            } catch {
                print("⚠️ Automations: could not save the migration state: \(error)")
            }
        }

        // Only a buddy job whose automation still exists is owned by it. `migratedOrigins` also
        // remembers automations the user deleted; those buddies go back to the old scheduler.
        let originsInStoreNow = Set(automationStore.automations.compactMap(\.legacyOrigin))
        var buddyIDsOwnedByAutomations: Set<UUID> = []
        for case .buddyJob(let buddyID) in originsInStoreNow {
            if let buddy = buddyStore.buddy(withID: buddyID), buddy.schedule.isRepeating {
                buddyIDsOwnedByAutomations.insert(buddyID)
            }
        }
        buddyStore.buddyIDsWhoseSchedulesAreOwnedByAutomations = buddyIDsOwnedByAutomations
    }
}

extension AutomationLegacyBuddySchedule {
    /// Mirrors a `BuddySchedule` into plain values the pure planner understands.
    init(_ buddySchedule: BuddySchedule) {
        switch buddySchedule {
        case .once:
            self = .once
        case .daily(let hour, let minute):
            self = .daily(hour: hour, minute: minute)
        case .weekly(let weekday, let hour, let minute):
            self = .weekly(weekday: weekday, hour: hour, minute: minute)
        }
    }
}

extension AutomationSchedule {
    /// Contract form: daily and weekly buddy schedules map across; `.once` is not a schedule.
    init?(legacy buddySchedule: BuddySchedule) {
        self.init(legacy: AutomationLegacyBuddySchedule(buddySchedule))
    }
}
