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

// A personality's work-style line rides in the addendum after the specialty line, and a
// neutral buddy's prompt is unchanged.
let neutralAddendum = BuddyThreadPolicy.systemPromptAddendum(buddyName: "Gmail Digest", job: "summarize my Gmail", specialtyLine: "You are an inbox specialist.")
let hypeAddendum = BuddyThreadPolicy.systemPromptAddendum(
    buddyName: "Gmail Digest", job: "summarize my Gmail",
    specialtyLine: "You are an inbox specialist.", personalityLine: BuddyPersonality.hype.personaLine
)
check(!neutralAddendum.contains("Work style"), "no personality adds no work-style line")
check(hypeAddendum.contains(BuddyPersonality.hype.personaLine), "the personality line reaches the prompt")
check(hypeAddendum.contains("You are an inbox specialist.") && hypeAddendum.contains("summarize my Gmail"), "specialty and job are kept alongside a personality")
check(hypeAddendum.count > neutralAddendum.count, "a personality only adds text")
check(
    (hypeAddendum.range(of: "inbox specialist")?.lowerBound ?? hypeAddendum.endIndex)
        < (hypeAddendum.range(of: "Work style")?.lowerBound ?? hypeAddendum.startIndex),
    "the work-style line follows the specialty line"
)

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

// MARK: - Buddy list policy (unread, order, copies, thread contents)

do {
    let createdAt = Date(timeIntervalSince1970: 1_000)
    let earlier = Date(timeIntervalSince1970: 2_000)
    let later = Date(timeIntervalSince1970: 3_000)

    check(!BuddyListPolicy.isUnread(latestFinishedRunAt: nil, lastReadAt: nil, createdAt: createdAt, isMarkedUnread: false),
          "a buddy that never finished anything isn't unread")
    check(BuddyListPolicy.isUnread(latestFinishedRunAt: earlier, lastReadAt: nil, createdAt: createdAt, isMarkedUnread: false),
          "a finish after creation, never opened, is unread")
    check(BuddyListPolicy.isUnread(latestFinishedRunAt: later, lastReadAt: earlier, createdAt: createdAt, isMarkedUnread: false),
          "a finish after the last read is unread")
    check(!BuddyListPolicy.isUnread(latestFinishedRunAt: earlier, lastReadAt: later, createdAt: createdAt, isMarkedUnread: false),
          "a finish before the last read is read")
    check(BuddyListPolicy.isUnread(latestFinishedRunAt: nil, lastReadAt: later, createdAt: createdAt, isMarkedUnread: true),
          "marked unread by hand stays unread")

    check(BuddyListPolicy.isNews(.succeeded) && BuddyListPolicy.isNews(.failed("x")), "answers and failures are news")
    check(!BuddyListPolicy.isNews(.cancelled) && !BuddyListPolicy.isNews(.interrupted) && !BuddyListPolicy.isNews(.running),
          "a run the user stopped, or one cut off, isn't news")

    struct ListedItem { let name: String; let isPinned: Bool; let lastActivityAt: Date; let createdAt: Date }
    let items = [
        ListedItem(name: "old", isPinned: false, lastActivityAt: earlier, createdAt: createdAt),
        ListedItem(name: "recent", isPinned: false, lastActivityAt: later, createdAt: createdAt),
        ListedItem(name: "pinned", isPinned: true, lastActivityAt: createdAt, createdAt: createdAt),
        ListedItem(name: "tieNewer", isPinned: false, lastActivityAt: earlier, createdAt: earlier),
    ]
    let orderedNames = BuddyListPolicy.ordered(
        items, isPinned: \.isPinned, lastActivityAt: \.lastActivityAt, createdAt: \.createdAt
    ).map(\.name)
    check(orderedNames == ["pinned", "recent", "tieNewer", "old"], "pinned first, then latest activity, then newest (got \(orderedNames))")

    check(BuddyListPolicy.duplicateName(of: "Gmail Digest", existingNames: ["Gmail Digest"]) == "Gmail Digest copy", "first copy name")
    check(BuddyListPolicy.duplicateName(of: "Gmail Digest", existingNames: ["Gmail Digest", "gmail digest copy"]) == "Gmail Digest copy 2",
          "a second copy is numbered, case-insensitively")

    let legacyRunID = UUID()
    let firstExchangeID = UUID()
    let secondExchangeID = UUID()
    let threadIDs = BuddyListPolicy.threadTaskIDs(
        exchangeTaskIDs: [firstExchangeID, secondExchangeID],
        runTaskIDs: [legacyRunID, secondExchangeID]
    )
    check(threadIDs == [legacyRunID, firstExchangeID, secondExchangeID],
          "the thread keeps exchanges whose runs aged out, with older thread-less runs first and no duplicates")

    let formattedAnswer = BuddyAnswerFormatting.attributedAnswer("**Three** new stories\n- one")
    check(String(formattedAnswer.characters) == "Three new stories\n- one", "markdown emphasis is drawn, not shown, and line breaks stay")
}

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
