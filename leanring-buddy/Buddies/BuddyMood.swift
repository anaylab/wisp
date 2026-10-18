//
//  BuddyMood.swift
//  leanring-buddy
//
//  How a buddy feels right now, derived from what it is doing so its face tells
//  the story without reading anything: working while a run is on, happy for a
//  moment after it lands, worried after a failure, wide-eyed when it needs the
//  user's ok, sleepy after a long quiet spell. Pure and time-injected so it is
//  tested without the app.
//

import Foundation

nonisolated enum BuddyMood: Equatable, Sendable {
    case idle
    case working
    /// Just finished something. Fades back to `.idle` (see `happyDurationSeconds`).
    case happy
    case sleepy
    /// The last run failed.
    case oops
    /// Waiting for the user to approve something.
    case waiting
}

enum BuddyMoodPolicy {
    /// How long a success keeps the buddy beaming.
    static let happyDurationSeconds: TimeInterval = 25
    /// How long a failure keeps it worried, unless the user has since looked.
    static let oopsDurationSeconds: TimeInterval = 600
    /// Quiet for this long and the buddy dozes off.
    static let sleepyAfterSeconds: TimeInterval = 6 * 3600

    static func mood(
        latestRunStatus: AgentTaskRecord.Status?,
        latestRunFinishedAt: Date?,
        lastActivityAt: Date,
        now: Date
    ) -> BuddyMood {
        switch latestRunStatus {
        case .running:
            return .working
        case .waitingForApproval:
            return .waiting
        case .succeeded:
            if let latestRunFinishedAt, now.timeIntervalSince(latestRunFinishedAt) < happyDurationSeconds {
                return .happy
            }
        case .failed:
            if let latestRunFinishedAt, now.timeIntervalSince(latestRunFinishedAt) < oopsDurationSeconds {
                return .oops
            }
        case .cancelled, .interrupted, nil:
            break
        }
        return now.timeIntervalSince(lastActivityAt) > sleepyAfterSeconds ? .sleepy : .idle
    }
}
