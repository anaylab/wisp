//
//  JobsTab.swift
//  leanring-buddy
//
//  The Jobs page: where the Canvas calendar job and the daily checklist are set
//  up and watched. A job is Source -> Rule -> Output -> Cadence and stays quiet
//  unless something changed, so this page is mostly a status readout.
//
//  Setup is two steps:
//    1. Add Canvas   - paste the calendar feed link once. It is validated here,
//                      kept in the Keychain by the engine, and fetched right away
//                      so the page can say how many items it found.
//    2. Plan my day  - allow Calendar and Reminders (asked only from this page,
//                      never at launch) and build today's checklist.
//  Below them: what changed in the last sync, study blocks waiting for approval
//  (one card, never written automatically) and today's checklist.
//
//  Everything here reads `JobsEngine`; nothing on this page touches EventKit,
//  the network or the Keychain itself. The feed link is a secret: it is only
//  ever in the text field while it is being pasted, and is cleared the moment
//  the engine accepts it.
//

import AppKit
import SwiftUI

struct JobsTab: View {
    @ObservedObject private var jobsEngine = JobsEngine.shared

    /// The pasted feed link, held only until the engine accepts it.
    @State private var feedLinkText = ""
    @State private var feedLinkErrorMessage: String?
    @State private var isConfirmingFeedRemoval = false
    @State private var isRequestingAccess = false
    @State private var isPlanningDay = false
    @State private var isApprovingStudyBlocks = false

    /// How many changed items the "What changed" card lists before "+N more".
    private let maximumListedChanges = 6

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                canvasCard
                planMyDayCard
                if let latestDiff = jobsEngine.latestDiff {
                    changesCard(latestDiff)
                }
                if !jobsEngine.pendingStudyBlocks.isEmpty {
                    studyBlocksCard
                }
                if !jobsEngine.todayChecklist.isEmpty {
                    checklistCard
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(WispColor.windowBackground)
        .task {
            // Reminders is the source of truth for ticks, so ticks made in the
            // Reminders app show up the moment this page is opened.
            await jobsEngine.refreshChecklistCompletion()
        }
    }

    // MARK: - Step 1: Canvas

    private var canvasCard: some View {
        DashboardCard(title: "1  Canvas") {
            if jobsEngine.hasCanvasFeed {
                connectedCanvasContent
            } else {
                addCanvasContent
            }
        }
    }

    private var addCanvasContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            // A secure field because the link is a password in all but name:
            // anyone who has it can read the calendar.
            SecureField("Paste your Canvas calendar feed link", text: $feedLinkText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { addCanvasFeed() }
                .onChange(of: feedLinkText) { _, _ in feedLinkErrorMessage = nil }

            if let feedLinkErrorMessage {
                problemLine(feedLinkErrorMessage)
            } else if case .failed(let failureMessage) = jobsEngine.syncState {
                problemLine(failureMessage)
            }

            HStack(spacing: 10) {
                Button("Add Canvas") { addCanvasFeed() }
                    .buttonStyle(WispPillButtonStyle())
                    .controlSize(.small)
                    .disabled(feedLinkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .pointerCursor()
                Text("Canvas > Calendar > Calendar Feed")
                    .font(.caption)
                    .foregroundStyle(WispColor.textTertiary)
            }
        }
    }

    private var connectedCanvasContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                statusDot
                VStack(alignment: .leading, spacing: 2) {
                    Text(canvasStatusTitle)
                        .font(.body.weight(.medium))
                        .foregroundStyle(WispColor.textPrimary)
                    Text(canvasStatusDetail)
                        .font(.callout)
                        .foregroundStyle(WispColor.textSecondary)
                }
                Spacer(minLength: 0)
                if jobsEngine.syncState == .syncing {
                    ProgressView().controlSize(.small)
                }
                Button("Sync now") {
                    Task { await jobsEngine.syncNow() }
                }
                .buttonStyle(WispPillButtonStyle(isProminent: false))
                .controlSize(.small)
                .disabled(jobsEngine.syncState == .syncing)
                .pointerCursor()
            }

            if case .failed(let failureMessage) = jobsEngine.syncState {
                problemLine(failureMessage)
            }

            Divider()
            SettingRow(title: "Keep in sync", detail: "") {
                Toggle("Keep in sync", isOn: $jobsEngine.isCanvasJobEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .pointerCursor()
            }
            SettingRow(title: "Suggest study blocks", detail: "") {
                Toggle("Suggest study blocks", isOn: $jobsEngine.studyBlockSettings.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .pointerCursor()
            }
            if jobsEngine.studyBlockSettings.isEnabled {
                SettingRow(title: "Block length", detail: "") {
                    WispSegmented(
                        options: [60, 90, 120],
                        title: { "\($0) min" },
                        selection: $jobsEngine.studyBlockSettings.blockMinutes
                    )
                }
            }

            Divider()
            feedRemovalRow
        }
    }

    @ViewBuilder
    private var feedRemovalRow: some View {
        if isConfirmingFeedRemoval {
            HStack(spacing: 10) {
                Text("Remove the link? Events already in your Wisp calendar stay.")
                    .font(.callout)
                    .foregroundStyle(WispColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Cancel") { isConfirmingFeedRemoval = false }
                    .buttonStyle(WispPillButtonStyle(isProminent: false))
                    .controlSize(.small)
                    .pointerCursor()
                Button("Remove") {
                    jobsEngine.removeCanvasFeed()
                    isConfirmingFeedRemoval = false
                }
                .buttonStyle(WispPillButtonStyle.destructive)
                .controlSize(.small)
                .pointerCursor()
            }
        } else {
            HStack {
                Spacer(minLength: 0)
                Button("Remove Canvas") { isConfirmingFeedRemoval = true }
                    .buttonStyle(WispPillButtonStyle(isProminent: false))
                    .controlSize(.small)
                    .pointerCursor()
            }
        }
    }

    private func addCanvasFeed() {
        let pastedLink = feedLinkText
        switch jobsEngine.saveCanvasFeed(urlText: pastedLink) {
        case .success:
            // The engine now owns the link (Keychain) and has started the first
            // fetch; keeping it in view state would only leave a secret around.
            feedLinkText = ""
            feedLinkErrorMessage = nil
        case .failure(let validationError):
            feedLinkErrorMessage = validationError.errorDescription
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(statusDotColor)
            .frame(width: 8, height: 8)
    }

    private var statusDotColor: Color {
        switch jobsEngine.syncState {
        case .failed: return WispColor.warning
        case .syncing: return WispColor.intelligence
        case .idle: return jobsEngine.isCanvasJobEnabled ? WispColor.success : WispColor.textTertiary
        case .notConfigured: return WispColor.textTertiary
        }
    }

    private var canvasStatusTitle: String {
        switch jobsEngine.syncState {
        case .syncing: return "Checking Canvas"
        case .failed: return "Couldn't reach Canvas"
        case .notConfigured: return "Not connected"
        case .idle:
            if !jobsEngine.isCanvasJobEnabled { return "Paused" }
            let itemCount = jobsEngine.itemCountInFeed
            return itemCount > 0 ? "Connected, \(itemCount) \(itemCount == 1 ? "item" : "items")" : "Connected"
        }
    }

    private var canvasStatusDetail: String {
        guard let lastSyncedAt = jobsEngine.lastSyncedAt else { return "Not synced yet" }
        return "Synced \(lastSyncedAt.formatted(.relative(presentation: .named)))"
    }

    // MARK: - Step 2: Plan my day

    private var planMyDayCard: some View {
        DashboardCard(title: "2  Plan my day") {
            VStack(alignment: .leading, spacing: 12) {
                accessRow(title: "Calendar", state: jobsEngine.calendarAccess, privacyPane: "Privacy_Calendars")
                accessRow(title: "Reminders", state: jobsEngine.remindersAccess, privacyPane: "Privacy_Reminders")

                if needsAccessPrompt {
                    HStack {
                        Button {
                            Task {
                                isRequestingAccess = true
                                await jobsEngine.requestCalendarAndRemindersAccess()
                                isRequestingAccess = false
                            }
                        } label: {
                            Text(isRequestingAccess ? "Asking…" : "Allow Calendar and Reminders")
                        }
                        .buttonStyle(WispPillButtonStyle())
                        .controlSize(.small)
                        .disabled(isRequestingAccess)
                        .pointerCursor()
                        Spacer(minLength: 0)
                    }
                }

                Divider()
                SettingRow(title: "Daily checklist", detail: "") {
                    Toggle("Daily checklist", isOn: $jobsEngine.isDailyChecklistEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .pointerCursor()
                }
                HStack {
                    Button {
                        Task {
                            isPlanningDay = true
                            await jobsEngine.rebuildChecklistNow()
                            isPlanningDay = false
                        }
                    } label: {
                        Text(isPlanningDay ? "Planning…" : (jobsEngine.todayChecklist.isEmpty ? "Plan my day" : "Rebuild today"))
                    }
                    .buttonStyle(WispPillButtonStyle(isProminent: jobsEngine.todayChecklist.isEmpty))
                    .controlSize(.small)
                    .disabled(isPlanningDay || !jobsEngine.isDailyChecklistEnabled)
                    .pointerCursor()
                    Spacer(minLength: 0)
                }
                if let actionProblemMessage = jobsEngine.lastActionProblemMessage {
                    problemLine(actionProblemMessage)
                }
            }
        }
    }

    private var needsAccessPrompt: Bool {
        jobsEngine.calendarAccess == .notDetermined || jobsEngine.remindersAccess == .notDetermined
    }

    private func accessRow(title: String, state: JobsAccessState, privacyPane: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(state == .granted ? WispColor.success : WispColor.textTertiary)
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(WispColor.textPrimary)
            Spacer(minLength: 0)
            switch state {
            case .granted:
                Text("On").font(.callout).foregroundStyle(WispColor.textSecondary)
            case .notDetermined:
                Text("Not yet").font(.callout).foregroundStyle(WispColor.textSecondary)
            case .denied:
                Button("Open System Settings") { openPrivacySettings(pane: privacyPane) }
                    .buttonStyle(WispPillButtonStyle(isProminent: false))
                    .controlSize(.small)
                    .pointerCursor()
            }
        }
    }

    private func openPrivacySettings(pane privacyPane: String) {
        guard let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(privacyPane)") else { return }
        NSWorkspace.shared.open(settingsURL)
    }

    // MARK: - What changed

    private func changesCard(_ latestDiff: CanvasDiff) -> some View {
        let listedRows = changeRows(for: latestDiff)
        return DashboardCard(title: "What changed") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(latestDiff.isFirstSync
                         ? "Added \(latestDiff.added.count) Canvas items to Wisp"
                         : latestDiff.summaryLine)
                        .font(.body.weight(.medium))
                        .foregroundStyle(WispColor.textPrimary)
                    Spacer(minLength: 0)
                    Button("Dismiss") { jobsEngine.dismissLatestDiff() }
                        .buttonStyle(WispPillButtonStyle(isProminent: false))
                        .controlSize(.small)
                        .pointerCursor()
                }
                // A first sync is one summary, not a list of everything.
                if !latestDiff.isFirstSync {
                    ForEach(listedRows.prefix(maximumListedChanges)) { changeRow in
                        HStack(spacing: 8) {
                            Image(systemName: changeRow.symbolName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(WispColor.textSecondary)
                                .frame(width: 14)
                            Text(changeRow.title)
                                .font(.callout)
                                .foregroundStyle(WispColor.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(changeRow.dateText)
                                .font(.caption)
                                .foregroundStyle(WispColor.textTertiary)
                        }
                    }
                    if listedRows.count > maximumListedChanges {
                        Text("+\(listedRows.count - maximumListedChanges) more")
                            .font(.caption)
                            .foregroundStyle(WispColor.textTertiary)
                    }
                }
            }
        }
    }

    private struct ChangeRow: Identifiable {
        let id: String
        let symbolName: String
        let title: String
        let dateText: String
    }

    private func changeRows(for canvasDiff: CanvasDiff) -> [ChangeRow] {
        let addedRows = canvasDiff.added.map {
            ChangeRow(id: "added-\($0.uid)", symbolName: "plus", title: $0.title, dateText: Self.itemDateText($0))
        }
        let changedRows = canvasDiff.changed.map {
            ChangeRow(id: "changed-\($0.after.uid)", symbolName: "arrow.triangle.2.circlepath", title: $0.after.title, dateText: Self.itemDateText($0.after))
        }
        let removedRows = canvasDiff.removed.map {
            ChangeRow(id: "removed-\($0.uid)", symbolName: "minus", title: $0.title, dateText: Self.itemDateText($0))
        }
        return addedRows + changedRows + removedRows
    }

    private static func itemDateText(_ canvasItem: CanvasItem) -> String {
        if canvasItem.isAllDay {
            return canvasItem.startDate.formatted(.dateTime.month(.abbreviated).day())
        }
        return canvasItem.startDate.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    // MARK: - Study blocks

    private var studyBlocksCard: some View {
        let pendingBlocks = jobsEngine.pendingStudyBlocks
        return DashboardCard(title: "Study blocks") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(pendingBlocks) { studyBlock in
                    HStack(spacing: 8) {
                        Text(studyBlock.title)
                            .font(.callout)
                            .foregroundStyle(WispColor.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(Self.studyBlockTimeText(studyBlock))
                            .font(.caption)
                            .foregroundStyle(WispColor.textSecondary)
                    }
                }
                HStack(spacing: 10) {
                    Button {
                        Task {
                            isApprovingStudyBlocks = true
                            await jobsEngine.approvePendingStudyBlocks()
                            isApprovingStudyBlocks = false
                        }
                    } label: {
                        Text(isApprovingStudyBlocks ? "Waiting for your OK…" : "Add \(pendingBlocks.count) to Wisp calendar")
                    }
                    .buttonStyle(WispPillButtonStyle())
                    .controlSize(.small)
                    .disabled(isApprovingStudyBlocks)
                    .pointerCursor()
                    Button("Dismiss") { jobsEngine.dismissPendingStudyBlocks() }
                        .buttonStyle(WispPillButtonStyle(isProminent: false))
                        .controlSize(.small)
                        .disabled(isApprovingStudyBlocks)
                        .pointerCursor()
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private static func studyBlockTimeText(_ studyBlock: StudyBlockProposal) -> String {
        let startText = studyBlock.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        let endText = studyBlock.end.formatted(date: .omitted, time: .shortened)
        return "\(startText) - \(endText)"
    }

    // MARK: - Checklist

    private var checklistCard: some View {
        let completedCount = jobsEngine.todayChecklist.filter(\.isCompleted).count
        return DashboardCard(title: "Today") {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(completedCount) of \(jobsEngine.todayChecklist.count) done")
                    .font(.caption)
                    .foregroundStyle(WispColor.textTertiary)
                    .padding(.bottom, 4)
                ForEach(jobsEngine.todayChecklist) { checklistItem in
                    checklistRow(checklistItem)
                }
            }
        }
    }

    private func checklistRow(_ checklistItem: ChecklistItem) -> some View {
        Button {
            Task {
                await jobsEngine.setChecklistItem(id: checklistItem.id, isCompleted: !checklistItem.isCompleted)
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: checklistItem.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(checklistItem.isCompleted ? WispColor.accentText : WispColor.textTertiary)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 1) {
                    Text(checklistItem.title)
                        .font(.callout)
                        .foregroundStyle(checklistItem.isCompleted ? WispColor.textTertiary : WispColor.textPrimary)
                        .strikethrough(checklistItem.isCompleted)
                    if let subtitle = checklistItem.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(WispColor.textTertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel(checklistItem.title)
        .accessibilityValue(checklistItem.isCompleted ? "Done" : "Not done")
    }

    // MARK: - Shared

    private func problemLine(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(WispColor.warning)
            Text(message)
                .font(.callout)
                .foregroundStyle(WispColor.warningText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
