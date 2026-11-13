//
//  MailInboxEngine.swift
//  leanring-buddy
//
//  Runs the Inbox: reads Mail.app every 10 minutes while Wisp runs (only when
//  Mail is open; Sync now opens it), sorts each thread with the rules in
//  `MailInboxImportancePolicy` and asks the model only about the ones the rules
//  aren't sure of, writes replies ahead for important mail that asks the user
//  something, and remembers where the user moved a thread.
//
//  Off by default. Nothing is sent: a draft opens in the email composer and
//  Send there is the only way it leaves the Mac. The model is the local one
//  unless the user picks Wisp's chat model in the Inbox settings.
//
//  State lives in `inbox.json` (0600) under Wisp's Application Support folder.
//

import Combine
import EventKit
import Foundation
import os

/// Sync steps, counts and errors only — never a sender, subject or body.
nonisolated let mailInboxLog = Logger(subsystem: "com.gluepixel.wisp", category: "inbox")

/// The Inbox's switches (UserDefaults).
@MainActor
final class MailInboxPreferences: ObservableObject {
    static let shared = MailInboxPreferences()

    private enum Key {
        static let isEnabled = "wisp.mailInbox.isEnabled"
        static let draftsAhead = "wisp.mailInbox.draftsAhead"
        static let usesChatModel = "wisp.mailInbox.usesChatModel"
        static let userRules = "wisp.mailInbox.userRules"
        static let styleNotes = "wisp.mailInbox.styleNotes"
    }

    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Key.isEnabled) } }
    /// Write replies ahead for important mail that asks something.
    @Published var draftsAhead: Bool { didSet { defaults.set(draftsAhead, forKey: Key.draftsAhead) } }
    /// Sort and draft with Wisp's selected chat model instead of the local one.
    @Published var usesChatModel: Bool { didSet { defaults.set(usesChatModel, forKey: Key.usesChatModel) } }
    /// "What matters to me", in the user's words, for the sorting prompt.
    @Published var userRules: String { didSet { defaults.set(userRules, forKey: Key.userRules) } }
    /// "How I write", for drafts.
    @Published var styleNotes: String { didSet { defaults.set(styleNotes, forKey: Key.styleNotes) } }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.isEnabled: false,
            Key.draftsAhead: true,
            Key.usesChatModel: false,
        ])
        isEnabled = defaults.bool(forKey: Key.isEnabled)
        draftsAhead = defaults.bool(forKey: Key.draftsAhead)
        usesChatModel = defaults.bool(forKey: Key.usesChatModel)
        userRules = defaults.string(forKey: Key.userRules) ?? ""
        styleNotes = defaults.string(forKey: Key.styleNotes) ?? ""
    }

    /// The provider the Inbox reads mail with.
    var modelProviderKind: BuddyChatProviderKind {
        usesChatModel ? BuddyChatProviderSelection.current : .localOllama
    }
}

/// A reply Wisp wrote ahead, for one message.
nonisolated struct MailInboxDraft: Codable, Equatable, Sendable {
    /// The message it answers; a newer message in the thread makes it stale.
    let messageID: String
    let toField: String
    let subject: String
    let body: String
    let writtenAt: Date
}

/// A thread's category, and which message it was decided for.
nonisolated struct MailInboxSortRecord: Codable, Equatable, Sendable {
    let verdict: MailInboxVerdict
    let latestMessageID: String
}

@MainActor
final class MailInboxEngine: ObservableObject {
    static let shared = MailInboxEngine()

    enum SyncPhase: Equatable {
        case idle
        case syncing(String)
        case failed(String)
    }

    @Published private(set) var threads: [MailInboxThread] = []
    @Published private(set) var sortRecords: [String: MailInboxSortRecord] = [:]
    @Published private(set) var drafts: [String: MailInboxDraft] = [:]
    @Published private(set) var corrections: [MailInboxCorrection] = []
    /// Messages the user answered from Wisp's composer (Mail's "replied" flag
    /// isn't set for those, since the composer sends a new message).
    @Published private(set) var answeredMessageIDs: Set<String> = []
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var syncPhase: SyncPhase = .idle
    /// Threads whose reply is being written right now.
    @Published private(set) var threadKeysBeingDrafted: Set<String> = []

    private let preferences = MailInboxPreferences.shared
    private var userSignals = MailInboxUserSignals()
    private var userSignalsReadAt: Date?
    private var clockTimer: Timer?
    private var hasStarted = false
    private var syncTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    static let syncIntervalSeconds: TimeInterval = 10 * 60
    private static let fullReadIntervalSeconds: TimeInterval = 60 * 60
    /// When Mail was last read in full (saved, so a relaunch can use the quick check).
    private var lastFullReadAt: Date?
    /// When the last sync began. Due-ness is measured from here, not from
    /// when it finished, or a sync that takes minutes would push every other
    /// one past the next timer tick.
    private var lastSyncStartedAt: Date?
    private static let userSignalsRefreshSeconds: TimeInterval = 60 * 60

    private init() {
        loadState()
    }

    // MARK: - Reading the state

    func verdict(for thread: MailInboxThread) -> MailInboxVerdict? {
        sortRecords[thread.threadKey]?.verdict
    }

    /// The category the list puts a thread in. Not sorted yet = Everything else,
    /// so an unsure thread never crowds Important.
    func category(of thread: MailInboxThread) -> MailInboxCategory {
        verdict(for: thread)?.category ?? .everythingElse
    }

    func draft(for thread: MailInboxThread) -> MailInboxDraft? {
        guard let draft = drafts[thread.threadKey], draft.messageID == thread.latestMessage.messageID else { return nil }
        return draft
    }

    func isAnswered(_ thread: MailInboxThread) -> Bool {
        thread.latestMessage.wasRepliedTo || answeredMessageIDs.contains(thread.latestMessage.messageID)
    }

    func threads(in category: MailInboxCategory) -> [MailInboxThread] {
        threads.filter { self.category(of: $0) == category }
    }

    /// For Today: important threads not yet answered, and drafts waiting.
    var importantWaitingCount: Int {
        threads(in: .important).filter { !isAnswered($0) && ($0.hasUnread || verdict(for: $0)?.needsReply == true) }.count
    }

    var draftsReadyCount: Int {
        threads(in: .important).filter { draft(for: $0) != nil && !isAnswered($0) }.count
    }

    // MARK: - Lifecycle

    /// Called once at launch. Does nothing until the Inbox is turned on.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        NotificationCenter.default.publisher(for: .wispEmailSent)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                self?.noteEmailSent(
                    subject: notification.userInfo?["subject"] as? String ?? "",
                    toField: notification.userInfo?["to"] as? String ?? ""
                )
            }
            .store(in: &cancellables)
        preferences.$isEnabled
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] isEnabled in
                guard let self else { return }
                if isEnabled { self.startClock() } else { self.stopClock() }
            }
            .store(in: &cancellables)
    }

    private func startClock() {
        guard clockTimer == nil else { return }
        clockTimer = Timer.scheduledTimer(withTimeInterval: Self.syncIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncIfDue() }
        }
        syncIfDue()
    }

    private func stopClock() {
        clockTimer?.invalidate()
        clockTimer = nil
        syncTask?.cancel()
        syncTask = nil
        syncPhase = .idle
    }

    private func syncIfDue() {
        guard preferences.isEnabled, !WispDemoMode.isOn else { return }
        if let lastSyncReference = lastSyncStartedAt ?? lastSyncAt,
           Date().timeIntervalSince(lastSyncReference) < Self.syncIntervalSeconds - 30 { return }
        sync(launchesMail: false)
    }

    /// "Sync now": opens Mail if it isn't running.
    func syncNow() {
        sync(launchesMail: true)
    }

    // MARK: - Sync

    private func sync(launchesMail: Bool) {
        guard syncTask == nil, preferences.isEnabled else { return }
        syncTask = Task { @MainActor [weak self] in
            await self?.runSync(launchesMail: launchesMail)
            self?.syncTask = nil
        }
    }

    private func runSync(launchesMail: Bool) async {
        syncPhase = .syncing("Reading Mail…")
        lastSyncStartedAt = Date()
        mailInboxLog.notice("sync started (launchesMail: \(launchesMail, privacy: .public))")
        var messages: [MailInboxMessage]
        do {
            messages = try await readMessagesFullyOrFromCache(launchesMail: launchesMail)
            // Bodies already read on an earlier sync are kept, so only new
            // mail costs a body read.
            let previousMessagesByID = Dictionary(
                threads.flatMap(\.messages).map { ($0.messageID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for messageIndex in messages.indices {
                guard let previous = previousMessagesByID[messages[messageIndex].messageID], previous.isBodyRead else { continue }
                messages[messageIndex].bodyExcerpt = previous.bodyExcerpt
                messages[messageIndex].hasListUnsubscribeHeader = previous.hasListUnsubscribeHeader
                messages[messageIndex].isBodyRead = true
            }
            // Show the list as soon as the headers are in.
            threads = MailInboxThread.threads(from: messages)
            syncPhase = .syncing("Checking who's who…")
            try await refreshUserSignalsIfNeeded()
            messages = try await readMissingBodies(of: messages)
        } catch let readerError as MailInboxReaderError {
            mailInboxLog.error("sync failed: \(readerError.localizedDescription, privacy: .public)")
            // Mail being closed on an automatic sync isn't a failure worth a red line.
            syncPhase = readerError == .mailNotRunning && !launchesMail ? .idle : .failed(readerError.localizedDescription)
            return
        } catch {
            mailInboxLog.error("sync failed: \(error.localizedDescription, privacy: .public)")
            syncPhase = .failed(error.localizedDescription)
            return
        }
        guard !Task.isCancelled else { return }
        mailInboxLog.notice("read \(messages.count, privacy: .public) messages; own addresses \(self.userSignals.ownAddresses.count, privacy: .public), contacts \(self.userSignals.contactAddresses.count, privacy: .public), wrote to \(self.userSignals.addressesUserWroteTo.count, privacy: .public)")

        threads = MailInboxThread.threads(from: messages)
        lastSyncAt = Date()
        dropRecordsForThreadsThatAreGone()

        // Rules first; collect what they weren't sure about.
        var unsureThreads: [MailInboxThread] = []
        for thread in threads {
            if let existingRecord = sortRecords[thread.threadKey],
               existingRecord.latestMessageID == thread.latestMessage.messageID || existingRecord.verdict.source == .you {
                if existingRecord.latestMessageID != thread.latestMessage.messageID {
                    // A new message from a sender the user placed: keep their
                    // choice, re-read whether it asks something.
                    resort(thread)
                }
                continue
            }
            let outcome = MailInboxImportancePolicy.decide(thread: thread, signals: userSignals, corrections: corrections)
            // Without its body a message can't be judged important (no question
            // to see, no List-Unsubscribe header yet): only "Everything else"
            // is safe to decide now; the rest waits for a later sync's body read.
            if !thread.latestMessage.isBodyRead {
                if case .decided(let verdict) = outcome, verdict.category == .everythingElse || verdict.source == .you {
                    sortRecords[thread.threadKey] = MailInboxSortRecord(verdict: verdict, latestMessageID: thread.latestMessage.messageID)
                }
                continue
            }
            switch outcome {
            case .decided(let verdict):
                sortRecords[thread.threadKey] = MailInboxSortRecord(verdict: verdict, latestMessageID: thread.latestMessage.messageID)
            case .unsure:
                unsureThreads.append(thread)
            }
        }
        saveState()
        mailInboxLog.notice("\(self.threads.count, privacy: .public) threads; \(unsureThreads.count, privacy: .public) left for the model")

        for (threadIndex, thread) in unsureThreads.prefix(MailInboxLimits.maximumModelTriagesPerSync).enumerated() {
            guard !Task.isCancelled, preferences.isEnabled else { return }
            syncPhase = .syncing("Sorting \(threadIndex + 1) of \(min(unsureThreads.count, MailInboxLimits.maximumModelTriagesPerSync))…")
            if let verdict = await askModelToSort(thread) {
                sortRecords[thread.threadKey] = MailInboxSortRecord(verdict: verdict, latestMessageID: thread.latestMessage.messageID)
                saveState()
            }
        }

        if preferences.draftsAhead {
            let now = Date()
            let threadsToDraft = threads.filter { thread in
                guard let verdict = verdict(for: thread), draft(for: thread) == nil, !isAnswered(thread) else { return false }
                return MailInboxDraftPolicy.shouldDraftAhead(thread: thread, verdict: verdict, signals: userSignals, now: now)
            }
            for (threadIndex, thread) in threadsToDraft.prefix(MailInboxLimits.maximumDraftsPerSync).enumerated() {
                guard !Task.isCancelled, preferences.isEnabled else { return }
                syncPhase = .syncing("Writing reply \(threadIndex + 1) of \(min(threadsToDraft.count, MailInboxLimits.maximumDraftsPerSync))…")
                _ = try? await writeDraft(for: thread, priority: .background)
            }
        }
        mailInboxLog.notice("sync finished: \(self.threads(in: .important).count, privacy: .public) important, \(self.drafts.count, privacy: .public) drafts")
        syncPhase = .idle
    }

    /// The full read takes Mail minutes on a big inbox, so it runs only when
    /// the quick id check finds new or removed mail, or once an hour (read and
    /// replied flags change without new mail). Otherwise the stored copy is used.
    private func readMessagesFullyOrFromCache(launchesMail: Bool) async throws -> [MailInboxMessage] {
        let cachedMessages = threads.flatMap(\.messages)
        if !cachedMessages.isEmpty, let lastFullReadAt, Date().timeIntervalSince(lastFullReadAt) < Self.fullReadIntervalSeconds {
            let recentIDs = try await MailInboxReader.readRecentMessageIDs(launchesMail: launchesMail)
            if recentIDs == Set(cachedMessages.map(\.messageID)) {
                return cachedMessages
            }
        }
        let freshMessages = try await MailInboxReader.readInboxMessages(launchesMail: launchesMail)
        lastFullReadAt = Date()
        return freshMessages
    }

    /// Reads bodies the cache doesn't have: people before automated senders,
    /// newest first, as many as fit the body step's time budget.
    private func readMissingBodies(of messages: [MailInboxMessage]) async throws -> [MailInboxMessage] {
        let unreadMessages = messages
            .filter { !$0.isBodyRead }
            .sorted { first, second in
                let firstAutomated = MailInboxImportancePolicy.looksAutomated(senderAddress: first.senderAddress)
                let secondAutomated = MailInboxImportancePolicy.looksAutomated(senderAddress: second.senderAddress)
                if firstAutomated != secondAutomated { return !firstAutomated }
                return first.receivedAt > second.receivedAt
            }
        guard !unreadMessages.isEmpty else { return messages }
        syncPhase = .syncing("Reading \(min(unreadMessages.count, MailInboxReader.maximumBodiesPerSync)) new emails…")
        let bodiesByID = try await MailInboxReader.readBodies(of: unreadMessages)
        return messages.map { message in
            guard let bodyRecord = bodiesByID[message.messageID] else { return message }
            var readMessage = message
            readMessage.bodyExcerpt = bodyRecord.body
            readMessage.hasListUnsubscribeHeader = bodyRecord.hasListUnsubscribeHeader
            readMessage.isBodyRead = true
            return readMessage
        }
    }

    private func refreshUserSignalsIfNeeded() async throws {
        if let userSignalsReadAt, Date().timeIntervalSince(userSignalsReadAt) < Self.userSignalsRefreshSeconds { return }
        let addressSignals = try await MailInboxReader.readUserAddressSignals()
        // The Me card's addresses count as the user's own too.
        let meCardAddresses = await ContactsDirectory.shared.meCard(asksForAccess: false)?
            .emailHandles.map { $0.value.lowercased() } ?? []
        userSignals = MailInboxUserSignals(
            ownAddresses: addressSignals.ownAddresses.union(meCardAddresses),
            contactAddresses: await ContactsDirectory.shared.allEmailAddressesIfAuthorized(),
            addressesUserWroteTo: addressSignals.addressesUserWroteTo
        )
        userSignalsReadAt = Date()
    }

    private func resort(_ thread: MailInboxThread) {
        if case .decided(let verdict) = MailInboxImportancePolicy.decide(thread: thread, signals: userSignals, corrections: corrections) {
            sortRecords[thread.threadKey] = MailInboxSortRecord(verdict: verdict, latestMessageID: thread.latestMessage.messageID)
        }
    }

    private func dropRecordsForThreadsThatAreGone() {
        let liveKeys = Set(threads.map(\.threadKey))
        sortRecords = sortRecords.filter { liveKeys.contains($0.key) }
        drafts = drafts.filter { liveKeys.contains($0.key) }
        let liveMessageIDs = Set(threads.flatMap { $0.messages.map(\.messageID) })
        answeredMessageIDs = answeredMessageIDs.filter { liveMessageIDs.contains($0) }
    }

    // MARK: - Model

    private func askModelToSort(_ thread: MailInboxThread) async -> MailInboxVerdict? {
        let request = ModelRequest(
            systemPrompt: MailInboxTriagePrompt.systemPrompt(userRules: preferences.userRules),
            messages: [BuddyChatMessage(role: .user, text: MailInboxTriagePrompt.userMessage(thread: thread, corrections: corrections))],
            maxOutputTokens: 40,
            temperature: 0
        )
        let modelProvider = ModelProviderFactory.make(preferences.modelProviderKind)
        do {
            let turn = try await ModelAccessGate.shared.withAccess(priority: .background) {
                try await modelProvider.completeTurn(request)
            }
            guard let parsed = MailInboxTriagePrompt.parse(modelReply: turn.text) else { return nil }
            return MailInboxVerdict(
                category: parsed.category,
                reason: parsed.category == .important ? "Wisp thinks it matters" : "Can wait",
                source: .model,
                needsReply: parsed.needsReply
            )
        } catch {
            mailInboxLog.error("sorting failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private struct EmptyDraftError: LocalizedError {
        var errorDescription: String? { "the model's reply had no email in it" }
    }

    @discardableResult
    private func writeDraft(for thread: MailInboxThread, priority: ModelAccessGate.Priority) async throws -> MailInboxDraft {
        threadKeysBeingDrafted.insert(thread.threadKey)
        defer { threadKeysBeingDrafted.remove(thread.threadKey) }

        let latest = thread.latestMessage
        let brainContext: String? = BrainPreferences.shared.isBrainEnabled
            ? BrainStore.shared.promptContext(forRequest: "\(latest.senderName) \(latest.subject)")
            : nil
        let meCard = await ContactsDirectory.shared.meCard(asksForAccess: false)
        let senderFirstName = meCard.map { $0.givenName.isEmpty ? $0.nickname : $0.givenName }
        let request = ModelRequest(
            systemPrompt: EmailDraftPrompt.systemPrompt(senderFirstName: senderFirstName, isReply: false),
            messages: [BuddyChatMessage(role: .user, text: MailInboxDraftPolicy.draftUserMessage(
                thread: thread,
                brainContext: brainContext,
                upcomingEventLines: await upcomingEventLines(),
                styleNotes: preferences.styleNotes
            ))],
            maxOutputTokens: 600,
            temperature: 0.4
        )
        let modelProvider = ModelProviderFactory.make(preferences.modelProviderKind)
        let turn = try await ModelAccessGate.shared.withAccess(priority: priority) {
            try await modelProvider.completeTurn(request)
        }
        guard let parsedDraft = EmailDraftReplyParser.parse(modelReply: turn.text) else { throw EmptyDraftError() }
        let draft = MailInboxDraft(
            messageID: latest.messageID,
            toField: latest.senderName.isEmpty
                ? latest.senderAddress
                : EmailAddressList.fieldEntry(displayName: latest.senderName, address: latest.senderAddress),
            subject: MailInboxDraftPolicy.replySubject(for: latest.subject),
            body: parsedDraft.body,
            writtenAt: Date()
        )
        drafts[thread.threadKey] = draft
        saveState()
        return draft
    }

    /// The next week's events, only if Calendar access was already given (the
    /// Inbox never asks for it).
    private func upcomingEventLines() async -> [String] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let now = Date()
        guard let events = try? await CalendarDataProvider.shared.events(
            from: now,
            to: now.addingTimeInterval(7 * 24 * 60 * 60),
            maximumEventCount: 15
        ) else { return [] }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM HH:mm"
        return events.map { event in
            event.isAllDay ? "\(formatter.string(from: event.startDate).prefix(10)) all day: \(event.title)" : "\(formatter.string(from: event.startDate)): \(event.title)"
        }
    }

    // MARK: - User actions

    /// Opens the reply in the composer: the draft written ahead, or one written now.
    func reply(to thread: MailInboxThread) {
        if let readyDraft = draft(for: thread) {
            EmailComposerWindowController.shared.open(
                with: EmailDraftFields(toField: readyDraft.toField, subject: readyDraft.subject, body: readyDraft.body),
                isWriting: false
            )
            return
        }
        let latest = thread.latestMessage
        let composerController = EmailComposerWindowController.shared
        let composerModel = composerController.open(
            with: EmailDraftFields(
                toField: latest.senderName.isEmpty
                    ? latest.senderAddress
                    : EmailAddressList.fieldEntry(displayName: latest.senderName, address: latest.senderAddress),
                subject: MailInboxDraftPolicy.replySubject(for: latest.subject)
            ),
            isWriting: true
        )
        func writeIntoComposer() {
            composerModel.phase = .writing
            composerController.draftWritingTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let writtenDraft = try await self.writeDraft(for: thread, priority: .interactive)
                    guard !Task.isCancelled else { return }
                    composerModel.fillWrittenDraft(subject: writtenDraft.subject, body: writtenDraft.body, toAddressFromScreen: nil)
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    composerModel.showWritingFailure(
                        "I couldn't write the reply (\(error.localizedDescription)). Write it here, or try again.",
                        retry: { writeIntoComposer() }
                    )
                }
            }
        }
        writeIntoComposer()
    }

    /// The user moved a thread to the other bucket. Remembered for its sender.
    func move(_ thread: MailInboxThread, to category: MailInboxCategory) {
        let latest = thread.latestMessage
        corrections.removeAll { MailInboxImportancePolicy.normalizedAddress($0.senderAddress) == MailInboxImportancePolicy.normalizedAddress(latest.senderAddress) }
        corrections.append(MailInboxCorrection(senderAddress: latest.senderAddress, subject: latest.subject, category: category, correctedAt: Date()))
        if corrections.count > MailInboxLimits.maximumStoredCorrections {
            corrections.removeFirst(corrections.count - MailInboxLimits.maximumStoredCorrections)
        }
        // Every thread from this sender follows the user's choice.
        for senderThread in threads where MailInboxImportancePolicy.normalizedAddress(senderThread.latestMessage.senderAddress)
            == MailInboxImportancePolicy.normalizedAddress(latest.senderAddress) {
            resort(senderThread)
        }
        saveState()
    }

    func openInMail(_ thread: MailInboxThread) {
        MailInboxReader.openInMail(messageID: thread.latestMessage.messageID)
    }

    /// Forgets everything the Inbox stored (it re-reads Mail on the next sync).
    func clearStoredMail() {
        threads = []
        sortRecords = [:]
        drafts = [:]
        answeredMessageIDs = []
        lastSyncAt = nil
        lastFullReadAt = nil
        try? FileManager.default.removeItem(at: Self.stateFileURL)
    }

    /// A draft sent from the composer: find the thread it answers and mark it.
    private func noteEmailSent(subject: String, toField: String) {
        let sentSubject = MailInboxThread.normalizedSubject(subject)
        let sentAddresses = Set(EmailAddressList.parse(toField).addresses.map { $0.lowercased() })
        guard let answeredThread = threads.first(where: { thread in
            MailInboxThread.normalizedSubject(thread.subject) == sentSubject
                && sentAddresses.contains(MailInboxImportancePolicy.normalizedAddress(thread.latestMessage.senderAddress))
        }) else { return }
        answeredMessageIDs.insert(answeredThread.latestMessage.messageID)
        drafts[answeredThread.threadKey] = nil
        saveState()
    }

    // MARK: - Persistence

    nonisolated private struct PersistedState: Codable {
        var messages: [MailInboxMessage]
        var sortRecords: [String: MailInboxSortRecord]
        var drafts: [String: MailInboxDraft]
        var corrections: [MailInboxCorrection]
        var answeredMessageIDs: [String]
        var lastSyncAt: Date?
        var lastFullReadAt: Date?
    }

    private static let stateWriteQueue = DispatchQueue(label: "com.wisp.mailInbox.state", qos: .utility)

    static var stateFileURL: URL {
        WispDemoMode.applicationSupportDirectory
            .appendingPathComponent("Wisp", isDirectory: true)
            .appendingPathComponent("inbox.json")
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: Self.stateFileURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return }
        threads = MailInboxThread.threads(from: state.messages)
        sortRecords = state.sortRecords
        drafts = state.drafts
        corrections = state.corrections
        answeredMessageIDs = Set(state.answeredMessageIDs)
        lastSyncAt = state.lastSyncAt
        lastFullReadAt = state.lastFullReadAt
    }

    private func saveState() {
        let state = PersistedState(
            messages: threads.flatMap(\.messages),
            sortRecords: sortRecords,
            drafts: drafts,
            corrections: corrections,
            answeredMessageIDs: Array(answeredMessageIDs),
            lastSyncAt: lastSyncAt,
            lastFullReadAt: lastFullReadAt
        )
        let fileURL = Self.stateFileURL
        guard let data = try? JSONEncoder().encode(state) else { return }
        // One serial queue, so saves land in the order they were made.
        Self.stateWriteQueue.async {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }
}
