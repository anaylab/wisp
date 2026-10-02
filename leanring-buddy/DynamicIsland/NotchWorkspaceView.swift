//
//  NotchWorkspaceView.swift
//  leanring-buddy
//
//  The notch's large surface, modeled on HeyClicky: a quick chat right in the
//  notch. It opens from the quick panel's Chat button and hangs from the notch
//  like the rest of the island: a sidebar of buddies and conversations
//  (exchanges grouped by `NotchConversationSessionGrouper`, searchable), the
//  selected thread, and a bottom bar with the talk pill ("Hold ⌃⌥ to talk",
//  live while listening) and a Type field that asks through the normal typed
//  turn.
//
//  Settings used to live here too, duplicating the dashboard's. They now have
//  one home, the Wisp window; the sidebar's Settings button opens it there.
//
//  The window, key focus and hover-out are the controller's job
//  (`NotchWindowController.setWorkspacePage`); this view only renders a page
//  and asks for page changes through `viewModel.requestWorkspacePage`.
//

import AppKit
import SwiftUI

/// What the notch's large surface is showing. Only the chat today; kept as a
/// type so the controller's open/close plumbing stays page-shaped.
enum NotchWorkspacePage: Equatable {
    case chat
}

struct NotchWorkspaceView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var taskRegistry = AgentTaskRegistry.shared
    @ObservedObject private var bindingStore = ShortcutBindingStore.shared
    @ObservedObject private var fileAttachmentStore = NotchFileAttachmentStore.shared
    @ObservedObject private var companionPreference = WispCompanionPreference.shared
    @ObservedObject private var buddyStore = BuddyStore.shared

    let page: NotchWorkspacePage

    /// The conversation shown, or nil for the newest (live) one.
    @State private var selectedSessionID: UUID?
    @State private var sessionSearchText = ""
    @State private var typedQuestionText = ""
    @FocusState private var isTypeFieldFocused: Bool
    @State private var hoveredSessionID: UUID?
    /// The buddy whose thread is shown instead of a conversation, if any.
    @State private var selectedBuddyID: UUID?
    /// Whether the main area is showing the new-buddy form.
    @State private var isCreatingBuddy = false

    private let sidebarWidth: CGFloat = 214
    private let threadBottomAnchorID = "notch-thread-bottom"

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: sidebarWidth)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color.white.opacity(0.035))
            Rectangle()
                .fill(WispColor.Island.separator)
                .frame(width: 1)
            mainArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // A near-opaque backdrop over the glass: a chat full of text needs a calm
        // surface, not the desktop refracting through it.
        .background(Color.black.opacity(0.78))
    }

    /// How far below the top edge content under the notch must start.
    private var notchTopInset: CGFloat {
        viewModel.hasNotch ? viewModel.collapsedSize.height : 0
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        chatSidebar
    }

    private var chatSidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The sidebar sits left of the notch, so its first row can use the
            // notch band itself, as HeyClicky's logo does.
            HStack(spacing: 7) {
                if companionPreference.isCompanionEnabled {
                    NotchCompanion(companionManager: companionManager, size: 22, isPokeable: true, isAnimating: true)
                } else {
                    WispMark(state: companionManager.islandState.markState, size: 16)
                }
                Text("Wisp")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(WispColor.Island.textPrimary)
                Spacer(minLength: 0)
            }
            .frame(height: max(notchTopInset, 28))

            sessionSearchField

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    buddiesSidebarSection

                    sidebarSectionHeader("CONVERSATIONS")
                    if filteredSessions.isEmpty {
                        Text(sessionSearchText.isEmpty ? "No conversations yet" : "Nothing matches")
                            .font(.system(size: 11))
                            .foregroundColor(WispColor.Island.textTertiary)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 6)
                    }
                    ForEach(filteredSessions) { session in
                        sessionRow(session)
                    }
                }
            }
            .scrollIndicators(.never)

            sidebarFooter
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private var sessionSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(WispColor.Island.textTertiary)
            TextField("Search", text: $sessionSearchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(WispColor.Island.textPrimary)
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(WispColor.Island.controlFill)
        )
    }

    private func sidebarSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.6)
            .foregroundColor(WispColor.Island.textTertiary)
            .padding(.horizontal, 6)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }

    /// BUDDIES: each buddy with its face and what it's up to, and a + to
    /// summon a new one. Search narrows it by name or job.
    private var buddiesSidebarSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                sidebarSectionHeader("BUDDIES")
                Spacer(minLength: 0)
                Button {
                    selectedBuddyID = nil
                    isCreatingBuddy = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(WispColor.Island.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(isCreatingBuddy ? 0.14 : 0.07)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .nativeTooltip("Summon a buddy — give it one job to keep doing")
                .padding(.top, 6)
            }
            if buddyStore.buddies.isEmpty {
                Text("Give a buddy a job it can repeat — a morning digest, a weekly check.")
                    .font(.system(size: 10.5))
                    .foregroundColor(WispColor.Island.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
            }
            ForEach(filteredBuddies) { buddy in
                buddyRow(buddy)
            }
        }
    }

    private var filteredBuddies: [WispBuddy] {
        let trimmedSearchText = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let orderedBuddies = buddyStore.orderedBuddies(in: taskRegistry)
        guard !trimmedSearchText.isEmpty else { return orderedBuddies }
        return orderedBuddies.filter { buddy in
            buddy.name.localizedCaseInsensitiveContains(trimmedSearchText)
                || buddy.instruction.localizedCaseInsensitiveContains(trimmedSearchText)
        }
    }

    private func buddyRow(_ buddy: WispBuddy) -> some View {
        let isSelected = selectedBuddyID == buddy.id && !isCreatingBuddy
        let isHovered = hoveredSessionID == buddy.id
        let isRunning = buddyStore.isRunning(buddy, in: taskRegistry)
        let isUnread = buddyStore.isUnread(buddy, in: taskRegistry) && !isSelected
        return Button {
            isCreatingBuddy = false
            selectedBuddyID = buddy.id
        } label: {
            HStack(spacing: 8) {
                BuddyAvatar(colorIndex: buddy.colorIndex, size: 28, isWorking: isRunning)
                VStack(alignment: .leading, spacing: 1) {
                    Text(buddy.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(WispColor.Island.textPrimary)
                        .lineLimit(1)
                    Text(BuddyStatusText.line(
                        for: buddy,
                        isRunning: isRunning,
                        latestRunRecord: buddyStore.latestRunRecord(of: buddy, in: taskRegistry)
                    ))
                    .font(.system(size: 10.5))
                    .foregroundColor(WispColor.Island.textSecondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isUnread {
                    Circle()
                        .fill(WispColor.Brand.lavender)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel("New")
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected
                          ? BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex).opacity(0.28)
                          : Color.white.opacity(isHovered ? 0.06 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isSelected ? BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex).opacity(0.6) : .clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering in
            hoveredSessionID = isHovering ? buddy.id : (hoveredSessionID == buddy.id ? nil : hoveredSessionID)
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private func sessionRow(_ session: NotchConversationSession) -> some View {
        let isSelected = session.id == displayedSession?.id && selectedBuddyID == nil && !isCreatingBuddy
        let isHovered = hoveredSessionID == session.id
        return Button {
            selectedBuddyID = nil
            isCreatingBuddy = false
            // Picking the newest one returns to following the live conversation.
            selectedSessionID = session.id == allSessions.first?.id ? nil : session.id
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(WispColor.Island.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(sessionTimeLabel(session.lastActivityAt))
                        .font(.system(size: 10))
                        .foregroundColor(WispColor.Island.textTertiary)
                        .lineLimit(1)
                }
                Text(session.latestAnswerPreview)
                    .font(.system(size: 11))
                    .foregroundColor(WispColor.Island.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected
                          ? WispColor.Island.controlFillHovered
                          : (isHovered ? WispColor.Island.controlFill : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering in
            hoveredSessionID = isHovering ? session.id : (hoveredSessionID == session.id ? nil : hoveredSessionID)
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    /// "10:39 PM" today, "Wed" this week, "Sep 12" before that.
    private func sessionTimeLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if let daysAgo = calendar.dateComponents([.day], from: date, to: Date()).day, daysAgo < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private var sidebarFooter: some View {
        HStack(spacing: 6) {
            sidebarFooterButton(
                systemImageName: "gearshape",
                title: "Settings",
                tooltip: "Open Wisp's settings"
            ) {
                WispWindowNavigator.open(.general)
            }
            Spacer(minLength: 0)
            sidebarFooterButton(
                systemImageName: "macwindow",
                title: nil,
                tooltip: "Open the Wisp window (today, buddies, routines, history)"
            ) {
                WispWindowNavigator.open(.home)
            }
        }
    }

    private func sidebarFooterButton(
        systemImageName: String,
        title: String?,
        tooltip: String,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            HStack(spacing: 5) {
                Image(systemName: systemImageName)
                    .font(.system(size: 11, weight: .medium))
                if let title {
                    Text(title)
                        .font(.system(size: 11.5, weight: .medium))
                }
            }
            .foregroundColor(WispColor.Island.textSecondary)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(Capsule(style: .continuous).fill(WispColor.Island.controlFill))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableScaleButtonStyle())
        .pointerCursor()
        .nativeTooltip(tooltip)
    }

    // MARK: - Main area

    @ViewBuilder
    private var mainArea: some View {
        if isCreatingBuddy {
            ZStack(alignment: .topTrailing) {
                NewBuddyForm(
                    topInset: notchTopInset,
                    onCreated: { newBuddyID in
                        isCreatingBuddy = false
                        selectedBuddyID = newBuddyID
                    },
                    onCancel: { isCreatingBuddy = false }
                )
                workspaceHeaderControls
                    .padding(.top, 8)
                    .padding(.trailing, 12)
            }
        } else if let selectedBuddyID, buddyStore.buddy(withID: selectedBuddyID) != nil {
            ZStack(alignment: .topTrailing) {
                BuddyDetailView(
                    buddyID: selectedBuddyID,
                    topInset: notchTopInset,
                    onDuplicated: { duplicatedBuddyID in self.selectedBuddyID = duplicatedBuddyID }
                )
                workspaceHeaderControls
                    .padding(.top, 8)
                    .padding(.trailing, 12)
            }
        } else {
            chatArea
        }
    }

    /// The top-right controls, in the notch band to the right of the cutout.
    private var workspaceHeaderControls: some View {
        HStack(spacing: 4) {
            if selectedBuddyID == nil && !isCreatingBuddy {
                headerIconButton(
                    systemImageName: "arrow.up.left.and.arrow.down.right",
                    tooltip: "Open the conversation in the Wisp window"
                ) {
                    viewModel.requestWorkspacePage?(nil)
                    companionManager.openConversationWindow()
                }
            }
            headerIconButton(systemImageName: "xmark", tooltip: "Close (Esc)") {
                viewModel.requestWorkspacePage?(nil)
            }
        }
    }

    private func headerIconButton(
        systemImageName: String,
        tooltip: String,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Image(systemName: systemImageName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(WispColor.Island.textSecondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(WispColor.Island.controlFill))
                .contentShape(Circle())
        }
        .buttonStyle(PressableScaleButtonStyle())
        .pointerCursor()
        .nativeTooltip(tooltip)
    }

    // MARK: Chat

    private var allSessions: [NotchConversationSession] {
        NotchConversationSessionGrouper.sessions(from: taskRegistry.records)
    }

    private var filteredSessions: [NotchConversationSession] {
        NotchConversationSessionGrouper.sessions(allSessions, matching: sessionSearchText)
    }

    /// The selected conversation, falling back to the newest when nothing (or
    /// a session that no longer exists) is selected.
    private var displayedSession: NotchConversationSession? {
        if let selectedSessionID, let selectedSession = allSessions.first(where: { $0.id == selectedSessionID }) {
            return selectedSession
        }
        return allSessions.first
    }

    private var isShowingLiveSession: Bool {
        displayedSession?.id == allSessions.first?.id
    }

    /// Changes whenever the shown thread grows or its newest answer settles, so
    /// the thread scrolls to follow it.
    private var threadScrollSignature: String {
        guard let newestExchange = displayedSession?.exchanges.last else { return "" }
        return "\(newestExchange.id)|\(newestExchange.status.displayName)|\(newestExchange.finalText?.count ?? 0)"
    }

    private var chatArea: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                chatHeader
                    .padding(.top, notchTopInset + 8)
                    .frame(maxWidth: .infinity)
                workspaceHeaderControls
                    .padding(.top, 8)
                    .padding(.trailing, 12)
            }

            if let displayedSession {
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(displayedSession.exchanges) { exchange in
                                exchangeView(exchange)
                            }
                            Color.clear
                                .frame(height: 1)
                                .id(threadBottomAnchorID)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
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
            } else {
                emptyThread
            }

            composerBar
        }
    }

    private var chatHeader: some View {
        VStack(spacing: 3) {
            Text(isShowingLiveSession ? "Conversation" : "Earlier conversation")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(WispColor.Island.textPrimary)
            Text(chatHeaderSubtitle)
                .font(.system(size: 10.5))
                .foregroundColor(WispColor.Island.textTertiary)
                .lineLimit(1)
        }
        .padding(.bottom, 4)
    }

    private var chatHeaderSubtitle: String {
        if companionManager.islandState.isActive {
            return companionManager.islandState.label
        }
        if !isShowingLiveSession, let displayedSession {
            return displayedSession.startedAt.formatted(date: .abbreviated, time: .shortened)
                + " · asking below continues your latest conversation"
        }
        return "Follow-ups remember the last few exchanges"
    }

    private var emptyThread: some View {
        VStack(spacing: 8) {
            Spacer()
            if companionPreference.isCompanionEnabled {
                NotchCompanion(companionManager: companionManager, size: 46, isPokeable: true, isAnimating: true)
            } else {
                WispMark(state: .idle, size: 34)
            }
            Text("Ask me anything")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(WispColor.Island.textPrimary)
            Text("Hold \(bindingStore.primaryHoldChord.displayText) to talk, or type below. I can see the screen behind this panel.")
                .font(.system(size: 11.5))
                .foregroundColor(WispColor.Island.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func exchangeView(_ exchange: AgentTaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer(minLength: 60)
                HStack(spacing: 6) {
                    // A routine or skill run's title is a label, not something typed.
                    if !exchange.isUsersOwnQuestion {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(WispColor.Island.textSecondary)
                    }
                    Text(exchange.title)
                        .font(.system(size: 12.5))
                        .foregroundColor(WispColor.Island.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(WispColor.Island.controlFillHovered)
                )
            }

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    answerBody(exchange)
                    Text(exchange.startedAt.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 9.5))
                        .foregroundColor(WispColor.Island.textTertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(WispColor.Island.controlFill)
                )
                Spacer(minLength: 60)
            }
        }
    }

    @ViewBuilder
    private func answerBody(_ exchange: AgentTaskRecord) -> some View {
        let answerText = AnswerDisplayText.cleaned(exchange.finalText ?? "")
        switch exchange.status {
        case .running, .waitingForApproval:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(exchange.status == .waitingForApproval
                     ? "Waiting for your ok"
                     : (companionManager.browserActivityText.isEmpty
                        ? (exchange.steps.last?.summary ?? "Thinking…")
                        : companionManager.browserActivityText))
                    .font(.system(size: 12))
                    .foregroundColor(WispColor.Island.textSecondary)
                    .lineLimit(2)
            }
        case .failed(let failureReason):
            Text(answerText.isEmpty ? failureReason : answerText)
                .font(.system(size: 12.5))
                .foregroundColor(DS.Colors.destructiveText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .cancelled, .interrupted:
            Text(exchange.status == .interrupted ? "Interrupted — Wisp quit while this was running." : "Stopped.")
                .font(.system(size: 12))
                .foregroundColor(WispColor.Island.textTertiary)
        case .succeeded:
            Text(answerText.isEmpty ? "Done." : answerText)
                .font(.system(size: 12.5))
                .foregroundColor(WispColor.Island.textPrimary)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Composer: talk pill + Type field

    private var composerBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A file dropped on the notch with "Ask about it" rides along with
            // every question until it's removed.
            if let attachedFile = fileAttachmentStore.attachedFile {
                NotchAttachedFileChip(attachedFile: attachedFile) {
                    fileAttachmentStore.detachFile()
                }
            }
            HStack(spacing: 10) {
                talkPill
                typeField
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private var isListening: Bool {
        companionManager.voiceState == .listening
    }

    private var talkPillText: String {
        switch companionManager.voiceState {
        case .listening:
            let heardSoFar = companionManager.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            return heardSoFar.isEmpty ? "Listening… release to send" : heardSoFar
        case .processing:
            return "Thinking…"
        case .responding:
            return "Responding…"
        case .idle:
            return companionManager.isListeningPaused
                ? "Listening paused — type instead"
                : "Hold \(bindingStore.primaryHoldChord.displayText) to talk"
        }
    }

    /// Not a button — talking is the hold chord, anywhere. The pill says so,
    /// and comes alive (glow, live words) while Wisp is listening.
    private var talkPill: some View {
        HStack(spacing: 8) {
            Image(systemName: isListening ? "waveform" : "mic.fill")
                .font(.system(size: 12, weight: .semibold))
                .symbolEffect(.variableColor.iterative, isActive: isListening)
            Text(talkPillText)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(isListening ? .head : .tail)
        }
        .foregroundColor(WispColor.Island.textPrimary)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: 38)
        .background(
            Capsule(style: .continuous)
                .fill(WispGradient.signature)
                .opacity(isListening ? 0.55 : 0.28)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(isListening ? 0.55 : 0.22), lineWidth: 1)
        )
        .shadow(color: WispColor.Brand.lavender.opacity(isListening ? 0.55 : 0.18), radius: isListening ? 14 : 6)
        .animation(WispMotion.smooth, value: isListening)
    }

    private var typeField: some View {
        HStack(spacing: 7) {
            Image(systemName: "keyboard")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(WispColor.Island.textTertiary)
            TextField("Type…", text: $typedQuestionText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundColor(WispColor.Island.textPrimary)
                .focused($isTypeFieldFocused)
                .onSubmit(sendTypedQuestion)
            if !typedQuestionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: sendTypedQuestion) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 17))
                        .foregroundColor(WispColor.Island.textSecondary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .nativeTooltip("Send (Return)")
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 230, height: 38)
        .background(
            Capsule(style: .continuous)
                .fill(WispColor.Island.controlFill)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(isTypeFieldFocused ? WispColor.Island.textTertiary : WispColor.Island.separator, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.15), value: isTypeFieldFocused)
    }

    private func sendTypedQuestion() {
        let question = typedQuestionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        typedQuestionText = ""
        // The answer continues the live conversation, so follow it there.
        selectedSessionID = nil
        selectedBuddyID = nil
        companionManager.askTypedQuestion(question)
    }
}
