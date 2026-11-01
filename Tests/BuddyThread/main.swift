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

// MARK: - Side threads

let sideThreadA = UUID()
let sideThreadB = UUID()
func threadExchange(_ text: String, answer: String?, thread: UUID?) -> BuddyThreadExchange {
    BuddyThreadExchange(taskID: UUID(), startedAt: Date(), origin: .message, userText: text, answerText: answer, threadID: thread)
}
let threadedExchanges = [
    threadExchange("main one", answer: "main answer", thread: nil),
    threadExchange("plan the trip to Lisbon next spring with a very long title", answer: "a", thread: sideThreadA),
    threadExchange("main two", answer: "main answer 2", thread: nil),
    threadExchange("second thread", answer: "b", thread: sideThreadB),
    threadExchange("follow up in A", answer: "a2", thread: sideThreadA),
]
check(BuddyThreadPolicy.historyMessages(from: threadedExchanges).map(\.combinedText) == ["main one", "main answer", "main two", "main answer 2"],
      "the main thread's history holds only main exchanges")
check(BuddyThreadPolicy.historyMessages(from: threadedExchanges, inThread: sideThreadA).map(\.combinedText)
      == ["plan the trip to Lisbon next spring with a very long title", "a", "follow up in A", "a2"],
      "a side thread's history holds only its own exchanges")
let threadTabs = BuddyThreadPolicy.threadSummaries(from: threadedExchanges, draftThreadIDs: [sideThreadA, UUID()])
check(threadTabs.count == 4, "main, two side threads and one empty draft (a draft that has messages isn't doubled)")
check(threadTabs[0].isMain && threadTabs[0].exchangeCount == 2, "the main tab is first and counts its exchanges")
check(threadTabs[1].id == sideThreadA && threadTabs[2].id == sideThreadB, "side threads keep the order they were started")
check(threadTabs[1].title.count == BuddyThreadPolicy.maximumThreadTitleCharacters && threadTabs[1].title.hasSuffix("…"), "a long first message is clipped for the tab title")
check(threadTabs[3].title == "New thread" && threadTabs[3].exchangeCount == 0, "a draft thread is called New thread")
check(BuddyThreadPolicy.threadTitle(fromFirstMessage: "  hello\n  world  ") == "hello world", "title collapses whitespace")
let legacyExchangeJSON = Data(#"{"taskID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","startedAt":"2026-01-01T00:00:00Z","origin":"job","userText":"x"}"#.utf8)
let legacyDecoder = JSONDecoder(); legacyDecoder.dateDecodingStrategy = .iso8601
check((try? legacyDecoder.decode(BuddyThreadExchange.self, from: legacyExchangeJSON))?.threadID == nil, "an exchange saved before threads loads into the main thread")

// MARK: - Chat layout

var utcCalendar = Calendar(identifier: .gregorian); utcCalendar.timeZone = TimeZone(identifier: "UTC")!
let usLocale = Locale(identifier: "en_US")
func utc(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
let layoutNow = utc("2026-10-31T15:00:00Z")
check(BuddyChatLayoutPolicy.dayLabel(for: utc("2026-10-31T01:00:00Z"), now: layoutNow, calendar: utcCalendar, locale: usLocale) == "Today", "same day is Today")
check(BuddyChatLayoutPolicy.dayLabel(for: utc("2026-10-30T23:59:00Z"), now: layoutNow, calendar: utcCalendar, locale: usLocale) == "Yesterday", "the day before is Yesterday")
check(BuddyChatLayoutPolicy.dayLabel(for: utc("2026-10-27T12:00:00Z"), now: layoutNow, calendar: utcCalendar, locale: usLocale) == "Tuesday", "within a week is the weekday")
check(BuddyChatLayoutPolicy.dayLabel(for: utc("2026-09-02T12:00:00Z"), now: layoutNow, calendar: utcCalendar, locale: usLocale) == "Sep 2", "older this year is month and day")
check(BuddyChatLayoutPolicy.dayLabel(for: utc("2025-09-02T12:00:00Z"), now: layoutNow, calendar: utcCalendar, locale: usLocale).contains("2025"), "another year shows the year")
check(BuddyChatLayoutPolicy.startsNewDay(previous: nil, current: layoutNow, calendar: utcCalendar), "the first entry opens a day")
check(!BuddyChatLayoutPolicy.startsNewDay(previous: utc("2026-10-31T01:00:00Z"), current: layoutNow, calendar: utcCalendar), "same day, no separator")
check(BuddyChatLayoutPolicy.startsNewDay(previous: utc("2026-10-30T23:59:00Z"), current: utc("2026-10-31T00:01:00Z"), calendar: utcCalendar), "a new day gets a separator")
let runBase = utc("2026-10-31T10:00:00Z")
check(BuddyChatLayoutPolicy.continuesAnswerRun(previous: runBase, current: runBase.addingTimeInterval(120), currentHasUserMessage: false, startsNewDay: false), "a quick answer with no user message continues the run")
check(!BuddyChatLayoutPolicy.continuesAnswerRun(previous: runBase, current: runBase.addingTimeInterval(120), currentHasUserMessage: true, startsNewDay: false), "a user message breaks the run")
check(!BuddyChatLayoutPolicy.continuesAnswerRun(previous: runBase, current: runBase.addingTimeInterval(3600), currentHasUserMessage: false, startsNewDay: false), "an hour later is a new block")
check(!BuddyChatLayoutPolicy.continuesAnswerRun(previous: runBase, current: runBase.addingTimeInterval(60), currentHasUserMessage: false, startsNewDay: true), "a day break ends the run")
check(!BuddyChatLayoutPolicy.continuesAnswerRun(previous: nil, current: runBase, currentHasUserMessage: false, startsNewDay: false), "the first entry opens a run")
check(BuddyChatLayoutPolicy.isAtBottom(contentOffsetY: 520, containerHeight: 480, contentHeight: 1000), "within slack counts as the bottom")
check(!BuddyChatLayoutPolicy.isAtBottom(contentOffsetY: 100, containerHeight: 480, contentHeight: 1000), "scrolled up is not the bottom")

let draftSuite = UserDefaults(suiteName: "wisp.test.drafts.\(UUID().uuidString)")!
let draftStore = BuddyComposerDraftStore(defaults: draftSuite)
let draftBuddy = UUID(); let draftThread = UUID()
check(draftStore.draft(buddyID: draftBuddy, threadID: nil) == "", "no draft yet")
draftStore.save("half a thought", buddyID: draftBuddy, threadID: nil)
draftStore.save("other thread", buddyID: draftBuddy, threadID: draftThread)
check(draftStore.draft(buddyID: draftBuddy, threadID: nil) == "half a thought", "the main thread's draft comes back")
check(draftStore.draft(buddyID: draftBuddy, threadID: draftThread) == "other thread", "each thread keeps its own draft")
draftStore.save("   \n", buddyID: draftBuddy, threadID: nil)
check(draftStore.draft(buddyID: draftBuddy, threadID: nil) == "", "a blank draft is removed")
draftStore.removeDrafts(ofBuddyWithID: draftBuddy)
check(draftStore.draft(buddyID: draftBuddy, threadID: draftThread) == "", "deleting a buddy forgets all its drafts")

// MARK: - Run trace

let traceStart = Date(timeIntervalSince1970: 1_000_000)
func traceStep(_ summary: String, model: Bool, at offset: TimeInterval, for duration: TimeInterval, error: Bool = false) -> AgentStepRecord {
    AgentStepRecord(kind: model ? .modelCall : .tool(name: "web_search"), summary: summary,
                    startedAt: traceStart.addingTimeInterval(offset), durationSeconds: duration, isError: error)
}
let sampleTrace = RunTraceBuilder.trace(
    steps: [traceStep("Searching", model: false, at: 0, for: 6), traceStep("Searching", model: false, at: 6, for: 0.4, error: true),
            traceStep("Answer", model: true, at: 8, for: 2)],
    runStartedAt: traceStart, runTotalSeconds: 10)
check(sampleTrace.stepCount == 3 && sampleTrace.modelCallCount == 1 && sampleTrace.toolCallCount == 2 && sampleTrace.errorCount == 1, "a trace counts steps, model calls, tool calls and errors")
check(sampleTrace.rows[0].isSlowest && !sampleTrace.rows[1].isSlowest && !sampleTrace.rows[2].isSlowest, "only the longest step is marked slowest")
check(abs(sampleTrace.rows[2].offsetFraction - 0.8) < 0.0001 && abs(sampleTrace.rows[2].widthFraction - 0.2) < 0.0001, "bars sit on one shared axis")
let longTrace = RunTraceBuilder.trace(steps: [traceStep("late", model: false, at: 4, for: 9)], runStartedAt: traceStart, runTotalSeconds: 5)
check(longTrace.totalSeconds == 13, "a step that runs past the run's clock stretches the axis")
check(!RunTraceBuilder.trace(steps: [traceStep("only", model: true, at: 0, for: 3)], runStartedAt: traceStart, runTotalSeconds: 3).rows[0].isSlowest, "a lone step is not called slowest")
let instantTrace = RunTraceBuilder.trace(steps: [traceStep("blink", model: false, at: 2, for: 0), traceStep("rest", model: false, at: 0, for: 100)], runStartedAt: traceStart, runTotalSeconds: 100)
check(instantTrace.rows[0].widthFraction >= RunTraceBuilder.minimumWidthFraction, "an instant step still gets a visible bar")
check(RunTraceBuilder.trace(steps: [], runStartedAt: traceStart, runTotalSeconds: 0).rows.isEmpty, "no steps, no rows")

// MARK: - Sidebar badge and groups

check(BuddySidebarPolicy.state(mood: .waiting, isUnread: true) == .waiting, "waiting outranks unread")
check(BuddySidebarPolicy.state(mood: .working, isUnread: true) == .working, "working outranks unread")
check(BuddySidebarPolicy.state(mood: .oops, isUnread: true) == .failed, "a recent failure outranks unread")
check(BuddySidebarPolicy.state(mood: .happy, isUnread: true) == .responded, "a fresh success shows its check before the unread dot")
check(BuddySidebarPolicy.state(mood: .idle, isUnread: true) == .unread, "an idle buddy with news is unread")
check(BuddySidebarPolicy.state(mood: .sleepy, isUnread: false) == nil, "a quiet buddy wears no badge")

struct SidebarItem { let name: String; let hidden: Bool; let waiting: Bool; let pinned: Bool }
let sidebarItems = [
    SidebarItem(name: "a", hidden: false, waiting: false, pinned: false),
    SidebarItem(name: "b", hidden: false, waiting: true, pinned: true),
    SidebarItem(name: "c", hidden: false, waiting: false, pinned: true),
    SidebarItem(name: "d", hidden: true, waiting: true, pinned: true),
    SidebarItem(name: "e", hidden: false, waiting: false, pinned: false),
]
let sidebarGroups = BuddySidebarGrouping.groups(
    of: sidebarItems, isHidden: \.hidden, isWaiting: \.waiting, isPinned: \.pinned
)
check(sidebarGroups.needsYou.map(\.name) == ["b"], "a waiting buddy goes to Needs you, even if pinned")
check(sidebarGroups.pinned.map(\.name) == ["c"], "pinned holds pinned buddies that are not waiting")
check(sidebarGroups.everyoneElse.map(\.name) == ["a", "e"], "the rest keep their order")
check(sidebarGroups.hidden.map(\.name) == ["d"], "a hidden buddy leaves every group, even while waiting")
check(sidebarGroups.visibleInDisplayOrder.map(\.name) == ["b", "c", "a", "e"], "shortcuts count over the visible rows in display order")

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
