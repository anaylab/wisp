//
//  BuddyRunLanes.swift
//  leanring-buddy
//
//  Which of a buddy's conversations may run at once, why a message is waiting,
//  and what a busy buddy does with a new message (phase 3 of
//  docs/openbot-buddies-plan.md).
//
//  Until now a buddy ran one thing at a time across all its threads: a long
//  job in the main thread held up a quick question in a side thread. Each
//  conversation is now a *lane*, as in OpenBot: the main thread is one, each
//  side thread and each group chat is another. One run per lane, and at most
//  `maximumParallelSideLanes` side lanes at once beside the main thread
//  (OpenBot's task limit, whose main chat doesn't count toward it either). The
//  background limit (`BackgroundTaskCapacityPolicy`) still applies above this.
//
//  A buddy's busy-message mode decides what a message sent to a busy lane
//  does. "Queue" (the default) waits for the run to finish. "Steer" hands it
//  to the run in progress at its next step: the agent loop adds it beside the
//  tool results (`AgentRunToolkit.takeSteeringMessages`, worded by `AgentRunSteering`). A run that answers
//  without another step never takes it, and it then runs next as queued.
//
//  Pure, so it is tested with plain swiftc (`Tests/BuddyRunLanes`).
//

import Foundation

/// What a message sent to a busy conversation does. Nil on a buddy is `.queue`.
nonisolated enum BuddyBusyMessageMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case queue
    case steer

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .queue: return "Wait for it to finish"
        case .steer: return "Join the run at its next step"
        }
    }
}

/// Why a waiting message hasn't started, for the line above the composer.
nonisolated enum BuddyRunHoldReason: Equatable, Sendable {
    /// The user paused the buddy's line.
    case paused
    /// This conversation already has a run; `steers` says it will take the
    /// message at its next step.
    case busyInThisConversation(steers: Bool)
    /// An earlier message for the same conversation goes first.
    case behindEarlierMessage
    /// The buddy already runs as many side conversations as it may.
    case sideLaneLimit(Int)
    /// Wisp's own limit on background work at once.
    case backgroundLimit
    /// The buddy is hidden; it starts nothing until it's shown again.
    case hidden

    var displayText: String {
        switch self {
        case .paused: return "Line paused"
        case .busyInThisConversation(let steers):
            return steers ? "Joins the run at its next step" : "Waits for the run to finish"
        case .behindEarlierMessage: return "After the message before it"
        case .sideLaneLimit(let limit): return "Waits for one of its \(limit) other threads to finish"
        case .backgroundLimit: return "Waits for other background work to finish"
        case .hidden: return "Waits until you show this buddy in the list again"
        }
    }
}

enum BuddyRunLanePolicy {
    /// Side conversations (side threads and group chats) one buddy may run at
    /// once, beside its main thread. OpenBot's default task limit.
    static let maximumParallelSideLanes = 2

    /// Whether a new run may start in `conversationID` (nil = main thread),
    /// given the lanes the buddy is running now.
    static func canStartRun(inConversation conversationID: UUID?, runningConversationIDs: [UUID?]) -> Bool {
        holdReasonForNewRun(inConversation: conversationID, runningConversationIDs: runningConversationIDs, steers: false) == nil
    }

    /// The lane rule alone: busy lane, or too many side lanes. Nil = may start.
    static func holdReasonForNewRun(
        inConversation conversationID: UUID?,
        runningConversationIDs: [UUID?],
        steers: Bool
    ) -> BuddyRunHoldReason? {
        if runningConversationIDs.contains(conversationID) {
            return .busyInThisConversation(steers: steers)
        }
        if conversationID != nil {
            let runningSideLaneCount = Set(runningConversationIDs.compactMap { $0 }).count
            if runningSideLaneCount >= maximumParallelSideLanes {
                return .sideLaneLimit(maximumParallelSideLanes)
            }
        }
        return nil
    }

    /// Why the waiting message `messageID` hasn't started, in the order the
    /// drain pass would check. Nil means it is about to start.
    static func holdReason(
        forWaitingMessageWithID messageID: UUID,
        waitingMessages: [QueuedBuddyMessage],
        isLinePaused: Bool,
        runningConversationIDs: [UUID?],
        busyMessageMode: BuddyBusyMessageMode,
        backgroundHasRoom: Bool
    ) -> BuddyRunHoldReason? {
        guard let message = waitingMessages.first(where: { $0.id == messageID }) else { return nil }
        if isLinePaused { return .paused }
        let earlierMessagesInLane = waitingMessages
            .prefix { $0.id != messageID }
            .filter { $0.threadID == message.threadID }
        if let laneHold = holdReasonForNewRun(
            inConversation: message.threadID,
            runningConversationIDs: runningConversationIDs,
            steers: busyMessageMode == .steer
        ) {
            // Only the first message of a busy lane is the one the run takes
            // next; the rest wait behind it either way.
            if case .busyInThisConversation = laneHold, !earlierMessagesInLane.isEmpty { return .behindEarlierMessage }
            return laneHold
        }
        if !earlierMessagesInLane.isEmpty { return .behindEarlierMessage }
        return backgroundHasRoom ? nil : .backgroundLimit
    }
}
