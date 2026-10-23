//
//  ResearchSession.swift
//  leanring-buddy
//
//  Research mode (phase 11): "research the best budget mechanical keyboards".
//
//  One run, as a background task ("Research · <topic>", so it shows in History
//  and talking carries on meanwhile):
//    1. search: Google's results page opens in a background tab in the purple
//       Wisp group (`openTab`), and its result links are read from the DOM
//       snapshot (`snapshotPage`) — no search API;
//    2. pick 5 (local model) or 8 (cloud) distinct pages (`ResearchSourcePicker`)
//       and open them, inactive, beside it in the Wisp group (`openTabs`);
//    3. read each with `getPageText` once it has settled;
//    4. write: local = one call per page (findings with quotes), then one call
//       combining the checked findings; cloud = one call over every page. Every
//       call is text-only, carries no tools, and goes through `ModelAccessGate`
//       at background priority;
//    5. check every quote against its page (`ResearchReportAssembler`), keep the
//       report (`ResearchSessionController.reports`), optionally file it in the
//       Brain, and tell the notch.
//
//  Which pages are opened and read is decided by this code alone, before any
//  model sees a page, so page text (untrusted, contracts §6) can't change the
//  plan; it can only be quoted, and a quote that isn't on the page is dropped.
//
//  The tabs stay open for the citations (`ResearchSessionController+Tabs`).
//

import Combine
import Foundation

@MainActor
final class ResearchSessionController: ObservableObject {
    static let shared = ResearchSessionController()

    /// Finished reports, newest first. Kept for this launch only: the citations
    /// lead to tabs, which don't outlive the browser session either. History
    /// keeps each report's text.
    @Published private(set) var reports: [ResearchReport] = []
    /// The notch line for the latest finished report, so the notch can offer
    /// "Open report" while that line is showing.
    @Published private(set) var notchLineForLatestReport: String?
    /// The report the Chat page should scroll to (the notch's "Open report").
    @Published var reportIDToReveal: UUID?

    static let maximumKeptReports = 10

    /// Research tabs Wisp opened and still tracks (see the +Tabs extension).
    @Published var openResearchTabs: [Int: ResearchOpenTab] = [:]
    var lastResearchActivityAt = Date()
    var wispFocusedTabAt: [Int: Date] = [:]
    var tabEventSubscription: AnyCancellable?
    var idleCheckTask: Task<Void, Never>?

    /// Shows a finished run in the notch. Set by `CompanionManager` at start-up.
    var presentFinishedResearch: ((String) -> Void)?

    private init() {}

    enum ResearchError: LocalizedError {
        case searchShowedNoResults
        case noReadableSources

        var errorDescription: String? {
            switch self {
            case .searchShowedNoResults:
                return "the search page didn't show results i could read (google may be asking for a captcha or cookie choice). open the wisp tab group, sort it out, and ask again."
            case .noReadableSources:
                return "none of the pages i opened had readable text — they're still in the wisp tab group if you want a look."
            }
        }
    }

    // MARK: - Starting

    /// The router's and the tool's entry point. Returns what to say now; the
    /// report arrives later. `onFinished` gets the report (the agent tool waits
    /// for it).
    @discardableResult
    func start(
        _ request: ResearchRequest,
        modelProvider: any ModelProvider,
        onFinished: ((Result<ResearchReport, Error>) -> Void)? = nil
    ) -> (replyText: String, didStart: Bool) {
        guard ChromeExtensionBridge.shared.isExtensionConnected else {
            return (ChromePageReader.ReaderError.extensionNotConnected.localizedDescription, false)
        }
        guard ChromeExtensionBridge.shared.hasCapability(.pagesRead) else {
            return (ChromePageReader.ReaderError.pagesReadNotAllowed.localizedDescription, false)
        }
        let isLocalModel = !modelProvider.deployment.sendsDataOffThisMachine
        let taskID = BackgroundTaskLauncher.startWork(
            title: "Research · \(request.topic)",
            runsOffThisMachine: !isLocalModel
        ) { [weak self] taskID in
            guard let self else { throw CancellationError() }
            do {
                let report = try await self.run(request, modelProvider: modelProvider, taskID: taskID)
                onFinished?(.success(report))
                return report.plainText
            } catch {
                onFinished?(.failure(error))
                throw error
            }
        }
        guard taskID != nil else {
            return ("wisp is already busy with two background tasks — try the research again when one finishes.", false)
        }
        let modelNote = isLocalModel ? "up to 5 pages, on this mac" : "up to 8 pages"
        return ("researching \(request.topic) in the background (\(modelNote)). the sources open in the wisp tab group; i'll tell you when it's written.", true)
    }

    // MARK: - One run

    private struct OpenedTabReply: Decodable {
        let tabId: Int
        let windowId: Int?
    }

    private struct OpenedTabsReply: Decodable {
        let tabIds: [Int]
    }

    private func run(_ request: ResearchRequest, modelProvider: any ModelProvider, taskID: UUID) async throws -> ResearchReport {
        let bridge = ChromeExtensionBridge.shared
        let isLocalModel = !modelProvider.deployment.sendsDataOffThisMachine
        startTrackingTabsIfNeeded()

        // 1. Search, in a background tab in the Wisp group.
        guard let searchURL = ResearchSearch.searchURL(for: request.searchQuery) else { throw ResearchError.searchShowedNoResults }
        let searchStep = Self.beginStep("Searching for \(request.searchQuery)", taskID: taskID)
        let searchTab = try await bridge.sendRequest(
            method: "openTab",
            parameters: JSONValue.object(["url": .string(searchURL.absoluteString), "active": .bool(false), "inWispGroup": .bool(true)]),
            resultType: OpenedTabReply.self
        )
        trackResearchTab(searchTab.tabId, openedURLString: searchURL.absoluteString)
        _ = await waitForTabToSettle(searchTab.tabId, waitSeconds: 10)
        let searchSnapshotReply = try await bridge.sendRequest(
            method: "snapshotPage",
            parameters: JSONValue.object([
                "tabId": .number(Double(searchTab.tabId)),
                "maximumTextCharacters": .number(500),
                "elementLimit": .number(200),
            ]),
            resultType: JSONValue.self,
            timeoutSeconds: 15
        )
        let searchSnapshot = (try? JSONEncoder().encode(searchSnapshotReply)).flatMap(BrowserPageSnapshotDecoding.snapshot(fromJSONData:))
        let resultLinks = (searchSnapshot?.elements ?? []).compactMap { element -> ResearchSearchResultLink? in
            guard let href = element.href else { return nil }
            return ResearchSearchResultLink(href: href, label: element.label)
        }
        let candidates = ResearchSourcePicker.pickedSources(
            fromSearchResultLinks: resultLinks,
            maximumCount: ResearchBudget.maximumSources(isLocalModel: isLocalModel)
        )
        Self.finishStep(searchStep, taskID: taskID, isError: candidates.isEmpty)
        guard !candidates.isEmpty else { throw ResearchError.searchShowedNoResults }
        try Task.checkCancellation()

        // 2. Open the sources, inactive, beside the search in the Wisp group.
        let openStep = Self.beginStep("Opening \(candidates.count) sources in the Wisp group", taskID: taskID)
        let openedTabs = try await bridge.sendRequest(
            method: "openTabs",
            parameters: JSONValue.object([
                "urls": .array(candidates.map { .string($0.url) }),
                "windowMode": .string("current"),
                "windowId": searchTab.windowId.map { .number(Double($0)) } ?? .null,
                "activateFirstTab": .bool(false),
            ]),
            resultType: OpenedTabsReply.self
        )
        for (candidate, tabID) in zip(candidates, openedTabs.tabIds) {
            trackResearchTab(tabID, openedURLString: candidate.url)
        }
        _ = try? await bridge.sendRequest(
            method: "getOrCreateWispGroup",
            parameters: JSONValue.object(["tabIds": .array(openedTabs.tabIds.map { .number(Double($0)) }), "collapsed": .bool(false)]),
            resultType: JSONValue.self
        )
        Self.finishStep(openStep, taskID: taskID, isError: false)

        // 3. Read each page once it has loaded.
        var sourceDocuments: [ResearchSourceDocument] = []
        for (candidate, tabID) in zip(candidates, openedTabs.tabIds) {
            try Task.checkCancellation()
            let readStep = Self.beginStep("Reading \(candidate.title)", taskID: taskID)
            _ = await waitForTabToSettle(tabID, waitSeconds: 12)
            do {
                let pageText = try await ChromePageReader.readPage(tabID: tabID, timeoutSeconds: 20)
                guard pageText.wordCount >= ResearchBudget.minimumSourceWords else {
                    Self.finishStep(readStep, taskID: taskID, isError: true, detail: "too little text to use (\(pageText.wordCount) words)")
                    continue
                }
                // The address Wisp opened, not one the page reports: a source's
                // address comes from the search results Wisp picked.
                openResearchTabs[tabID]?.readURLString = pageText.url
                sourceDocuments.append(ResearchSourceDocument(
                    url: pageText.url.hasPrefix("http") ? pageText.url : candidate.url,
                    title: pageText.title.isEmpty ? candidate.title : pageText.title,
                    text: pageText.text
                ))
                Self.finishStep(readStep, taskID: taskID, isError: false, detail: "\(pageText.wordCount) words")
            } catch {
                Self.finishStep(readStep, taskID: taskID, isError: true, detail: error.localizedDescription)
            }
        }
        guard !sourceDocuments.isEmpty else { throw ResearchError.noReadableSources }

        // 4. Write.
        let draft = try await Self.writeDraft(topic: request.topic, sources: sourceDocuments, modelProvider: modelProvider, taskID: taskID)

        // 5. Check, keep, file, announce.
        let report = ResearchReportAssembler.assemble(
            topic: request.topic,
            summary: draft.summary,
            draftClaims: draft.claims,
            sourceDocuments: sourceDocuments,
            usedLocalModel: isLocalModel,
            createdAt: Date()
        )
        AgentTaskRegistry.shared.appendStep(AgentStepRecord(
            kind: .tool(name: "research"),
            summary: "Checked every quote against its page: kept \(report.claims.count), dropped \(report.droppedClaimCount)",
            isError: report.claims.isEmpty
        ), to: taskID)
        reports.insert(report, at: 0)
        if reports.count > Self.maximumKeptReports { reports.removeLast(reports.count - Self.maximumKeptReports) }
        lastResearchActivityAt = Date()

        if request.savesToBrain {
            let brainResult = saveToBrain(report)
            AgentTaskRegistry.shared.appendStep(AgentStepRecord(kind: .tool(name: "brain"), summary: brainResult), to: taskID)
        }
        let notchLine = ResearchReportText.notchLine(for: report)
        notchLineForLatestReport = notchLine
        presentFinishedResearch?(notchLine)
        return report
    }

    // MARK: - Writing

    /// The model's part: map → reduce on the local model, one combine call on a
    /// cloud model. Text-only requests with no tools; the pages only ever sit in
    /// the user message's data fences. Static and free of browser state, so
    /// `Tests/HostileProviderAttack` drives it with a hostile model. `taskID`
    /// nil records no History steps.
    static func writeDraft(
        topic: String,
        sources: [ResearchSourceDocument],
        modelProvider: any ModelProvider,
        taskID: UUID?
    ) async throws -> ResearchDraft {
        modelProvider.deployment.sendsDataOffThisMachine
            ? try await writeWithCloudModel(topic: topic, sources: sources, modelProvider: modelProvider, taskID: taskID)
            : try await writeWithLocalModel(topic: topic, sources: sources, modelProvider: modelProvider, taskID: taskID)
    }

    private static func writeWithLocalModel(
        topic: String,
        sources: [ResearchSourceDocument],
        modelProvider: any ModelProvider,
        taskID: UUID?
    ) async throws -> ResearchDraft {
        var findings: [ResearchFinding] = []
        for (offset, source) in sources.enumerated() {
            try Task.checkCancellation()
            let mapStep = Self.beginStep("Noting what \(source.title) says", taskID: taskID, kind: .modelCall)
            let mapReply = try await completeInBackground(
                ModelRequest(
                    systemPrompt: ResearchPrompts.mapSystemPrompt,
                    messages: [BuddyChatMessage(role: .user, text: ResearchPrompts.mapUserMessage(topic: topic, source: source))],
                    maxOutputTokens: ResearchPrompts.maximumMapOutputTokens,
                    temperature: 0.1
                ),
                modelProvider: modelProvider
            )
            let pageFindings = ResearchPrompts.parsedFindings(fromMapReply: mapReply, sourceNumber: offset + 1, firstFindingNumber: findings.count + 1)
            let checkedFindings = ResearchPrompts.verifiedFindings(pageFindings, sources: sources)
            findings.append(contentsOf: checkedFindings)
            Self.finishStep(mapStep, taskID: taskID, isError: false, detail: "\(checkedFindings.count) of \(pageFindings.count) quotes found on the page")
        }
        guard !findings.isEmpty else { return ResearchDraft(summary: "", claims: []) }

        let reduceStep = Self.beginStep("Writing the answer from \(findings.count) findings", taskID: taskID, kind: .modelCall)
        let reduceReply = try await completeInBackground(
            ModelRequest(
                systemPrompt: ResearchPrompts.reduceSystemPrompt,
                messages: [BuddyChatMessage(role: .user, text: ResearchPrompts.reduceUserMessage(
                    topic: topic, findings: findings, sourceTitles: sources.map(\.title)
                ))],
                maxOutputTokens: ResearchPrompts.maximumReduceOutputTokens,
                temperature: 0.2
            ),
            modelProvider: modelProvider
        )
        Self.finishStep(reduceStep, taskID: taskID, isError: false)
        return ResearchPrompts.parsedDraft(fromReduceReply: reduceReply, findings: findings)
    }

    private static func writeWithCloudModel(
        topic: String,
        sources: [ResearchSourceDocument],
        modelProvider: any ModelProvider,
        taskID: UUID?
    ) async throws -> ResearchDraft {
        let combineStep = Self.beginStep("Writing the answer from \(sources.count) pages", taskID: taskID, kind: .modelCall)
        let combineReply = try await completeInBackground(
            ModelRequest(
                systemPrompt: ResearchPrompts.combineSystemPrompt,
                messages: [BuddyChatMessage(role: .user, text: ResearchPrompts.combineUserMessage(topic: topic, sources: sources))],
                maxOutputTokens: ResearchPrompts.maximumCombineOutputTokens,
                temperature: 0.2
            ),
            modelProvider: modelProvider
        )
        Self.finishStep(combineStep, taskID: taskID, isError: false)
        return ResearchPrompts.parsedDraft(fromCombineReply: combineReply)
    }

    /// One text-only model call, queued behind any conversation.
    private static func completeInBackground(_ modelRequest: ModelRequest, modelProvider: any ModelProvider) async throws -> String {
        let callStartedAt = Date()
        let turn = try await ModelAccessGate.shared.withAccess(priority: .background) {
            try await modelProvider.completeTurn(modelRequest)
        }
        UsageLogStore.shared.recordTurn(
            providerIdentifier: modelProvider.identifier,
            counts: UsageTokenCounts(
                inputTokens: turn.promptTokens, outputTokens: turn.outputTokens,
                cacheReadTokens: turn.cacheReadTokens, cacheWriteTokens: turn.cacheWriteTokens,
                reportedCostUSD: turn.reportedCostUSD
            ),
            durationSeconds: Date().timeIntervalSince(callStartedAt),
            screenshotWasAttached: false,
            isBackgroundRun: true
        )
        return turn.text
    }

    // MARK: - Brain

    /// Files a report as Brain pages (`.external`: append and create only).
    @discardableResult
    func saveToBrain(_ report: ResearchReport) -> String {
        guard BrainPreferences.shared.isBrainEnabled else { return "the brain is off, so nothing was saved." }
        let proposals = ResearchBrainPages.proposals(for: report)
        guard !proposals.isEmpty else { return "there were no cited points to save." }
        let applyResult = BrainStore.shared.apply(proposals: proposals, provenance: ResearchBrainPages.provenance(for: report))
        if applyResult.changeID == nil {
            return applyResult.refusals.isEmpty ? "it's already in your brain." : "the brain didn't take it: \(applyResult.refusals.joined(separator: "; "))."
        }
        return "saved to your brain: \(ResearchBrainPages.topicPageTitle(for: report)) and \(report.sources.count) source pages."
    }

    // MARK: - History steps

    private static func beginStep(_ summary: String, taskID: UUID?, kind: AgentStepRecord.Kind = .tool(name: "research")) -> (summary: String, kind: AgentStepRecord.Kind, startedAt: Date) {
        (summary, kind, Date())
    }

    private static func finishStep(
        _ step: (summary: String, kind: AgentStepRecord.Kind, startedAt: Date),
        taskID: UUID?,
        isError: Bool,
        detail: String? = nil
    ) {
        guard let taskID else { return }
        AgentTaskRegistry.shared.appendStep(AgentStepRecord(
            kind: step.kind,
            summary: step.summary,
            detail: detail,
            startedAt: step.startedAt,
            durationSeconds: Date().timeIntervalSince(step.startedAt),
            isError: isError
        ), to: taskID)
    }

    private struct SettleReply: Decodable {
        let loaded: Bool
        let settled: Bool
    }

    func waitForTabToSettle(_ tabID: Int, waitSeconds: Double) async -> Bool {
        let timeouts = ExtensionBrowserReplies.settleRequestTimeouts(forWaitSeconds: waitSeconds)
        let reply = try? await ChromeExtensionBridge.shared.sendRequest(
            method: "waitForSettled",
            parameters: JSONValue.object([
                "tabId": .number(Double(tabID)),
                "waitSeconds": .number(timeouts.waitSeconds),
                "requireQuiet": .bool(true),
            ]),
            resultType: SettleReply.self,
            timeoutSeconds: timeouts.requestTimeoutSeconds
        )
        return reply?.loaded ?? false
    }
}
