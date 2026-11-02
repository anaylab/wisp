//
//  Buddy run lanes suite: which of a buddy's conversations may run at once,
//  why a waiting message hasn't started, the queue's per-conversation lanes,
//  and taking messages into a run in progress (steer mode).
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

let sideThreadA = UUID()
let sideThreadB = UUID()
let sideThreadC = UUID()

// MARK: Lanes

check(BuddyRunLanePolicy.canStartRun(inConversation: nil, runningConversationIDs: []), "an idle buddy can start anywhere")
check(!BuddyRunLanePolicy.canStartRun(inConversation: nil, runningConversationIDs: [nil]), "one run per conversation: the main thread is busy")
check(BuddyRunLanePolicy.canStartRun(inConversation: sideThreadA, runningConversationIDs: [nil]), "a side thread runs beside a busy main thread")
check(BuddyRunLanePolicy.canStartRun(inConversation: nil, runningConversationIDs: [sideThreadA, sideThreadB]),
      "the main thread doesn't count toward the side-thread limit")
check(BuddyRunLanePolicy.canStartRun(inConversation: sideThreadB, runningConversationIDs: [nil, sideThreadA]), "two side threads may run at once")
check(!BuddyRunLanePolicy.canStartRun(inConversation: sideThreadC, runningConversationIDs: [nil, sideThreadA, sideThreadB]),
      "a third side thread waits")
check(BuddyRunLanePolicy.holdReasonForNewRun(inConversation: sideThreadC, runningConversationIDs: [sideThreadA, sideThreadB], steers: false)
      == .sideLaneLimit(2), "the limit is named")
check(BuddyRunLanePolicy.holdReasonForNewRun(inConversation: sideThreadA, runningConversationIDs: [sideThreadA], steers: true)
      == .busyInThisConversation(steers: true), "a busy conversation in steer mode says the run will take it")

// MARK: Why a message waits

let buddy = UUID()
var queue = BuddyMessageQueue()
let firstMain = queue.enqueue("first in main", forBuddyWithID: buddy)!
let inSideA = queue.enqueue("in side A", forBuddyWithID: buddy, threadID: sideThreadA)!
let secondMain = queue.enqueue("second in main", forBuddyWithID: buddy)!
let waiting = queue.waitingMessages(forBuddyWithID: buddy)

func reason(_ message: QueuedBuddyMessage, running: [UUID?], paused: Bool = false, mode: BuddyBusyMessageMode = .queue, room: Bool = true) -> BuddyRunHoldReason? {
    BuddyRunLanePolicy.holdReason(
        forWaitingMessageWithID: message.id, waitingMessages: waiting, isLinePaused: paused,
        runningConversationIDs: running, busyMessageMode: mode, backgroundHasRoom: room
    )
}
check(reason(firstMain, running: [nil]) == .busyInThisConversation(steers: false), "the first message of a busy lane waits for the run")
check(reason(firstMain, running: [nil], mode: .steer) == .busyInThisConversation(steers: true), "in steer mode it joins the run")
check(reason(secondMain, running: [nil]) == .behindEarlierMessage, "the next one in the same lane waits behind it")
check(reason(secondMain, running: []) == .behindEarlierMessage, "order within a lane holds even when free")
check(reason(inSideA, running: [nil]) == nil, "a side thread's message isn't held by the busy main thread")
check(reason(inSideA, running: [nil], room: false) == .backgroundLimit, "the background limit is named")
check(reason(inSideA, running: [], paused: true) == .paused, "a paused line says so first")
check(BuddyRunHoldReason.sideLaneLimit(2).displayText.contains("2"), "the side-thread limit's text names it")

// MARK: Queue lanes

check(queue.front(forBuddyWithID: buddy, inThread: nil)?.id == firstMain.id, "each lane's front is its oldest message")
check(queue.front(forBuddyWithID: buddy, inThread: sideThreadA)?.id == inSideA.id, "a side thread has its own front")
check(queue.front(forBuddyWithID: buddy, inThread: sideThreadB)?.id == nil, "an empty lane has no front")
check(queue.threadIDsWithWaitingMessages(forBuddyWithID: buddy) == [nil, sideThreadA], "lanes are listed in the order first sent")

var steeringQueue = queue
let takenFromMain = steeringQueue.takeAll(forBuddyWithID: buddy, inThread: nil)
check(takenFromMain.map(\.id) == [firstMain.id, secondMain.id], "steering takes every message of its lane, in order")
check(steeringQueue.waitingMessages(forBuddyWithID: buddy).map(\.id) == [inSideA.id], "other lanes stay in the line")
check(steeringQueue.takeAll(forBuddyWithID: buddy, inThread: nil).isEmpty, "taking twice takes nothing")

var pausedQueue = queue
pausedQueue.setPaused(true, forBuddyWithID: buddy)
check(pausedQueue.takeAll(forBuddyWithID: buddy, inThread: nil).isEmpty, "a paused line hands nothing to a run")
check(pausedQueue.front(forBuddyWithID: buddy, inThread: sideThreadA)?.id == nil, "a paused line has no lane front")

// MARK: Steering text

let oneMessageText = AgentRunSteering.promptText(for: ["use the 3pm slot"])
check(oneMessageText.contains("\"use the 3pm slot\"") && oneMessageText.contains("this message"), "one message is quoted")
let twoMessagesText = AgentRunSteering.promptText(for: ["a", "b"])
check(twoMessagesText.contains("these messages") && twoMessagesText.contains("\"a\"\n\"b\""), "several messages are quoted in order")

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
