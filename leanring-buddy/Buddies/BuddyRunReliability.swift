//
//  BuddyRunReliability.swift
//  leanring-buddy
//
//  The pure rules for keeping a buddy's automation dependable and explainable:
//  why each run started (`BuddyRunReason`, kept in a short per-buddy trail), what
//  to do about a slot that was missed while Wisp was closed
//  (`BuddyCatchUpPolicy`), when a failed scheduled run is tried again, and when a
//  buddy that keeps failing is paused instead of failing forever
//  (`BuddyRunReliabilityPolicy`). `BuddyStore` applies these; nothing here
//  touches the registry, the clock or the disk, so it is all testable.
//

import Foundation

/// Why a run started — shown in the buddy's run trail.
enum BuddyRunReason: String, Codable, Equatable {
    /// Its schedule came due on time.
    case scheduled
    /// Its schedule came due while Wisp was closed or the Mac slept, and it ran once on return.
    case catchUp
    /// An earlier scheduled run failed and this is the automatic retry.
    case retry
    /// One of its event triggers fired (`BuddyTrigger`). Not retried: a retry would
    /// run the job without the event that started it.
    case triggered
    /// A step of a pipeline (`BuddyPipeline`). Not retried here: the pipeline owns failure.
    case pipeline
    /// The user pressed Run now (or the buddy was just created).
    case manual
    /// The user sent the buddy a message.
    case message
    /// Another buddy asked for it (`ask_buddy`).
    case delegated

    /// Whether a failure of this kind of run counts toward retrying and pausing.
    /// A run the user or a peer started is theirs to read; only the buddy's own
    /// automation is retried or paused.
    var isAutomatic: Bool {
        switch self {
        case .scheduled, .catchUp, .retry: return true
        case .triggered, .pipeline, .manual, .message, .delegated: return false
        }
    }

    var title: String {
        switch self {
        case .scheduled: return "On schedule"
        case .catchUp: return "Catching up"
        case .retry: return "Retry"
        case .triggered: return "Trigger"
        case .pipeline: return "Pipeline step"
        case .manual: return "Run now"
        case .message: return "Your message"
        case .delegated: return "Asked by a buddy"
        }
    }
}

/// One line of a buddy's run trail: which run, and why it started.
struct BuddyRunLogEntry: Codable, Equatable, Identifiable {
    /// The run's background task id — also its identity, matching `BuddyThreadExchange`.
    let taskID: UUID
    let reason: BuddyRunReason
    let startedAt: Date
    /// For scheduled and catch-up runs, the slot this run was for.
    var dueAt: Date?
    /// For a retry, which attempt this is (1 = the first retry).
    var retryAttempt: Int?
    /// For a triggered run, what fired it ("New file in Downloads").
    var detail: String?

    var id: UUID { taskID }
}

/// What a repeating buddy does about a slot it missed (Wisp closed, Mac asleep).
enum BuddyCatchUpPolicy: String, Codable, CaseIterable, Equatable {
    /// Run once when Wisp is back, however many slots were missed. The long-standing behaviour.
    case runOnce
    /// Wait for the next slot; a stale morning digest at 4pm helps nobody.
    case skipMissed

    var title: String {
        switch self {
        case .runOnce: return "Run once when Wisp is back"
        case .skipMissed: return "Skip, wait for the next one"
        }
    }
}

/// A buddy's running tally of how its automatic runs are going.
struct BuddyAutomationState: Codable, Equatable {
    /// Slots in a row that failed even after their retries.
    var consecutiveFailedSlots = 0
    /// Retries already used for the slot in progress.
    var retryAttempt = 0
    /// When the next automatic retry is due; nil when none is waiting.
    var nextRetryAt: Date?
    /// Set when the buddy was paused after too many failures; nil while active.
    var pausedReason: String?
    /// The last finished run already counted, so a run is never counted twice.
    var lastAccountedTaskID: UUID?
    /// The failure the paused reason is about, kept for the buddy's page.
    var lastFailureMessage: String?
}

enum BuddyRunReliabilityPolicy {
    /// Retries after a failed automatic run, then the slot is given up on.
    static let maximumRetries = 2
    /// Wait before the first and second retry.
    static let retryDelaySeconds: [TimeInterval] = [5 * 60, 15 * 60]
    /// Slots in a row that fail (retries included) before the buddy is paused.
    static let pauseAfterConsecutiveFailedSlots = 3
    /// A due slot this late was missed rather than merely checked a little late.
    /// The check runs once a minute with a tolerance, so a slot minutes late is still on time.
    static let onTimeToleranceSeconds: TimeInterval = 5 * 60

    enum DueDecision: Equatable {
        case run(BuddyRunReason)
        /// Don't run; just move on to the next slot.
        case skip
    }

    /// What to do with a schedule slot that is due at `now`.
    static func dueDecision(dueAt: Date, now: Date, catchUpPolicy: BuddyCatchUpPolicy) -> DueDecision {
        if now.timeIntervalSince(dueAt) <= onTimeToleranceSeconds { return .run(.scheduled) }
        switch catchUpPolicy {
        case .runOnce: return .run(.catchUp)
        case .skipMissed: return .skip
        }
    }

    enum Event: Equatable {
        case none
        /// A retry was scheduled for this attempt number (1-based).
        case retryScheduled(attempt: Int, at: Date)
        /// The slot failed for good but the buddy is still active.
        case slotFailed
        /// The buddy was paused after repeated failures.
        case autoPaused(reason: String)
    }

    /// The state after a finished run, and the event the store may want to surface.
    /// `failureMessage` is the failed run's reason, when it has one.
    static func stateAfterRun(
        status: AgentTaskRecord.Status,
        reason: BuddyRunReason,
        taskID: UUID,
        state previousState: BuddyAutomationState,
        now: Date
    ) -> (state: BuddyAutomationState, event: Event) {
        var state = previousState
        state.lastAccountedTaskID = taskID

        switch status {
        case .running, .waitingForApproval:
            // Not finished; the caller shouldn't ask, but never count it.
            state.lastAccountedTaskID = previousState.lastAccountedTaskID
            return (state, .none)

        case .succeeded:
            // Any success, even a manual one, shows the buddy works again.
            return (BuddyAutomationState(lastAccountedTaskID: taskID), .none)

        case .cancelled, .interrupted:
            // Stopping a run or quitting Wisp isn't a failure, and a pending retry
            // for a run the user stopped would just undo that.
            state.nextRetryAt = nil
            return (state, .none)

        case .failed(let failureMessage):
            guard reason.isAutomatic else { return (state, .none) }
            state.lastFailureMessage = failureMessage

            if state.retryAttempt < maximumRetries {
                state.retryAttempt += 1
                let retryDelay = retryDelaySeconds[min(state.retryAttempt - 1, retryDelaySeconds.count - 1)]
                let retryAt = now.addingTimeInterval(retryDelay)
                state.nextRetryAt = retryAt
                return (state, .retryScheduled(attempt: state.retryAttempt, at: retryAt))
            }

            state.retryAttempt = 0
            state.nextRetryAt = nil
            state.consecutiveFailedSlots += 1
            if state.consecutiveFailedSlots >= pauseAfterConsecutiveFailedSlots {
                let pausedReason = "Paused after \(state.consecutiveFailedSlots) failed runs in a row"
                state.pausedReason = pausedReason
                return (state, .autoPaused(reason: pausedReason))
            }
            return (state, .slotFailed)
        }
    }

    /// A new schedule slot supersedes a retry still waiting for the previous one.
    static func stateEnteringNewSlot(_ state: BuddyAutomationState) -> BuddyAutomationState {
        var newState = state
        newState.retryAttempt = 0
        newState.nextRetryAt = nil
        return newState
    }

    /// The user resumed a paused buddy: clear the pause and the failure streak.
    static func stateAfterResume(_ state: BuddyAutomationState) -> BuddyAutomationState {
        BuddyAutomationState(lastAccountedTaskID: state.lastAccountedTaskID)
    }

    /// The trail kept per buddy: newest last, the same length as the runs it remembers.
    static func trimmedLog(_ log: [BuddyRunLogEntry], limit: Int) -> [BuddyRunLogEntry] {
        log.count > limit ? Array(log.suffix(limit)) : log
    }
}
