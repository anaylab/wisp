//
//  BuddyChatView.swift
//  leanring-buddy
//
//  One buddy's own chat: a tinted space in the buddy's colour with its living
//  character in the header, the thread as bubbles (the user's in the buddy's
//  gradient, the buddy's beside a small avatar), typing dots while it works,
//  handoff cards when another buddy asked it something, and a composer that
//  takes files — paperclip, drag and drop — and a message together.
//
//  The thread is the same data as before (`BuddyThreadStore` exchanges + the run
//  records in `AgentTaskRegistry`); only the presentation is new.
//

import AppKit
import SwiftUI

struct BuddyChatView: View {
    let buddyID: UUID
    @Binding var isInspectorOpen: Bool
    var onRequestClearConversation: () -> Void
    var onRequestDeletion: () -> Void
    var onDuplicated: (UUID) -> Void

    @ObservedObject private var buddyStore = BuddyStore.shared
    @ObservedObject private var taskRegistry = AgentTaskRegistry.shared
    @ObservedObject private var threadStore = BuddyThreadStore.shared

    @State private var draftMessageText = ""
    @State private var pendingFileURLs: [URL] = []
    @State private var isDropTargeted = false
    @State private var isSending = false
    @State private var didFailToStartRun = false
    @State private var expandedRunIDs: Set<UUID> = []
    @State private var bounceCount = 0
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
        let isRunning = buddyStore.isRunning(buddy, in: taskRegistry)
        let mood = buddyStore.mood(of: buddy, in: taskRegistry)
        let latestRunRecord = buddyStore.latestRunRecord(of: buddy, in: taskRegistry)
        let threadTaskIDs = BuddyListPolicy.threadTaskIDs(
            exchangeTaskIDs: threadStore.exchanges(ofBuddyWithID: buddy.id).map(\.taskID),
            runTaskIDs: buddy.runTaskIDs
        )
        return ZStack {
            BuddyAmbientBackground(colorIndex: buddy.colorIndex)

            VStack(spacing: 0) {
                header(for: buddy, mood: mood, isRunning: isRunning, latestRunRecord: latestRunRecord)

                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            missionCard(for: buddy)
                            if threadTaskIDs.isEmpty {
                                quickStarts(for: buddy)
                            }
                            ForEach(threadTaskIDs, id: \.self) { taskID in
                                threadEntry(taskID: taskID, buddy: buddy)
                            }
                            Color.clear.frame(height: 1).id(bottomAnchorID)
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, 8)
                        .padding(.bottom, 18)
                        .frame(maxWidth: 820)
                        .frame(maxWidth: .infinity)
                    }
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

            if isDropTargeted {
                BuddyDropOverlay(buddyName: buddy.name, colorIndex: buddy.colorIndex)
            }
        }
        .dropDestination(for: URL.self) { droppedURLs, _ in
            addPendingFiles(droppedURLs)
            return true
        } isTargeted: { isTargeted in
            withAnimation(WispMotion.quick) { isDropTargeted = isTargeted }
        }
        .onAppear { buddyStore.markRead(buddyWithID: buddy.id, in: taskRegistry) }
        .onChange(of: buddyID) { _, newBuddyID in
            buddyStore.markRead(buddyWithID: newBuddyID, in: taskRegistry)
            draftMessageText = ""
            pendingFileURLs = []
            expandedRunIDs = []
            didFailToStartRun = false
            bounceCount += 1
        }
    }

    // MARK: - Header

    private func header(for buddy: WispBuddy, mood: BuddyMood, isRunning: Bool, latestRunRecord: AgentTaskRecord?) -> some View {
        HStack(spacing: 14) {
            BuddyCharacter(colorIndex: buddy.colorIndex, size: 58, mood: mood, liveliness: .full, bounceTrigger: bounceCount, looksAtPointer: true)
                .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(buddy.name)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(WispColor.textPrimary)
                        .lineLimit(1)
                    if let specialty = buddy.specialty, specialty != .general {
                        BuddyChip(symbolName: specialty.symbolName, text: specialty.title, colorIndex: buddy.colorIndex)
                    }
                }
                Text(statusLine(for: buddy, mood: mood, latestRunRecord: latestRunRecord))
                    .font(.system(size: 12))
                    .foregroundStyle(BuddyFormatting.moodColor(mood, colorIndex: buddy.colorIndex))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(WispMotion.smooth, value: mood)
            }

            Spacer(minLength: 8)

            if isRunning {
                Button {
                    buddyStore.stopRun(ofBuddyWithID: buddy.id)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(BuddyPillButtonStyle(colorIndex: buddy.colorIndex, isProminent: false))
                .pointerCursor()
            } else {
                Button {
                    didFailToStartRun = !buddyStore.runNow(buddyWithID: buddy.id)
                } label: {
                    Label("Run now", systemImage: "play.fill")
                }
                .buttonStyle(BuddyPillButtonStyle(colorIndex: buddy.colorIndex))
                .pointerCursor()
                .nativeTooltip(didFailToStartRun ? "Its model is busy with other runs — try again when one finishes" : "Do its job now")
            }

            Menu {
                BuddyActionsMenuItems(
                    buddy: buddy,
                    isRunning: isRunning,
                    showsReadState: false,
                    onDuplicated: onDuplicated,
                    onRequestClearConversation: onRequestClearConversation,
                    onRequestDeletion: onRequestDeletion
                )
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WispColor.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(WispColor.surface2.opacity(0.7)))
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .pointerCursor()
            .accessibilityLabel("More actions")

            Button {
                withAnimation(WispMotion.island) { isInspectorOpen.toggle() }
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(BuddyIconButtonStyle(tint: isInspectorOpen ? BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex) : WispColor.textSecondary))
            .pointerCursor()
            .accessibilityLabel(isInspectorOpen ? "Hide details" : "Show details")
            .nativeTooltip(isInspectorOpen ? "Hide details" : "Automation, files, memory and settings")
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private func statusLine(for buddy: WispBuddy, mood: BuddyMood, latestRunRecord: AgentTaskRecord?) -> String {
        switch mood {
        case .working:
            return latestRunRecord?.steps.last?.summary ?? "Working on it…"
        case .waiting:
            return "Waiting for your ok"
        case .happy:
            return "Just finished — take a look"
        case .oops:
            return "Its last run hit a snag"
        case .sleepy, .idle:
            return buddy.schedule.isRepeating
                ? "\(buddy.schedule.summary()) · next \(BuddyFormatting.nextRunPhrase(for: buddy))"
                : "Here when you need it"
        }
    }

    // MARK: - Thread

    private func missionCard(for buddy: WispBuddy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "flag.fill").font(.system(size: 10, weight: .bold))
                Text("MISSION")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .tracking(1.2)
            }
            .foregroundStyle(BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex))

            Text(buddy.instruction)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(WispColor.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                BuddyChip(symbolName: "clock", text: buddy.schedule.summary(), colorIndex: buddy.colorIndex)
                if let modelChoice = buddy.modelChoice {
                    BuddyChip(symbolName: modelChoice.sendsDataOffThisMachine ? "cloud" : "cpu", text: modelChoice.displayName, colorIndex: buddy.colorIndex)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex).opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(BuddyAppearance.accentGradient(forColorIndex: buddy.colorIndex).opacity(0.55), lineWidth: 1.2)
        )
    }

    /// Tap-to-send suggestions for a buddy that hasn't said anything yet.
    private func quickStarts(for buddy: WispBuddy) -> some View {
        let suggestions = (buddy.specialty ?? .general).starterJobs.prefix(3)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Try saying")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(WispColor.textTertiary)
            ForEach(Array(suggestions), id: \.self) { suggestion in
                Button {
                    draftMessageText = suggestion
                    isComposerFocused = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "text.bubble.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex))
                        Text(suggestion)
                            .font(.system(size: 12.5))
                            .foregroundStyle(WispColor.textPrimary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(WispColor.surface2.opacity(0.85)))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PressableScaleButtonStyle())
                .pointerCursor()
            }
        }
        .transition(.opacity)
    }

    private func threadEntry(taskID: UUID, buddy: WispBuddy) -> some View {
        let runRecord = taskRegistry.records.first { $0.id == taskID }
        let exchange = threadStore.exchange(forTaskID: taskID, ofBuddyWithID: buddy.id)
        return VStack(alignment: .leading, spacing: 10) {
            if let exchange, exchange.origin == .delegated, let requesterName = exchange.requesterName {
                handoffCard(requesterName: requesterName, message: exchange.userText, buddy: buddy)
            } else if let exchange, exchange.origin == .message {
                userBubble(exchange, buddy: buddy)
            }

            if let runRecord {
                if !runRecord.steps.isEmpty { progressDisclosure(for: runRecord, buddy: buddy) }
                switch runRecord.status {
                case .running, .waitingForApproval:
                    typingBubble(runRecord: runRecord, buddy: buddy)
                case .succeeded:
                    buddyBubble(text: AnswerDisplayText.cleaned(runRecord.finalText ?? "").nonEmptyOr("Done."), buddy: buddy)
                case .failed(let failureReason):
                    errorBubble(text: AnswerDisplayText.cleaned(runRecord.finalText ?? "").nonEmptyOr(failureReason))
                case .cancelled, .interrupted:
                    Text(runRecord.status == .cancelled ? "Stopped." : "Interrupted when Wisp quit.")
                        .font(.system(size: 11.5)).foregroundStyle(WispColor.textTertiary)
                        .padding(.leading, 38)
                }
                Text("\(statusWord(runRecord.status)) · \(BuddyFormatting.timeText(runRecord.startedAt))")
                    .font(.system(size: 10.5, design: .rounded).monospacedDigit())
                    .foregroundStyle(WispColor.textTertiary)
                    .padding(.leading, 38)
            } else if let exchange {
                if let answerText = exchange.answerText, !answerText.isEmpty {
                    buddyBubble(text: answerText, buddy: buddy)
                } else {
                    Text("No answer was kept for this run.")
                        .font(.system(size: 11.5)).foregroundStyle(WispColor.textTertiary).padding(.leading, 38)
                }
                Text(BuddyFormatting.timeText(exchange.startedAt))
                    .font(.system(size: 10.5, design: .rounded).monospacedDigit())
                    .foregroundStyle(WispColor.textTertiary).padding(.leading, 38)
            }
        }
        .transition(.opacity.combined(with: .offset(y: 8)))
    }

    private func statusWord(_ status: AgentTaskRecord.Status) -> String {
        switch status {
        case .running: return "Working"
        case .waitingForApproval: return "Needs your ok"
        case .succeeded: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Stopped"
        case .interrupted: return "Interrupted"
        }
    }

    private func userBubble(_ exchange: BuddyThreadExchange, buddy: WispBuddy) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let names = exchange.attachmentNames, !names.isEmpty {
                HStack(spacing: 6) {
                    ForEach(names, id: \.self) { fileName in
                        HStack(spacing: 5) {
                            Image(systemName: "paperclip").font(.system(size: 10, weight: .bold))
                            Text(fileName).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        }
                        .foregroundStyle(BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Capsule().fill(BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex).opacity(0.14)))
                    }
                }
            }
            Text(exchange.userText)
                .font(.system(size: 13.5))
                .foregroundStyle(Color.white)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(BuddyAppearance.accentGradient(forColorIndex: buddy.colorIndex))
                )
                .shadow(color: BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex).opacity(0.25), radius: 8, y: 3)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 60)
    }

    /// Another buddy asked this one for help: both characters, an arrow, the ask.
    private func handoffCard(requesterName: String, message: String, buddy: WispBuddy) -> some View {
        let requester = buddyStore.buddies.first { $0.name == requesterName }
        return HStack(alignment: .center, spacing: 12) {
            HStack(spacing: -4) {
                if let requester {
                    BuddyCharacter(colorIndex: requester.colorIndex, size: 34, mood: .happy, liveliness: .still)
                } else {
                    Circle().fill(WispColor.surface3).frame(width: 34, height: 34)
                }
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex))
                    .padding(.horizontal, 8)
                BuddyCharacter(colorIndex: buddy.colorIndex, size: 34, mood: .idle, liveliness: .still)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(requesterName) asked for help")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex))
                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(WispColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(WispColor.surface2.opacity(0.85)))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex).opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
    }

    private func buddyBubble(text: String, buddy: WispBuddy) -> some View {
        HStack(alignment: .top, spacing: 8) {
            BuddyCharacter(colorIndex: buddy.colorIndex, size: 30, mood: .idle, liveliness: .still)
                .frame(width: 30, height: 30)
            Text(BuddyAnswerFormatting.attributedAnswer(text))
                .font(.system(size: 13.5))
                .foregroundStyle(WispColor.textPrimary)
                .tint(BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(WispColor.surface2.opacity(0.92)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(WispColor.cardSeparator.opacity(0.5), lineWidth: 0.5))
                .contextMenu {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
            Spacer(minLength: 40)
        }
    }

    private func errorBubble(text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(DS.Colors.destructiveText)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DS.Colors.destructive.opacity(0.10)))
            .padding(.leading, 38)
    }

    private func typingBubble(runRecord: AgentTaskRecord, buddy: WispBuddy) -> some View {
        HStack(alignment: .center, spacing: 8) {
            BuddyCharacter(colorIndex: buddy.colorIndex, size: 30, mood: runRecord.status == .waitingForApproval ? .waiting : .working, liveliness: .full)
                .frame(width: 30, height: 30)
            HStack(spacing: 10) {
                BuddyTypingDots(colorIndex: buddy.colorIndex)
                Text(runRecord.status == .waitingForApproval ? "Waiting for your ok" : (runRecord.steps.last?.summary ?? "Working on it…"))
                    .font(.system(size: 12))
                    .foregroundStyle(WispColor.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Capsule(style: .continuous).fill(WispColor.surface2.opacity(0.92)))
            Spacer(minLength: 0)
        }
    }

    private func progressDisclosure(for runRecord: AgentTaskRecord, buddy: WispBuddy) -> some View {
        let isExpanded = expandedRunIDs.contains(runRecord.id)
        return VStack(alignment: .leading, spacing: 5) {
            Button {
                withAnimation(WispMotion.smooth) {
                    if isExpanded { expandedRunIDs.remove(runRecord.id) } else { expandedRunIDs.insert(runRecord.id) }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(runRecord.steps.count == 1 ? "1 step" : "\(runRecord.steps.count) steps")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(WispColor.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(runRecord.steps) { step in
                        HStack(alignment: .top, spacing: 6) {
                            Circle()
                                .fill(step.isError ? DS.Colors.destructive : BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex).opacity(0.6))
                                .frame(width: 5, height: 5).padding(.top, 5)
                            Text(step.summary)
                                .font(.system(size: 11)).foregroundStyle(WispColor.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 14)
                .transition(.opacity)
            }
        }
        .padding(.leading, 38)
    }

    // MARK: - Composer

    private func composer(for buddy: WispBuddy, isRunning: Bool) -> some View {
        let trimmedDraft = draftMessageText.trimmingCharacters(in: .whitespacesAndNewlines)
        let canSend = (!trimmedDraft.isEmpty || !pendingFileURLs.isEmpty) && !isRunning && !isSending
        return VStack(spacing: 8) {
            if !pendingFileURLs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pendingFileURLs, id: \.self) { fileURL in
                            pendingFileChip(fileURL, buddy: buddy)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    chooseFiles()
                } label: {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(BuddyIconButtonStyle(tint: BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex)))
                .pointerCursor()
                .accessibilityLabel("Attach files")
                .nativeTooltip("Attach files — or just drop them here")

                TextField(
                    isRunning ? "\(buddy.name) is working — reply when it's done" : "Message \(buddy.name)",
                    text: $draftMessageText,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(WispColor.textPrimary)
                .lineLimit(1...6)
                .focused($isComposerFocused)
                .padding(.vertical, 6)
                .onSubmit { if canSend { send(to: buddy) } }

                Button {
                    send(to: buddy)
                } label: {
                    Image(systemName: isSending ? "ellipsis" : "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(canSend
                            ? AnyShapeStyle(BuddyAppearance.accentGradient(forColorIndex: buddy.colorIndex))
                            : AnyShapeStyle(WispColor.surface4)))
                        .contentShape(Circle())
                }
                .buttonStyle(PressableScaleButtonStyle())
                .disabled(!canSend)
                .pointerCursor()
                .accessibilityLabel("Send message")
                .nativeTooltip("Send")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(
                        isComposerFocused
                            ? AnyShapeStyle(BuddyAppearance.accentGradient(forColorIndex: buddy.colorIndex))
                            : AnyShapeStyle(WispColor.cardSeparator.opacity(0.6)),
                        lineWidth: isComposerFocused ? 1.6 : 0.8
                    )
            )
            .shadow(color: BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex).opacity(isComposerFocused ? 0.18 : 0), radius: 14, y: 4)
            .animation(WispMotion.smooth, value: isComposerFocused)

            if didFailToStartRun {
                Text("Busy — its model is working on something else. Try again in a moment.")
                    .font(.system(size: 11)).foregroundStyle(DS.Colors.warningText)
            }
        }
        .frame(maxWidth: 820)
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .padding(.top, 4)
        .frame(maxWidth: .infinity)
    }

    private func pendingFileChip(_ fileURL: URL, buddy: WispBuddy) -> some View {
        let isImage = BuddyAttachmentPolicy.kind(forFileExtension: fileURL.pathExtension) == .image
        return HStack(spacing: 7) {
            if isImage, let thumbnail = NSImage(contentsOf: fileURL) {
                Image(nsImage: thumbnail)
                    .resizable().scaledToFill()
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex))
                    .frame(width: 26, height: 26)
            }
            Text(fileURL.lastPathComponent)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(WispColor.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: 160)
            Button {
                withAnimation(WispMotion.quick) { pendingFileURLs.removeAll { $0 == fileURL } }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(WispColor.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.leading, 6).padding(.trailing, 8).padding(.vertical, 5)
        .background(Capsule(style: .continuous).fill(WispColor.surface2))
        .overlay(Capsule(style: .continuous).strokeBorder(BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex).opacity(0.4), lineWidth: 1))
    }

    // MARK: - Actions

    private func chooseFiles() {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = false
        openPanel.message = "Choose files to send"
        guard openPanel.runModal() == .OK else { return }
        addPendingFiles(openPanel.urls)
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
        didFailToStartRun = false
        Task {
            let didStart = await buddyStore.sendMessage(messageText, attachmentFileURLs: fileURLs, toBuddyWithID: buddy.id)
            isSending = false
            if didStart {
                draftMessageText = ""
                withAnimation(WispMotion.smooth) { pendingFileURLs = [] }
            } else {
                didFailToStartRun = true
            }
        }
    }
}

private extension String {
    func nonEmptyOr(_ fallback: String) -> String {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : self
    }
}
