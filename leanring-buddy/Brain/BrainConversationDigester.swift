//
//  BrainConversationDigester.swift
//  leanring-buddy
//
//  Files lasting things from the user's finished conversations into the brain.
//
//  The record of a conversation is `AgentTaskRegistry` — each exchange keeps
//  the user's question (as its title) and Wisp's final answer — grouped into
//  sessions by `NotchConversationSessionGrouper` (a 30-minute pause starts a
//  new one; dictation and background work are already left out). Every ten
//  minutes, sessions that have ended and weren't digested yet are cleaned
//  (`BrainConversationDigestPlanner`), saved to `raw/conversations/`, read by
//  `BrainKnowledgeExtractor` and applied as one undoable change per session
//  with `.conversation` provenance and `.derivedFromUser` trust — so a digest
//  may add facts to the user's own page but never overwrite anything.
//
//  `ConversationHistoryStore` is not used: it keeps only 20 turns and the
//  model-facing projection (tool calls, tool results) rather than what was
//  said, and its turns have no session boundaries.
//

import Combine
import Foundation

@MainActor
final class BrainConversationDigester: ObservableObject {
    static let shared = BrainConversationDigester()

    @Published private(set) var lastDigestDate: Date?
    @Published private(set) var isDigesting = false
    /// One line about the last digest ("filed 4 facts into 2 pages").
    @Published private(set) var lastDigestSummary: String?

    /// How often finished sessions are looked for.
    static let checkIntervalSeconds: TimeInterval = 10 * 60
    /// First check after launch — late enough not to compete with the user's
    /// first turns while the model loads.
    static let firstCheckDelaySeconds: TimeInterval = 2 * 60

    private var periodicCheckTask: Task<Void, Never>?

    private var stateFileURL: URL {
        BrainStore.shared.vaultURL
            .appendingPathComponent(".brain", isDirectory: true)
            .appendingPathComponent("digest-state.json")
    }

    private init() {
        let savedState = loadState()
        lastDigestDate = savedState.lastDigestDate
        lastDigestSummary = savedState.lastDigestSummary
    }

    /// Begins the periodic check for finished conversation sessions.
    func start() {
        guard periodicCheckTask == nil else { return }
        periodicCheckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.firstCheckDelaySeconds))
            while !Task.isCancelled {
                await self?.runDigestPass()
                try? await Task.sleep(for: .seconds(Self.checkIntervalSeconds))
            }
        }
    }

    /// Digests any undigested finished sessions right away.
    func digestNow() {
        Task { [weak self] in
            await self?.runDigestPass()
        }
    }

    // MARK: - The pass

    private var isDigestAllowed: Bool {
        BrainPreferences.shared.isBrainEnabled && BrainPreferences.shared.isConversationDigestEnabled
    }

    /// Digests up to `maximumSessionsPerPass` ended sessions, oldest first.
    /// A model failure stops the pass (the session is retried next time, up
    /// to `maximumAttemptsPerSession`), so an unreachable Ollama doesn't burn
    /// through every session as "nothing lasting".
    private func runDigestPass() async {
        guard isDigestAllowed, !isDigesting else { return }
        isDigesting = true
        defer { isDigesting = false }

        var digestState = loadState()
        let now = Date()
        if digestState.lastDigestedExchangeDate == nil {
            // First ever run: fix the one-week lookback now, so a restart
            // tomorrow doesn't widen it.
            digestState.lastDigestedExchangeDate = BrainConversationDigestPlanner.effectiveWatermark(state: digestState, now: now)
            saveState(digestState)
        }

        let watermark = BrainConversationDigestPlanner.effectiveWatermark(state: digestState, now: now)
        let recordsAfterWatermark = BrainConversationDigestPlanner.recordsAfterWatermark(
            AgentTaskRegistry.shared.records,
            watermark: watermark
        )
        let sessionsNewestFirst = NotchConversationSessionGrouper.sessions(from: recordsAfterWatermark)
        let sessionsToDigest = BrainConversationDigestPlanner.sessionsReadyToDigest(
            from: sessionsNewestFirst,
            state: digestState,
            now: now
        )
        guard !sessionsToDigest.isEmpty else { return }

        var allChangeDescriptions: [String] = []
        var allTouchedSlugs = Set<String>()
        var digestedSessionCount = 0
        var skippedSessionCount = 0
        var modelFailureMessage: String?

        for session in sessionsToDigest {
            // The user may switch the digest (or the brain) off mid-pass.
            guard isDigestAllowed, !Task.isCancelled else { break }

            let exchanges = BrainConversationDigestPlanner.digestibleExchanges(
                from: session.exchanges,
                isDirectCommand: Self.isDirectCommand
            )
            guard BrainConversationDigestPlanner.isWorthDigesting(exchanges) else {
                digestState.markSessionHandled(sessionID: session.id, lastExchangeDate: session.lastActivityAt)
                saveState(digestState)
                skippedSessionCount += 1
                continue
            }

            let transcriptMarkdown = BrainConversationDigestPlanner.transcriptMarkdown(
                exchanges: exchanges,
                sessionStartDate: session.startedAt
            )
            let transcriptFileName = BrainConversationDigestPlanner.transcriptFileStem(for: session.startedAt) + ".md"
            do {
                try BrainStore.shared.storeRawText(transcriptMarkdown, fileName: transcriptFileName, subfolder: "conversations")
            } catch {
                // The transcript is evidence, not a prerequisite: still digest.
                print("⚠️ Brain digest: couldn't save \(transcriptFileName): \(error.localizedDescription)")
            }

            let provenanceLabel = BrainConversationDigestPlanner.provenanceLabel(for: session.startedAt)
            let sourceMaterial = BrainKnowledgeExtractor.SourceMaterial(
                title: provenanceLabel,
                text: BrainConversationDigestPlanner.materialText(exchanges: exchanges, sessionStartDate: session.startedAt),
                materialDescription: "a conversation between the user and Wisp, their assistant",
                extraInstructions: BrainConversationDigestPlanner.extractionInstructions,
                // A digest files facts onto real pages; it is not a source to cite.
                createsSourcePage: false
            )

            let proposals: [BrainEditProposal]
            do {
                proposals = try await BrainKnowledgeExtractor.proposeEdits(
                    for: sourceMaterial,
                    modelProvider: ModelProviderFactory.make()
                )
            } catch {
                let didGiveUp = digestState.recordFailedAttempt(sessionID: session.id, lastExchangeDate: session.lastActivityAt)
                saveState(digestState)
                modelFailureMessage = error.localizedDescription
                print("⚠️ Brain digest: \(provenanceLabel) failed\(didGiveUp ? " (giving up on it)" : ""): \(error.localizedDescription)")
                break
            }

            // Re-check after the (slow) model call before writing anything.
            guard isDigestAllowed else { break }
            let applyResult = BrainStore.shared.apply(
                proposals: proposals,
                provenance: BrainEditProvenance(origin: .conversation, label: provenanceLabel, trust: .derivedFromUser)
            )
            allChangeDescriptions += applyResult.changeDescriptions
            allTouchedSlugs.formUnion(applyResult.touchedSlugs)
            digestState.markSessionHandled(sessionID: session.id, lastExchangeDate: session.lastActivityAt)
            saveState(digestState)
            digestedSessionCount += 1
        }

        guard digestedSessionCount + skippedSessionCount > 0 else {
            if let modelFailureMessage {
                lastDigestSummary = "couldn't read conversations: \(modelFailureMessage)"
            }
            return
        }
        let summaryLine = BrainConversationDigestPlanner.summaryLine(
            changeDescriptions: allChangeDescriptions,
            touchedPageCount: allTouchedSlugs.count,
            digestedSessionCount: digestedSessionCount,
            skippedSessionCount: skippedSessionCount
        )
        lastDigestDate = Date()
        lastDigestSummary = summaryLine
        digestState.lastDigestDate = lastDigestDate
        digestState.lastDigestSummary = summaryLine
        saveState(digestState)
    }

    /// Requests the app's own routers would have carried out without a
    /// conversation — browser tab commands and web tasks, "text mom …". The
    /// planner's word heuristic and the "handled natively" step catch the rest.
    private static func isDirectCommand(_ request: String) -> Bool {
        BrowserCommandRouter.route(request) != nil
            || MessageCommandParser.candidates(from: request) != nil
    }

    // MARK: - State file

    private func loadState() -> BrainConversationDigestState {
        guard let stateData = try? Data(contentsOf: stateFileURL) else { return BrainConversationDigestState() }
        // Dates use the default (fractional seconds) encoding, not ISO 8601:
        // the watermark is compared with `>` against exchange dates, and ISO
        // 8601's whole seconds would let the last digested exchange back in.
        let decoder = JSONDecoder()
        return (try? decoder.decode(BrainConversationDigestState.self, from: stateData)) ?? BrainConversationDigestState()
    }

    private func saveState(_ digestState: BrainConversationDigestState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let stateData = try? encoder.encode(digestState) else { return }
        try? FileManager.default.createDirectory(at: stateFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? stateData.write(to: stateFileURL, options: .atomic)
    }
}
