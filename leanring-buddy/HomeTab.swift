//
//  HomeTab.swift
//  leanring-buddy
//
//  The Wisp window's Today page, laid out as a bento grid of live widgets
//  (`WispBentoTile`) rather than a column of settings-like cards:
//
//  - a hero: the greeting, Wisp's mark moving with what it is doing right now
//    (with the live transcript or browser step), and the ask bar (a typed
//    question, or `/` to run a routine),
//  - "Today": what Wisp did today, counted and drawn hour by hour,
//  - "Needs you": problems that block Wisp, each with its fix,
//  - running work with a Stop, ringed by a flowing rim while it runs,
//  - buddies (bobbing while they work, a dot when they have news), the next
//    meetings and the brain,
//  - routines one click away, and recent answers to copy.
//
//  Two columns of tiles when there is room, one when the window is narrow.
//  Anything that runs from here closes the window first, so the screenshot
//  Wisp takes shows the user's work and not this window. Fully adaptive
//  (light/dark) via the `WispColor` tokens.
//

import AppKit
import EventKit
import SwiftUI

struct HomeTab: View {
    @ObservedObject var taskRegistry: AgentTaskRegistry
    @ObservedObject private var companionManager: CompanionManager
    @ObservedObject private var bindingStore = ShortcutBindingStore.shared
    @ObservedObject private var routineStore = RoutineStore.shared
    @ObservedObject private var voiceOutputPreference = VoiceOutputPreference.shared
    @ObservedObject private var brainStore = BrainStore.shared
    @ObservedObject private var brainIngestQueue = BrainIngestQueue.shared
    @ObservedObject private var buddyStore = BuddyStore.shared

    /// Moves the Wisp window to another page (e.g. "All routines").
    let onSelectPage: (WispPage) -> Void

    @State private var askBarText = ""
    @FocusState private var isAskBarFocused: Bool
    @State private var localServicesHealth = LocalServicesHealth.unknown
    @State private var calendarState: TodayCalendarState = .loading
    /// Alerts the user dismissed this session, keyed by `NeedsYouAlert.id`.
    @State private var dismissedAlertIDs: Set<String> = []
    /// The recent answer whose Copy button just fired, for its checkmark.
    @State private var recentlyCopiedRecordID: UUID?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        taskRegistry: AgentTaskRegistry,
        companionManager: CompanionManager,
        onSelectPage: @escaping (WispPage) -> Void
    ) {
        self.taskRegistry = taskRegistry
        self.companionManager = companionManager
        self.onSelectPage = onSelectPage
    }

    /// How often the page re-checks the local services and the calendar while
    /// it is on screen. The loop stops when the page goes away.
    private let refreshIntervalSeconds: UInt64 = 30

    private let tileSpacing = WispBentoMetrics.gridSpacing

    /// The width of the page's content column, measured as it lays out.
    @State private var contentWidth: CGFloat = 0
    /// Below this the tiles stack in one column. Matches the widest row of the
    /// wide grid (buddies + up next + brain, with spacing).
    private let wideGridMinimumWidth: CGFloat = 560

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: tileSpacing) {
                if !companionManager.allPermissionsGranted {
                    setupTile.wispEntrance(order: 0)
                }
                // Chosen from the measured width rather than `ViewThatFits`,
                // which measures the ask bar's text field at its (very wide)
                // ideal width and so always fell back to one column.
                if contentWidth >= wideGridMinimumWidth {
                    wideGrid
                } else {
                    narrowGrid
                }
            }
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.width
            } action: { measuredWidth in
                contentWidth = measuredWidth
            }
            .padding(.horizontal, WispSpacing.xxl)
            .padding(.vertical, WispSpacing.xl)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .task {
            while !Task.isCancelled {
                await refreshLiveData()
                try? await Task.sleep(nanoseconds: refreshIntervalSeconds * 1_000_000_000)
            }
        }
    }

    // MARK: - Grid

    /// Rows of tiles; each row is held to the height of its tallest tile so
    /// the grid's edges line up.
    private var wideGrid: some View {
        VStack(alignment: .leading, spacing: tileSpacing) {
            HStack(alignment: .top, spacing: tileSpacing) {
                heroTile.frame(minWidth: 330)
                todayTile(fillsRowHeight: true).frame(width: 230)
            }
            .fixedSize(horizontal: false, vertical: true)
            .wispEntrance(order: 1)

            needsYouStrip.wispEntrance(order: 2)
            runningNowTile.wispEntrance(order: 2)

            HStack(alignment: .top, spacing: tileSpacing) {
                buddiesTile.frame(minWidth: 200)
                upNextTile.frame(minWidth: 180)
                brainTile.frame(width: 150)
            }
            .fixedSize(horizontal: false, vertical: true)
            .wispEntrance(order: 3)

            HStack(alignment: .top, spacing: tileSpacing) {
                routinesTile.frame(minWidth: 270)
                recentAnswersTile.frame(minWidth: 250)
            }
            .fixedSize(horizontal: false, vertical: true)
            .wispEntrance(order: 4)
        }
    }

    /// One column; each tile keeps its natural height (in a row the tiles
    /// stretch to match each other, here there is nothing to match).
    private var narrowGrid: some View {
        VStack(alignment: .leading, spacing: tileSpacing) {
            heroTile.wispEntrance(order: 1)
            needsYouStrip.wispEntrance(order: 2)
            runningNowTile.wispEntrance(order: 2)
            todayTile(fillsRowHeight: false).wispEntrance(order: 3)
            buddiesTile.wispEntrance(order: 3)
            upNextTile.wispEntrance(order: 4)
            routinesTile.wispEntrance(order: 4)
            brainTile.wispEntrance(order: 5)
            recentAnswersTile.wispEntrance(order: 5)
        }
    }

    // MARK: - Hero

    /// The one tile with Wisp's own colour: a wash of the signature gradient
    /// that drifts while Wisp is working and holds still at rest.
    private var heroTile: some View {
        let islandState = companionManager.islandState
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                        .font(WispFont.overline)
                        .tracking(0.8)
                        .foregroundStyle(WispColor.textSecondary)
                    Text(greeting)
                        .font(WispFont.hero)
                        .foregroundStyle(WispColor.textPrimary)
                }
                Spacer(minLength: 8)
                voiceModeButton
            }

            HStack(alignment: .center, spacing: 12) {
                WispMark(state: islandState.markState, size: 40)
                    .frame(width: 52, height: 52)
                    .background(
                        Circle()
                            .fill(.background.opacity(0.55))
                            .shadow(color: islandState.accent.opacity(islandState.isActive ? 0.45 : 0), radius: 12)
                    )
                    .scaleEffect(islandState == .listening && !reduceMotion ? 1.06 : 1)
                    .animation(WispMotion.island, value: islandState)
                VStack(alignment: .leading, spacing: 3) {
                    Text(companionManager.isListeningPaused ? "Listening paused" : islandState.label)
                        .font(WispFont.headline)
                        .foregroundStyle(WispColor.textPrimary)
                        .contentTransition(.opacity)
                    heroLiveLine
                }
                .animation(WispMotion.smooth, value: islandState.label)
                Spacer(minLength: 0)
            }

            askBar
            if isAskBarInRoutineMode {
                routineMatchesList
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(WispMotion.smooth, value: isAskBarInRoutineMode)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(heroBackground(isActive: islandState.isActive))
        .clipShape(RoundedRectangle(cornerRadius: WispBentoMetrics.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WispBentoMetrics.cornerRadius, style: .continuous)
                .strokeBorder(WispColor.cardSeparator, lineWidth: 0.5)
        )
        .overlay {
            if islandState.isActive {
                WispLiveRim(cornerRadius: WispBentoMetrics.cornerRadius)
            }
        }
        .shadow(color: .black.opacity(0.06), radius: 10, x: 0, y: 4)
    }

    /// Under the state label: what Wisp is hearing or doing, or how to start.
    @ViewBuilder
    private var heroLiveLine: some View {
        if companionManager.voiceState == .listening && !companionManager.liveTranscript.isEmpty {
            Text("“\(companionManager.liveTranscript)”")
                .font(WispFont.callout)
                .foregroundStyle(WispColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)
        } else if !companionManager.browserActivityText.isEmpty {
            Text("Step \(companionManager.browserTaskStepCount) · \(companionManager.browserActivityText)")
                .font(WispFont.callout)
                .foregroundStyle(WispColor.textSecondary)
                .lineLimit(1)
        } else {
            HStack(spacing: 4) {
                Text("Hold")
                ForEach(bindingStore.primaryHoldChord.keyCapsuleLabels, id: \.self) { keyLabel in
                    keyCap(keyLabel)
                }
                Text("to talk, or type below")
            }
            .font(WispFont.callout)
            .foregroundStyle(WispColor.textSecondary)
        }
    }

    @ViewBuilder
    private func heroBackground(isActive: Bool) -> some View {
        ZStack {
            WispColor.groupedCardBackground
            if isActive && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
                    let driftPhase = timeline.date.timeIntervalSinceReferenceDate * 0.35
                    LinearGradient(
                        colors: WispGradient.signatureStops,
                        startPoint: UnitPoint(x: 0.5 + 0.5 * cos(driftPhase), y: 0),
                        endPoint: UnitPoint(x: 0.5 - 0.5 * cos(driftPhase), y: 1)
                    )
                    .opacity(0.32)
                }
            } else {
                WispGradient.signature.opacity(isActive ? 0.32 : 0.2)
            }
            // Fades the wash out toward the bottom so the ask bar sits on a
            // calm surface.
            LinearGradient(
                colors: [.clear, WispColor.groupedCardBackground.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .animation(WispMotion.gentle, value: isActive)
    }

    private var voiceModeButton: some View {
        let isVoiceOn = voiceOutputPreference.isReplySpeechEnabled
        return Button {
            withAnimation(WispMotion.island) { voiceOutputPreference.isReplySpeechEnabled.toggle() }
        } label: {
            Image(systemName: isVoiceOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isVoiceOn ? WispColor.accentText : WispColor.textSecondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 32, height: 32)
                .background(Circle().fill(.background.opacity(0.6)))
                .overlay(Circle().strokeBorder(WispColor.cardSeparator, lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(WispBentoPressStyle())
        .pointerCursor()
        .nativeTooltip(isVoiceOn
            ? "Voice on: Wisp says a short line out loud. Click for silent mode."
            : "Silent: replies show in the notch only. Click to have them spoken.")
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    // MARK: - Setup

    /// Until every permission is granted Wisp can't hear or see anything, so
    /// the checklist leads the page rather than hiding in Settings.
    private var setupTile: some View {
        WispBentoTile(
            title: companionManager.hasEverHadAllPermissions
                ? "Wisp needs its permissions back"
                : "Finish setting up Wisp",
            symbolName: "checklist",
            tint: WispColor.warningText
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text(companionManager.hasEverHadAllPermissions
                     ? "Some permissions were turned off. Grant them again to keep using Wisp."
                     : "Wisp only takes a screenshot while you're asking something, and the models that read it run on this Mac.")
                    .font(.callout)
                    .foregroundStyle(WispColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                PermissionsChecklist(companionManager: companionManager)
            }
        }
    }

    // MARK: - Ask bar

    private var askBar: some View {
        HStack(spacing: 10) {
            Image(systemName: isAskBarInRoutineMode ? "bolt.fill" : "sparkle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isAskBarFocused ? WispColor.intelligence : WispColor.textTertiary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 18)
            TextField("Ask anything, or type / to run a routine", text: $askBarText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(WispColor.textPrimary)
                .focused($isAskBarFocused)
                .onSubmit(submitAskBar)
            if !askBarText.isEmpty {
                Button(action: submitAskBar) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(WispColor.textOnAccent)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(WispColor.accent))
                }
                .buttonStyle(WispBentoPressStyle())
                .pointerCursor()
                .transition(.scale.combined(with: .opacity))
                .nativeTooltip(isAskBarInRoutineMode ? "Run routine" : "Ask Wisp")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: WispRadius.input, style: .continuous)
                .fill(.background.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: WispRadius.input, style: .continuous)
                .strokeBorder(
                    isAskBarFocused ? WispColor.intelligence.opacity(0.8) : WispColor.borderSubtle,
                    lineWidth: isAskBarFocused ? 1.5 : 1
                )
        )
        .shadow(color: WispColor.intelligence.opacity(isAskBarFocused ? 0.25 : 0), radius: 10)
        .animation(WispMotion.smooth, value: isAskBarFocused)
        .animation(WispMotion.island, value: askBarText.isEmpty)
    }

    private var isAskBarInRoutineMode: Bool {
        askBarText.hasPrefix("/")
    }

    /// Routines whose name contains what follows the "/" — all of them for a
    /// bare "/".
    private var routineMatchesForAskBar: [WispRoutine] {
        let routineQuery = askBarText.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !routineQuery.isEmpty else { return routineStore.routines }
        return routineStore.routines.filter { $0.name.localizedCaseInsensitiveContains(routineQuery) }
    }

    private var routineMatchesList: some View {
        VStack(alignment: .leading, spacing: 2) {
            if routineMatchesForAskBar.isEmpty {
                Text("No routine matches — press Return to ask it as a question instead.")
                    .font(WispFont.callout)
                    .foregroundStyle(WispColor.textSecondary)
                    .padding(8)
            } else {
                ForEach(Array(routineMatchesForAskBar.prefix(5).enumerated()), id: \.element.id) { matchIndex, routine in
                    Button {
                        askBarText = ""
                        runOnUsersWork { companionManager.runRoutine(withID: routine.id) }
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: routine.symbolName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(WispColor.accentText)
                                .frame(width: 16)
                            Text(routine.name)
                                .font(WispFont.bodyMedium)
                                .foregroundStyle(WispColor.textPrimary)
                            Spacer(minLength: 0)
                            // Return runs the first match.
                            if matchIndex == 0 {
                                Text("↩")
                                    .font(WispFont.caption)
                                    .foregroundStyle(WispColor.textTertiary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: WispRadius.medium, style: .continuous)
                                .fill(matchIndex == 0 ? WispColor.surface2 : .clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: WispRadius.large, style: .continuous)
                .fill(.background.opacity(0.85))
        )
    }

    private func submitAskBar() {
        let submittedText = askBarText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submittedText.isEmpty else { return }

        if isAskBarInRoutineMode, let firstMatchingRoutine = routineMatchesForAskBar.first {
            askBarText = ""
            runOnUsersWork { companionManager.runRoutine(withID: firstMatchingRoutine.id) }
            return
        }

        // A "/" with no match is asked as a plain question, minus the slash.
        let question = submittedText.hasPrefix("/") ? String(submittedText.dropFirst()) : submittedText
        askBarText = ""
        runOnUsersWork { companionManager.askTypedQuestion(question) }
    }

    /// Closes the window, then runs `action` once the user's previous app is
    /// back in front, so the turn's screenshot shows their work.
    private func runOnUsersWork(_ action: @escaping @MainActor () -> Void) {
        NSApp.keyWindow?.performClose(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            action()
        }
    }

    private func keyCap(_ keyLabel: String) -> some View {
        Text(keyLabel)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(WispColor.textSecondary)
            .padding(.horizontal, 5)
            .frame(height: 18)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.background.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(WispColor.borderSubtle, lineWidth: 1)
            )
    }

    // MARK: - Today

    /// Today's interactive answers, buddy runs and brain changes, plus a bar
    /// per hour for the last twelve hours of everything Wisp ran.
    /// `fillsRowHeight`: beside the hero the tile is as tall as the hero, so the
    /// bars sit at its bottom; on its own it keeps its natural height.
    private func todayTile(fillsRowHeight: Bool) -> some View {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let recordsToday = taskRegistry.records.filter { $0.startedAt >= startOfToday }
        let answersTodayCount = recordsToday.filter { $0.kind == .interactive && $0.status == .succeeded }.count
        let buddyRunsTodayCount = recordsToday.filter { $0.title.hasPrefix("Buddy · ") }.count
        let brainChangesTodayCount = brainStore.changeRecords.filter { !$0.isUndone && $0.date >= startOfToday }.count

        return WispBentoTile(
            title: "Today",
            symbolName: "chart.bar.fill",
            tint: WispColor.intelligence,
            action: { onSelectPage(.timeline) }
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    WispBentoStat(value: answersTodayCount, caption: "answers")
                    WispBentoStat(value: buddyRunsTodayCount, caption: "buddy runs")
                    WispBentoStat(value: brainChangesTodayCount, caption: "learned")
                }
                if fillsRowHeight {
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 5) {
                    WispActivityBars(
                        bucketCounts: hourlyActivityCounts(),
                        highlightedBucketIndex: hourlyActivityBucketCount - 1
                    )
                    HStack {
                        Text("12h ago")
                        Spacer()
                        Text("now")
                    }
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(WispColor.textTertiary)
                }
            }
        }
        .nativeTooltip("Open History")
    }

    private let hourlyActivityBucketCount = 12

    /// How many tasks started in each of the last twelve hours, oldest first.
    private func hourlyActivityCounts() -> [Int] {
        let now = Date()
        var bucketCounts = Array(repeating: 0, count: hourlyActivityBucketCount)
        for record in taskRegistry.records {
            let hoursAgo = Int(now.timeIntervalSince(record.startedAt) / 3600)
            guard hoursAgo >= 0 && hoursAgo < hourlyActivityBucketCount else { continue }
            bucketCounts[hourlyActivityBucketCount - 1 - hoursAgo] += 1
        }
        return bucketCounts
    }

    // MARK: - Needs you

    /// One problem blocking Wisp, with the action that fixes it.
    private struct NeedsYouAlert: Identifiable {
        let id: String
        let symbolName: String
        let title: String
        let detail: String
        let actionTitle: String?
        let action: (() -> Void)?
    }

    private var needsYouAlerts: [NeedsYouAlert] {
        var alerts: [NeedsYouAlert] = []

        if companionManager.isListeningPaused {
            alerts.append(NeedsYouAlert(
                id: "listening-paused",
                symbolName: "pause.circle",
                title: "Listening is paused",
                detail: "The talk shortcut is off until you resume.",
                actionTitle: "Resume",
                action: { companionManager.setListeningPaused(false) }
            ))
        }

        if localServicesHealth.isLocalModelUnreachable {
            alerts.append(NeedsYouAlert(
                id: "ollama",
                symbolName: "cpu",
                title: "The local model isn't running",
                detail: "Start Ollama with `ollama serve` in Terminal.",
                actionTitle: "Copy command",
                action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("ollama serve", forType: .string)
                }
            ))
        }

        if localServicesHealth.isVoiceServerUnreachable && voiceOutputPreference.isReplySpeechEnabled {
            alerts.append(NeedsYouAlert(
                id: "tts",
                symbolName: "speaker.slash",
                title: "The voice server isn't running",
                detail: "Replies show in the notch but won't be spoken.",
                actionTitle: "Use silent mode",
                action: { voiceOutputPreference.isReplySpeechEnabled = false }
            ))
        }

        if companionManager.pendingToolConfirmation != nil {
            alerts.append(NeedsYouAlert(
                id: "confirmation",
                symbolName: "hand.raised",
                title: "Wisp is waiting for your ok",
                detail: "The request is under the notch — allow it or cancel it there.",
                actionTitle: nil,
                action: nil
            ))
        }

        if let recentFailure = mostRecentUnfinishedTask {
            alerts.append(NeedsYouAlert(
                id: "failure-\(recentFailure.id.uuidString)",
                symbolName: "exclamationmark.triangle",
                title: "Didn't finish: \(recentFailure.title)",
                detail: failureDetail(for: recentFailure),
                actionTitle: "See in History",
                action: { onSelectPage(.timeline) }
            ))
        }

        return alerts.filter { !dismissedAlertIDs.contains($0.id) }
    }

    /// The newest task from the last two hours that failed or was cut off by a
    /// quit — worth a nudge, where an older one is just history.
    private var mostRecentUnfinishedTask: AgentTaskRecord? {
        let oldestRelevantDate = Date().addingTimeInterval(-2 * 60 * 60)
        return taskRegistry.records.first { record in
            let didNotFinish: Bool
            switch record.status {
            case .failed, .interrupted: didNotFinish = true
            default: didNotFinish = false
            }
            return didNotFinish && (record.finishedAt ?? record.startedAt) >= oldestRelevantDate
        }
    }

    private func failureDetail(for record: AgentTaskRecord) -> String {
        switch record.status {
        case .failed(let reason): return reason
        case .interrupted: return "Wisp quit while this was running."
        default: return ""
        }
    }

    @ViewBuilder
    private var needsYouStrip: some View {
        let alerts = needsYouAlerts
        if !alerts.isEmpty {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 300), spacing: tileSpacing, alignment: .top)],
                alignment: .leading,
                spacing: tileSpacing
            ) {
                ForEach(alerts) { alert in
                    needsYouCard(alert)
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
            }
            .animation(WispMotion.island, value: alerts.map(\.id))
        }
    }

    private func needsYouCard(_ alert: NeedsYouAlert) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: alert.symbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(WispColor.warningText)
                .frame(width: 30, height: 30)
                .background(Circle().fill(WispColor.warning.opacity(0.16)))
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title)
                    .font(WispFont.bodyMedium)
                    .foregroundStyle(WispColor.textPrimary)
                    .lineLimit(1)
                Text(alert.detail)
                    .font(WispFont.callout)
                    .foregroundStyle(WispColor.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if let actionTitle = alert.actionTitle, let action = alert.action {
                Button(actionTitle, action: action)
                    .buttonStyle(WispPillButtonStyle(isProminent: false))
                    .pointerCursor()
            }
            Button {
                withAnimation(WispMotion.island) { _ = dismissedAlertIDs.insert(alert.id) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(WispColor.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .nativeTooltip("Dismiss")
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: WispBentoMetrics.cornerRadius, style: .continuous)
                .fill(WispColor.warning.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: WispBentoMetrics.cornerRadius, style: .continuous)
                .strokeBorder(WispColor.warning.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Running now

    @ViewBuilder
    private var runningNowTile: some View {
        let runningRecords = taskRegistry.runningRecords
        if !runningRecords.isEmpty {
            WispBentoTile(
                title: "Running now",
                symbolName: "waveform",
                tint: WispColor.intelligence,
                isLive: true
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(runningRecords) { runningRecord in
                        runningTaskRow(runningRecord)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .animation(WispMotion.island, value: runningRecords.map(\.id))
            }
        }
    }

    private func runningTaskRow(_ runningRecord: AgentTaskRecord) -> some View {
        let isInteractiveTask = runningRecord.kind == .interactive
        return HStack(alignment: .center, spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(runningRecord.title)
                    .font(WispFont.bodyMedium)
                    .foregroundStyle(WispColor.textPrimary)
                    .lineLimit(1)
                Text(runningTaskStatusLine(runningRecord))
                    .font(WispFont.callout)
                    .foregroundStyle(WispColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                if isInteractiveTask {
                    companionManager.stopCurrentTask()
                } else {
                    taskRegistry.cancelTask(runningRecord.id)
                }
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(WispFont.caption)
            }
            .buttonStyle(WispPillButtonStyle(isProminent: false))
            .pointerCursor()
        }
    }

    /// For the live turn, what the browser is doing right now when a browser
    /// task is running; otherwise how long it has run and its latest step.
    private func runningTaskStatusLine(_ runningRecord: AgentTaskRecord) -> String {
        if runningRecord.status == .waitingForApproval {
            return "Waiting for your ok"
        }
        if runningRecord.kind == .interactive && !companionManager.browserActivityText.isEmpty {
            return "Step \(companionManager.browserTaskStepCount) · \(companionManager.browserActivityText)"
        }
        let elapsedMinutes = Int(runningRecord.elapsedSeconds / 60)
        let elapsedText = elapsedMinutes < 1 ? "Just started" : "\(elapsedMinutes) min"
        let kindText = runningRecord.kind == .background ? "Background" : "Now"
        if let latestStepSummary = runningRecord.steps.last?.summary {
            return "\(kindText) · \(elapsedText) · \(latestStepSummary)"
        }
        return "\(kindText) · \(elapsedText)"
    }

    // MARK: - Buddies

    private var buddiesTile: some View {
        let orderedBuddies = Array(buddyStore.orderedBuddies(in: taskRegistry).prefix(4))
        return WispBentoTile(
            title: "Buddies",
            symbolName: "person.2.fill",
            accessory: AnyView(newBuddyButton)
        ) {
            if orderedBuddies.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: -8) {
                        ForEach(0..<3, id: \.self) { colorIndex in
                            BuddyAvatar(colorIndex: colorIndex, size: 34, isWorking: true)
                        }
                    }
                    Text("A buddy takes one job off your hands and runs it on a schedule.")
                        .font(WispFont.callout)
                        .foregroundStyle(WispColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    WispBentoLink(title: "Summon a buddy", action: openNewBuddyForm)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(orderedBuddies) { buddy in
                        TodayBuddyRow(
                            buddy: buddy,
                            isWorking: buddyStore.isRunning(buddy, in: taskRegistry),
                            isUnread: buddyStore.isUnread(buddy, in: taskRegistry),
                            statusText: buddyStatusText(buddy),
                            onOpen: { openBuddy(buddy.id) }
                        )
                    }
                    if buddyStore.buddies.count > orderedBuddies.count {
                        WispBentoLink(title: "All \(buddyStore.buddies.count) buddies") {
                            onSelectPage(.buddies)
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    private var newBuddyButton: some View {
        Button(action: openNewBuddyForm) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(WispColor.accentText)
                .frame(width: 24, height: 24)
                .background(Circle().fill(WispColor.accentSubtle))
                .contentShape(Circle())
        }
        .buttonStyle(WispBentoPressStyle())
        .pointerCursor()
        .nativeTooltip("New buddy")
    }

    /// "Working…", the start of its latest answer, or its schedule.
    private func buddyStatusText(_ buddy: WispBuddy) -> String {
        if buddyStore.isRunning(buddy, in: taskRegistry) {
            return "Working…"
        }
        if let latestRunRecord = buddyStore.latestRunRecord(of: buddy, in: taskRegistry),
           let latestAnswer = latestRunRecord.finalText,
           !latestAnswer.isEmpty {
            return AnswerDisplayText.cleaned(latestAnswer).replacingOccurrences(of: "\n", with: " ")
        }
        return buddy.schedule.summary()
    }

    private func openBuddy(_ buddyID: UUID) {
        WispWindowRouter.shared.buddyIDToOpen = buddyID
        onSelectPage(.buddies)
    }

    private func openNewBuddyForm() {
        WispWindowRouter.shared.isNewBuddyFormRequested = true
        onSelectPage(.buddies)
    }

    // MARK: - Up next

    private var upNextTile: some View {
        WispBentoTile(title: "Up next", symbolName: "calendar", tint: WispColor.destructiveText) {
            switch calendarState {
            case .loading:
                ProgressView().controlSize(.small)
            case .needsAccess:
                VStack(alignment: .leading, spacing: 10) {
                    Text("Your next meetings appear here. Calendar is read on this Mac only.")
                        .font(WispFont.callout)
                        .foregroundStyle(WispColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Connect Calendar") {
                        Task { await loadCalendar(requestingAccess: true) }
                    }
                    .buttonStyle(WispPillButtonStyle())
                    .pointerCursor()
                }
            case .accessDenied:
                Text("Calendar access is off. Turn it on for Wisp in System Settings › Privacy & Security › Calendars.")
                    .font(WispFont.callout)
                    .foregroundStyle(WispColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .loaded(let upcomingEvents):
                if upcomingEvents.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("All clear")
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundStyle(WispColor.textPrimary)
                        Text("Nothing on your calendar this week.")
                            .font(WispFont.callout)
                            .foregroundStyle(WispColor.textSecondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(upcomingEvents.prefix(3)) { upcomingEvent in
                            upcomingEventRow(upcomingEvent)
                        }
                    }
                }
            }
        }
    }

    private func upcomingEventRow(_ upcomingEvent: CalendarGlanceEvent) -> some View {
        let calendarColor = upcomingEvent.calendarColorHex.map { Color(hex: $0) } ?? WispColor.accent
        let isStartingSoon = !upcomingEvent.isAllDay
            && upcomingEvent.startDate.timeIntervalSinceNow < 15 * 60
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(calendarColor)
                .frame(width: 3, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(upcomingEvent.title)
                    .font(WispFont.bodyMedium)
                    .foregroundStyle(WispColor.textPrimary)
                    .lineLimit(1)
                Text(upcomingEventDetail(upcomingEvent))
                    .font(WispFont.callout)
                    .foregroundStyle(isStartingSoon ? WispColor.warningText : WispColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    /// "9:30 AM · in 12 min · Zoom", "Tuesday 2:00 PM · Room 4", "All day".
    private func upcomingEventDetail(_ upcomingEvent: CalendarGlanceEvent) -> String {
        var detailParts: [String] = []
        let secondsUntilStart = upcomingEvent.startDate.timeIntervalSinceNow
        if upcomingEvent.isAllDay {
            detailParts.append("All day")
        } else if upcomingEvent.startDate <= Date() {
            detailParts.append("Now")
        } else {
            let timeText = upcomingEvent.startDate.formatted(date: .omitted, time: .shortened)
            if !Calendar.current.isDateInToday(upcomingEvent.startDate) {
                detailParts.append("\(upcomingEvent.startDate.formatted(.dateTime.weekday(.wide))) \(timeText)")
            } else if secondsUntilStart < 60 * 60 {
                detailParts.append("\(timeText) · in \(Int((secondsUntilStart / 60).rounded(.up))) min")
            } else {
                detailParts.append(timeText)
            }
        }
        if let location = upcomingEvent.location {
            detailParts.append(location)
        }
        return detailParts.joined(separator: " · ")
    }

    // MARK: - Brain

    /// A glance at the brain: how big it is, whether it's reading something,
    /// and the latest change. The whole tile opens Brain.
    private var brainTile: some View {
        let isReading = brainIngestQueue.pendingJobCount > 0
        let latestBrainChange = brainStore.changeRecords.first { !$0.isUndone }
        return WispBentoTile(
            title: "Brain",
            symbolName: "brain",
            tint: WispColor.intelligence,
            isLive: isReading,
            action: { onSelectPage(.brainPages) }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                WispBentoStat(
                    value: brainStore.pages.count,
                    caption: brainStore.pages.count == 1 ? "page" : "pages"
                )
                if isReading {
                    HStack(spacing: 6) {
                        WispPulsingDot(color: WispColor.intelligence)
                        Text("Reading \(brainIngestQueue.pendingJobCount)")
                            .font(WispFont.caption)
                            .foregroundStyle(WispColor.textSecondary)
                    }
                } else if let latestBrainChange {
                    Text(latestBrainChange.changeDescriptions.first ?? latestBrainChange.provenance.label)
                        .font(WispFont.callout)
                        .foregroundStyle(WispColor.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(latestBrainChange.date.formatted(.relative(presentation: .named)))
                        .font(WispFont.caption)
                        .foregroundStyle(WispColor.textTertiary)
                } else {
                    Text("Wisp files lasting facts from your conversations here.")
                        .font(WispFont.callout)
                        .foregroundStyle(WispColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Routines

    /// Routines with a shortcut or a notch pin first — the ones the user has
    /// said they reach for.
    private var featuredRoutines: [WispRoutine] {
        let routines = routineStore.routines
        let featured = routines.filter { $0.shortcutDigit != nil || $0.isPinnedInNotch }
        let others = routines.filter { $0.shortcutDigit == nil && !$0.isPinnedInNotch }
        return Array((featured + others).prefix(4))
    }

    private var routinesTile: some View {
        WispBentoTile(
            title: "Routines",
            symbolName: "bolt.fill",
            tint: WispColor.warningText,
            accessory: AnyView(
                WispBentoLink(title: featuredRoutines.isEmpty ? "Create" : "All") {
                    onSelectPage(.routines)
                }
            )
        ) {
            if featuredRoutines.isEmpty {
                Text("Save an instruction you use often and run it in one click.")
                    .font(WispFont.callout)
                    .foregroundStyle(WispColor.textSecondary)
            } else {
                // Two across when the tile is wide enough for the names, one
                // per row otherwise, so names aren't cut to "Summa…".
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 190), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(featuredRoutines) { routine in
                        TodayRoutineButton(
                            routine: routine,
                            subtitle: routineTileSubtitle(routine),
                            onRun: { runOnUsersWork { companionManager.runRoutine(withID: routine.id) } }
                        )
                    }
                }
            }
        }
    }

    private func routineTileSubtitle(_ routine: WispRoutine) -> String {
        if let shortcutDigit = routine.shortcutDigit {
            return RoutineStore.shortcutLabel(forDigit: shortcutDigit)
        }
        if let firstAppName = routine.suggestedAppNames.first {
            return "In \(firstAppName)"
        }
        return routine.isPinnedInNotch ? "In the notch" : "Click to run"
    }

    // MARK: - Recent answers

    /// The last few finished questions that produced an answer.
    private var recentAnswers: [AgentTaskRecord] {
        Array(
            taskRegistry.records
                .filter { record in
                    record.kind == .interactive
                        && record.status == .succeeded
                        && !(record.finalText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                .prefix(3)
        )
    }

    private var recentAnswersTile: some View {
        WispBentoTile(
            title: "Recent answers",
            symbolName: "text.bubble.fill",
            accessory: AnyView(WispBentoLink(title: "History") { onSelectPage(.timeline) })
        ) {
            if recentAnswers.isEmpty {
                Text("Answers Wisp gives you will show up here.")
                    .font(WispFont.callout)
                    .foregroundStyle(WispColor.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(recentAnswers) { answerRecord in
                        TodayRecentAnswerRow(
                            answerRecord: answerRecord,
                            isJustCopied: recentlyCopiedRecordID == answerRecord.id,
                            onCopy: { copyAnswer(answerRecord) }
                        )
                    }
                }
            }
        }
    }

    private func copyAnswer(_ answerRecord: AgentTaskRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AnswerDisplayText.cleaned(answerRecord.finalText ?? ""), forType: .string)
        withAnimation(WispMotion.island) { recentlyCopiedRecordID = answerRecord.id }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            if recentlyCopiedRecordID == answerRecord.id {
                withAnimation(WispMotion.smooth) { recentlyCopiedRecordID = nil }
            }
        }
    }

    // MARK: - Live data

    private func refreshLiveData() async {
        localServicesHealth = await LocalServicesHealth.check()
        await loadCalendar(requestingAccess: false)
    }

    /// Reads the next events. Only the Connect button requests access — a
    /// refresh never triggers a permission prompt on its own.
    private func loadCalendar(requestingAccess: Bool) async {
        let authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        if authorizationStatus == .notDetermined && !requestingAccess {
            calendarState = .needsAccess
            return
        }
        do {
            let calendarSnapshot = try await CalendarDataProvider.shared.snapshot()
            calendarState = .loaded(calendarSnapshot.events)
        } catch {
            calendarState = .accessDenied
        }
    }
}

// MARK: - Supporting types

private enum TodayCalendarState {
    case loading
    case needsAccess
    case accessDenied
    case loaded([CalendarGlanceEvent])
}

/// Whether the local services Wisp relies on are answering. Only services the
/// current setup actually uses are checked: the local model only when the
/// selected provider is local Ollama, the voice server only when the build uses
/// Chatterbox. Everything here is an HTTP request to `localhost`.
private struct LocalServicesHealth {
    var isLocalModelUnreachable: Bool
    var isVoiceServerUnreachable: Bool

    static let unknown = LocalServicesHealth(isLocalModelUnreachable: false, isVoiceServerUnreachable: false)

    @MainActor
    static func check() async -> LocalServicesHealth {
        let isUsingLocalModel = BuddyChatProviderSelection.current == .localOllama
        let isUsingLocalVoiceServer = AppBundleConfiguration
            .stringValue(forKey: "VoiceTTSProvider")?.lowercased() == "chatterbox"

        async let localModelReachable: Bool = isUsingLocalModel
            ? SystemReadouts.ollamaResidency() != .unreachable
            : true
        async let voiceServerReachable: Bool = isUsingLocalVoiceServer
            ? isServerAnswering(
                baseURLString: AppBundleConfiguration.stringValue(forKey: "ChatterboxTTSServerURL")
                    ?? "http://localhost:8004"
            )
            : true

        return LocalServicesHealth(
            isLocalModelUnreachable: !(await localModelReachable),
            isVoiceServerUnreachable: !(await voiceServerReachable)
        )
    }

    /// Any HTTP response counts as up; only a connection failure is down.
    private static func isServerAnswering(baseURLString: String) async -> Bool {
        guard let serverURL = URL(string: baseURLString) else { return false }
        var healthRequest = URLRequest(url: serverURL)
        healthRequest.timeoutInterval = 3
        do {
            _ = try await URLSession.shared.data(for: healthRequest)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Today rows

/// One buddy on Today: its avatar (bobbing while it works), name, a dot when
/// it has news, and what it's up to. Highlights under the pointer.
private struct TodayBuddyRow: View {
    let buddy: WispBuddy
    let isWorking: Bool
    let isUnread: Bool
    let statusText: String
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                BuddyAvatar(colorIndex: buddy.colorIndex, size: 30, isWorking: isWorking)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(buddy.name)
                            .font(WispFont.bodyMedium)
                            .foregroundStyle(WispColor.textPrimary)
                            .lineLimit(1)
                        if isUnread {
                            Circle()
                                .fill(WispColor.intelligence)
                                .frame(width: 6, height: 6)
                                .transition(.scale)
                        }
                    }
                    Text(statusText)
                        .font(WispFont.callout)
                        .foregroundStyle(isWorking ? WispColor.intelligence : WispColor.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(WispColor.textTertiary)
                    .opacity(isHovered ? 1 : 0)
                    .offset(x: isHovered ? 0 : -4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: WispRadius.medium, style: .continuous)
                    .fill(isHovered ? WispColor.surface2 : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(WispBentoPressStyle())
        .pointerCursor()
        .onHover { hovering in
            withAnimation(WispMotion.quick) { isHovered = hovering }
        }
        .padding(.horizontal, -8)
    }
}

/// A routine on Today: its icon in a tinted chip that turns into a play button
/// under the pointer, so it's clear a click runs it.
private struct TodayRoutineButton: View {
    let routine: WispRoutine
    let subtitle: String
    let onRun: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onRun) {
            HStack(spacing: 9) {
                Image(systemName: isHovered ? "play.fill" : routine.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isHovered ? WispColor.textOnAccent : WispColor.accentText)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(isHovered ? WispColor.accent : WispColor.accentSubtle)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(routine.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(WispColor.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(WispColor.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isHovered ? WispColor.surface3 : WispColor.surface2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(WispBentoPressStyle())
        .pointerCursor()
        .nativeTooltip(routine.instruction)
        .onHover { hovering in
            withAnimation(WispMotion.smooth) { isHovered = hovering }
        }
    }
}

/// A recent answer: the question, the start of the answer, when, and a Copy
/// button that appears under the pointer and checks itself when used.
private struct TodayRecentAnswerRow: View {
    let answerRecord: AgentTaskRecord
    let isJustCopied: Bool
    let onCopy: () -> Void

    @State private var isHovered = false

    var body: some View {
        let answerText = AnswerDisplayText.cleaned(answerRecord.finalText ?? "")
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(answerRecord.title)
                    .font(WispFont.bodyMedium)
                    .foregroundStyle(WispColor.textPrimary)
                    .lineLimit(1)
                Text(answerText.replacingOccurrences(of: "\n", with: " "))
                    .font(WispFont.callout)
                    .foregroundStyle(WispColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isHovered || isJustCopied {
                Button(action: onCopy) {
                    Image(systemName: isJustCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isJustCopied ? WispColor.success : WispColor.textSecondary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(WispColor.surface2))
                        .contentShape(Circle())
                }
                .buttonStyle(WispBentoPressStyle())
                .pointerCursor()
                .nativeTooltip("Copy answer")
                .transition(.scale.combined(with: .opacity))
            } else {
                Text((answerRecord.finishedAt ?? answerRecord.startedAt).formatted(.relative(presentation: .named)))
                    .font(.system(size: 10.5))
                    .foregroundStyle(WispColor.textTertiary)
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: WispRadius.medium, style: .continuous)
                .fill(isHovered ? WispColor.surface2.opacity(0.6) : .clear)
        )
        .padding(.horizontal, -8)
        .onHover { hovering in
            withAnimation(WispMotion.quick) { isHovered = hovering }
        }
    }
}

/// A small dot that breathes, for "something is happening".
private struct WispPulsingDot: View {
    let color: Color
    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .background(
                Circle()
                    .fill(color.opacity(0.35))
                    .scaleEffect(isExpanded ? 2.2 : 1)
                    .opacity(isExpanded ? 0 : 1)
            )
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) {
                    isExpanded = true
                }
            }
    }
}
