//
//  BuddyReliabilityTests.swift
//  AgentRuntimeIntegration
//
//  Run reliability for buddies: the pure policy (catch-up, retry, auto-pause)
//  and the store applying it — a failed scheduled run is retried and then
//  given up on, repeated failures pause the buddy, a missed slot is run once
//  or skipped as chosen, "pause all" holds every schedule without saving up a
//  burst, and every run records why it started.
//

import Foundation

@MainActor func buddyRunReliabilitySuite() {
    section("Buddy reliability: catch-up decision")
    do {
        let dueAt = Date(timeIntervalSince1970: 1_000_000)
        func decision(late: TimeInterval, _ policy: BuddyCatchUpPolicy) -> BuddyRunReliabilityPolicy.DueDecision {
            BuddyRunReliabilityPolicy.dueDecision(dueAt: dueAt, now: dueAt.addingTimeInterval(late), catchUpPolicy: policy)
        }
        check("a slot checked seconds late is on time", decision(late: 20, .skipMissed) == .run(.scheduled))
        check("a slot a few minutes late is still on time", decision(late: 4 * 60, .runOnce) == .run(.scheduled))
        check("a missed slot runs once when asked to", decision(late: 3 * 3600, .runOnce) == .run(.catchUp))
        check("a missed slot is skipped when asked to", decision(late: 3 * 3600, .skipMissed) == .skip)
    }

    section("Buddy reliability: retry and pause policy")
    do {
        let now = Date(timeIntervalSince1970: 2_000_000)
        func after(_ status: AgentTaskRecord.Status, _ reason: BuddyRunReason, _ state: BuddyAutomationState) -> (state: BuddyAutomationState, event: BuddyRunReliabilityPolicy.Event) {
            BuddyRunReliabilityPolicy.stateAfterRun(status: status, reason: reason, taskID: UUID(), state: state, now: now)
        }

        let firstFailure = after(.failed("boom"), .scheduled, BuddyAutomationState())
        check("a failed scheduled run schedules a retry in 5 minutes",
              firstFailure.event == .retryScheduled(attempt: 1, at: now.addingTimeInterval(300))
              && firstFailure.state.nextRetryAt == now.addingTimeInterval(300))
        check("the failure counts as nothing yet", firstFailure.state.consecutiveFailedSlots == 0)

        let secondFailure = after(.failed("boom"), .retry, firstFailure.state)
        check("the second retry waits 15 minutes", secondFailure.event == .retryScheduled(attempt: 2, at: now.addingTimeInterval(900)))

        let giveUp = after(.failed("boom"), .retry, secondFailure.state)
        check("after the retries the slot is given up on", giveUp.event == .slotFailed && giveUp.state.consecutiveFailedSlots == 1)
        check("giving up clears the pending retry", giveUp.state.nextRetryAt == nil && giveUp.state.retryAttempt == 0)

        var slotState = giveUp.state
        var lastEvent = giveUp.event
        for _ in 0..<2 {
            for _ in 0...BuddyRunReliabilityPolicy.maximumRetries {
                let step = after(.failed("boom"), .scheduled, slotState)
                slotState = step.state
                lastEvent = step.event
            }
        }
        check("three failed slots in a row pause the buddy",
              slotState.pausedReason != nil && slotState.consecutiveFailedSlots == 3
              && lastEvent == .autoPaused(reason: "Paused after 3 failed runs in a row"))

        let afterSuccess = after(.succeeded, .manual, slotState).state
        check("a success clears the streak and the pause",
              afterSuccess.pausedReason == nil && afterSuccess.consecutiveFailedSlots == 0
              && afterSuccess.retryAttempt == 0 && afterSuccess.nextRetryAt == nil)
        check("a failed manual run is not retried or counted",
              after(.failed("x"), .manual, BuddyAutomationState()).event == .none
              && after(.failed("x"), .message, BuddyAutomationState()).state.consecutiveFailedSlots == 0)
        check("a stopped run cancels a pending retry and counts as nothing",
              after(.cancelled, .scheduled, firstFailure.state).state.nextRetryAt == nil
              && after(.interrupted, .scheduled, BuddyAutomationState()).state.consecutiveFailedSlots == 0)
        check("a new slot supersedes a waiting retry",
              BuddyRunReliabilityPolicy.stateEnteringNewSlot(firstFailure.state).nextRetryAt == nil
              && BuddyRunReliabilityPolicy.stateEnteringNewSlot(firstFailure.state).retryAttempt == 0)
        check("resuming clears the pause", BuddyRunReliabilityPolicy.stateAfterResume(slotState).pausedReason == nil)
        check("the trail keeps the newest entries",
              BuddyRunReliabilityPolicy.trimmedLog((0..<5).map { index in
                  BuddyRunLogEntry(taskID: UUID(), reason: .scheduled, startedAt: Date(timeIntervalSince1970: Double(index)))
              }, limit: 3).first?.startedAt == Date(timeIntervalSince1970: 2))
    }

    section("Buddy reliability: the store applies it")
    do {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-reliability-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "buddy-reliability-\(UUID().uuidString)")!
        let registry = AgentTaskRegistry.shared

        let store = BuddyStore(buddiesFileURL: sandbox.appendingPathComponent("buddies.json"), userDefaults: defaults)
        var startedTaskIDs: [UUID] = []
        store.start { _, _ in
            let taskID = registry.beginTask(title: "Buddy · test", kind: .background)
            startedTaskIDs.append(taskID)
            return taskID
        }

        let buddy = store.createBuddy(instruction: "check the build", schedule: .daily(hour: 9, minute: 0), runImmediately: false)
        let dueAt = store.buddy(withID: buddy.id)!.nextScheduledRunAt!
        func currentBuddy() -> WispBuddy { store.buddy(withID: buddy.id)! }

        // On time: runs as scheduled and moves to the next slot.
        store.runDueBuddies(now: dueAt.addingTimeInterval(20))
        check("a due slot starts a run", startedTaskIDs.count == 1)
        check("the run records that it was scheduled", currentBuddy().runLog?.last?.reason == .scheduled && currentBuddy().runLog?.last?.dueAt == dueAt)
        check("the schedule moved to the next slot", currentBuddy().nextScheduledRunAt! > dueAt)

        // It fails: the next pass schedules a retry, and a pass before then waits.
        registry.finishTask(startedTaskIDs[0], status: .failed("network down"))
        let failureSeenAt = dueAt.addingTimeInterval(80)
        store.runDueBuddies(now: failureSeenAt)
        check("a failed scheduled run waits for a retry", currentBuddy().automationState?.retryAttempt == 1
              && currentBuddy().automationState?.nextRetryAt == failureSeenAt.addingTimeInterval(300))
        store.runDueBuddies(now: failureSeenAt.addingTimeInterval(120))
        check("it doesn't retry early", startedTaskIDs.count == 1)
        store.runDueBuddies(now: failureSeenAt.addingTimeInterval(310))
        check("it retries when the wait is over", startedTaskIDs.count == 2 && currentBuddy().runLog?.last?.reason == .retry
              && currentBuddy().runLog?.last?.retryAttempt == 1)

        // The retry succeeds: everything resets.
        registry.finishTask(startedTaskIDs[1], status: .succeeded, finalText: "ok")
        store.runDueBuddies(now: failureSeenAt.addingTimeInterval(400))
        check("a success resets the tally", currentBuddy().automationState == BuddyAutomationState(lastAccountedTaskID: startedTaskIDs[1]))

        // Pause all: the slot is moved past, not saved up; manual runs still work.
        store.setAllAutomationsPaused(true)
        check("pause-all persists", defaults.bool(forKey: "BuddyAllAutomationsPaused"))
        let secondSlot = currentBuddy().nextScheduledRunAt!
        store.runDueBuddies(now: secondSlot.addingTimeInterval(30))
        check("nothing runs while all automation is paused", startedTaskIDs.count == 2)
        check("the paused slot is moved past", currentBuddy().nextScheduledRunAt! > secondSlot)
        check("a manual run still works while paused", store.runNow(buddyWithID: buddy.id) && startedTaskIDs.count == 3
              && currentBuddy().runLog?.last?.reason == .manual)
        registry.finishTask(startedTaskIDs[2], status: .succeeded, finalText: "ok")
        store.setAllAutomationsPaused(false)

        // Missed slots follow the buddy's catch-up policy.
        store.runDueBuddies(now: Date(timeIntervalSince1970: 0))   // account for the manual run
        let thirdSlot = currentBuddy().nextScheduledRunAt!
        store.updateCatchUpPolicy(ofBuddyWithID: buddy.id, to: .skipMissed)
        check("skip-missed is stored", currentBuddy().catchUpPolicy == .skipMissed)
        store.runDueBuddies(now: thirdSlot.addingTimeInterval(3 * 3600))
        check("a missed slot is skipped", startedTaskIDs.count == 3 && currentBuddy().nextScheduledRunAt! > thirdSlot)

        store.updateCatchUpPolicy(ofBuddyWithID: buddy.id, to: .runOnce)
        check("run-once is the default and stores nothing", currentBuddy().catchUpPolicy == nil)
        let fourthSlot = currentBuddy().nextScheduledRunAt!
        store.runDueBuddies(now: fourthSlot.addingTimeInterval(3 * 3600))
        check("a missed slot runs once as a catch-up", startedTaskIDs.count == 4 && currentBuddy().runLog?.last?.reason == .catchUp)
        registry.finishTask(startedTaskIDs[3], status: .succeeded, finalText: "ok")

        // Repeated failures pause the buddy until resumed. A slot is the scheduled
        // run plus its retries, all failing.
        func failLatestRun() {
            if let latestTaskID = startedTaskIDs.last { registry.finishTask(latestTaskID, status: .failed("still down")) }
        }
        var clock = currentBuddy().nextScheduledRunAt!
        for _ in 0..<BuddyRunReliabilityPolicy.pauseAfterConsecutiveFailedSlots {
            clock = currentBuddy().nextScheduledRunAt!.addingTimeInterval(10)
            store.runDueBuddies(now: clock)                       // the scheduled run starts
            for _ in 0...BuddyRunReliabilityPolicy.maximumRetries {
                failLatestRun()
                clock = clock.addingTimeInterval(60)
                store.runDueBuddies(now: clock)                   // the failure is counted; a retry is scheduled
                clock = clock.addingTimeInterval(1000)
                store.runDueBuddies(now: clock)                   // the retry starts
            }
        }
        check("repeated failures pause the buddy", currentBuddy().isAutomationPausedAfterFailures,
              "state: \(String(describing: currentBuddy().automationState))")
        check("a paused buddy counts as needing attention", store.buddiesNeedingAttentionCount() >= 1)
        let runsWhilePaused = startedTaskIDs.count
        clock = currentBuddy().nextScheduledRunAt!.addingTimeInterval(10)
        store.runDueBuddies(now: clock)
        check("a paused buddy doesn't run on its schedule", startedTaskIDs.count == runsWhilePaused)
        store.resumeAutomation(ofBuddyWithID: buddy.id)
        check("resuming clears the pause", !currentBuddy().isAutomationPausedAfterFailures)

        // An older buddies.json without any of this still loads.
        let legacyJSON = """
        [{"id":"\(UUID().uuidString)","name":"Old","instruction":"x","colorIndex":1,"schedule":{"once":{}},"createdAt":"2026-01-01T00:00:00Z","runTaskIDs":[]}]
        """
        let legacyURL = sandbox.appendingPathComponent("legacy.json")
        try? legacyJSON.write(to: legacyURL, atomically: true, encoding: .utf8)
        let legacy = BuddyStore(buddiesFileURL: legacyURL, userDefaults: defaults).buddies
        check("a buddy saved before reliability still loads", legacy.count == 1 && legacy[0].runLog == nil && legacy[0].automationState == nil)
    }
}
