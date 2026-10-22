//
//  ChromeTabLife.swift
//  leanring-buddy
//
//  Carrying out the tab-life commands (phase 04) through the Wisp Tabs
//  extension: save / restore / list tab sessions, close stale tabs (saved as a
//  session first), and the triage plan. Plus their confirmation cards and the
//  agent tools.
//
//  What asks, and why:
//  * Closing stale tabs and the triage plan always ask, on one card that says
//    how many tabs close and where they were saved — even under session
//    auto-approve (`ChromeTabLifeToolNames.mustAlwaysAsk`), because closing is
//    what contracts §6 says always gets a card.
//  * Restoring asks only for 10+ tabs: a few tabs are what the user asked for
//    by name, a big session is a lot of pages to open on a misheard name.
//  * Saving and listing don't ask: saving only adds a row to Wisp's own list,
//    which the user can delete, and nothing in Chrome changes.
//
//  The spoken route and the agent tools run the same functions, so the card
//  and its numbers are the same either way.
//

import Foundation

@MainActor
enum ChromeTabLife {

    /// Runs a spoken command and returns the reply.
    static func perform(_ command: ChromeTabLifeCommand, modelProvider: any ModelProvider) async throws -> String {
        switch command {
        case .saveSession(let sessionName, let scope):
            return try await saveSession(named: sessionName, scope: scope == .allWindows ? .allWindows : .focusedWindow)
        case .restoreSession(let spokenName):
            return try await restoreSession(spokenName: spokenName)
        case .listSessions:
            return ChromeTabSessionDescriptions.listText(for: ChromeTabSessionStore.shared.sessions)
        case .closeStaleTabs(let rules):
            switch try await prepareStaleSweep(rules: rules) {
            case .nothingToDo(let replyText):
                return replyText
            case .ready(let preparedInput):
                let decision = await ToolConfirmationCoordinator.shared.requestApproval(
                    toolName: ChromeTabLifeToolNames.closeStaleTabs, toolInput: preparedInput
                )
                guard decision.isApproved else { return "okay, i left your tabs alone." }
                return try await runStaleSweep(preparedInput: preparedInput)
            }
        case .triage(let rules):
            return try await triageTabs(staleRules: rules, modelProvider: modelProvider)
        }
    }

    // MARK: - Save

    static func saveSession(named requestedName: String?, scope: ChromeTabSessionBuilder.Scope) async throws -> String {
        let snapshot = try await ChromeTabOrganizer.fetchSnapshot()
        let store = ChromeTabSessionStore.shared
        let cleanedRequestedName = requestedName.map(ChromeTabSessionBuilder.cleanedName) ?? ""
        let sessionName = ChromeTabSessionNameMatcher.normalizedName(cleanedRequestedName).isEmpty
            ? ChromeTabSessionBuilder.uniqueName(ChromeTabSessionBuilder.datedName(prefix: "Tabs", on: Date()), existingNames: store.sessionNames)
            : cleanedRequestedName
        guard let newSession = ChromeTabSessionBuilder.session(named: sessionName, from: snapshot, scope: scope, createdAt: Date()) else {
            return "there are no web pages to save in that window."
        }
        let saveEffect = store.save(newSession, mayAddToBrain: true)
        let replacedText = saveEffect == .replacedSessionWithSameName ? " (replacing the old one)" : ""
        let groupText = newSession.groupCount > 0
            ? " and \(newSession.groupCount) group\(newSession.groupCount == 1 ? "" : "s")"
            : ""
        return "saved \(ChromeTabSessionDescriptions.tabCountText(newSession.tabCount))\(groupText) as \"\(newSession.name)\"\(replacedText). say \"restore \(newSession.name.lowercased())\" to bring them back."
    }

    // MARK: - Restore

    private struct OpenTabsParameters: Encodable {
        let urls: [String]
        let windowMode: String
        let windowId: Int?
        let groupTitle: String?
        let groupColor: String?
        let pinned: Bool
    }

    private struct OpenTabsResult: Decodable {
        let windowId: Int
        let openedCount: Int
    }

    static func restoreSession(spokenName: String) async throws -> String {
        let store = ChromeTabSessionStore.shared
        let sessionToRestore: ChromeTabSession
        switch ChromeTabSessionNameMatcher.match(spokenPhrase: spokenName, in: store.sessions) {
        case .found(let foundSession):
            sessionToRestore = foundSession
        case .ambiguous(let lookAlikeSessions):
            let names = lookAlikeSessions.prefix(3).map { "\"\($0.name)\"" }.joined(separator: " and ")
            return "a few sessions have that name — \(names). rename one in wisp's settings, then try again."
        case .notFound:
            if store.sessions.isEmpty { return "you have no saved tab sessions yet." }
            let recentNames = ChromeTabSessionList.newestFirst(store.sessions).prefix(3).map { "\"\($0.name)\"" }.joined(separator: ", ")
            return "i don't have a tab session called \"\(spokenName)\". recent ones: \(recentNames)."
        }

        return try await restore(sessionToRestore, asksBeforeBigRestore: true)
    }

    /// Opens a session's tabs. The Tab sessions row passes
    /// `asksBeforeBigRestore: false`: clicking Restore on that exact session
    /// is the consent a misheard name can't give.
    static func restore(_ sessionToRestore: ChromeTabSession, asksBeforeBigRestore: Bool) async throws -> String {
        if asksBeforeBigRestore && ChromeTabRestorePlanner.asksBeforeRestoring(sessionToRestore) {
            let decision = await ToolConfirmationCoordinator.shared.requestApproval(
                toolName: ChromeTabLifeToolNames.restoreTabSession,
                toolInput: restoreConfirmationInput(for: sessionToRestore)
            )
            guard decision.isApproved else { return "okay, i didn't open them." }
        }

        // Each saved window becomes a new window; later sections of that
        // window go into the window its first request made.
        var newWindowIDsByWindowOffset: [Int: Int] = [:]
        var openedTabCount = 0
        for openRequest in ChromeTabRestorePlanner.openRequests(for: sessionToRestore) {
            let existingWindowID = newWindowIDsByWindowOffset[openRequest.windowOffset]
            let opensNewWindow = openRequest.opensNewWindow || existingWindowID == nil
            let openResult = try await ChromeExtensionBridge.shared.sendRequest(
                method: "openTabs",
                parameters: OpenTabsParameters(
                    urls: openRequest.urls,
                    windowMode: opensNewWindow ? "new" : "current",
                    windowId: opensNewWindow ? nil : existingWindowID,
                    groupTitle: openRequest.groupTitle,
                    groupColor: openRequest.groupColor,
                    pinned: openRequest.pinned
                ),
                resultType: OpenTabsResult.self,
                timeoutSeconds: 20
            )
            newWindowIDsByWindowOffset[openRequest.windowOffset] = openResult.windowId
            openedTabCount += openResult.openedCount
        }
        return "opened \(ChromeTabSessionDescriptions.tabCountText(openedTabCount)) from \"\(sessionToRestore.name)\"."
    }

    /// What the restore card is drawn from.
    static func restoreConfirmationInput(for session: ChromeTabSession) -> JSONValue {
        .object([
            "session_name": .string(session.name),
            "window_count": .number(Double(session.windows.count)),
            "group_count": .number(Double(session.groupCount)),
            "tabs": .array(session.allTabs.map { ChromeTabLifeCards.listedTabValue(title: $0.title, url: $0.url, tabID: nil) }),
        ])
    }

    // MARK: - Stale sweep

    enum PreparedChange {
        case nothingToDo(String)
        case ready(JSONValue)
    }

    /// Finds the stale tabs and names the session they'll be saved as. The
    /// result is both what the card shows and what `runStaleSweep` runs.
    static func prepareStaleSweep(rules: ChromeStaleTabRules) async throws -> PreparedChange {
        let snapshot = try await ChromeTabOrganizer.fetchSnapshot()
        let staleTabs = ChromeStaleTabFinder.staleTabs(in: snapshot, nowMilliseconds: currentMilliseconds(), rules: rules)
        guard !staleTabs.isEmpty else { return .nothingToDo(ChromeStaleTabFinder.nothingStaleText(rules: rules)) }
        return .ready(.object([
            "session_name": .string(cleanupSessionName()),
            "minimum_days": .number(Double(rules.minimumDaysUnused)),
            "tabs": .array(staleTabs.map { ChromeTabLifeCards.listedTabValue(title: $0.title, url: $0.url, tabID: $0.id) }),
        ]))
    }

    /// Saves the approved tabs as a session, then closes them. Only tabs that
    /// are still open at the same address are touched — the card may have been
    /// up for a while, and a model's input names ids that must still mean the
    /// same pages.
    static func runStaleSweep(preparedInput: JSONValue) async throws -> String {
        let approvedTabs = ChromeTabLifeCards.listedTabs(in: preparedInput, key: "tabs")
        let requestedName = ToolCallInspection.stringValue(forAnyOf: ["session_name"], in: preparedInput) ?? ""
        let snapshot = try await ChromeTabOrganizer.fetchSnapshot()
        let openURLsByTabID = Dictionary(snapshot.tabs.map { ($0.id, $0.url) }, uniquingKeysWith: { first, _ in first })
        let closableTabIDs = approvedTabs.compactMap { approvedTab -> Int? in
            guard let tabID = approvedTab.tabID, openURLsByTabID[tabID] == approvedTab.url else { return nil }
            return tabID
        }
        guard !closableTabIDs.isEmpty else { return "those tabs are already closed." }

        let store = ChromeTabSessionStore.shared
        let sessionName = ChromeTabSessionBuilder.uniqueName(
            requestedName.isEmpty ? cleanupSessionName() : requestedName,
            existingNames: store.sessionNames
        )
        guard let safetySession = ChromeTabSessionBuilder.session(
            named: sessionName, from: snapshot, scope: .tabs(withIDs: Set(closableTabIDs)), createdAt: Date()
        ) else { return "couldn't save those tabs first, so i left them open." }
        // Saved before anything closes: if the close fails, nothing is lost.
        store.save(safetySession, mayAddToBrain: false)
        try await ChromeTabOrganizer.closeTabs(withIDs: closableTabIDs)
        return "closed \(ChromeTabSessionDescriptions.tabCountText(closableTabIDs.count)) you hadn't used. they're saved as \"\(safetySession.name)\" — say \"restore \(safetySession.name.lowercased())\" to bring them back."
    }

    // MARK: - Triage

    /// Plans duplicates + stale tabs + groups, asks once with one card, then
    /// runs exactly what the card said (minus tabs closed meanwhile).
    static func triageTabs(staleRules: ChromeStaleTabRules, modelProvider: any ModelProvider) async throws -> String {
        let snapshot = try await ChromeTabOrganizer.fetchSnapshot()
        let nowMilliseconds = currentMilliseconds()
        let (duplicateTabs, staleTabs) = ChromeTabTriagePlanner.tabsToClose(
            in: snapshot, nowMilliseconds: nowMilliseconds, staleRules: staleRules
        )
        let remainingSnapshot = ChromeTabTriagePlanner.snapshot(snapshot, removingTabIDs: Set((duplicateTabs + staleTabs).map(\.id)))
        // The same topic call "organize my tabs" makes; no answer → by site.
        let topicGroups = await ChromeTabOrganizer.requestTopicGroups(for: remainingSnapshot, modelProvider: modelProvider)
        let triagePlan = ChromeTabTriagePlanner.plan(
            for: snapshot, nowMilliseconds: nowMilliseconds, staleRules: staleRules, topicGroups: topicGroups
        )
        guard !triagePlan.isEmpty else { return "your tabs are already tidy — no duplicates, nothing old, nothing to group." }

        let sessionName = triagePlan.staleTabs.isEmpty ? nil : cleanupSessionName()
        let decision = await ToolConfirmationCoordinator.shared.requestApproval(
            toolName: ChromeTabLifeToolNames.applyTabTriage,
            toolInput: triageConfirmationInput(for: triagePlan, sessionName: sessionName)
        )
        guard decision.isApproved else { return "okay, i left your tabs alone." }

        let currentSnapshot = try await ChromeTabOrganizer.fetchSnapshot()
        let currentURLsByTabID = Dictionary(currentSnapshot.tabs.map { ($0.id, $0.url) }, uniquingKeysWith: { first, _ in first })
        let plannedURLsByTabID = Dictionary(snapshot.tabs.map { ($0.id, $0.url) }, uniquingKeysWith: { first, _ in first })
        let unchangedOpenTabIDs = Set(currentURLsByTabID.keys.filter { currentURLsByTabID[$0] == plannedURLsByTabID[$0] })
        let appliedPlan = ChromeTabTriagePlanner.restricted(triagePlan, toOpenTabIDs: unchangedOpenTabIDs)

        var savedSessionName: String?
        if !appliedPlan.staleTabs.isEmpty {
            let store = ChromeTabSessionStore.shared
            let uniqueSessionName = ChromeTabSessionBuilder.uniqueName(sessionName ?? cleanupSessionName(), existingNames: store.sessionNames)
            if let safetySession = ChromeTabSessionBuilder.session(
                named: uniqueSessionName, from: currentSnapshot,
                scope: .tabs(withIDs: Set(appliedPlan.staleTabs.map(\.id))), createdAt: Date()
            ) {
                store.save(safetySession, mayAddToBrain: false)
                savedSessionName = safetySession.name
            }
        }
        // Stale tabs close only once they're saved; duplicates always have a copy left open.
        var tabIDsToClose = appliedPlan.duplicateTabs.map(\.id)
        if savedSessionName != nil { tabIDsToClose += appliedPlan.staleTabs.map(\.id) }
        if !tabIDsToClose.isEmpty {
            try await ChromeTabOrganizer.closeTabs(withIDs: tabIDsToClose)
        }
        if !appliedPlan.groupingPlan.plannedGroups.isEmpty {
            try await ChromeTabOrganizer.apply(appliedPlan.groupingPlan)
        }
        let reportedPlan = savedSessionName == nil
            ? ChromeTabTriagePlan(duplicateTabs: appliedPlan.duplicateTabs, staleTabs: [], groupingPlan: appliedPlan.groupingPlan, staleRules: staleRules)
            : appliedPlan
        return ChromeTabTriagePlanner.resultText(for: reportedPlan, savedSessionName: savedSessionName)
    }

    static func triageConfirmationInput(for triagePlan: ChromeTabTriagePlan, sessionName: String?) -> JSONValue {
        var fields: [String: JSONValue] = [
            "minimum_days": .number(Double(triagePlan.staleRules.minimumDaysUnused)),
            "duplicates": .array(triagePlan.duplicateTabs.map { ChromeTabLifeCards.listedTabValue(title: $0.title, url: $0.url, tabID: $0.id) }),
            "stale": .array(triagePlan.staleTabs.map { ChromeTabLifeCards.listedTabValue(title: $0.title, url: $0.url, tabID: $0.id) }),
            "group_titles": .array(triagePlan.uniqueGroupTitles.map { .string($0) }),
            "grouped_tab_count": .number(Double(triagePlan.groupedTabCount)),
        ]
        if let sessionName { fields["session_name"] = .string(sessionName) }
        return .object(fields)
    }

    // MARK: - Helpers

    static func cleanupSessionName() -> String {
        ChromeTabSessionBuilder.uniqueName(
            ChromeTabSessionBuilder.datedName(prefix: "Cleanup", on: Date()),
            existingNames: ChromeTabSessionStore.shared.sessionNames
        )
    }

    static func currentMilliseconds() -> Double {
        Date().timeIntervalSince1970 * 1000
    }

}

// MARK: - Agent tools

enum ChromeTabLifeToolDefinitions {

    static let saveTabSession = BuddyToolDefinition(
        name: ChromeTabLifeToolNames.saveTabSession,
        description: "Save Chrome tabs as a named tab session the user can restore later (URLs, titles, pinned tabs and tab groups). Saves the front window, or every window with all_windows.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object(["type": .string("string"), "description": .string("The session's name, e.g. \"thesis research\". Omit for a dated name.")]),
                "all_windows": .object(["type": .string("boolean"), "description": .string("true to save every Chrome window, not just the front one.")]),
            ]),
        ]),
        // Only adds a row to Wisp's own session list, which the user can
        // delete; nothing in Chrome changes. So it doesn't stop to ask.
        metadata: ToolMetadata(readOnly: false, dataSource: .localMachine, isTrivialAndReversible: true)
    )

    static let restoreTabSession = BuddyToolDefinition(
        name: ChromeTabLifeToolNames.restoreTabSession,
        description: "Reopen a saved Chrome tab session by its name (from chrome_list_tab_sessions) in a new window, with its tab groups. Asks the user first for 10 or more tabs.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object(["type": .string("string"), "description": .string("The saved session's name.")]),
            ]),
            "required": .array([.string("name")]),
        ]),
        // Opening tabs is undone by closing them; the tool itself asks before
        // a big restore (10+ tabs), so the registry doesn't ask for every one.
        metadata: ToolMetadata(readOnly: false, dataSource: .localMachine, isTrivialAndReversible: true)
    )

    static let listTabSessions = BuddyToolDefinition(
        name: ChromeTabLifeToolNames.listTabSessions,
        description: "List the user's saved Chrome tab sessions: name, tab count, groups and date.",
        inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
        metadata: .reading(.localMachine)
    )

    static let closeStaleTabs = BuddyToolDefinition(
        name: ChromeTabLifeToolNames.closeStaleTabs,
        description: "Close Chrome tabs the user hasn't looked at in a while (default 14 days), after saving them as a tab session so they can be restored. Never closes pinned tabs, tabs playing sound, the showing tab or tabs in groups. The user approves on a card first.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "days": .object(["type": .string("integer"), "description": .string("Only tabs unused for at least this many days. Default 14.")]),
                "include_chrome_pages": .object(["type": .string("boolean"), "description": .string("true only if the user said to include chrome:// pages.")]),
            ]),
        ]),
        metadata: ToolMetadata(readOnly: false, destructive: true, dataSource: .localMachine)
    )
}

extension AgentToolRegistry {

    /// Phase 04's tools. Like the other Chrome tools they are always
    /// registered; without the extension each says how to connect it.
    func registerChromeTabLifeTools() {
        register(ChromeTabLifeToolDefinitions.saveTabSession) { input in
            var requestedName: String?
            var savesAllWindows = false
            if case .object(let arguments) = input {
                if case .string(let nameText)? = arguments["name"] { requestedName = nameText }
                if case .bool(let allWindowsFlag)? = arguments["all_windows"] { savesAllWindows = allWindowsFlag }
            }
            return try await ChromeTabLife.saveSession(named: requestedName, scope: savesAllWindows ? .allWindows : .focusedWindow)
        }

        register(ChromeTabLifeToolDefinitions.restoreTabSession) { input in
            guard case .object(let arguments) = input, case .string(let requestedName)? = arguments["name"],
                  !requestedName.trimmingCharacters(in: .whitespaces).isEmpty else {
                return "i need the session's name, from chrome_list_tab_sessions."
            }
            return try await ChromeTabLife.restoreSession(spokenName: requestedName)
        }

        register(ChromeTabLifeToolDefinitions.listTabSessions) { _ in
            ChromeTabSessionDescriptions.listText(for: ChromeTabSessionStore.shared.sessions)
        }

        // Prepared before the approval, so the card lists the real tabs and
        // the session they'll be saved as, and nothing-stale never shows a card.
        register(ChromeTabLifeToolDefinitions.closeStaleTabs, preparingInputWith: { input in
            var minimumDays = ChromeStaleTabRules.defaultMinimumDaysUnused
            var includesChromePages = false
            if case .object(let arguments) = input {
                if case .number(let requestedDays)? = arguments["days"] { minimumDays = Int(requestedDays) }
                if case .string(let requestedDaysText)? = arguments["days"], let parsedDays = Int(requestedDaysText) { minimumDays = parsedDays }
                if case .bool(let chromePagesFlag)? = arguments["include_chrome_pages"] { includesChromePages = chromePagesFlag }
            }
            do {
                switch try await ChromeTabLife.prepareStaleSweep(
                    rules: ChromeStaleTabRules(minimumDaysUnused: minimumDays, includesChromePages: includesChromePages)
                ) {
                case .nothingToDo(let replyText): return .finished(replyText)
                case .ready(let preparedInput): return .ready(preparedInput)
                }
            } catch {
                return .finished(error.localizedDescription)
            }
        }) { preparedInput in
            try await ChromeTabLife.runStaleSweep(preparedInput: preparedInput)
        }
    }
}
