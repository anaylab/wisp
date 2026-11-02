//
//  BuddyChatView.swift
//  leanring-buddy
//
//  One buddy's own chat. Quiet by design: a plain header (character, name, one
//  line of status), the thread, and a composer that takes files by paperclip or
//  drag and drop. The user's bubble carries the buddy's colour; everything else
//  is neutral. Under each answer, on hover: copy it, run it again, or hand it to
//  another buddy (which shows up in that buddy's thread as a handoff).
//

import AppKit
import SwiftUI

struct BuddyChatView: View {
    let buddyID: UUID
    @Binding var isInspectorOpen: Bool
    var onRequestClearConversation: () -> Void
    var onRequestDeletion: () -> Void
    /// Opens a buddy in the page (after a duplicate or a handoff).
    var onOpenBuddy: (UUID) -> Void

    @ObservedObject private var buddyStore = BuddyStore.shared
    @ObservedObject private var advancedFeatures = WispAdvancedFeaturesPreference.shared
    @ObservedObject private var taskRegistry = AgentTaskRegistry.shared
    @ObservedObject private var threadStore = BuddyThreadStore.shared

    @State private var draftMessageText = ""
    @State private var pendingFileURLs: [URL] = []
    @State private var isDropTargeted = false
    @State private var isSending = false
    @State private var sendFailureMessage: String?
    @State private var expandedRunIDs: Set<UUID> = []
    @State private var hoveredTaskID: UUID?
    @State private var bounceCount = 0
    /// The open thread; nil is the main thread. Side threads are named by their first message.
    @State private var activeThreadID: UUID?
    /// New threads that have no message yet (not kept past a restart, as in OpenBot).
    @State private var draftThreadIDs: [UUID] = []
    @State private var threadPendingDeletion: UUID?
    /// The run whose Trace window is open.
    @State private var tracedRunID: UUID?
    /// False once the user scrolls up from the newest entry; shows the jump-to-latest pill.
    @State private var isScrolledToBottom = true
    /// Whose composer text `draftMessageText` is, so a thread or buddy switch can't write
    /// one conversation's draft into another's.
    @State private var draftOwner: (buddyID: UUID, threadID: UUID?)?
    private let draftStore = BuddyComposerDraftStore()
    @FocusState private var isComposerFocused: Bool

    private let bottomAnchorID = "buddy-chat-bottom"

    var body: some View {
        if let buddy = buddyStore.buddy(withID: buddyID) {
            content(for: buddy)
        } else {
            Color.clear
        }
    }

    private func content(for buddy: WispBuddy) -> some View {
        // Each thread is its own lane: the open one's run decides Stop, the
        // typing dots and the composer, whatever the buddy's other threads do.
        let isRunning = buddyStore.isRunning(buddy, inConversation: activeThreadID, in: taskRegistry)
        let mood = buddyStore.mood(of: buddy, in: taskRegistry)
        let latestRunRecord = buddyStore.latestRunRecord(of: buddy, in: taskRegistry)
        let allExchanges = threadStore.exchanges(ofBuddyWithID: buddy.id)
        // A group chat's runs are filed under the group's id; they are not tabs of the buddy's own.
        let ownExchanges = allExchanges.filter { exchange in
            // A group chat's or a workflow's runs are filed under its own id, not a tab of the buddy's.
            exchange.threadID.map { !BuddyGroupStore.shared.isGroupID($0) && WorkflowStore.shared.workflow(withID: $0) == nil } ?? true
        }
        let threadSummaries = BuddyThreadPolicy.threadSummaries(from: ownExchanges, draftThreadIDs: draftThreadIDs)
        // Runs from before buddies had threads have no exchange; they belong to the main thread.
        let threadTaskIDs = activeThreadID == nil
            ? BuddyListPolicy.threadTaskIDs(
                exchangeTaskIDs: BuddyThreadPolicy.exchanges(allExchanges, inThread: nil).map(\.taskID),
                runTaskIDs: buddy.runTaskIDs.filter { runID in !allExchanges.contains { $0.taskID == runID && $0.threadID != nil } }
            )
            : BuddyThreadPolicy.exchanges(allExchanges, inThread: activeThreadID).map(\.taskID)
        let entryStartedAt: [UUID: Date] = Dictionary(
            threadTaskIDs.compactMap { taskID in
                let startedAt = allExchanges.first { $0.taskID == taskID }?.startedAt
                    ?? taskRegistry.records.first { $0.id == taskID }?.startedAt
                return startedAt.map { (taskID, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        return ZStack {
            BuddyAmbientBackground(colorIndex: buddy.colorIndex)

            VStack(spacing: 0) {
                header(for: buddy, mood: mood, isRunning: isRunning, latestRunRecord: latestRunRecord, summaries: threadSummaries)
                Rectangle().fill(WispColor.cardSeparator.opacity(0.4)).frame(height: 0.5)

                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if activeThreadID == nil { missionRow(for: buddy) }
                            if threadTaskIDs.isEmpty { quickStarts(for: buddy) }
                            ForEach(Array(threadTaskIDs.enumerated()), id: \.element) { index, taskID in
                                let startedAt = entryStartedAt[taskID]
                                let previousStartedAt = index > 0 ? entryStartedAt[threadTaskIDs[index - 1]] : nil
                                let startsNewDay = startedAt.map {
                                    BuddyChatLayoutPolicy.startsNewDay(previous: previousStartedAt, current: $0)
                                } ?? false
                                if let startedAt, startsNewDay {
                                    daySeparator(BuddyChatLayoutPolicy.dayLabel(for: startedAt, now: Date()))
                                }
                                threadEntry(
                                    taskID: taskID,
                                    buddy: buddy,
                                    continuesRun: BuddyChatLayoutPolicy.continuesAnswerRun(
                                        previous: previousStartedAt,
                                        current: startedAt,
                                        currentHasUserMessage: allExchanges.first { $0.taskID == taskID }?.origin == .message
                                            || allExchanges.first { $0.taskID == taskID }?.origin == .delegated,
                                        startsNewDay: startsNewDay
                                    )
                                )
                            }
                            Color.clear.frame(height: 1).id(bottomAnchorID)
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, 20)
                        .padding(.bottom, 16)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                    }
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        BuddyChatLayoutPolicy.isAtBottom(
                            contentOffsetY: geometry.contentOffset.y,
                            containerHeight: geometry.containerSize.height,
                            contentHeight: geometry.contentSize.height
                        )
                    } action: { _, isAtBottom in
                        isScrolledToBottom = isAtBottom
                    }
                    .overlay(alignment: .bottom) {
                        if !isScrolledToBottom {
                            Button {
                                withAnimation(WispMotion.smooth) { scrollProxy.scrollTo(bottomAnchorID, anchor: .bottom) }
                            } label: {
                                Label("Latest", systemImage: "arrow.down")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(WispColor.textPrimary)
                                    .padding(.horizontal, 12)
                                    .frame(height: 28)
                                    .wispBevel(Capsule(style: .continuous), fill: WispColor.surface3)
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .pointerCursor()
                            .padding(.bottom, 10)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(WispMotion.quick, value: isScrolledToBottom)
                    .onAppear { scrollProxy.scrollTo(bottomAnchorID, anchor: .bottom) }
                    .onChange(of: threadTaskIDs.count) { _, _ in
                        withAnimation(WispMotion.smooth) { scrollProxy.scrollTo(bottomAnchorID, anchor: .bottom) }
                    }
                    .onChange(of: latestRunRecord.map { "\($0.id)|\($0.status.displayName)|\($0.steps.count)" } ?? "") { _, _ in
                        withAnimation(WispMotion.smooth) { scrollProxy.scrollTo(bottomAnchorID, anchor: .bottom) }
                        buddyStore.markRead(buddyWithID: buddy.id, in: taskRegistry)
                    }
                }

                composer(for: buddy, isRunning: isRunning)
            }

            if isDropTargeted { BuddyDropOverlay(colorIndex: buddy.colorIndex) }
        }
        .sheet(isPresented: Binding(get: { tracedRunID != nil }, set: { if !$0 { tracedRunID = nil } })) {
            if let tracedRunID, let tracedRecord = taskRegistry.records.first(where: { $0.id == tracedRunID }) {
                RunTraceView(runRecord: tracedRecord, buddy: buddy, onClose: { self.tracedRunID = nil })
            }
        }
        .confirmationDialog(
            "Delete this thread?",
            isPresented: Binding(
                get: { threadPendingDeletion != nil },
                set: { if !$0 { threadPendingDeletion = nil } }
            )
        ) {
            Button("Delete Thread", role: .destructive) {
                if let threadID = threadPendingDeletion {
                    threadStore.deleteSideThread(threadID, ofBuddyWithID: buddy.id)
                    BuddySessionStore.shared.forgetSession(for: BuddySessionKey(buddyID: buddy.id, conversationID: threadID))
                    draftThreadIDs.removeAll { $0 == threadID }
                    if activeThreadID == threadID { activeThreadID = nil }
                }
            }
        } message: {
            Text("Its messages are removed. The runs stay in History.")
        }
        .dropDestination(for: URL.self) { droppedURLs, _ in
            addPendingFiles(droppedURLs)
            return true
        } isTargeted: { isTargeted in
            withAnimation(WispMotion.quick) { isDropTargeted = isTargeted }
        }
        .onAppear {
            buddyStore.markRead(buddyWithID: buddy.id, in: taskRegistry)
            loadDraft(buddyID: buddy.id)
        }
        .onChange(of: draftMessageText) { _, newText in
            guard let draftOwner else { return }
            draftStore.save(newText, buddyID: draftOwner.buddyID, threadID: draftOwner.threadID)
        }
        .onChange(of: activeThreadID) { _, _ in loadDraft(buddyID: buddy.id) }
        .onChange(of: buddyID) { _, newBuddyID in
            buddyStore.markRead(buddyWithID: newBuddyID, in: taskRegistry)
            activeThreadID = nil
            draftThreadIDs = []
            loadDraft(buddyID: newBuddyID)
            pendingFileURLs = []
            expandedRunIDs = []
            sendFailureMessage = nil
            bounceCount += 1
        }
    }

    /// Puts the open conversation's unsent text in the composer. The owner changes
    /// first, so the text change this causes is saved under the right conversation.
    private func loadDraft(buddyID: UUID) {
        draftOwner = (buddyID, activeThreadID)
        draftMessageText = draftStore.draft(buddyID: buddyID, threadID: activeThreadID)
    }

    private func daySeparator(_ label: String) -> some View {
        HStack(spacing: 10) {
            Rectangle().fill(WispColor.cardSeparator.opacity(0.5)).frame(height: 0.5)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(WispColor.textTertiary)
            Rectangle().fill(WispColor.cardSeparator.opacity(0.5)).frame(height: 0.5)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Threads

    /// The tabs of the top bar: the buddy's own (its character and name) first, then one
    /// per side thread, then "+" to start another thread.
    private func threadTabs(for buddy: WispBuddy, summaries: [BuddyThreadSummary], mood: BuddyMood) -> some View {
        let accent = BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex)
        return HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(summaries) { summary in
                        let isActive = summary.id == activeThreadID
                        HStack(spacing: 6) {
                            if summary.isMain {
                                BuddyCharacter(colorIndex: buddy.colorIndex, size: 18, mood: mood, liveliness: .working, looksAtPointer: false)
                                    .frame(width: 22, height: 22)
                            }
                            Text(summary.isMain ? buddy.name : summary.title)
                                .font(.system(size: 12.5, weight: isActive ? .semibold : .medium))
                                .foregroundStyle(isActive ? WispColor.textPrimary : WispColor.textSecondary)
                                .lineLimit(1)
                            if let threadID = summary.id, isActive {
                                Button {
                                    if summary.exchangeCount == 0 {
                                        draftThreadIDs.removeAll { $0 == threadID }
                                        activeThreadID = nil
                                    } else {
                                        threadPendingDeletion = threadID
                                    }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(WispColor.textTertiary)
                                }
                                .buttonStyle(.plain)
                                .pointerCursor()
                                .accessibilityLabel("Delete thread")
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background {
                            if isActive {
                                Color.clear.wispBevel(RoundedRectangle(cornerRadius: 9, style: .continuous), fill: WispColor.surface3)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .onTapGesture { withAnimation(WispMotion.quick) { activeThreadID = summary.id } }
                        .pointerCursor()
                        .accessibilityLabel(summary.isMain ? buddy.name : summary.title)
                        .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            BuddyIconButton(symbolName: "plus", label: "New thread", tint: accent, size: 26) {
                let newThreadID = UUID()
                draftThreadIDs.append(newThreadID)
                withAnimation(WispMotion.quick) { activeThreadID = newThreadID }
                isComposerFocused = true
            }
        }
        .animation(WispMotion.quick, value: summaries)
    }

    // MARK: - Header

    /// One bar, as in OpenBot: the buddy's own tab and its side threads (with +) on the
    /// left; on the right what it is doing, its model, Run / Stop, the menu and the
    /// details toggle. The buddy's name lives in its tab, so there is no second title.
    private func header(
        for buddy: WispBuddy, mood: BuddyMood, isRunning: Bool, latestRunRecord: AgentTaskRecord?,
        summaries: [BuddyThreadSummary]
    ) -> some View {
        HStack(spacing: 8) {
            threadTabs(for: buddy, summaries: summaries, mood: mood)

            Spacer(minLength: 8)

            if mood == .working || mood == .waiting || mood == .oops {
                Text(statusLine(for: buddy, mood: mood, latestRunRecord: latestRunRecord))
                    .font(.system(size: 11.5))
                    .foregroundStyle(BuddyFormatting.moodColor(mood, colorIndex: buddy.colorIndex))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 220, alignment: .trailing)
                    .animation(WispMotion.smooth, value: mood)
            }

            Text(buddy.runsOnLabel ?? ActiveStackReadout.shared.chatModelName)
                .font(.system(size: 11.5))
                .foregroundStyle(WispColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 160)
                .nativeTooltip("The model this buddy uses")

            if isRunning {
                Button { buddyStore.stopRun(ofBuddyWithID: buddy.id, inConversation: activeThreadID) } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(BuddyPillButtonStyle(colorIndex: buddy.colorIndex, isProminent: false))
                    .pointerCursor()
            } else {
                Button {
                    if !buddyStore.runNow(buddyWithID: buddy.id) {
                        sendFailureMessage = buddy.isHiddenInList ? "It's hidden. Show it in the list to run it." : "Its model is busy — try again in a moment."
                    }
                } label: { Label("Run now", systemImage: "play.fill") }
                    .buttonStyle(BuddyPillButtonStyle(colorIndex: buddy.colorIndex))
                    .pointerCursor()
            }

            Menu {
                BuddyActionsMenuItems(
                    buddy: buddy,
                    isRunning: isRunning,
                    showsReadState: false,
                    onDuplicated: onOpenBuddy,
                    onRequestClearConversation: onRequestClearConversation,
                    onRequestDeletion: onRequestDeletion
                )
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WispColor.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .pointerCursor()
            .accessibilityLabel("More actions")

            BuddyIconButton(
                symbolName: "sidebar.right",
                label: isInspectorOpen ? "Hide details" : "Show details",
                tint: isInspectorOpen ? WispColor.textPrimary : WispColor.textSecondary
            ) {
                withAnimation(WispMotion.island) { isInspectorOpen.toggle() }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    /// One line, only when it says something: what it's doing, or when it next runs.
    private func statusLine(for buddy: WispBuddy, mood: BuddyMood, latestRunRecord: AgentTaskRecord?) -> String {
        switch mood {
        case .working: return latestRunRecord?.steps.last?.summary ?? "Working…"
        case .waiting: return "Waiting for your ok"
        case .oops: return "Its last run failed"
        default:
            let specialtyPrefix = buddy.specialty.flatMap { $0 == .general ? nil : $0.title + " · " } ?? ""
            return buddy.schedule.isRepeating
                ? "\(specialtyPrefix)Next run \(BuddyFormatting.nextRunPhrase(for: buddy))"
                : (specialtyPrefix.isEmpty ? "Runs when you ask" : String(specialtyPrefix.dropLast(3)))
        }
    }

    // MARK: - Thread

    private func missionRow(for buddy: WispBuddy) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "flag")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(WispColor.textTertiary)
            Text(buddy.instruction)
                .font(.system(size: 13))
                .foregroundStyle(WispColor.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WispColor.surface2.opacity(0.6)))
    }

    /// Tap-to-fill suggestions for a buddy that hasn't said anything yet.
    private func quickStarts(for buddy: WispBuddy) -> some View {
        let suggestions = Array((buddy.specialty ?? .general).starterJobs.prefix(3))
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(suggestions, id: \.self) { suggestion in
                Button {
                    draftMessageText = suggestion
                    isComposerFocused = true
                } label: {
                    Text(suggestion)
                        .font(.system(size: 12.5))
                        .foregroundStyle(WispColor.textSecondary)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(WispColor.cardSeparator.opacity(0.7), lineWidth: 0.5))
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(PressableScaleButtonStyle())
                .pointerCursor()
            }
        }
    }

    private func threadEntry(taskID: UUID, buddy: WispBuddy, continuesRun: Bool = false) -> some View {
        let runRecord = taskRegistry.records.first { $0.id == taskID }
        let exchange = threadStore.exchange(forTaskID: taskID, ofBuddyWithID: buddy.id)
        let isRunning = runRecord.map { !$0.status.isTerminal } ?? false
        return VStack(alignment: .leading, spacing: 8) {
            if let exchange, exchange.origin == .delegated, let requesterName = exchange.requesterName {
                handoffRow(requesterName: requesterName, message: exchange.userText, buddy: buddy)
            } else if let exchange, exchange.origin == .message {
                userBubble(exchange, buddy: buddy)
            }

            if let runRecord {
                if !runRecord.steps.isEmpty { progressDisclosure(for: runRecord, buddy: buddy) }
                switch runRecord.status {
                case .running, .waitingForApproval:
                    typingRow(runRecord: runRecord, buddy: buddy)
                case .succeeded:
                    answerRow(text: AnswerDisplayText.cleaned(runRecord.finalText ?? "").nonEmptyOr("Done."), taskID: taskID, exchange: exchange, buddy: buddy, isRunning: isRunning, meta: metaText(for: runRecord), showsAvatar: !continuesRun)
                case .failed(let failureReason):
                    errorRow(text: AnswerDisplayText.cleaned(runRecord.finalText ?? "").nonEmptyOr(failureReason), meta: metaText(for: runRecord))
                case .cancelled, .interrupted:
                    Text("\(runRecord.status == .cancelled ? "Stopped" : "Interrupted") · \(BuddyFormatting.timeText(runRecord.startedAt))")
                        .font(.system(size: 11)).foregroundStyle(WispColor.textTertiary)
                        .padding(.leading, 34)
                }
            } else if let exchange {
                if let answerText = exchange.answerText, !answerText.isEmpty {
                    answerRow(text: answerText, taskID: taskID, exchange: exchange, buddy: buddy, isRunning: false, meta: BuddyFormatting.timeText(exchange.startedAt), showsAvatar: !continuesRun)
                } else {
                    Text("No answer was kept · \(BuddyFormatting.timeText(exchange.startedAt))")
                        .font(.system(size: 11)).foregroundStyle(WispColor.textTertiary).padding(.leading, 34)
                }
            }
        }
        .onHover { isHovering in
            if isHovering { hoveredTaskID = taskID } else if hoveredTaskID == taskID { hoveredTaskID = nil }
        }
    }

    private func metaText(for runRecord: AgentTaskRecord) -> String {
        "\(BuddyFormatting.timeText(runRecord.startedAt)) · \(BuddyFormatting.durationText(runRecord.elapsedSeconds))"
    }

    private func userBubble(_ exchange: BuddyThreadExchange, buddy: WispBuddy) -> some View {
        VStack(alignment: .trailing, spacing: 5) {
            if let names = exchange.attachmentNames, !names.isEmpty {
                HStack(spacing: 5) {
                    ForEach(names, id: \.self) { fileName in
                        Label(fileName, systemImage: "paperclip")
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .foregroundStyle(WispColor.textSecondary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(WispColor.surface3.opacity(0.8)))
                    }
                }
            }
            Text(exchange.userText)
                .font(.system(size: 13.5))
                .foregroundStyle(WispColor.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 9)
                // Neutral and quiet, as in OpenBot: the user's words sit in a soft bubble and
                // the buddy's answer is plain text beside its face.
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(WispColor.surface3))
            // Messages the run took in while it worked (steer mode), in the order sent.
            ForEach(Array((exchange.addedTexts ?? []).enumerated()), id: \.offset) { _, addedText in
                Text(addedText)
                    .font(.system(size: 13.5))
                    .foregroundStyle(WispColor.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(WispColor.surface3))
                    .nativeTooltip("Sent while it worked; it took this in at its next step")
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 70)
    }

    /// Another buddy handed this one something.
    private func handoffRow(requesterName: String, message: String, buddy: WispBuddy) -> some View {
        let requester = buddyStore.buddies.first { $0.name == requesterName }
        return HStack(alignment: .top, spacing: 10) {
            if let requester {
                BuddyCharacter(colorIndex: requester.colorIndex, size: 26, mood: .idle, liveliness: .still)
                    .frame(width: 28, height: 28)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("From \(requesterName)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WispColor.textSecondary)
                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(WispColor.textSecondary)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(WispColor.cardSeparator.opacity(0.8), style: StrokeStyle(lineWidth: 0.7, dash: [4, 3])))
    }

    private func answerRow(text: String, taskID: UUID, exchange: BuddyThreadExchange?, buddy: WispBuddy, isRunning: Bool, meta: String, showsAvatar: Bool = true) -> some View {
        // As in OpenBot: the buddy's reply is a bubble of its own on the left, the same quiet
        // surface as the user's on the right, with no avatar beside it (the tab and the
        // list already say who is talking). `showsAvatar` is kept for callers but unused.
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Text(BuddyAnswerFormatting.attributedAnswer(text))
                    .font(.system(size: 13.5))
                    .foregroundStyle(WispColor.textPrimary)
                    .tint(BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(WispColor.surface3))

                HStack(spacing: 2) {
                    Text(meta)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(WispColor.textTertiary)
                        .padding(.leading, 4)
                    messageActions(text: text, exchange: exchange, buddy: buddy, isRunning: isRunning)
                        .opacity(hoveredTaskID == taskID ? 1 : 0)
                        .animation(WispMotion.quick, value: hoveredTaskID)
                }
            }
            Spacer(minLength: 40)
        }
    }

    /// Copy, run again, hand off — shown on hover under an answer.
    private func messageActions(text: String, exchange: BuddyThreadExchange?, buddy: WispBuddy, isRunning: Bool) -> some View {
        let peers = buddyStore.orderedBuddies(in: taskRegistry).filter { $0.id != buddy.id }
        return HStack(spacing: 0) {
            BuddyIconButton(symbolName: "doc.on.doc", label: "Copy", size: 24) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            BuddyIconButton(symbolName: "arrow.clockwise", label: "Run again", size: 24) {
                guard !isRunning else { return }
                let didStart: Bool
                if let exchange, exchange.origin == .message {
                    didStart = buddyStore.sendMessage(exchange.userText, toBuddyWithID: buddy.id, inThread: exchange.threadID)
                } else {
                    didStart = buddyStore.runNow(buddyWithID: buddy.id)
                }
                if !didStart { sendFailureMessage = "Its model is busy — try again in a moment." }
            }
            if advancedFeatures.isEnabled && !peers.isEmpty {
                Menu {
                    ForEach(peers) { peer in
                        Button(peer.runtimeKind == .claudeCodeSession || peer.modelChoice?.sendsDataOffThisMachine == true ? "\(peer.name) · cloud model" : peer.name) {
                            handOff(answer: text, from: buddy, to: peer)
                        }
                    }
                } label: {
                    Image(systemName: "arrowshape.turn.up.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(WispColor.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().pointerCursor()
                .accessibilityLabel("Hand off to another buddy")
                .nativeTooltip("Hand off to another buddy")
            }
        }
    }

    private func handOff(answer: String, from buddy: WispBuddy, to peer: WispBuddy) {
        let message = "\(buddy.name) handed this over:\n\n" + String(answer.prefix(1500))
        if buddyStore.startDelegatedRun(to: peer.id, message: message, fromBuddyNamed: buddy.name) != nil {
            onOpenBuddy(peer.id)
        } else {
            sendFailureMessage = "\(peer.name) is busy — try again in a moment."
        }
    }

    private func errorRow(text: String, meta: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(DS.Colors.destructiveText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 13).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.destructive.opacity(0.09)))
            Text("Failed · \(meta)")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(WispColor.textTertiary).padding(.leading, 4)
        }
        .padding(.leading, 34)
    }

    private func typingRow(runRecord: AgentTaskRecord, buddy: WispBuddy) -> some View {
        HStack(spacing: 8) {
            BuddyCharacter(colorIndex: buddy.colorIndex, size: 24, mood: runRecord.status == .waitingForApproval ? .waiting : .working, liveliness: .full)
                .frame(width: 26, height: 26)
            HStack(spacing: 9) {
                BuddyTypingDots(colorIndex: buddy.colorIndex)
                Text(runRecord.status == .waitingForApproval ? "Waiting for your ok" : (runRecord.steps.last?.summary ?? "Working…"))
                    .font(.system(size: 12))
                    .foregroundStyle(WispColor.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 13).padding(.vertical, 9)
            .background(Capsule(style: .continuous).fill(WispColor.surface2.opacity(0.9)))
            Spacer(minLength: 0)
        }
    }

    private func stepCountText(for runRecord: AgentTaskRecord) -> String {
        runRecord.steps.count == 1 ? "1 step" : "\(runRecord.steps.count) steps"
    }

    /// "4 steps  11s ›": opens the run's Trace (`RunTraceView`), as in OpenBot.
    private func progressDisclosure(for runRecord: AgentTaskRecord, buddy: WispBuddy) -> some View {
        Button {
            tracedRunID = runRecord.id
        } label: {
            HStack(spacing: 6) {
                Text(stepCountText(for: runRecord)).font(.system(size: 11.5, weight: .medium))
                Text(BuddyFormatting.durationText(runRecord.elapsedSeconds)).font(.system(size: 11.5).monospacedDigit())
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(WispColor.textTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel("Open trace, \(stepCountText(for: runRecord))")
        .padding(.leading, 4)
    }

    // MARK: - Composer

    private func composer(for buddy: WispBuddy, isRunning: Bool) -> some View {
        let trimmedDraft = draftMessageText.trimmingCharacters(in: .whitespacesAndNewlines)
        // A text message sent while the buddy works joins its line; files and
        // pictures are read when sent, so they have to wait for it to be free.
        // A hidden buddy takes nothing new until it's shown again.
        let canSend = (!trimmedDraft.isEmpty || !pendingFileURLs.isEmpty)
            && !(isRunning && !pendingFileURLs.isEmpty) && !isSending && !buddy.isHiddenInList
        let accent = BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex)
        let waitingMessages = buddyStore.waitingMessages(of: buddy)
        return VStack(spacing: 8) {
            if buddy.isHiddenInList {
                HStack(spacing: 8) {
                    Image(systemName: "eye.slash").foregroundStyle(WispColor.textTertiary)
                    Text("Hidden: it doesn't run on its schedule or take messages.")
                        .font(.system(size: 12))
                        .foregroundStyle(WispColor.textSecondary)
                    Spacer()
                    Button("Show in List") { buddyStore.setHidden(buddyWithID: buddy.id, isHidden: false) }
                        .buttonStyle(BuddyPillButtonStyle(colorIndex: buddy.colorIndex, isProminent: false))
                        .controlSize(.small)
                        .pointerCursor()
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(WispColor.surface2.opacity(0.7)))
            }
            if !waitingMessages.isEmpty {
                waitingMessageLine(for: buddy, waitingMessages: waitingMessages, accent: accent)
                    .transition(.opacity)
            }

            if !pendingFileURLs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { ForEach(pendingFileURLs, id: \.self) { pendingFileChip($0) } }
                }
                .transition(.opacity)
            }

            HStack(alignment: .bottom, spacing: 6) {
                // OpenBot's "+" is a small menu: attach, or start a side thread.
                Menu {
                    Button("Attach files…", systemImage: "paperclip") { chooseFiles() }
                    Button("New thread", systemImage: "plus.bubble") {
                        let newThreadID = UUID()
                        draftThreadIDs.append(newThreadID)
                        withAnimation(WispMotion.quick) { activeThreadID = newThreadID }
                        isComposerFocused = true
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(accent)
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).fixedSize()
                .pointerCursor()
                .accessibilityLabel("Add")

                TextField(isRunning ? (buddy.busyMode == .steer ? "Add to what \(buddy.name) is doing…" : "Queue a message for \(buddy.name)…") : "Message \(buddy.name)", text: $draftMessageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .foregroundStyle(WispColor.textPrimary)
                    .lineLimit(1...6)
                    .focused($isComposerFocused)
                    .padding(.vertical, 7)
                    .onSubmit { if canSend { send(to: buddy) } }

                Button { send(to: buddy) } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(canSend ? WispColor.windowBackground : WispColor.textTertiary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(canSend ? WispColor.textPrimary : WispColor.surface4.opacity(0.7)))
                        .contentShape(Circle())
                }
                .buttonStyle(PressableScaleButtonStyle())
                .disabled(!canSend)
                .pointerCursor()
                .accessibilityLabel("Send message")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(WispColor.surface2.opacity(0.9)))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(isComposerFocused ? accent.opacity(0.7) : WispColor.cardSeparator.opacity(0.7), lineWidth: isComposerFocused ? 1 : 0.5)
            )
            .animation(WispMotion.smooth, value: isComposerFocused)

            if let sendFailureMessage {
                Text(sendFailureMessage).font(.system(size: 11)).foregroundStyle(DS.Colors.warningText)
            }
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 28)
        .padding(.top, 6)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
    }

    private func pendingFileChip(_ fileURL: URL) -> some View {
        let isImage = BuddyAttachmentPolicy.kind(forFileExtension: fileURL.pathExtension) == .image
        return HStack(spacing: 7) {
            if isImage, let thumbnail = NSImage(contentsOf: fileURL) {
                Image(nsImage: thumbnail).resizable().scaledToFill().frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: "doc.text").font(.system(size: 13)).foregroundStyle(WispColor.textSecondary).frame(width: 22, height: 22)
            }
            Text(fileURL.lastPathComponent).font(.system(size: 12)).foregroundStyle(WispColor.textPrimary).lineLimit(1).frame(maxWidth: 160)
            Button {
                withAnimation(WispMotion.quick) { pendingFileURLs.removeAll { $0 == fileURL } }
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(WispColor.textTertiary)
            }
            .buttonStyle(.plain).pointerCursor().accessibilityLabel("Remove \(fileURL.lastPathComponent)")
        }
        .padding(.leading, 6).padding(.trailing, 9).padding(.vertical, 5)
        .background(Capsule(style: .continuous).fill(WispColor.surface2))
        .overlay(Capsule(style: .continuous).strokeBorder(WispColor.cardSeparator.opacity(0.7), lineWidth: 0.5))
    }

    // MARK: - Actions

    private func chooseFiles() {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = false
        guard openPanel.runModal() == .OK else { return }
        addPendingFiles(openPanel.urls)
    }

    /// The messages waiting their turn, with a way to take one back out and to
    /// hold the whole line.
    private func waitingMessageLine(for buddy: WispBuddy, waitingMessages: [QueuedBuddyMessage], accent: Color) -> some View {
        let isLinePaused = buddyStore.isMessageLinePaused(buddyWithID: buddy.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(isLinePaused ? "Line paused · \(waitingMessages.count) waiting" : "\(waitingMessages.count) waiting")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(WispColor.textSecondary)
                Spacer()
                BuddyIconButton(
                    symbolName: isLinePaused ? "play.fill" : "pause.fill",
                    label: isLinePaused ? "Resume line" : "Pause line",
                    tint: accent,
                    size: 22
                ) {
                    buddyStore.setMessageLinePaused(!isLinePaused, forBuddyWithID: buddy.id)
                }
            }
            ForEach(waitingMessages) { waitingMessage in
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(waitingMessage.text)
                            .font(.system(size: 12))
                            .foregroundStyle(WispColor.textPrimary)
                            .lineLimit(1)
                        // Why it hasn't started; a message for another thread says so.
                        if let holdReason = buddyStore.holdReason(forWaitingMessage: waitingMessage, of: buddy) {
                            Text(waitingMessage.threadID == activeThreadID
                                 ? holdReason.displayText
                                 : "In another thread · " + holdReason.displayText)
                                .font(.system(size: 10.5))
                                .foregroundStyle(WispColor.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    BuddyIconButton(symbolName: "xmark", label: "Take this message back", tint: accent, size: 22) {
                        withAnimation(WispMotion.smooth) {
                            buddyStore.cancelWaitingMessage(withID: waitingMessage.id, ofBuddyWithID: buddy.id)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(WispColor.surface2.opacity(0.7)))
            }
        }
    }

    private func addPendingFiles(_ fileURLs: [URL]) {
        withAnimation(WispMotion.smooth) {
            for fileURL in fileURLs where fileURL.isFileURL && !pendingFileURLs.contains(fileURL) {
                pendingFileURLs.append(fileURL)
            }
        }
        isComposerFocused = true
    }

    private func send(to buddy: WispBuddy) {
        let messageText = draftMessageText
        let fileURLs = pendingFileURLs
        guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !fileURLs.isEmpty else { return }
        isSending = true
        sendFailureMessage = nil
        Task {
            let didStart = await buddyStore.sendMessage(messageText, attachmentFileURLs: fileURLs, toBuddyWithID: buddy.id, inThread: activeThreadID)
            isSending = false
            if didStart {
                draftMessageText = ""
                withAnimation(WispMotion.smooth) { pendingFileURLs = [] }
            } else {
                sendFailureMessage = fileURLs.isEmpty
                    ? "Its line is full or its model is busy — try again in a moment."
                    : "Files can't wait in line — send them once it's free."
            }
        }
    }
}

private extension String {
    func nonEmptyOr(_ fallback: String) -> String {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : self
    }
}
