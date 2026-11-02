//
//  BuddyMemoryReviewTests.swift
//
//  Phase 5 of docs/openbot-buddies-plan.md: who wrote each note, applying a
//  checked review to the real memory store, and the reviewer end to end with a
//  scripted model (and, with WISP_LIVE_CLAUDE=1, with Claude Haiku).
//

import Foundation

@MainActor func buddyMemoryReviewSuite() async {
    func temporaryMemoryStore() -> BuddyMemoryStore {
        BuddyMemoryStore(memoryDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("memory-review-\(UUID().uuidString)"))
    }
    func exchange(_ question: String, _ answer: String) -> BuddyThreadExchange {
        BuddyThreadExchange(taskID: UUID(), startedAt: Date(), origin: .message, userText: question, answerText: answer)
    }

    section("memory review: who wrote each note")
    do {
        let store = temporaryMemoryStore()
        let buddyID = UUID()
        store.remember("user wants replies in the morning", forBuddyWithID: buddyID)
        store.remember("the essay is due friday", forBuddyWithID: buddyID, writtenByBuddy: true)
        check("authorship: the buddy's own note is marked", store.buddyWrittenFacts(ofBuddyWithID: buddyID) == ["the essay is due friday"])
        let applied = store.applyReviewChanges([
            .update(oldText: "the essay is due friday", newText: "the essay is due monday"),
            .forget("user wants replies in the morning"),
            .update(oldText: "user wants replies in the morning", newText: "user wants replies at night"),
            .add("prefers short answers"),
        ], forBuddyWithID: buddyID)
        let facts = store.facts(ofBuddyWithID: buddyID)
        check("apply: the user's note survives a forget and a rewrite", facts.contains("user wants replies in the morning"))
        check("apply: the buddy's note is rewritten", facts.contains("the essay is due monday") && !facts.contains("the essay is due friday"))
        check("apply: an addition is saved", facts.contains("prefers short answers"))
        check("apply: only the allowed changes are reported", applied.count == 2, "\(applied)")
        check("apply: rewritten and added notes are the buddy's", store.buddyWrittenFacts(ofBuddyWithID: buddyID) == ["the essay is due monday", "prefers short answers"])
        store.forgetExactFact("prefers short answers", forBuddyWithID: buddyID)
        check("authorship: a removed note leaves the list", store.buddyWrittenFacts(ofBuddyWithID: buddyID) == ["the essay is due monday"])
    }

    section("memory review: the reviewer end to end")
    do {
        let store = temporaryMemoryStore()
        let buddy = WispBuddy(id: UUID(), name: "Writer", instruction: "draft essays", colorIndex: 0, schedule: .once,
                              createdAt: Date(), runTaskIDs: [], nextScheduledRunAt: nil)
        store.remember("user wants replies in the morning", forBuddyWithID: buddy.id)
        store.remember("the essay is due friday", forBuddyWithID: buddy.id, writtenByBuddy: true)
        let provider = ScriptedProvider(turns: [BuddyChatTurn(text: """
        {"add": ["the essay is about rivers"], "update": [{"id": "n2", "text": "the essay is due monday"}], "forget": ["n1"]}
        """)])
        let exchanges = [exchange("my essay moved to monday", "got it, monday"), exchange("it's about rivers", "nice topic")]
        let reviewer = BuddyMemoryReviewer()
        reviewer.buddyLookup = { $0 == buddy.id ? buddy : nil }
        reviewer.exchangesLookup = { _ in exchanges }
        reviewer.memoryStore = store
        reviewer.modelProviderFor = { _ in provider }
        reviewer.interval = { .everyTen }

        let applied = await reviewer.runReview(buddyID: buddy.id, exchanges: exchanges, trigger: .enoughMessages, key: nil)
        let facts = store.facts(ofBuddyWithID: buddy.id)
        check("reviewer: the buddy's note is brought up to date", facts.contains("the essay is due monday"))
        check("reviewer: a new fact is added", facts.contains("the essay is about rivers"))
        check("reviewer: the user's note is kept although the model said to forget it", facts.contains("user wants replies in the morning"))
        check("reviewer: two changes applied", applied.count == 2, "\(applied)")
        check("reviewer: the summary is kept for the page", reviewer.lastSummaryByBuddyID[buddy.id]?.displayText == "added 1, rewrote 1")
        let request = provider.receivedRequests.first
        check("reviewer: one text-only call, no tools", provider.receivedRequests.count == 1 && request?.tools.isEmpty == true && request?.containsImages == false)
        check("reviewer: the prompt carries the conversation and marks authors",
              request?.messages.first?.combinedText.contains("my essay moved to monday") == true
              && request?.messages.first?.combinedText.contains("n1 [user]") == true)

        // The same exchanges aren't reviewed twice.
        let secondProvider = ScriptedProvider(turns: [BuddyChatTurn(text: "{}")])
        reviewer.modelProviderFor = { _ in secondProvider }
        reviewer.noteCompletedTurn(buddyID: buddy.id, conversationID: nil)
        for _ in 0..<9 { reviewer.noteCompletedTurn(buddyID: buddy.id, conversationID: nil) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        check("reviewer: already reviewed exchanges start no call", secondProvider.receivedRequests.isEmpty)

        // Ten new messages start a review on their own.
        let newExchanges = (0..<10).map { exchange("question \($0)", "answer \($0)") }
        reviewer.exchangesLookup = { _ in exchanges + newExchanges }
        for _ in 0..<10 { reviewer.noteCompletedTurn(buddyID: buddy.id, conversationID: nil) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        check("reviewer: the 10th message starts a review", secondProvider.receivedRequests.count == 1)
        check("reviewer: it reads only the new exchanges",
              secondProvider.receivedRequests.first.map { !$0.messages[0].combinedText.contains("my essay moved") && $0.messages[0].combinedText.contains("question 9") } ?? false)

        // Off starts nothing; a buddy that saves a note restarts the count.
        let offProvider = ScriptedProvider(turns: [])
        reviewer.modelProviderFor = { _ in offProvider }
        reviewer.interval = { .off }
        reviewer.exchangesLookup = { _ in [exchange("fresh", "fresh answer")] }
        for _ in 0..<12 { reviewer.noteCompletedTurn(buddyID: buddy.id, conversationID: nil) }
        reviewer.reviewBeforeClearing(buddyID: buddy.id, exchanges: [exchange("fresh", "fresh answer")])
        try? await Task.sleep(nanoseconds: 200_000_000)
        check("reviewer: off starts nothing, not even before clearing", offProvider.receivedRequests.isEmpty)
        reviewer.interval = { .everyTen }
        for _ in 0..<9 { reviewer.noteCompletedTurn(buddyID: buddy.id, conversationID: UUID()) }
        reviewer.noteBuddyChangedItsNotes(buddyID: buddy.id)
        try? await Task.sleep(nanoseconds: 100_000_000)
        check("reviewer: saving a note itself restarts the count", offProvider.receivedRequests.isEmpty)

        // A broken answer changes nothing.
        let brokenProvider = ScriptedProvider(turns: [BuddyChatTurn(text: "Sure! I updated the notes.")])
        reviewer.modelProviderFor = { _ in brokenProvider }
        let factsBefore = store.facts(ofBuddyWithID: buddy.id)
        let brokenApplied = await reviewer.runReview(buddyID: buddy.id, exchanges: [exchange("x", "y")], trigger: .beforeClearing, key: nil)
        check("reviewer: an answer that isn't JSON changes nothing", brokenApplied.isEmpty && store.facts(ofBuddyWithID: buddy.id) == factsBefore)
    }

    section("memory review: which model reviews")
    do {
        let localBuddy = WispBuddy(id: UUID(), name: "L", instruction: "j", colorIndex: 0, schedule: .once, createdAt: Date(), runTaskIDs: [], nextScheduledRunAt: nil,
                                   modelChoice: BuddyModelChoice(providerKind: .localOllama, claudeModel: nil))
        check("model: a local buddy is reviewed on this Mac", !BuddyMemoryReviewer.reviewModelProvider(for: localBuddy).deployment.sendsDataOffThisMachine)
        var sessionBuddy = localBuddy
        sessionBuddy.runtime = .claudeCodeSession
        check("model: a Claude Code buddy is reviewed by Haiku, outside its session",
              BuddyMemoryReviewer.reviewModelProvider(for: sessionBuddy).identifier == "claude-subscription/claude-haiku-4-5")
        let claudeBuddy = WispBuddy(id: UUID(), name: "C", instruction: "j", colorIndex: 0, schedule: .once, createdAt: Date(), runTaskIDs: [], nextScheduledRunAt: nil,
                                    modelChoice: BuddyModelChoice(providerKind: .anthropic, claudeModel: .opus))
        check("model: a Claude buddy is reviewed by Haiku", BuddyMemoryReviewer.reviewModelProvider(for: claudeBuddy).identifier.contains("haiku"),
              BuddyMemoryReviewer.reviewModelProvider(for: claudeBuddy).identifier)
    }

    if ProcessInfo.processInfo.environment["WISP_LIVE_CLAUDE"] == "1" {
        section("memory review: live (Claude Haiku reviews real notes)")
        let store = temporaryMemoryStore()
        let buddy = WispBuddy(id: UUID(), name: "Writer", instruction: "help the user with their school essays", colorIndex: 0, schedule: .once,
                              createdAt: Date(), runTaskIDs: [], nextScheduledRunAt: nil)
        store.remember("user wants replies in the morning", forBuddyWithID: buddy.id)
        store.remember("the history essay is due friday", forBuddyWithID: buddy.id, writtenByBuddy: true)
        let reviewer = BuddyMemoryReviewer()
        reviewer.buddyLookup = { _ in buddy }
        reviewer.memoryStore = store
        reviewer.modelProviderFor = { _ in ClaudeSubscriptionProvider(modelChoice: .haiku, effortLevel: .low) }
        let applied = await reviewer.runReview(buddyID: buddy.id, exchanges: [
            exchange("my teacher moved the history essay to next wednesday", "thanks, i'll plan for wednesday"),
            exchange("also, i always want sources in MLA format", "got it, MLA from now on"),
            exchange("thanks!", "anytime"),
        ], trigger: .enoughMessages, key: nil)
        let facts = store.facts(ofBuddyWithID: buddy.id)
        check("live review: the due date was brought up to date",
              facts.contains { $0.lowercased().contains("wednesday") } && !facts.contains("the history essay is due friday"), facts.description)
        check("live review: the lasting preference was saved", facts.contains { $0.lowercased().contains("mla") }, facts.description)
        check("live review: the user's own note is untouched", facts.contains("user wants replies in the morning"), facts.description)
        check("live review: small talk wasn't saved", !facts.contains { $0.lowercased().contains("anytime") || $0.lowercased().contains("thanks") }, facts.description)
        check("live review: changes were applied", !applied.isEmpty)
    }

    if ProcessInfo.processInfo.environment["WISP_LIVE_OLLAMA"] == "1" {
        section("memory review: live (the local 3B model reviews real notes)")
        let store = temporaryMemoryStore()
        let buddy = WispBuddy(id: UUID(), name: "Writer", instruction: "help the user with their school essays", colorIndex: 0, schedule: .once,
                              createdAt: Date(), runTaskIDs: [], nextScheduledRunAt: nil,
                              modelChoice: BuddyModelChoice(providerKind: .localOllama, claudeModel: nil))
        store.remember("user wants replies in the morning", forBuddyWithID: buddy.id)
        store.remember("the history essay is due friday", forBuddyWithID: buddy.id, writtenByBuddy: true)
        let reviewer = BuddyMemoryReviewer()
        reviewer.buddyLookup = { _ in buddy }
        reviewer.memoryStore = store
        let startedAt = Date()
        let applied = await reviewer.runReview(buddyID: buddy.id, exchanges: [
            exchange("my teacher moved the history essay to next wednesday", "thanks, i'll plan for wednesday"),
            exchange("also, i always want sources in MLA format", "got it, MLA from now on"),
        ], trigger: .enoughMessages, key: nil)
        let facts = store.facts(ofBuddyWithID: buddy.id)
        print("        local review took \(String(format: "%.1f", Date().timeIntervalSince(startedAt)))s; applied \(applied); notes now \(facts)")
        check("live local review: the user's own note is untouched", facts.contains("user wants replies in the morning"), facts.description)
        check("live local review: it produced a usable answer", !applied.isEmpty, "\(facts)")
    }
}
