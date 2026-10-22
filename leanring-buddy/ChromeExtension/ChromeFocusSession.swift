//
//  ChromeFocusSession.swift
//  leanring-buddy
//
//  Runs focus mode (phase 09): one session at a time, a countdown in
//  `WispTimerStore` (so the notch shows the timer card and the system
//  notification fires), and a restore when it ends — on time, on "stop focus",
//  on the card's Cancel, or on the next launch if Wisp quit mid-session.
//
//  The plan comes from `ChromeFocusPlanner`; the extension applies it and hands
//  back a restore token (`applyFocusLayout`). Only the token, the topic and the
//  end date are persisted. Tab ids are never persisted (contracts §1): the
//  extension keeps the prior layout in Chrome's session storage under the token.
//
//  A token that can't be restored yet (the extension isn't connected, Chrome is
//  restarting) is kept in a small pending list and retried whenever the
//  extension connects, so a layout is never left focused for good. A token
//  Chrome no longer knows (it restarted) is simply forgotten: there is nothing
//  left to put back.
//
//  It also starts focus on its own when an approved study block begins, if the
//  user asked for that: the "Focus block" automation's "Also focus Chrome"
//  switch (every approved block) or a block's own Focus chip in the checklist.
//

import Combine
import Foundation

/// The user's focus-mode settings, edited in Settings → Agent → Chrome Tabs.
@MainActor
final class ChromeFocusSettings: ObservableObject {
    static let shared = ChromeFocusSettings()

    private static let distractingSitesKey = "wisp.chromeFocus.distractingSites"
    private static let allowListedSitesKey = "wisp.chromeFocus.allowListedSites"
    private static let movesDistractingTabsKey = "wisp.chromeFocus.movesDistractingTabs"

    /// Comma-separated, as typed.
    @Published var distractingSitesText: String {
        didSet { UserDefaults.standard.set(distractingSitesText, forKey: Self.distractingSitesKey) }
    }
    @Published var allowListedSitesText: String {
        didSet { UserDefaults.standard.set(allowListedSitesText, forKey: Self.allowListedSitesKey) }
    }
    /// Off by default: a minimised window the user didn't expect is a surprise.
    @Published var movesDistractingTabsToLaterWindow: Bool {
        didSet { UserDefaults.standard.set(movesDistractingTabsToLaterWindow, forKey: Self.movesDistractingTabsKey) }
    }

    var distractingHosts: [String] { ChromeFocusPlanner.hosts(fromListText: distractingSitesText) }
    var allowListedHosts: [String] { ChromeFocusPlanner.hosts(fromListText: allowListedSitesText) }

    private init() {
        let defaults = UserDefaults.standard
        distractingSitesText = defaults.string(forKey: Self.distractingSitesKey)
            ?? ChromeFocusPlanner.defaultDistractingHosts.joined(separator: ", ")
        allowListedSitesText = defaults.string(forKey: Self.allowListedSitesKey) ?? ""
        movesDistractingTabsToLaterWindow = defaults.object(forKey: Self.movesDistractingTabsKey) as? Bool ?? false
    }
}

@MainActor
final class ChromeFocusSession: ObservableObject {
    static let shared = ChromeFocusSession()

    /// What is persisted about the running session: enough to restore it after a
    /// quit, nothing that names a tab.
    struct ActiveSession: Codable, Equatable {
        let restoreToken: String
        let topic: String
        let startedAt: Date
        let endDate: Date
        /// Set when an approved study block started it.
        let studyBlockID: String?
    }

    @Published private(set) var activeSession: ActiveSession?
    /// The countdown in `WispTimerStore`; not persisted (timers don't survive a quit).
    @Published private(set) var activeTimerID: UUID?
    /// Study blocks the user turned focus on for with the checklist chip.
    @Published private(set) var optedInStudyBlockIDs: Set<String>

    // Hooks set by `NotchWindowController`, so this file doesn't reach into CompanionManager.
    /// Shows a line in the notch, with the session's timer card when one is given. Needed
    /// because a session can start or end outside any turn (a study block, time up).
    var presentInNotch: ((_ message: String, _ timerID: UUID?) -> Void)?
    var flashIsland: ((_ didSucceed: Bool) -> Void)?

    private static let activeSessionKey = "wisp.chromeFocus.activeSession"
    private static let pendingRestoreTokensKey = "wisp.chromeFocus.pendingRestoreTokens"
    private static let optedInStudyBlockIDsKey = "wisp.chromeFocus.optedInStudyBlockIDs"
    private static let focusedStudyBlockIDsKey = "wisp.chromeFocus.focusedStudyBlockIDs"
    private static let maximumRememberedStudyBlockIDs = 200
    private static let clockIntervalSeconds: TimeInterval = 30

    private var pendingRestoreTokens: [String]
    private var focusedStudyBlockIDs: [String]
    private var hasStarted = false
    private var clockTimer: Timer?
    private var subscriptions: Set<AnyCancellable> = []
    private var isRetryingPendingRestores = false
    private var isStartingSession = false

    private init() {
        let defaults = UserDefaults.standard
        pendingRestoreTokens = defaults.stringArray(forKey: Self.pendingRestoreTokensKey) ?? []
        focusedStudyBlockIDs = defaults.stringArray(forKey: Self.focusedStudyBlockIDsKey) ?? []
        optedInStudyBlockIDs = Set(defaults.stringArray(forKey: Self.optedInStudyBlockIDsKey) ?? [])

        // A session that was running when Wisp quit is restored, not resumed: its
        // timer is gone, and a layout nobody is counting down is one the user
        // would have to undo by hand.
        if let storedSessionData = defaults.data(forKey: Self.activeSessionKey),
           let interruptedSession = try? JSONDecoder().decode(ActiveSession.self, from: storedSessionData) {
            if !pendingRestoreTokens.contains(interruptedSession.restoreToken) {
                pendingRestoreTokens.append(interruptedSession.restoreToken)
            }
            defaults.removeObject(forKey: Self.activeSessionKey)
            defaults.set(pendingRestoreTokens, forKey: Self.pendingRestoreTokensKey)
        }
    }

    /// Called once at launch: restores what a quit left focused (as soon as the
    /// extension connects) and starts the study-block clock.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        ChromeExtensionBridge.shared.$connectionState
            .receive(on: RunLoop.main)
            .sink { [weak self] connectionState in
                guard case .connected = connectionState else { return }
                Task { await self?.retryPendingRestores() }
            }
            .store(in: &subscriptions)

        // The timer card's Cancel ends the countdown without its finish handler;
        // that counts as "stop focus".
        WispTimerStore.shared.$timersByID
            .receive(on: RunLoop.main)
            .sink { [weak self] timersByID in
                guard let self, let activeTimerID = self.activeTimerID,
                      timersByID[activeTimerID]?.status == .cancelled else { return }
                Task { await self.endSession(because: .cancelledFromCard) }
            }
            .store(in: &subscriptions)

        clockTimer = Timer.scheduledTimer(withTimeInterval: Self.clockIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.clockTick() }
        }
        Task { await clockTick() }
    }

    var isFocusing: Bool { activeSession != nil }

    // MARK: - Start and stop

    /// Plans, applies and starts the countdown. Returns the line to show and say.
    func startFocus(topic: String, minutes: Int, studyBlockID: String? = nil) async -> (replyText: String, didSucceed: Bool) {
        let clampedMinutes = min(max(minutes, ChromeFocusCommandParser.allowedMinutes.lowerBound), ChromeFocusCommandParser.allowedMinutes.upperBound)
        guard !isStartingSession else { return ("focus mode is already starting.", false) }
        isStartingSession = true
        defer { isStartingSession = false }

        // One session at a time: a new one replaces the old, which is put back first
        // so the two layouts never stack.
        if activeSession != nil {
            _ = await endSession(because: .replaced)
        }

        let settings = ChromeFocusSettings.shared
        let appliedLayout: AppliedFocusLayout
        do {
            let snapshot = try await ChromeTabOrganizer.fetchSnapshot()
            let plan = ChromeFocusPlanner.plan(
                snapshot: snapshot,
                topic: topic,
                allowListedHosts: settings.allowListedHosts,
                distractingHosts: settings.distractingHosts,
                movesDistractingTabsToLaterWindow: settings.movesDistractingTabsToLaterWindow
            )
            appliedLayout = try await ChromeExtensionBridge.shared.sendRequest(
                method: "applyFocusLayout",
                parameters: ApplyFocusLayoutParameters(plan: plan),
                resultType: AppliedFocusLayout.self,
                timeoutSeconds: 20
            )
        } catch {
            return (error.localizedDescription, false)
        }

        let startDate = Date()
        let session = ActiveSession(
            restoreToken: appliedLayout.token,
            topic: topic,
            startedAt: startDate,
            endDate: startDate.addingTimeInterval(TimeInterval(clampedMinutes * 60)),
            studyBlockID: studyBlockID
        )
        activeSession = session
        persistActiveSession()

        let timerLabel = topic.isEmpty ? "Focus" : "Focus: \(topic)"
        let startedTimer = WispTimerStore.shared.startTimer(
            durationSeconds: clampedMinutes * 60,
            label: timerLabel,
            onFinished: { [weak self] in
                Task { await self?.endSession(because: .timeIsUp) }
            }
        )
        activeTimerID = startedTimer.id

        let changesText = ChromeFocusPlanner.describe(
            collapsedGroupCount: appliedLayout.collapsedGroupCount,
            mutedTabCount: appliedLayout.mutedTabCount,
            focusGroupedTabCount: appliedLayout.focusGroupedTabCount,
            movedTabCount: appliedLayout.movedTabCount
        )
        let durationText = WispTimerDurationFormatter.spokenDurationText(totalSeconds: clampedMinutes * 60)
        let topicText = topic.isEmpty ? "" : " on \(topic)"
        let replyText = "focusing\(topicText) for \(durationText) — \(changesText). say \"stop focus\" to put it back."
        presentInNotch?(replyText, startedTimer.id)
        return (replyText, true)
    }

    enum EndReason {
        case timeIsUp
        case stoppedByUser
        case cancelledFromCard
        case replaced
    }

    /// Restores the layout and stops the countdown.
    @discardableResult
    func endSession(because endReason: EndReason) async -> (replyText: String, didSucceed: Bool) {
        guard let endingSession = activeSession else {
            return ("focus mode isn't on.", false)
        }
        // Cleared first, so the timer's cancellation (below) doesn't end it twice.
        activeSession = nil
        persistActiveSession()
        if let endingTimerID = activeTimerID {
            activeTimerID = nil
            if endReason != .timeIsUp && endReason != .cancelledFromCard {
                WispTimerStore.shared.cancelTimer(withID: endingTimerID)
            }
        }

        let replyText: String
        let didSucceed: Bool
        switch await restoreLayout(withToken: endingSession.restoreToken) {
        case .restored:
            replyText = endReason == .timeIsUp
                ? "focus time's up — your tabs are back how they were."
                : "focus off — your tabs are back how they were."
            didSucceed = true
        case .nothingToRestore:
            replyText = "focus off. chrome had restarted, so there was nothing to put back."
            didSucceed = true
        case .couldNotReachChrome:
            replyText = "focus off. i'll put your tabs back as soon as chrome reconnects."
            didSucceed = false
        }

        // Nobody asked in a turn for these two, so the notch says what happened.
        if endReason == .timeIsUp || endReason == .cancelledFromCard {
            flashIsland?(didSucceed)
            presentInNotch?(replyText, nil)
        }
        return (replyText, didSucceed)
    }

    /// What a start would do right now, changing nothing (an automation's Test run).
    func previewText(topic: String, minutes: Int) async -> String {
        let settings = ChromeFocusSettings.shared
        do {
            let snapshot = try await ChromeTabOrganizer.fetchSnapshot()
            let plan = ChromeFocusPlanner.plan(
                snapshot: snapshot,
                topic: topic,
                allowListedHosts: settings.allowListedHosts,
                distractingHosts: settings.distractingHosts,
                movesDistractingTabsToLaterWindow: settings.movesDistractingTabsToLaterWindow
            )
            let wouldDoText = ChromeFocusPlanner.describe(
                collapsedGroupCount: plan.collapseGroupIDs.count,
                mutedTabCount: plan.muteTabIDs.count,
                focusGroupedTabCount: plan.focusGroupTabIDs.count,
                movedTabCount: plan.movesDistractingTabsToLaterWindow ? plan.distractingTabIDs.count : 0
            )
            return "Right now this would keep \(plan.keepTabIDs.count) on-topic tab\(plan.keepTabIDs.count == 1 ? "" : "s") in view and: \(wouldDoText), for \(minutes) min."
        } catch {
            return error.localizedDescription
        }
    }

    func stopFocus() async -> (replyText: String, didSucceed: Bool) {
        await endSession(because: .stoppedByUser)
    }

    func perform(_ command: ChromeFocusCommand) async -> (replyText: String, didSucceed: Bool) {
        switch command {
        case .start(let topic, let minutes):
            return await startFocus(topic: topic, minutes: minutes)
        case .stop:
            return await stopFocus()
        }
    }

    // MARK: - Restoring

    private enum RestoreOutcome {
        case restored
        case nothingToRestore
        case couldNotReachChrome
    }

    private func restoreLayout(withToken restoreToken: String) async -> RestoreOutcome {
        do {
            let restoredLayout = try await ChromeExtensionBridge.shared.sendRequest(
                method: "restoreFocusLayout",
                parameters: RestoreFocusLayoutParameters(token: restoreToken),
                resultType: RestoredFocusLayout.self,
                timeoutSeconds: 20
            )
            removePendingRestoreToken(restoreToken)
            return restoredLayout.restored ? .restored : .nothingToRestore
        } catch {
            if !pendingRestoreTokens.contains(restoreToken) {
                pendingRestoreTokens.append(restoreToken)
                UserDefaults.standard.set(pendingRestoreTokens, forKey: Self.pendingRestoreTokensKey)
            }
            return .couldNotReachChrome
        }
    }

    private func retryPendingRestores() async {
        guard !isRetryingPendingRestores, !pendingRestoreTokens.isEmpty,
              ChromeExtensionBridge.shared.isExtensionConnected else { return }
        isRetryingPendingRestores = true
        defer { isRetryingPendingRestores = false }
        for restoreToken in pendingRestoreTokens {
            _ = await restoreLayout(withToken: restoreToken)
        }
    }

    private func removePendingRestoreToken(_ restoreToken: String) {
        guard pendingRestoreTokens.contains(restoreToken) else { return }
        pendingRestoreTokens.removeAll { $0 == restoreToken }
        UserDefaults.standard.set(pendingRestoreTokens, forKey: Self.pendingRestoreTokensKey)
    }

    private func persistActiveSession() {
        if let activeSession, let encodedSession = try? JSONEncoder().encode(activeSession) {
            UserDefaults.standard.set(encodedSession, forKey: Self.activeSessionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.activeSessionKey)
        }
    }

    // MARK: - Study blocks

    /// The checklist chip: focus Chrome for this block when it starts (or now, if it
    /// already has). Tapping again turns it off for that block.
    func toggleFocus(forStudyBlockID studyBlockID: String) {
        if optedInStudyBlockIDs.contains(studyBlockID) {
            optedInStudyBlockIDs.remove(studyBlockID)
            // Turning it off while that block's focus runs means "stop".
            if activeSession?.studyBlockID == studyBlockID {
                Task { await endSession(because: .stoppedByUser) }
            }
        } else {
            optedInStudyBlockIDs.insert(studyBlockID)
        }
        let trimmedIDs = Array(optedInStudyBlockIDs).sorted().suffix(Self.maximumRememberedStudyBlockIDs)
        UserDefaults.standard.set(Array(trimmedIDs), forKey: Self.optedInStudyBlockIDsKey)
        Task { await clockTick() }
    }

    func isFocusOptedIn(forStudyBlockID studyBlockID: String) -> Bool {
        optedInStudyBlockIDs.contains(studyBlockID)
    }

    /// The "Focus block" automation's "Also focus Chrome" switch, on any enabled one.
    private var focusesEveryApprovedStudyBlock: Bool {
        AutomationStore.shared.automations.contains { automation in
            automation.isEnabled && automation.action == .proposeStudyBlocks && automation.focusesChromeDuringStudyBlocks == true
        }
    }

    private func clockTick() async {
        await retryPendingRestores()

        // Never take over a session the user started themselves.
        guard activeSession == nil, ChromeExtensionBridge.shared.isExtensionConnected else { return }
        let now = Date()
        let studyBlocks = JobsEngine.shared.approvedStudyBlocks.map { approvedBlock in
            ChromeFocusStudyBlockPolicy.Block(
                id: approvedBlock.id,
                title: approvedBlock.title,
                courseCode: approvedBlock.courseCode,
                start: approvedBlock.start,
                end: approvedBlock.end
            )
        }
        guard let blockToFocus = ChromeFocusStudyBlockPolicy.blockToStartFocus(
            blocks: studyBlocks,
            now: now,
            focusesEveryApprovedBlock: focusesEveryApprovedStudyBlock,
            optedInBlockIDs: optedInStudyBlockIDs,
            alreadyFocusedBlockIDs: Set(focusedStudyBlockIDs)
        ) else { return }

        // Marked before starting, so a failure doesn't retry every 30s for the whole block.
        focusedStudyBlockIDs.append(blockToFocus.id)
        if focusedStudyBlockIDs.count > Self.maximumRememberedStudyBlockIDs {
            focusedStudyBlockIDs.removeFirst(focusedStudyBlockIDs.count - Self.maximumRememberedStudyBlockIDs)
        }
        UserDefaults.standard.set(focusedStudyBlockIDs, forKey: Self.focusedStudyBlockIDsKey)

        _ = await startFocus(
            topic: ChromeFocusStudyBlockPolicy.topic(for: blockToFocus),
            minutes: ChromeFocusStudyBlockPolicy.minutesRemaining(in: blockToFocus, now: now),
            studyBlockID: blockToFocus.id
        )
    }

    // MARK: - Wire shapes

    private struct ApplyFocusLayoutParameters: Encodable {
        let keepTabIds: [Int]
        let keepGroupIds: [Int]
        let distractingTabIds: [Int]
        let moveDistractingToLaterWindow: Bool
        let collapseGroupIds: [Int]
        let muteTabIds: [Int]
        let focusTabIds: [Int]

        init(plan: ChromeFocusPlan) {
            keepTabIds = plan.keepTabIDs
            keepGroupIds = plan.keepGroupIDs
            distractingTabIds = plan.distractingTabIDs
            moveDistractingToLaterWindow = plan.movesDistractingTabsToLaterWindow
            collapseGroupIds = plan.collapseGroupIDs
            muteTabIds = plan.muteTabIDs
            focusTabIds = plan.focusGroupTabIDs
        }
    }

    private struct AppliedFocusLayout: Decodable {
        let token: String
        let collapsedGroupCount: Int
        let mutedTabCount: Int
        let focusGroupedTabCount: Int
        let movedTabCount: Int
    }

    private struct RestoreFocusLayoutParameters: Encodable {
        let token: String
    }

    private struct RestoredFocusLayout: Decodable {
        let restored: Bool
    }
}

// MARK: - The notch

extension CompanionManager {
    /// Shows focus mode's countdown card and lines in the notch. The card is set even
    /// mid-turn (the spoken "focus on …" route), but the line is left to that turn so it
    /// isn't written twice; outside a turn (a study block, time up) the line is shown here.
    func presentChromeFocusUpdate(message: String, timerID: UUID?) {
        if let timerID {
            resolvedGlanceCard = .timer(TimerCardState(timerID: timerID))
        }
        guard voiceState == .idle, !message.isEmpty else { return }
        currentReplyText = message
    }
}
