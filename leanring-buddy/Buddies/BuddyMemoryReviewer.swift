//
//  BuddyMemoryReviewer.swift
//  leanring-buddy
//
//  Runs the background review of a buddy's notes (`BuddyMemoryReviewPolicy`
//  holds the rules). It counts the user's messages per conversation, starts a
//  review when there are enough, after a quiet spell, or just before a
//  conversation is cleared, and runs one review at a time.
//
//  The review is one text-only call on the buddy's own provider, so nothing
//  goes anywhere the buddy's conversation hasn't already gone: a local buddy
//  is reviewed by the local model, at background priority through
//  `ModelAccessGate` so it never delays a reply. A Claude buddy is reviewed by
//  Claude Haiku, its cheapest model, as OpenBot reviews on the cheaper model of
//  the same provider. Counts live in memory only; after a relaunch the next
//  review reads the latest exchanges.
//

import Combine
import Foundation

@MainActor
final class BuddyMemoryReviewer: ObservableObject {
    static let shared = BuddyMemoryReviewer()

    struct ConversationKey: Hashable {
        let buddyID: UUID
        let conversationID: UUID?
    }

    struct ConversationProgress {
        var messagesSinceReview = 0
        var lastMessageAt: Date?
    }

    /// The last review of each buddy, for its Memory page.
    @Published private(set) var lastSummaryByBuddyID: [UUID: BuddyMemoryReviewSummary] = [:]
    @Published private(set) var reviewingBuddyID: UUID?

    private var progressByKey: [ConversationKey: ConversationProgress] = [:]
    /// Exchanges already reviewed, so a review reads only what's new.
    private var reviewedTaskIDs: Set<UUID> = []
    /// A review asked for while another ran (only clearing, whose exchanges
    /// are about to be deleted, is kept for later).
    private var waitingClearReviews: [(buddyID: UUID, exchanges: [BuddyThreadExchange])] = []

    // Injected so the flow can be tested without the app's stores or a model.
    var buddyLookup: (UUID) -> WispBuddy? = { BuddyStore.shared.buddy(withID: $0) }
    var exchangesLookup: (ConversationKey) -> [BuddyThreadExchange] = { key in
        BuddyThreadPolicy.exchanges(BuddyThreadStore.shared.exchanges(ofBuddyWithID: key.buddyID), inThread: key.conversationID)
    }
    var memoryStore: BuddyMemoryStore = .shared
    var modelProviderFor: (WispBuddy) -> any ModelProvider = BuddyMemoryReviewer.reviewModelProvider(for:)
    var interval: () -> BuddyMemoryReviewInterval = { BuddyMemoryReviewInterval.current }
    var now: () -> Date = Date.init

    // MARK: - Signals

    /// One of the user's messages to the buddy was answered.
    func noteCompletedTurn(buddyID: UUID, conversationID: UUID?) {
        let key = ConversationKey(buddyID: buddyID, conversationID: conversationID)
        var progress = progressByKey[key] ?? ConversationProgress()
        progress.messagesSinceReview += 1
        progress.lastMessageAt = now()
        progressByKey[key] = progress
        if BuddyMemoryReviewPolicy.trigger(
            messagesSinceReview: progress.messagesSinceReview, lastMessageAt: progress.lastMessageAt,
            now: now(), interval: interval()
        ) == .enoughMessages {
            startReview(of: key, trigger: .enoughMessages)
        }
    }

    /// The buddy saved or removed a note itself, so the count starts again.
    func noteBuddyChangedItsNotes(buddyID: UUID) {
        for key in progressByKey.keys where key.buddyID == buddyID {
            progressByKey[key]?.messagesSinceReview = 0
        }
    }

    /// Called every minute: reviews conversations that went quiet after a few messages.
    func checkQuietConversations() {
        for (key, progress) in progressByKey {
            if BuddyMemoryReviewPolicy.trigger(
                messagesSinceReview: progress.messagesSinceReview, lastMessageAt: progress.lastMessageAt,
                now: now(), interval: interval()
            ) == .quietAfterMessages {
                startReview(of: key, trigger: .quietAfterMessages)
                return   // one at a time; the next tick takes the next
            }
        }
    }

    /// The user is clearing the buddy's conversation: review it first, from
    /// the exchanges that are about to be deleted.
    func reviewBeforeClearing(buddyID: UUID, exchanges: [BuddyThreadExchange]) {
        guard interval() != .off else { return }
        let unreviewedExchanges = exchanges.filter { !reviewedTaskIDs.contains($0.taskID) && $0.answerText != nil }
        guard !unreviewedExchanges.isEmpty else { return }
        guard reviewingBuddyID == nil else {
            waitingClearReviews.append((buddyID, unreviewedExchanges))
            return
        }
        Task { await runReview(buddyID: buddyID, exchanges: unreviewedExchanges, trigger: .beforeClearing, key: nil) }
    }

    func forgetBuddy(buddyID: UUID) {
        progressByKey = progressByKey.filter { $0.key.buddyID != buddyID }
        lastSummaryByBuddyID[buddyID] = nil
        waitingClearReviews.removeAll { $0.buddyID == buddyID }
    }

    // MARK: - Running

    private func startReview(of key: ConversationKey, trigger: BuddyMemoryReviewTrigger) {
        guard reviewingBuddyID == nil else { return }   // the count stays, so a later trigger tries again
        let unreviewedExchanges = exchangesLookup(key).filter { !reviewedTaskIDs.contains($0.taskID) && $0.answerText != nil }
        guard !unreviewedExchanges.isEmpty else {
            progressByKey[key]?.messagesSinceReview = 0
            return
        }
        Task { await runReview(buddyID: key.buddyID, exchanges: unreviewedExchanges, trigger: trigger, key: key) }
    }

    /// One review: prompt, model call, check, apply. Returns the changes made
    /// (for tests); failures are logged and change nothing.
    @discardableResult
    func runReview(
        buddyID: UUID,
        exchanges: [BuddyThreadExchange],
        trigger: BuddyMemoryReviewTrigger,
        key: ConversationKey?
    ) async -> [BuddyMemoryReviewChange] {
        guard reviewingBuddyID == nil, let buddy = buddyLookup(buddyID) else { return [] }
        reviewingBuddyID = buddyID
        defer {
            reviewingBuddyID = nil
            if !waitingClearReviews.isEmpty {
                let waitingReview = waitingClearReviews.removeFirst()
                Task { await runReview(buddyID: waitingReview.buddyID, exchanges: waitingReview.exchanges, trigger: .beforeClearing, key: nil) }
            }
        }

        let reviewedExchanges = Array(exchanges.suffix(BuddyMemoryReviewPolicy.maximumExchangesReviewed))
        let shownFacts = memoryStore.facts(ofBuddyWithID: buddyID)
        let userMessage = BuddyMemoryReviewPolicy.userMessage(
            buddyName: buddy.name,
            buddyJob: buddy.instruction,
            facts: shownFacts,
            buddyWrittenFacts: memoryStore.buddyWrittenFacts(ofBuddyWithID: buddyID),
            exchanges: reviewedExchanges.map { (BuddyThreadPolicy.userText(for: $0), AnswerDisplayText.cleaned($0.answerText ?? "")) }
        )
        let request = ModelRequest(
            systemPrompt: BuddyMemoryReviewPolicy.systemPrompt,
            messages: [BuddyChatMessage(role: .user, text: userMessage)],
            maxOutputTokens: BuddyMemoryReviewPolicy.maximumOutputTokens,
            temperature: 0
        )
        let modelProvider = modelProviderFor(buddy)
        let replyText: String
        do {
            // The local model is shared: wait behind anything the user is waiting on.
            // A cloud model holds nothing back, so it doesn't queue.
            if modelProvider.deployment.sendsDataOffThisMachine {
                replyText = try await modelProvider.completeTurn(request).text
            } else {
                replyText = try await ModelAccessGate.shared.withAccess(priority: .background) {
                    try await modelProvider.completeTurn(request)
                }.text
            }
        } catch {
            print("🧠 Buddy memory review of \(buddy.name) failed: \(error.localizedDescription)")
            return []
        }

        // The buddy may have been deleted while the model thought.
        guard buddyLookup(buddyID) != nil else { return [] }
        guard let proposedChanges = BuddyMemoryReviewPolicy.parseReply(replyText) else {
            print("🧠 Buddy memory review of \(buddy.name): the answer wasn't JSON, nothing changed")
            return []
        }
        let checkedChanges = BuddyMemoryReviewPolicy.checkedChanges(
            proposedChanges,
            shownFacts: shownFacts,
            currentFacts: memoryStore.facts(ofBuddyWithID: buddyID),
            buddyWrittenFacts: memoryStore.buddyWrittenFacts(ofBuddyWithID: buddyID)
        )
        let appliedChanges = memoryStore.applyReviewChanges(checkedChanges, forBuddyWithID: buddyID)

        reviewedTaskIDs.formUnion(reviewedExchanges.map(\.taskID))
        if let key { progressByKey[key]?.messagesSinceReview = 0 }
        lastSummaryByBuddyID[buddyID] = BuddyMemoryReviewPolicy.summary(of: appliedChanges, at: now())
        print("🧠 Buddy memory review of \(buddy.name) (\(trigger)): \(lastSummaryByBuddyID[buddyID]?.displayText ?? "")")
        return appliedChanges
    }

    // MARK: - Model

    /// The buddy's own provider, on Claude's cheapest model when it is Claude.
    static func reviewModelProvider(for buddy: WispBuddy) -> any ModelProvider {
        if buddy.runtimeKind == .claudeCodeSession {
            // A one-off call, outside the buddy's kept session.
            return ClaudeSubscriptionProvider(modelChoice: .haiku, effortLevel: .low)
        }
        let providerKind = buddy.modelChoice?.providerKind ?? BuddyChatProviderSelection.current
        switch providerKind {
        case .anthropic, .claudeSubscription:
            return ModelProviderFactory.make(providerKind, claudeModelOverride: .haiku)
        default:
            return buddy.modelChoice.map(ModelProviderFactory.make) ?? ModelProviderFactory.make(providerKind)
        }
    }
}
