//
//  Buddy thread suite: what a buddy's stored conversation puts in front of the
//  model, how it is capped, and that it survives a restart.
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

func makeExchange(_ userText: String, answer: String?, origin: BuddyThreadExchange.Origin = .job) -> BuddyThreadExchange {
    BuddyThreadExchange(taskID: UUID(), startedAt: Date(), origin: origin, userText: userText, answerText: answer)
}

// MARK: - History projection

let historyExchanges = [
    makeExchange("job", answer: "first answer"),
    makeExchange("unanswered", answer: nil),
    makeExchange("blank", answer: "   \n"),
    makeExchange("what about X?", answer: "X is fine", origin: .message),
]
let history = BuddyThreadPolicy.historyMessages(from: historyExchanges)
check(history.count == 4, "only answered exchanges become messages, two each")
check(history.map(\.role) == [.user, .assistant, .user, .assistant], "roles alternate user/assistant")
check(history.first?.combinedText == "job", "oldest exchange first")
check(history.last?.combinedText == "X is fine", "newest answer last")

let manyExchanges = (0..<20).map { makeExchange("q\($0)", answer: "a\($0)") }
let cappedHistory = BuddyThreadPolicy.historyMessages(from: manyExchanges)
check(cappedHistory.count == BuddyThreadPolicy.maximumExchangesInPrompt * 2, "prompt history is capped")
check(cappedHistory.last?.combinedText == "a19", "the cap keeps the newest exchanges")

let longAnswerHistory = BuddyThreadPolicy.historyMessages(
    from: [makeExchange("q", answer: String(repeating: "x", count: 5000))]
)
check(longAnswerHistory.last?.combinedText.count == BuddyThreadPolicy.maximumAnswerCharactersInPrompt, "long answers are clipped in the prompt")

let addendum = BuddyThreadPolicy.systemPromptAddendum(buddyName: "Gmail Digest", job: "summarize my Gmail")
check(addendum.contains("Gmail Digest") && addendum.contains("summarize my Gmail"), "addendum names the buddy and its job")

// MARK: - Stored cap

var storedExchanges: [BuddyThreadExchange] = []
for exchangeNumber in 0..<(BuddyThreadPolicy.maximumStoredExchanges + 10) {
    storedExchanges = BuddyThreadPolicy.appending(makeExchange("q\(exchangeNumber)", answer: "a"), to: storedExchanges)
}
check(storedExchanges.count == BuddyThreadPolicy.maximumStoredExchanges, "stored thread is capped")
check(storedExchanges.first?.userText == "q10", "the oldest exchanges fall off")

// MARK: - Store round trip

MainActor.assumeIsolated {
    let threadsFileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("buddy-threads-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: threadsFileURL) }

    let buddyID = UUID()
    let otherBuddyID = UUID()
    let taskID = UUID()
    let store = BuddyThreadStore(threadsFileURL: threadsFileURL)
    store.beginExchange(forBuddyWithID: buddyID, taskID: taskID, origin: .message, userText: "hello")
    check(store.historyMessages(forBuddyWithID: buddyID).isEmpty, "an unanswered exchange is not replayed")
    check(store.exchange(forTaskID: taskID, ofBuddyWithID: buddyID)?.userText == "hello", "the question shows before the answer")

    store.completeExchange(forBuddyWithID: buddyID, taskID: taskID, answerText: "hi there")
    check(store.historyMessages(forBuddyWithID: buddyID).count == 2, "the answered exchange is replayed")
    check(store.exchanges(ofBuddyWithID: otherBuddyID).isEmpty, "threads are per buddy")

    let reloadedStore = BuddyThreadStore(threadsFileURL: threadsFileURL)
    check(reloadedStore.exchange(forTaskID: taskID, ofBuddyWithID: buddyID)?.answerText == "hi there", "the thread survives a restart")
    check(reloadedStore.exchange(forTaskID: taskID, ofBuddyWithID: buddyID)?.origin == .message, "origin survives a restart")

    reloadedStore.deleteThread(ofBuddyWithID: buddyID)
    check(BuddyThreadStore(threadsFileURL: threadsFileURL).exchanges(ofBuddyWithID: buddyID).isEmpty, "deleting a buddy deletes its thread")


}

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
