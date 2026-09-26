//
//  ConversationWindowView.swift
//  leanring-buddy
//
//  The pop-out conversation window's content: the recent back-and-forth as a
//  thread, a box to type follow-ups, and a side panel of the tasks Wisp is
//  working on (live step + Stop) and has recently finished.
//
//  The thread is built from `AgentTaskRegistry` (question = record title, answer
//  = final text), limited to the last few hours — roughly what the model itself
//  still remembers for a follow-up (`ConversationHistoryCodec` resumes 6 hours).
//  A follow-up goes through `CompanionManager.askTypedQuestion`, the same turn
//  as the text composer. Screen capture excludes Wisp's own windows, so the
//  turn sees the user's work behind this window, not the window itself.
//

import AppKit
import SwiftUI

struct ConversationWindowView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var taskRegistry: AgentTaskRegistry
    @ObservedObject private var bindingStore = ShortcutBindingStore.shared

    @State private var followUpText = ""
    @FocusState private var isFollowUpFieldFocused: Bool
    @State private var recentlyCopiedRecordID: UUID?

    /// How far back the thread reaches, matching how long a conversation is
    /// resumed into the model's context.
    private let threadLookbackSeconds: TimeInterval = 6 * 60 * 60
    private let maximumThreadExchanges = 30
    private let threadBottomAnchorID = "thread-bottom"

    var body: some View {
        HStack(spacing: 0) {
            threadColumn
            Divider().background(DS.Colors.borderSubtle)
            tasksSidebar
                .frame(width: 240)
        }
        .background(DS.Colors.background)
        .onAppear {
            isFollowUpFieldFocused = true
        }
    }

    // MARK: - Thread

    /// The recent exchanges, oldest first. Dictation isn't a question, so it's
    /// left out; routine runs stay in, labelled by name.
    private var threadRecords: [AgentTaskRecord] {
        let oldestShownDate = Date().addingTimeInterval(-threadLookbackSeconds)
        let recentExchanges = taskRegistry.records.filter { record in
            record.kind == .interactive
                && !record.title.hasPrefix(AgentTaskRecord.dictationTitlePrefix)
                && record.startedAt >= oldestShownDate
        }
        return Array(recentExchanges.prefix(maximumThreadExchanges).reversed())
    }

    /// Changes whenever the newest exchange grows or settles, so the thread
    /// scrolls to follow it.
    private var threadScrollSignature: String {
        guard let newestRecord = threadRecords.last else { return "" }
        return "\(newestRecord.id)|\(newestRecord.status.displayName)|\(newestRecord.finalText?.count ?? 0)|\(companionManager.browserActivityText)"
    }

    private var threadColumn: some View {
        VStack(spacing: 0) {
            threadHeader
            if threadRecords.isEmpty {
                emptyThread
            } else {
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(threadRecords) { record in
                                exchangeView(record)
                            }
                            Color.clear
                                .frame(height: 1)
                                .id(threadBottomAnchorID)
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 16)
                    }
                    .onAppear {
                        scrollProxy.scrollTo(threadBottomAnchorID, anchor: .bottom)
                    }
                    .onChange(of: threadScrollSignature) { _, _ in
                        withAnimation(.easeOut(duration: 0.2)) {
                            scrollProxy.scrollTo(threadBottomAnchorID, anchor: .bottom)
                        }
                    }
                }
            }
            Divider().background(DS.Colors.borderSubtle)
            followUpComposer
        }
    }

    private var threadHeader: some View {
        HStack(spacing: 9) {
            WispMark(state: companionManager.islandState.markState, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Conversation")
                    .font(WispFont.headline)
                    .foregroundStyle(DS.Colors.textPrimary)
                Text(companionManager.islandState.isActive
                     ? companionManager.islandState.label
                     : "Follow-ups remember the last few exchanges")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            Spacer()
        }
        // The window's content runs under its transparent title bar; clear the
        // traffic lights.
        .padding(.top, 34)
        .padding(.horizontal, 22)
        .padding(.bottom, 10)
    }

    private var emptyThread: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 24))
                .foregroundStyle(DS.Colors.textTertiary)
            Text("Nothing in the last few hours")
                .font(WispFont.bodyMedium)
                .foregroundStyle(DS.Colors.textSecondary)
            Text("Ask below, or hold your talk shortcut anywhere.")
                .font(WispFont.callout)
                .foregroundStyle(DS.Colors.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func exchangeView(_ record: AgentTaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            questionBubble(record)
            answerBubble(record)
        }
    }

    private func questionBubble(_ record: AgentTaskRecord) -> some View {
        HStack {
            Spacer(minLength: 80)
            HStack(spacing: 6) {
                // A routine run's title is a label, not something the user typed.
                if !record.isUsersOwnQuestion {
                    Image(systemName: "bolt")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.Colors.accentText)
                }
                Text(record.title)
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(DS.Colors.accentSubtle)
            )
        }
    }

    @ViewBuilder
    private func answerBubble(_ record: AgentTaskRecord) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                answerBody(record)
                answerFooter(record)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(DS.Colors.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
            )
            Spacer(minLength: 80)
        }
    }

    @ViewBuilder
    private func answerBody(_ record: AgentTaskRecord) -> some View {
        let answerText = (record.finalText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch record.status {
        case .running, .waitingForApproval:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(liveStatusText(for: record))
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .lineLimit(2)
            }
        case .failed(let failureReason):
            Text(answerText.isEmpty ? failureReason : answerText)
                .font(.system(size: 13))
                .foregroundStyle(DS.Colors.destructiveText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .cancelled, .interrupted:
            Text(record.status == .interrupted ? "Interrupted — Wisp quit while this was running." : "Stopped.")
                .font(.system(size: 12))
                .foregroundStyle(DS.Colors.textTertiary)
        case .succeeded:
            Text(answerText.isEmpty ? "Done." : answerText)
                .font(.system(size: 13))
                .foregroundStyle(DS.Colors.textPrimary)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The running turn's live step when it's a browser task, else a plain status.
    private func liveStatusText(for record: AgentTaskRecord) -> String {
        if record.status == .waitingForApproval {
            return "Waiting for your ok under the notch"
        }
        if record.id == threadRecords.last?.id && !companionManager.browserActivityText.isEmpty {
            return companionManager.browserActivityText
        }
        return record.steps.last?.summary ?? "Thinking…"
    }

    @ViewBuilder
    private func answerFooter(_ record: AgentTaskRecord) -> some View {
        let answerText = (record.finalText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        HStack(spacing: 10) {
            Text(record.startedAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10))
                .foregroundStyle(DS.Colors.textTertiary)
            if !record.status.isTerminal && record.status != .waitingForApproval {
                Button {
                    companionManager.stopCurrentTask()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            if record.status == .succeeded && !answerText.isEmpty {
                Button {
                    copyToClipboard(answerText, fromRecordID: record.id)
                } label: {
                    Label(recentlyCopiedRecordID == record.id ? "Copied" : "Copy",
                          systemImage: recentlyCopiedRecordID == record.id ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .nativeTooltip("Copy this answer")
            }
        }
    }

    private func copyToClipboard(_ answerText: String, fromRecordID recordID: UUID) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answerText, forType: .string)
        recentlyCopiedRecordID = recordID
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            if recentlyCopiedRecordID == recordID {
                recentlyCopiedRecordID = nil
            }
        }
    }

    // MARK: - Follow-up composer

    private var followUpComposer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask a follow-up…", text: $followUpText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...5)
                    .focused($isFollowUpFieldFocused)
                    .onSubmit(sendFollowUp)
                Button(action: sendFollowUp) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(isFollowUpEmpty ? DS.Colors.textTertiary : DS.Colors.accentText)
                }
                .buttonStyle(.plain)
                .disabled(isFollowUpEmpty)
                .pointerCursor(isEnabled: !isFollowUpEmpty)
                .nativeTooltip("Send (Return)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: WispRadius.panel, style: .continuous)
                    .fill(DS.Colors.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: WispRadius.panel, style: .continuous)
                    .strokeBorder(isFollowUpFieldFocused ? DS.Colors.accent.opacity(0.5) : DS.Colors.borderSubtle,
                                  lineWidth: 1)
            )

            Text("Return to send · Wisp looks at your screen behind this window · or hold \(bindingStore.primaryHoldChord.displayText) to talk")
                .font(.system(size: 10.5))
                .foregroundStyle(DS.Colors.textTertiary)
                .padding(.horizontal, 4)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var isFollowUpEmpty: Bool {
        followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendFollowUp() {
        let question = followUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        followUpText = ""
        companionManager.askTypedQuestion(question)
    }

    // MARK: - Tasks sidebar

    /// Finished tasks worth a glance: background work, or turns that used tools.
    private var recentlyFinishedTasks: [AgentTaskRecord] {
        Array(
            taskRegistry.records
                .filter { record in
                    guard record.status.isTerminal else { return false }
                    let usedTools = record.steps.contains { step in
                        if case .tool = step.kind { return true }
                        return false
                    }
                    return record.kind == .background || usedTools
                }
                .prefix(6)
        )
    }

    private var tasksSidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                sidebarLabel("WORKING ON")
                if taskRegistry.runningRecords.isEmpty {
                    Text("Nothing running")
                        .font(WispFont.callout)
                        .foregroundStyle(DS.Colors.textTertiary)
                } else {
                    ForEach(taskRegistry.runningRecords) { runningRecord in
                        runningTaskRow(runningRecord)
                    }
                }
            }

            if !recentlyFinishedTasks.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    sidebarLabel("RECENTLY DONE")
                    ForEach(recentlyFinishedTasks) { finishedRecord in
                        finishedTaskRow(finishedRecord)
                    }
                }
            }

            Spacer()
        }
        .padding(.top, 40)
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.Colors.surface1.opacity(0.5))
    }

    private func sidebarLabel(_ text: String) -> some View {
        Text(text)
            .font(WispFont.overline)
            .tracking(0.6)
            .foregroundStyle(DS.Colors.textTertiary)
    }

    private func runningTaskRow(_ runningRecord: AgentTaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 7) {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.top, 1)
                Text(runningRecord.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(2)
            }
            Text(runningTaskStatusLine(runningRecord))
                .font(.system(size: 10.5))
                .foregroundStyle(DS.Colors.textSecondary)
                .lineLimit(2)
            Button {
                if runningRecord.kind == .interactive {
                    companionManager.stopCurrentTask()
                } else {
                    taskRegistry.cancelTask(runningRecord.id)
                }
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .buttonStyle(WispGlassButtonStyle())
            .pointerCursor()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface2)
        )
    }

    private func runningTaskStatusLine(_ runningRecord: AgentTaskRecord) -> String {
        if runningRecord.status == .waitingForApproval {
            return "Waiting for your ok"
        }
        if runningRecord.kind == .interactive && !companionManager.browserActivityText.isEmpty {
            return "Step \(companionManager.browserTaskStepCount) · \(companionManager.browserActivityText)"
        }
        let elapsedMinutes = Int(runningRecord.elapsedSeconds / 60)
        let elapsedText = elapsedMinutes < 1 ? "Just started" : "\(elapsedMinutes) min"
        if let latestStepSummary = runningRecord.steps.last?.summary {
            return "\(elapsedText) · \(latestStepSummary)"
        }
        return runningRecord.kind == .background ? "\(elapsedText) · background" : elapsedText
    }

    private func finishedTaskRow(_ finishedRecord: AgentTaskRecord) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: finishedRecord.status == .succeeded ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(finishedRecord.status == .succeeded ? DS.Colors.success : DS.Colors.textTertiary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(finishedRecord.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(2)
                Text((finishedRecord.finishedAt ?? finishedRecord.startedAt).formatted(.relative(presentation: .named)))
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Colors.textTertiary)
            }
        }
    }
}
