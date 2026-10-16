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
                Rectangle().fill(WispColor.cardSeparator.opacity(0.5)).frame(height: 0.5)

                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            missionRow(for: buddy)
                            if threadTaskIDs.isEmpty { quickStarts(for: buddy) }
                            ForEach(threadTaskIDs, id: \.self) { taskID in
                                threadEntry(taskID: taskID, buddy: buddy)
                            }
                            Color.clear.frame(height: 1).id(bottomAnchorID)
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, 20)
                        .padding(.bottom, 16)
                        .frame(maxWidth: 760)
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

            if isDropTargeted { BuddyDropOverlay(colorIndex: buddy.colorIndex) }
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
            sendFailureMessage = nil
            bounceCount += 1
        }
    }

    // MARK: - Header

    private func header(for buddy: WispBuddy, mood: BuddyMood, isRunning: Bool, latestRunRecord: AgentTaskRecord?) -> some View {
        HStack(spacing: 12) {
            BuddyCharacter(colorIndex: buddy.colorIndex, size: 40, mood: mood, liveliness: .full, bounceTrigger: bounceCount, looksAtPointer: true)
                .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 2) {
                Text(buddy.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(WispColor.textPrimary)
                    .lineLimit(1)
                Text(statusLine(for: buddy, mood: mood, latestRunRecord: latestRunRecord))
                    .font(.system(size: 12))
                    .foregroundStyle(BuddyFormatting.moodColor(mood, colorIndex: buddy.colorIndex))
                    .lineLimit(1)
                    .animation(WispMotion.smooth, value: mood)
            }

            Spacer(minLength: 8)

            if isRunning {
                Button { buddyStore.stopRun(ofBuddyWithID: buddy.id) } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(BuddyPillButtonStyle(colorIndex: buddy.colorIndex, isProminent: false))
                    .pointerCursor()
            } else {
                Button {
                    if !buddyStore.runNow(buddyWithID: buddy.id) { sendFailureMessage = "Its model is busy — try again in a moment." }
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
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    /// One line, only when it says something: what it's doing, or when it next runs.
    private func statusLine(for buddy: WispBuddy, mood: BuddyMood, latestRunRecord: AgentTaskRecord?) -> String {
        switch mood {
        case .working: return latestRunRecord?.steps.last?.summary ?? "Working…"
        case .waiting: return "Waiting for your ok"
        case .oops: return "Its last run failed"
        default:
            if buddy.isAutomationPausedAfterFailures { return "Paused after repeated failures" }
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

    private func threadEntry(taskID: UUID, buddy: WispBuddy) -> some View {
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
                    answerRow(text: AnswerDisplayText.cleaned(runRecord.finalText ?? "").nonEmptyOr("Done."), taskID: taskID, exchange: exchange, buddy: buddy, isRunning: isRunning, meta: metaText(for: runRecord))
                case .failed(let failureReason):
                    errorRow(text: AnswerDisplayText.cleaned(runRecord.finalText ?? "").nonEmptyOr(failureReason), meta: metaText(for: runRecord))
                case .cancelled, .interrupted:
                    Text("\(runRecord.status == .cancelled ? "Stopped" : "Interrupted") · \(BuddyFormatting.timeText(runRecord.startedAt))")
                        .font(.system(size: 11)).foregroundStyle(WispColor.textTertiary)
                        .padding(.leading, 34)
                }
            } else if let exchange {
                if let answerText = exchange.answerText, !answerText.isEmpty {
                    answerRow(text: answerText, taskID: taskID, exchange: exchange, buddy: buddy, isRunning: false, meta: BuddyFormatting.timeText(exchange.startedAt))
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
                .foregroundStyle(Color.white)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 13).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex)))
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

    private func answerRow(text: String, taskID: UUID, exchange: BuddyThreadExchange?, buddy: WispBuddy, isRunning: Bool, meta: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            BuddyCharacter(colorIndex: buddy.colorIndex, size: 24, mood: .idle, liveliness: .still)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 5) {
                Text(BuddyAnswerFormatting.attributedAnswer(text))
                    .font(.system(size: 13.5))
                    .foregroundStyle(WispColor.textPrimary)
                    .tint(BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(WispColor.surface2.opacity(0.9)))

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
                    didStart = buddyStore.sendMessage(exchange.userText, toBuddyWithID: buddy.id)
                } else {
                    didStart = buddyStore.runNow(buddyWithID: buddy.id)
                }
                if !didStart { sendFailureMessage = "Its model is busy — try again in a moment." }
            }
            if !peers.isEmpty {
                Menu {
                    ForEach(peers) { peer in
                        Button(peer.modelChoice?.sendsDataOffThisMachine == true ? "\(peer.name) · cloud model" : peer.name) {
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

    private func progressDisclosure(for runRecord: AgentTaskRecord, buddy: WispBuddy) -> some View {
        let isExpanded = expandedRunIDs.contains(runRecord.id)
        return VStack(alignment: .leading, spacing: 5) {
            Button {
                withAnimation(WispMotion.smooth) {
                    if isExpanded { expandedRunIDs.remove(runRecord.id) } else { expandedRunIDs.insert(runRecord.id) }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(runRecord.steps.count == 1 ? "1 step" : "\(runRecord.steps.count) steps").font(.system(size: 11, weight: .medium))
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
                            Circle().fill(step.isError ? DS.Colors.destructive : WispColor.textTertiary).frame(width: 4, height: 4).padding(.top, 5)
                            Text(step.summary).font(.system(size: 11)).foregroundStyle(WispColor.textTertiary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 12)
                .transition(.opacity)
            }
        }
        .padding(.leading, 34)
    }

    // MARK: - Composer

    private func composer(for buddy: WispBuddy, isRunning: Bool) -> some View {
        let trimmedDraft = draftMessageText.trimmingCharacters(in: .whitespacesAndNewlines)
        let canSend = (!trimmedDraft.isEmpty || !pendingFileURLs.isEmpty) && !isRunning && !isSending
        let accent = BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex)
        return VStack(spacing: 8) {
            if !pendingFileURLs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { ForEach(pendingFileURLs, id: \.self) { pendingFileChip($0) } }
                }
                .transition(.opacity)
            }

            HStack(alignment: .bottom, spacing: 6) {
                BuddyIconButton(symbolName: "paperclip", label: "Attach files", tint: accent, size: 32) { chooseFiles() }

                TextField(isRunning ? "\(buddy.name) is working…" : "Message \(buddy.name)", text: $draftMessageText, axis: .vertical)
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
                        .foregroundStyle(canSend ? Color.white : WispColor.textTertiary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(canSend ? accent : WispColor.surface4.opacity(0.7)))
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
            let didStart = await buddyStore.sendMessage(messageText, attachmentFileURLs: fileURLs, toBuddyWithID: buddy.id)
            isSending = false
            if didStart {
                draftMessageText = ""
                withAnimation(WispMotion.smooth) { pendingFileURLs = [] }
            } else {
                sendFailureMessage = "Its model is busy — try again in a moment."
            }
        }
    }
}

private extension String {
    func nonEmptyOr(_ fallback: String) -> String {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : self
    }
}
