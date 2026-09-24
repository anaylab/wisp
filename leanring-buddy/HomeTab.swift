//
//  HomeTab.swift
//  leanring-buddy
//
//  The dashboard's Today page — what's happening and what's worth doing next,
//  rather than a map of the settings. Top to bottom:
//
//  - an ask bar (a typed question, or `/` to run a routine),
//  - "Needs you": problems that block Wisp, each with its fix,
//  - running tasks with a Stop,
//  - the next few calendar events,
//  - routines one click away, and recent answers to copy.
//
//  Anything that runs from here closes the dashboard first, so the screenshot
//  Wisp takes shows the user's work and not this window. Fully adaptive
//  (light/dark) via the `DS`/`WispColor` tokens.
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

    /// Navigates the dashboard to another page (e.g. "All routines").
    let onSelectTab: (DashboardView.DashboardTab) -> Void

    @State private var askBarText = ""
    @State private var localServicesHealth = LocalServicesHealth.unknown
    @State private var calendarState: TodayCalendarState = .loading
    /// Alerts the user dismissed this session, keyed by `NeedsYouAlert.id`.
    @State private var dismissedAlertIDs: Set<String> = []
    /// The recent answer whose Copy button just fired, for its checkmark.
    @State private var recentlyCopiedRecordID: UUID?

    init(
        taskRegistry: AgentTaskRegistry,
        companionManager: CompanionManager,
        onSelectTab: @escaping (DashboardView.DashboardTab) -> Void
    ) {
        self.taskRegistry = taskRegistry
        self.companionManager = companionManager
        self.onSelectTab = onSelectTab
    }

    /// How often the page re-checks the local services and the calendar while
    /// it is on screen. The loop stops when the page goes away.
    private let refreshIntervalSeconds: UInt64 = 30

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                askBar
                needsYouSection
                // Two columns when there is room, one when the window is narrow.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        primaryColumn.frame(minWidth: 300)
                        secondaryColumn.frame(minWidth: 300)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        primaryColumn
                        secondaryColumn
                    }
                }
            }
            .padding(.horizontal, WispSpacing.xxl)
            .padding(.vertical, WispSpacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            while !Task.isCancelled {
                await refreshLiveData()
                try? await Task.sleep(nanoseconds: refreshIntervalSeconds * 1_000_000_000)
            }
        }
    }

    private var primaryColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            runningNowCard
            upNextCard
        }
    }

    private var secondaryColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            routinesCard
            recentAnswersCard
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(WispFont.callout)
                    .foregroundStyle(DS.Colors.textSecondary)
                Text(greeting)
                    .font(WispFont.hero)
                    .foregroundStyle(DS.Colors.textPrimary)
            }
            Spacer(minLength: 8)
            Button {
                voiceOutputPreference.isReplySpeechEnabled.toggle()
            } label: {
                Label(
                    voiceOutputPreference.isReplySpeechEnabled ? "Voice on" : "Silent",
                    systemImage: voiceOutputPreference.isReplySpeechEnabled ? "speaker.wave.2" : "speaker.slash"
                )
                .font(WispFont.caption)
            }
            .buttonStyle(WispGlassButtonStyle())
            .pointerCursor()
            .nativeTooltip(voiceOutputPreference.isReplySpeechEnabled
                ? "Replies are spoken. Click for silent mode."
                : "Replies show in the notch only. Click to have them spoken.")
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    // MARK: - Ask bar

    private var askBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                WispMark(state: companionManager.islandState.markState, size: 20)
                TextField("Ask anything, or type / to run a routine", text: $askBarText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .onSubmit(submitAskBar)
                HStack(spacing: 4) {
                    ForEach(bindingStore.primaryHoldChord.keyCapsuleLabels, id: \.self) { keyLabel in
                        keyCap(keyLabel)
                    }
                    Text("hold to talk")
                        .font(WispFont.caption)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: WispRadius.panel, style: .continuous)
                    .fill(DS.Colors.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: WispRadius.panel, style: .continuous)
                    .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
            )

            if isAskBarInRoutineMode {
                routineMatchesList
            }
        }
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
                    .foregroundStyle(DS.Colors.textSecondary)
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
                                .foregroundStyle(DS.Colors.accentText)
                                .frame(width: 16)
                            Text(routine.name)
                                .font(WispFont.bodyMedium)
                                .foregroundStyle(DS.Colors.textPrimary)
                            Spacer(minLength: 0)
                            // Return runs the first match.
                            if matchIndex == 0 {
                                Text("↩")
                                    .font(WispFont.caption)
                                    .foregroundStyle(DS.Colors.textTertiary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(matchIndex == 0 ? DS.Colors.surface2 : .clear)
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
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface1)
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

    /// Closes the dashboard, then runs `action` once the user's previous app is
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
            .foregroundStyle(DS.Colors.textSecondary)
            .padding(.horizontal, 5)
            .frame(height: 18)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
            )
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

        if !companionManager.allPermissionsGranted {
            alerts.append(NeedsYouAlert(
                id: "permissions",
                symbolName: "lock",
                title: "Wisp is missing a permission",
                detail: "It can't see the screen or hear you until it's granted.",
                actionTitle: "Review",
                action: { onSelectTab(.agent) }
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
                action: { onSelectTab(.activity) }
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
    private var needsYouSection: some View {
        let alerts = needsYouAlerts
        if !alerts.isEmpty {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(alerts) { alert in
                    needsYouCard(alert)
                }
            }
        }
    }

    private func needsYouCard(_ alert: NeedsYouAlert) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: alert.symbolName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DS.Colors.warningText)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title)
                    .font(WispFont.bodyMedium)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                Text(alert.detail)
                    .font(WispFont.callout)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if let actionTitle = alert.actionTitle, let action = alert.action {
                Button(actionTitle, action: action)
                    .buttonStyle(WispGlassButtonStyle())
                    .pointerCursor()
            }
            Button {
                dismissedAlertIDs.insert(alert.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .nativeTooltip("Dismiss")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.warning.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .strokeBorder(DS.Colors.warning.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Running now

    @ViewBuilder
    private var runningNowCard: some View {
        let runningRecords = taskRegistry.runningRecords
        if !runningRecords.isEmpty {
            DashboardCard(title: "Running now") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(runningRecords) { runningRecord in
                        runningTaskRow(runningRecord)
                    }
                }
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
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                Text(runningTaskStatusLine(runningRecord))
                    .font(WispFont.callout)
                    .foregroundStyle(DS.Colors.textSecondary)
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
            .buttonStyle(WispGlassButtonStyle())
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

    // MARK: - Up next

    private var upNextCard: some View {
        DashboardCard(title: "Up next") {
            switch calendarState {
            case .loading:
                ProgressView().controlSize(.small)
            case .needsAccess:
                VStack(alignment: .leading, spacing: 8) {
                    Text("See your next meetings here. Wisp reads Calendar on this Mac; nothing is sent anywhere.")
                        .font(WispFont.callout)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Connect Calendar") {
                        Task { await loadCalendar(requestingAccess: true) }
                    }
                    .buttonStyle(WispGlassButtonStyle(prominence: .prominent))
                    .pointerCursor()
                }
            case .accessDenied:
                Text("Calendar access is off. Turn it on for Wisp in System Settings › Privacy & Security › Calendars.")
                    .font(WispFont.callout)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .loaded(let upcomingEvents):
                if upcomingEvents.isEmpty {
                    Text("Nothing on your calendar this week.")
                        .font(WispFont.callout)
                        .foregroundStyle(DS.Colors.textSecondary)
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
        HStack(spacing: 12) {
            Text(upcomingEvent.isAllDay ? "All day" : upcomingEvent.startDate.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(DS.Colors.accentText)
                .frame(width: 64, alignment: .leading)
            RoundedRectangle(cornerRadius: 2)
                .fill(DS.Colors.accent.opacity(0.6))
                .frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(upcomingEvent.title)
                    .font(WispFont.bodyMedium)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                Text(upcomingEventDetail(upcomingEvent))
                    .font(WispFont.callout)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    /// "In 12 min · Zoom", "Tomorrow · Room 4", or just the location.
    private func upcomingEventDetail(_ upcomingEvent: CalendarGlanceEvent) -> String {
        var detailParts: [String] = []
        let secondsUntilStart = upcomingEvent.startDate.timeIntervalSinceNow
        if upcomingEvent.startDate <= Date() {
            detailParts.append("Now")
        } else if secondsUntilStart < 60 * 60 {
            detailParts.append("In \(Int((secondsUntilStart / 60).rounded(.up))) min")
        } else if !Calendar.current.isDateInToday(upcomingEvent.startDate) {
            detailParts.append(upcomingEvent.startDate.formatted(.dateTime.weekday(.wide)))
        }
        if let location = upcomingEvent.location {
            detailParts.append(location)
        }
        return detailParts.isEmpty ? "Today" : detailParts.joined(separator: " · ")
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

    private var routinesCard: some View {
        DashboardCard(title: "Routines") {
            VStack(alignment: .leading, spacing: 10) {
                if featuredRoutines.isEmpty {
                    Text("Save an instruction you use often and run it in one click.")
                        .font(WispFont.callout)
                        .foregroundStyle(DS.Colors.textSecondary)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(featuredRoutines) { routine in
                            routineTile(routine)
                        }
                    }
                }
                Button {
                    onSelectTab(.routines)
                } label: {
                    Text(featuredRoutines.isEmpty ? "Create a routine" : "All routines")
                        .font(WispFont.caption)
                        .foregroundStyle(DS.Colors.accentText)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    private func routineTile(_ routine: WispRoutine) -> some View {
        Button {
            runOnUsersWork { companionManager.runRoutine(withID: routine.id) }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: routine.symbolName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Colors.accentText)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(DS.Colors.accentSubtle)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(routine.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(routineTileSubtitle(routine))
                        .font(.system(size: 10.5))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableScaleButtonStyle())
        .pointerCursor()
        .nativeTooltip(routine.instruction)
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

    private var recentAnswersCard: some View {
        DashboardCard(title: "Recent answers") {
            VStack(alignment: .leading, spacing: 0) {
                if recentAnswers.isEmpty {
                    Text("Answers Wisp gives you will show up here.")
                        .font(WispFont.callout)
                        .foregroundStyle(DS.Colors.textSecondary)
                } else {
                    ForEach(Array(recentAnswers.enumerated()), id: \.element.id) { answerIndex, answerRecord in
                        if answerIndex > 0 {
                            Divider().background(DS.Colors.borderSubtle)
                        }
                        recentAnswerRow(answerRecord)
                    }
                }
                Button {
                    onSelectTab(.activity)
                } label: {
                    Text("Open History")
                        .font(WispFont.caption)
                        .foregroundStyle(DS.Colors.accentText)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .padding(.top, 10)
            }
        }
    }

    private func recentAnswerRow(_ answerRecord: AgentTaskRecord) -> some View {
        let answerText = answerRecord.finalText ?? ""
        let isJustCopied = recentlyCopiedRecordID == answerRecord.id
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(answerRecord.title)
                    .font(WispFont.bodyMedium)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                Text(answerText.replacingOccurrences(of: "\n", with: " "))
                    .font(WispFont.callout)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text((answerRecord.finishedAt ?? answerRecord.startedAt).formatted(.relative(presentation: .named)))
                .font(.system(size: 10.5))
                .foregroundStyle(DS.Colors.textTertiary)
                .lineLimit(1)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(answerText, forType: .string)
                recentlyCopiedRecordID = answerRecord.id
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.6))
                    if recentlyCopiedRecordID == answerRecord.id {
                        recentlyCopiedRecordID = nil
                    }
                }
            } label: {
                Image(systemName: isJustCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isJustCopied ? DS.Colors.success : DS.Colors.textSecondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .nativeTooltip("Copy answer")
        }
        .padding(.vertical, 8)
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
