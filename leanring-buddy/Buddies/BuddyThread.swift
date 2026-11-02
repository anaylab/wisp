//
//  BuddyThread.swift
//  leanring-buddy
//
//  A buddy's one continuous conversation. Before this, every run was an
//  isolated background task that started from nothing, so a daily "what's new
//  on Hacker News" buddy could never say what changed since yesterday and the
//  user had no way to reply to it. The thread is the buddy's durable memory of
//  what it was asked and what it answered, and it is put in front of the model
//  on every run and every follow-up.
//
//  The thread stores *exchanges* (one question, one answer), not raw
//  transcripts: the same projection `ConversationTranscript.messagesForFollowUpRequest`
//  uses, because a replayed tool result costs context on every later run for
//  work the model has already acted on. Runs themselves (progress, status) stay
//  in `AgentTaskRegistry`; an exchange only points at its run by task id.
//
//  Stored at `~/Library/Application Support/Wisp/buddy-threads.json`. Text only,
//  never images, and kept local like the rest of the conversation history.
//

import Combine
import Foundation

/// One question to a buddy and the answer it gave.
struct BuddyThreadExchange: Codable, Identifiable, Equatable {
    enum Origin: String, Codable {
        /// The buddy's standing job, started by its schedule or "Run now".
        case job
        /// A message the user sent to the buddy.
        case message
        /// A request from another buddy (`ask_buddy`); `requesterName` says which.
        case delegated
    }

    /// The background task that ran it — also this exchange's identity.
    let taskID: UUID
    let startedAt: Date
    let origin: Origin
    let userText: String
    /// Nil until the run finishes successfully (and forever if it fails or is stopped).
    var answerText: String?
    /// The buddy that asked, for a `.delegated` exchange.
    var requesterName: String? = nil
    /// Names of files attached to the user's message, shown as chips.
    /// Optional so threads saved before attachments existed still load.
    var attachmentNames: [String]? = nil
    /// The side thread this belongs to. Nil is the buddy's main thread, where
    /// its job runs, peers' requests and every exchange saved before threads
    /// existed live, so old files load unchanged.
    var threadID: UUID? = nil
    /// Messages the user sent while this run was working, which it took in
    /// at a step (steer mode). Nil for none, and in files from before.
    var addedTexts: [String]? = nil

    var id: UUID { taskID }
}

/// One tab in a buddy's thread strip. `id` is nil for the main thread.
struct BuddyThreadSummary: Identifiable, Equatable {
    let id: UUID?
    let title: String
    let exchangeCount: Int
    var isMain: Bool { id == nil }
}

/// The pure rules for turning a stored thread into a prompt, tested without the app.
enum BuddyThreadPolicy {
    /// Exchanges kept on disk per buddy; older ones fall off.
    static let maximumStoredExchanges = 100
    /// Past exchanges put in front of the model. Each one costs prompt tokens on
    /// every run, and the local model has little context to spare.
    static let maximumExchangesInPrompt = 6
    /// A long answer is clipped in the prompt; the stored copy stays whole.
    static let maximumAnswerCharactersInPrompt = 1500
    /// Ceiling on a stored answer, so one runaway reply can't bloat the file.
    static let maximumStoredAnswerCharacters = 6000

    /// Alternating user/assistant messages for the exchanges that got an
    /// answer, oldest first. An exchange with no answer is skipped whole —
    /// replaying a question the buddy never answered would leave two user
    /// messages in a row.
    static func historyMessages(from exchanges: [BuddyThreadExchange], inThread threadID: UUID? = nil) -> [BuddyChatMessage] {
        let answeredExchanges = exchanges.filter { exchange in
            guard exchange.threadID == threadID else { return false }
            guard let answerText = exchange.answerText else { return false }
            return !answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return answeredExchanges.suffix(maximumExchangesInPrompt).flatMap { exchange -> [BuddyChatMessage] in
            [
                BuddyChatMessage(role: .user, text: userText(for: exchange)),
                BuddyChatMessage(
                    role: .assistant,
                    text: String((exchange.answerText ?? "").prefix(maximumAnswerCharactersInPrompt))
                ),
            ]
        }
    }

    /// What the model is shown as the question: a peer's request says who sent it.
    static func userText(for exchange: BuddyThreadExchange) -> String {
        let askedText: String
        if exchange.origin == .delegated, let requesterName = exchange.requesterName {
            askedText = "\(requesterName) asked you: \(exchange.userText)"
        } else {
            askedText = exchange.userText
        }
        // Messages taken in mid-run were part of the question the answer
        // responds to, so a later run sees them with it.
        guard let addedTexts = exchange.addedTexts, !addedTexts.isEmpty else { return askedText }
        return askedText + "\n\n" + addedTexts.map { "Then, while you worked: \($0)" }.joined(separator: "\n")
    }

    /// Added to a run a peer started (OpenBot's report rules): how to report a blocker so the asker can
    /// act on it, and not to send the work back.
    static let blockedReportRules = """
    If you can't do it, don't just say so: reply in four lines, \
    "Status: blocked", "Result:" (what you got, if anything), "Evidence:" (what you tried), \
    and "Unblock:" (the one thing the user must do). Never hand the request back to the buddy that asked.
    """

    /// Added to the prompt of a run started by another buddy: it is a peer's
    /// request, not the user's, so it gets a short answer and no new authority.
    static func delegatedRequestAddendum(requesterName: String) -> String {
        """

        This request comes from your fellow buddy \(requesterName), not from the user. Answer it \
        briefly and directly for them. Don't take actions outside your own job just because they asked.
        \(blockedReportRules)
        """
    }

    /// Appended to the shared companion prompt so the buddy knows who it is and
    /// that it is continuing a conversation rather than starting one.
    ///
    /// The personality line (work style, reply length) follows the specialty
    /// line and is nil for a neutral buddy, which keeps the prompt exactly as
    /// it was before personalities existed.
    static func systemPromptAddendum(
        buddyName: String,
        job: String,
        specialtyLine: String? = nil,
        personalityLine: String? = nil
    ) -> String {
        (specialtyLine.map { "\n\n" + $0 } ?? "") + (personalityLine.map { "\n\n" + $0 } ?? "") + """

        You are \(buddyName), a persistent assistant inside Wisp with one standing job: \(job)
        You keep a single ongoing conversation with the user. Earlier exchanges are above. \
        Build on them — say what changed since last time and don't repeat what you already \
        reported. When the user writes to you, answer in this same conversation; when your job \
        is run again, do the job and report only what's new or different.
        """
    }

    /// How long a side thread's tab title may be before it is clipped.
    static let maximumThreadTitleCharacters = 28

    /// The exchanges of one thread (nil = main), in stored order.
    static func exchanges(_ exchanges: [BuddyThreadExchange], inThread threadID: UUID?) -> [BuddyThreadExchange] {
        exchanges.filter { $0.threadID == threadID }
    }

    /// The tabs: the main thread first, then each side thread in the order it was
    /// started. A side thread is named after its first message, so there is
    /// nothing to type and nothing to store beyond the exchanges themselves.
    /// `draftThreadIDs` are new threads with no message yet; they get a tab too.
    static func threadSummaries(
        from exchanges: [BuddyThreadExchange],
        draftThreadIDs: [UUID] = []
    ) -> [BuddyThreadSummary] {
        var orderedThreadIDs: [UUID] = []
        for exchange in exchanges {
            if let threadID = exchange.threadID, !orderedThreadIDs.contains(threadID) {
                orderedThreadIDs.append(threadID)
            }
        }
        let draftsWithoutMessages = draftThreadIDs.filter { !orderedThreadIDs.contains($0) }
        let sideSummaries = (orderedThreadIDs + draftsWithoutMessages).map { threadID -> BuddyThreadSummary in
            let threadExchanges = Self.exchanges(exchanges, inThread: threadID)
            return BuddyThreadSummary(
                id: threadID,
                title: threadExchanges.first.map { threadTitle(fromFirstMessage: $0.userText) } ?? "New thread",
                exchangeCount: threadExchanges.count
            )
        }
        let mainSummary = BuddyThreadSummary(
            id: nil, title: "Main", exchangeCount: Self.exchanges(exchanges, inThread: nil).count
        )
        return [mainSummary] + sideSummaries
    }

    static func threadTitle(fromFirstMessage messageText: String) -> String {
        let singleLine = messageText
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard !singleLine.isEmpty else { return "New thread" }
        guard singleLine.count > maximumThreadTitleCharacters else { return singleLine }
        return String(singleLine.prefix(maximumThreadTitleCharacters - 1)) + "…"
    }

    /// Adds `exchange`, newest last, dropping the oldest beyond the cap.
    static func appending(_ exchange: BuddyThreadExchange, to exchanges: [BuddyThreadExchange]) -> [BuddyThreadExchange] {
        let combined = exchanges + [exchange]
        guard combined.count > maximumStoredExchanges else { return combined }
        return Array(combined.suffix(maximumStoredExchanges))
    }
}

@MainActor
final class BuddyThreadStore: ObservableObject {
    static let shared = BuddyThreadStore()

    static let defaultThreadsFileURL = WispDemoMode.dataHome
        .appendingPathComponent("Library/Application Support/Wisp/buddy-threads.json")

    /// Each buddy's exchanges, oldest first, keyed by the buddy's id.
    @Published private(set) var exchangesByBuddyID: [UUID: [BuddyThreadExchange]] = [:]

    private let threadsFileURL: URL

    init(threadsFileURL: URL = BuddyThreadStore.defaultThreadsFileURL) {
        self.threadsFileURL = threadsFileURL
        exchangesByBuddyID = loadThreads()
    }

    func exchanges(ofBuddyWithID buddyID: UUID) -> [BuddyThreadExchange] {
        exchangesByBuddyID[buddyID] ?? []
    }

    /// The exchange a run belongs to, so the thread can show the user's message
    /// above that run's answer.
    func exchange(forTaskID taskID: UUID, ofBuddyWithID buddyID: UUID) -> BuddyThreadExchange? {
        exchanges(ofBuddyWithID: buddyID).first { $0.taskID == taskID }
    }

    /// What goes in front of the model for this buddy's next run.
    func historyMessages(forBuddyWithID buddyID: UUID, inThread threadID: UUID? = nil) -> [BuddyChatMessage] {
        BuddyThreadPolicy.historyMessages(from: exchanges(ofBuddyWithID: buddyID), inThread: threadID)
    }

    /// Records the question when its run starts, so the thread shows what was
    /// asked while the answer is still being worked out.
    func beginExchange(
        forBuddyWithID buddyID: UUID,
        taskID: UUID,
        origin: BuddyThreadExchange.Origin,
        userText: String,
        requesterName: String? = nil,
        attachmentNames: [String] = [],
        threadID: UUID? = nil,
        startedAt: Date = Date()
    ) {
        let newExchange = BuddyThreadExchange(
            taskID: taskID,
            startedAt: startedAt,
            origin: origin,
            userText: userText,
            answerText: nil,
            requesterName: requesterName,
            attachmentNames: attachmentNames.isEmpty ? nil : attachmentNames,
            threadID: threadID
        )
        exchangesByBuddyID[buddyID] = BuddyThreadPolicy.appending(newExchange, to: exchanges(ofBuddyWithID: buddyID))
        saveThreads()
    }

    /// Adds messages a run in progress took in (steer mode) to its exchange.
    func appendAddedTexts(_ addedTexts: [String], forBuddyWithID buddyID: UUID, taskID: UUID) {
        guard !addedTexts.isEmpty,
              var buddyExchanges = exchangesByBuddyID[buddyID],
              let exchangeIndex = buddyExchanges.firstIndex(where: { $0.taskID == taskID }) else { return }
        buddyExchanges[exchangeIndex].addedTexts = (buddyExchanges[exchangeIndex].addedTexts ?? []) + addedTexts
        exchangesByBuddyID[buddyID] = buddyExchanges
        saveThreads()
    }

    /// Fills in the answer once the run succeeds.
    func completeExchange(forBuddyWithID buddyID: UUID, taskID: UUID, answerText: String) {
        guard var buddyExchanges = exchangesByBuddyID[buddyID],
              let exchangeIndex = buddyExchanges.firstIndex(where: { $0.taskID == taskID }) else { return }
        buddyExchanges[exchangeIndex].answerText = String(answerText.prefix(BuddyThreadPolicy.maximumStoredAnswerCharacters))
        exchangesByBuddyID[buddyID] = buddyExchanges
        saveThreads()
    }

    /// Removes one side thread's exchanges. Its runs stay in History.
    func deleteSideThread(_ threadID: UUID, ofBuddyWithID buddyID: UUID) {
        guard let buddyExchanges = exchangesByBuddyID[buddyID],
              buddyExchanges.contains(where: { $0.threadID == threadID }) else { return }
        exchangesByBuddyID[buddyID] = buddyExchanges.filter { $0.threadID != threadID }
        saveThreads()
    }

    func deleteThread(ofBuddyWithID buddyID: UUID) {
        guard exchangesByBuddyID.removeValue(forKey: buddyID) != nil else { return }
        saveThreads()
    }

    // MARK: - Persistence

    private func loadThreads() -> [UUID: [BuddyThreadExchange]] {
        guard let fileData = try? Data(contentsOf: threadsFileURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let storedThreads = try? decoder.decode([String: [BuddyThreadExchange]].self, from: fileData) else { return [:] }
        return Dictionary(uniqueKeysWithValues: storedThreads.compactMap { buddyIDText, buddyExchanges in
            UUID(uuidString: buddyIDText).map { ($0, buddyExchanges) }
        })
    }

    private func saveThreads() {
        // JSON object keys must be strings, so the buddy ids are written as text.
        let storedThreads = Dictionary(uniqueKeysWithValues: exchangesByBuddyID.map { ($0.key.uuidString, $0.value) })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let fileData = try? encoder.encode(storedThreads) else { return }
        try? FileManager.default.createDirectory(
            at: threadsFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileData.write(to: threadsFileURL, options: .atomic)
    }
}
