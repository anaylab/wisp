//
//  Buddy message queue suite: FIFO order, the cap, pause, cancel, and that a
//  message only leaves the line once removed after its run started.
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

let buddy = UUID()
let otherBuddy = UUID()
var queue = BuddyMessageQueue()

check(queue.front(forBuddyWithID: buddy) == nil, "an empty line has no front")
check(queue.enqueue("   ", forBuddyWithID: buddy) == nil, "a blank message is refused")

queue.enqueue("first", forBuddyWithID: buddy)
queue.enqueue("  second  ", forBuddyWithID: buddy)
queue.enqueue("elsewhere", forBuddyWithID: otherBuddy)
check(queue.front(forBuddyWithID: buddy)?.text == "first", "the first message sent is at the front")
check(queue.waitingMessages(forBuddyWithID: buddy).map(\.text) == ["first", "second"], "order is the order sent, text trimmed")
check(queue.waitingMessages(forBuddyWithID: otherBuddy).count == 1, "each buddy has its own line")

// A message stays until its run has started.
check(queue.front(forBuddyWithID: buddy)?.text == "first", "looking at the front does not remove it")
queue.removeFront(forBuddyWithID: buddy)
check(queue.front(forBuddyWithID: buddy)?.text == "second", "after the run starts, the next one is at the front")
queue.removeFront(forBuddyWithID: buddy)
check(queue.waitingMessages(forBuddyWithID: buddy).isEmpty, "a drained line is empty")
check(!queue.buddyIDsWithWaitingMessages.contains(buddy), "a drained buddy is not listed")
queue.removeFront(forBuddyWithID: buddy)
check(queue.waitingMessages(forBuddyWithID: buddy).isEmpty, "removing from an empty line is harmless")

// Pause holds the front back without losing anything.
queue.enqueue("held", forBuddyWithID: buddy)
queue.setPaused(true, forBuddyWithID: buddy)
check(queue.front(forBuddyWithID: buddy) == nil, "a paused line gives no front")
check(queue.waitingMessages(forBuddyWithID: buddy).count == 1, "a paused line keeps its messages")
check(queue.enqueue("while paused", forBuddyWithID: buddy) != nil, "a paused line still accepts messages")
queue.setPaused(false, forBuddyWithID: buddy)
check(queue.front(forBuddyWithID: buddy)?.text == "held", "resuming gives the front back")

// Cancel takes one out by id.
let cancelled = queue.waitingMessages(forBuddyWithID: buddy)[1]
check(queue.cancel(messageWithID: cancelled.id, forBuddyWithID: buddy), "a waiting message can be cancelled")
check(!queue.cancel(messageWithID: cancelled.id, forBuddyWithID: buddy), "cancelling it twice does nothing")
check(queue.waitingMessages(forBuddyWithID: buddy).map(\.text) == ["held"], "the others stay in order")
check(!queue.cancel(messageWithID: UUID(), forBuddyWithID: otherBuddy), "an unknown id is not cancelled")

// The cap.
var fullQueue = BuddyMessageQueue()
for number in 1...BuddyMessageQueue.maximumWaitingMessagesPerBuddy {
    check(fullQueue.enqueue("m\(number)", forBuddyWithID: buddy) != nil, "message \(number) fits")
}
check(fullQueue.enqueue("one too many", forBuddyWithID: buddy) == nil, "the line refuses past its cap")
check(fullQueue.enqueue("another buddy is fine", forBuddyWithID: otherBuddy) != nil, "the cap is per buddy")

// Forgetting a buddy.
fullQueue.setPaused(true, forBuddyWithID: buddy)
fullQueue.removeAll(forBuddyWithID: buddy)
check(fullQueue.waitingMessages(forBuddyWithID: buddy).isEmpty && !fullQueue.isPaused(buddyWithID: buddy), "removeAll clears messages and pause")

// Saved and loaded unchanged.
let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
var savedQueue = BuddyMessageQueue()
savedQueue.enqueue("survives a restart", forBuddyWithID: buddy, now: Date(timeIntervalSince1970: 1_700_000_000))
savedQueue.setPaused(true, forBuddyWithID: otherBuddy)
let reloadedQueue = try! decoder.decode(BuddyMessageQueue.self, from: try! encoder.encode(savedQueue))
check(reloadedQueue == savedQueue, "the queue round-trips through JSON")

// A queued message remembers its thread, and an old saved line still loads.
do {
    var threadQueue = BuddyMessageQueue()
    let threadBuddy = UUID()
    let sideThread = UUID()
    threadQueue.enqueue("in a side thread", forBuddyWithID: threadBuddy, threadID: sideThread)
    threadQueue.enqueue("in main", forBuddyWithID: threadBuddy)
    check(threadQueue.front(forBuddyWithID: threadBuddy)?.threadID == sideThread, "the queued message keeps its thread")
    let reloaded = try! JSONDecoder().decode(BuddyMessageQueue.self, from: JSONEncoder().encode(threadQueue))
    check(reloaded.waitingMessages(forBuddyWithID: threadBuddy).map(\.threadID) == [sideThread, nil], "thread ids survive the codec")
    let oldMessageJSON = Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","text":"hi","queuedAt":0}"#.utf8)
    check((try? JSONDecoder().decode(QueuedBuddyMessage.self, from: oldMessageJSON))?.threadID == nil, "a message queued before threads loads as main")
}

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
