//
//  ResearchSessionTabs.swift
//  leanring-buddy
//
//  The tabs a research run opened (phase 11): following them, opening a
//  citation in its tab at its quote, and closing them.
//
//  * Citations: the source's tab is brought forward (`focusTab`) and the quote
//    is marked in the page (`highlightTextFragments`, the phase 05 look). If the
//    quote can't be found there — the page changed — the tab is sent to the
//    quote's text-fragment address so Chrome's own matcher tries. A source
//    whose tab was closed opens again at its text-fragment address.
//  * Closing: "done" (or "close the research tabs") closes them. Tabs the user
//    has used — shown them without Wisp doing it, or gone to another page in
//    them — are closed only after a confirmation card; declining keeps those
//    and closes the rest. After 30 minutes with no research activity, the
//    untouched ones close on their own and the used ones are left alone (an
//    unattended card at a random moment would be worse).
//

import Combine
import Foundation

/// A tab Wisp opened for research. Ids last for the browser session only.
struct ResearchOpenTab: Equatable {
    let tabID: Int
    let openedURLString: String
    /// What `getPageText` reported, when it read the tab.
    var readURLString: String?
    var hasBeenUsedByTheUser = false
}

/// What the router hands over.
enum ResearchCommand: Equatable {
    case start(ResearchRequest)
    case finishSession
}

extension ResearchSessionController {

    /// Read by `BrowserCommandRouter`: a bare "done" only means "close the
    /// research tabs" while there are some.
    var hasOpenResearchTabs: Bool { !openResearchTabs.isEmpty }

    func perform(_ command: ResearchCommand, modelProvider: any ModelProvider) async -> (replyText: String, didSucceed: Bool) {
        switch command {
        case .start(let request):
            let started = start(request, modelProvider: modelProvider)
            return (started.replyText, started.didStart)
        case .finishSession:
            return (await closeResearchTabs(askingAboutUsedTabs: true), true)
        }
    }

    // MARK: - Following the tabs

    func trackResearchTab(_ tabID: Int, openedURLString: String) {
        openResearchTabs[tabID] = ResearchOpenTab(tabID: tabID, openedURLString: openedURLString)
        lastResearchActivityAt = Date()
        startIdleCheckIfNeeded()
    }

    func startTrackingTabsIfNeeded() {
        guard tabEventSubscription == nil else { return }
        tabEventSubscription = ChromeExtensionBridge.shared.extensionEventPublisher
            .filter { ["tab.activated", "tab.updated", "tab.removed"].contains($0.eventName) }
            .sink { [weak self] event in
                MainActor.assumeIsolated { self?.handleTabEvent(event) }
            }
    }

    private struct RemovedTabPayload: Decodable {
        let id: Int
    }

    private func handleTabEvent(_ event: ChromeExtensionEvent) {
        switch event.eventName {
        case "tab.removed":
            guard let removedTab = event.decodePayload(as: RemovedTabPayload.self) else { return }
            openResearchTabs[removedTab.id] = nil
            wispFocusedTabAt[removedTab.id] = nil
        case "tab.activated":
            guard let activatedTab = event.decodePayload(as: ChromeExtensionTabEventPayload.self),
                  openResearchTabs[activatedTab.id] != nil else { return }
            lastResearchActivityAt = Date()
            // Wisp showing a citation isn't the user picking the tab.
            let wasShownByWisp = wispFocusedTabAt[activatedTab.id].map { Date().timeIntervalSince($0) < 3 } ?? false
            if !wasShownByWisp { openResearchTabs[activatedTab.id]?.hasBeenUsedByTheUser = true }
        case "tab.updated":
            guard let updatedTab = event.decodePayload(as: ChromeExtensionTabEventPayload.self),
                  let trackedTab = openResearchTabs[updatedTab.id],
                  updatedTab.changedFields?.contains("url") == true,
                  let newURLString = updatedTab.url else { return }
            // Loading the address Wisp opened (or its redirect, which the read
            // recorded) is still Wisp's page; another page is the user's doing.
            let knownKeys = [trackedTab.openedURLString, trackedTab.readURLString]
                .compactMap { $0 }
                .compactMap(ResearchSourceKey.key(forURLString:))
            if let newKey = ResearchSourceKey.key(forURLString: newURLString),
               !knownKeys.contains(newKey),
               !(wispFocusedTabAt[updatedTab.id].map { Date().timeIntervalSince($0) < 10 } ?? false) {
                openResearchTabs[updatedTab.id]?.hasBeenUsedByTheUser = true
            }
        default:
            break
        }
    }

    // MARK: - Citations

    /// The open research tab showing this source, if any.
    func openTabID(forSourceURLString sourceURLString: String) -> Int? {
        guard let sourceKey = ResearchSourceKey.key(forURLString: sourceURLString) else { return nil }
        return openResearchTabs.values.first { trackedTab in
            [trackedTab.readURLString, trackedTab.openedURLString]
                .compactMap { $0 }
                .contains { ResearchSourceKey.key(forURLString: $0) == sourceKey }
        }?.tabID
    }

    private struct HighlightReply: Decodable {
        let found: [Int]
        let missing: [Int]
    }

    private struct OpenedTabReply: Decodable {
        let tabId: Int
    }

    /// Brings the claim's source forward at its quote. Returns an error line for
    /// the report to show, or nil when it worked.
    @discardableResult
    func openCitation(_ claim: ResearchReport.Claim, in report: ResearchReport) async -> String? {
        guard let source = report.source(numbered: claim.sourceNumber) else { return "that source isn't in the report." }
        let bridge = ChromeExtensionBridge.shared
        guard bridge.isExtensionConnected else { return ChromePageReader.ReaderError.extensionNotConnected.localizedDescription }
        startTrackingTabsIfNeeded()
        lastResearchActivityAt = Date()
        let fragmentURLString = claim.textFragmentURLString ?? source.url

        if let tabID = openTabID(forSourceURLString: source.url) {
            wispFocusedTabAt[tabID] = Date()
            _ = try? await bridge.sendRequest(method: "focusTab", parameters: JSONValue.object(["tabId": .number(Double(tabID))]), resultType: JSONValue.self)
            if await highlight(claim.quote, inTabID: tabID) { return nil }
            // The page no longer has the words where Wisp can find them: let
            // Chrome's own text-fragment matcher try.
            do {
                _ = try await bridge.sendRequest(
                    method: "navigateTab",
                    parameters: JSONValue.object(["tabId": .number(Double(tabID)), "url": .string(fragmentURLString)]),
                    resultType: JSONValue.self
                )
                return nil
            } catch {
                return "i couldn't show that quote: \(error.localizedDescription)"
            }
        }

        // The tab is gone: open the source again, at its quote.
        do {
            let reopenedTab = try await bridge.sendRequest(
                method: "openTab",
                parameters: JSONValue.object(["url": .string(fragmentURLString), "active": .bool(true), "inWispGroup": .bool(true)]),
                resultType: OpenedTabReply.self
            )
            trackResearchTab(reopenedTab.tabId, openedURLString: source.url)
            wispFocusedTabAt[reopenedTab.tabId] = Date()
            if await waitForTabToSettle(reopenedTab.tabId, waitSeconds: 8) {
                _ = await highlight(claim.quote, inTabID: reopenedTab.tabId)
            }
            return nil
        } catch {
            return "i couldn't open that source: \(error.localizedDescription)"
        }
    }

    private func highlight(_ quote: String, inTabID tabID: Int) async -> Bool {
        guard ChromeExtensionBridge.shared.hasCapability(.pagesRead) else { return false }
        let reply = try? await ChromeExtensionBridge.shared.sendRequest(
            method: "highlightTextFragments",
            parameters: JSONValue.object([
                "tabId": .number(Double(tabID)),
                "quotes": .array([.string(quote)]),
                "color": .string(ChromeInPagePointing.markerColorCSS()),
            ]),
            resultType: HighlightReply.self
        )
        return reply?.found.isEmpty == false
    }

    // MARK: - Closing

    /// Closes the research tabs. Used ones are asked about first (a card) when
    /// `askingAboutUsedTabs`, and otherwise left open.
    func closeResearchTabs(askingAboutUsedTabs: Bool) async -> String {
        guard !openResearchTabs.isEmpty else { return "there are no research tabs open." }
        guard ChromeExtensionBridge.shared.isExtensionConnected else {
            return ChromePageReader.ReaderError.extensionNotConnected.localizedDescription
        }
        let usedTabIDs = openResearchTabs.values.filter(\.hasBeenUsedByTheUser).map(\.tabID)
        var tabIDsToClose = openResearchTabs.values.filter { !$0.hasBeenUsedByTheUser }.map(\.tabID)
        var keptUsedTabCount = usedTabIDs.count

        if askingAboutUsedTabs && !usedTabIDs.isEmpty {
            let decision = await ToolConfirmationCoordinator.shared.requestApproval(
                toolName: ResearchToolNames.closeResearchTabs,
                toolInput: .object([
                    "used_tab_count": .number(Double(usedTabIDs.count)),
                    "untouched_tab_count": .number(Double(tabIDsToClose.count)),
                ])
            )
            if decision.isApproved {
                tabIDsToClose.append(contentsOf: usedTabIDs)
                keptUsedTabCount = 0
            }
        }

        if !tabIDsToClose.isEmpty {
            do {
                _ = try await ChromeExtensionBridge.shared.sendRequest(
                    method: "closeTabs",
                    parameters: JSONValue.object(["tabIds": .array(tabIDsToClose.map { .number(Double($0)) })]),
                    resultType: JSONValue.self
                )
            } catch {
                return "i couldn't close the research tabs: \(error.localizedDescription)"
            }
        }
        // Whatever stays open is the user's now; Wisp stops tracking it.
        openResearchTabs.removeAll()
        wispFocusedTabAt.removeAll()
        idleCheckTask?.cancel()
        idleCheckTask = nil

        let closedText = tabIDsToClose.count == 1 ? "closed 1 research tab" : "closed \(tabIDsToClose.count) research tabs"
        guard keptUsedTabCount > 0 else { return "\(closedText)." }
        let keptText = keptUsedTabCount == 1 ? "kept the one you used" : "kept the \(keptUsedTabCount) you used"
        return tabIDsToClose.isEmpty ? "okay, \(keptText)." : "\(closedText) and \(keptText)."
    }

    private func startIdleCheckIfNeeded() {
        guard idleCheckTask == nil else { return }
        idleCheckTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, !Task.isCancelled else { return }
                guard !self.openResearchTabs.isEmpty else { continue }
                let isAnyResearchRunning = AgentTaskRegistry.shared.runningRecords.contains { $0.title.hasPrefix("Research · ") }
                guard !isAnyResearchRunning,
                      Date().timeIntervalSince(self.lastResearchActivityAt) >= ResearchBudget.idleCloseSeconds else { continue }
                self.idleCheckTask = nil
                let closeResult = await self.closeResearchTabs(askingAboutUsedTabs: false)
                print("🔎 Research: idle for 30 minutes — \(closeResult)")
                return
            }
        }
    }
}
