//
//  MailInboxPage.swift
//  leanring-buddy
//
//  The Inbox: the user's Mail sorted into Important and Everything else, with
//  replies Wisp wrote ahead. A thread list on the left, the selected thread on
//  the right, settings in a sheet. Off until the user turns it on here.
//
//  Everything shown comes from `MailInboxEngine`; this view sends nothing.
//  Reply opens the email composer, where Send is the user's own click.
//

import SwiftUI

struct MailInboxPage: View {
    @ObservedObject private var engine = MailInboxEngine.shared
    @ObservedObject private var preferences = MailInboxPreferences.shared

    @State private var selectedCategory: MailInboxCategory = .important
    @State private var selectedThreadKey: String?
    @State private var isShowingSettings = false

    var body: some View {
        Group {
            if preferences.isEnabled {
                enabledContent
            } else {
                introduction
            }
        }
        .background(WispColor.windowBackground)
        .sheet(isPresented: $isShowingSettings) {
            MailInboxSettingsSheet(isPresented: $isShowingSettings)
        }
    }

    // MARK: - Turned off

    private var introduction: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DashboardCard(title: "Inbox") {
                    Text("Wisp reads your mail from the Mail app, sorts it into Important and Everything else, and writes replies ahead for the emails that ask you something.")
                        .foregroundStyle(WispColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 6) {
                        bullet("lock", "Mail is read and sorted on this Mac by the local model. Nothing is uploaded.")
                        bullet("paperplane", "Nothing is ever sent for you. A reply opens for you to edit; Send is your click.")
                        bullet("tray.2", "Covers every account you've added to Mail. Mail needs to be open for Wisp to check it.")
                    }
                    Button("Turn on Inbox") {
                        preferences.isEnabled = true
                        engine.syncNow()
                    }
                    .buttonStyle(WispPillButtonStyle())
                    .controlSize(.regular)
                    .pointerCursor()
                    .padding(.top, 4)
                }
            }
            .padding(20)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func bullet(_ symbolName: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbolName)
                .font(.system(size: 12))
                .foregroundStyle(WispColor.accentText)
                .frame(width: 16)
            Text(text)
                .font(.callout)
                .foregroundStyle(WispColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Turned on

    private var visibleThreads: [MailInboxThread] {
        engine.threads(in: selectedCategory)
    }

    private var selectedThread: MailInboxThread? {
        guard let selectedThreadKey else { return nil }
        return engine.threads.first { $0.threadKey == selectedThreadKey }
    }

    private var enabledContent: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                threadList
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 400)
                Divider()
                Group {
                    if let selectedThread {
                        MailInboxThreadDetail(thread: selectedThread)
                            .id(selectedThread.threadKey)
                    } else {
                        Text(visibleThreads.isEmpty ? "" : "Choose an email")
                            .foregroundStyle(WispColor.textTertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            WispSegmented(
                options: MailInboxCategory.allCases,
                title: { category in
                    let count = engine.threads(in: category).count
                    return count > 0 ? "\(category.title)  \(count)" : category.title
                },
                selection: $selectedCategory
            )
            .frame(maxWidth: 320)
            Spacer(minLength: 8)
            syncStatus
            Button {
                engine.syncNow()
            } label: {
                Label("Sync now", systemImage: "arrow.clockwise")
            }
            .buttonStyle(WispPillButtonStyle(isProminent: false))
            .controlSize(.small)
            .disabled(isSyncing)
            .pointerCursor()
            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(WispPillButtonStyle(isProminent: false))
            .controlSize(.small)
            .accessibilityLabel("Inbox settings")
            .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var isSyncing: Bool {
        if case .syncing = engine.syncPhase { return true }
        return false
    }

    @ViewBuilder
    private var syncStatus: some View {
        switch engine.syncPhase {
        case .syncing(let text):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(text).font(.caption).foregroundStyle(WispColor.textSecondary)
            }
        case .failed(let message):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(WispColor.warning)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(WispColor.warningText)
                    .lineLimit(2)
            }
            .frame(maxWidth: 360, alignment: .trailing)
        case .idle:
            if let lastSyncAt = engine.lastSyncAt {
                Text("Checked \(lastSyncAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(WispColor.textTertiary)
            }
        }
    }

    private var threadList: some View {
        Group {
            if visibleThreads.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: selectedCategory == .important ? "checkmark.circle" : "tray")
                        .font(.system(size: 26))
                        .foregroundStyle(WispColor.textTertiary)
                    Text(emptyListText)
                        .font(.callout)
                        .foregroundStyle(WispColor.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(visibleThreads) { thread in
                            MailInboxThreadRow(
                                thread: thread,
                                isSelected: thread.threadKey == selectedThreadKey,
                                action: { selectedThreadKey = thread.threadKey }
                            )
                        }
                    }
                    .padding(8)
                }
            }
        }
    }

    private var emptyListText: String {
        if engine.lastSyncAt == nil { return "Wisp hasn't checked Mail yet. Open Mail, then press Sync now." }
        return selectedCategory == .important ? "Nothing important in the last two weeks." : "Nothing else here."
    }
}

// MARK: - Row

private struct MailInboxThreadRow: View {
    let thread: MailInboxThread
    let isSelected: Bool
    let action: () -> Void

    @ObservedObject private var engine = MailInboxEngine.shared
    @State private var isHovered = false

    var body: some View {
        let latest = thread.latestMessage
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(thread.hasUnread ? WispColor.accent : Color.clear)
                    .frame(width: 7, height: 7)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(latest.senderName.isEmpty ? latest.senderAddress : latest.senderName)
                            .font(.body.weight(thread.hasUnread ? .semibold : .regular))
                            .foregroundStyle(WispColor.textPrimary)
                            .lineLimit(1)
                        if thread.messages.count > 1 {
                            Text("\(thread.messages.count)")
                                .font(.caption2)
                                .foregroundStyle(WispColor.textTertiary)
                        }
                        Spacer(minLength: 4)
                        Text(Self.shortTime(latest.receivedAt))
                            .font(.caption)
                            .foregroundStyle(WispColor.textTertiary)
                    }
                    Text(latest.subject.isEmpty ? "(no subject)" : latest.subject)
                        .font(.callout)
                        .foregroundStyle(WispColor.textPrimary)
                        .lineLimit(1)
                    Text(MailInboxImportancePolicy.previewLine(of: latest.bodyExcerpt))
                        .font(.caption)
                        .foregroundStyle(WispColor.textSecondary)
                        .lineLimit(2)
                    chips
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? WispColor.surface3 : (isHovered ? WispColor.surface2 : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerCursor()
    }

    @ViewBuilder
    private var chips: some View {
        let isAnswered = engine.isAnswered(thread)
        let hasDraft = engine.draft(for: thread) != nil && !isAnswered
        let isDrafting = engine.threadKeysBeingDrafted.contains(thread.threadKey)
        let reason = engine.verdict(for: thread)?.reason ?? "Not sorted yet"
        HStack(spacing: 6) {
            if hasDraft {
                chip("Draft ready", symbolName: "pencil.line", isAccent: true)
            } else if isDrafting {
                chip("Writing…", symbolName: "ellipsis", isAccent: true)
            }
            if isAnswered {
                chip("Answered", symbolName: "arrowshape.turn.up.left", isAccent: false)
            }
            chip(reason, symbolName: nil, isAccent: false)
        }
        .padding(.top, 2)
    }

    private func chip(_ text: String, symbolName: String?, isAccent: Bool) -> some View {
        HStack(spacing: 3) {
            if let symbolName { Image(systemName: symbolName).font(.system(size: 9)) }
            Text(text).font(.caption2)
        }
        .foregroundStyle(isAccent ? WispColor.accentText : WispColor.textTertiary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(isAccent ? WispColor.accentSubtle : WispColor.surface2))
    }

    static func shortTime(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Detail

private struct MailInboxThreadDetail: View {
    let thread: MailInboxThread

    @ObservedObject private var engine = MailInboxEngine.shared

    var body: some View {
        let latest = thread.latestMessage
        let category = engine.category(of: thread)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(latest.subject.isEmpty ? "(no subject)" : latest.subject)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(WispColor.textPrimary)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Button {
                        engine.reply(to: thread)
                    } label: {
                        Label(engine.draft(for: thread) != nil ? "Open reply" : "Write a reply", systemImage: "arrowshape.turn.up.left")
                    }
                    .buttonStyle(WispPillButtonStyle())
                    .controlSize(.small)
                    .disabled(engine.threadKeysBeingDrafted.contains(thread.threadKey))
                    .pointerCursor()
                    Button("Open in Mail") { engine.openInMail(thread) }
                        .buttonStyle(WispPillButtonStyle(isProminent: false))
                        .controlSize(.small)
                        .pointerCursor()
                    Button(category == .important ? "Not important" : "Mark important") {
                        engine.move(thread, to: category == .important ? .everythingElse : .important)
                    }
                    .buttonStyle(WispPillButtonStyle(isProminent: false))
                    .controlSize(.small)
                    .help("Wisp remembers this for everything from \(latest.senderAddress)")
                    .pointerCursor()
                }
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let draft = engine.draft(for: thread), !engine.isAnswered(thread) {
                        draftPreview(draft)
                    }
                    ForEach(thread.messages.reversed()) { message in
                        messageCard(message)
                    }
                }
                .padding(16)
            }
        }
    }

    private func draftPreview(_ draft: MailInboxDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Reply Wisp wrote", systemImage: "pencil.line")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WispColor.accentText)
                Spacer()
                Text("Not sent")
                    .font(.caption2)
                    .foregroundStyle(WispColor.textTertiary)
            }
            Text(draft.body)
                .font(.callout)
                .foregroundStyle(WispColor.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(WispColor.accentSubtle))
    }

    private func messageCard(_ message: MailInboxMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(message.senderName.isEmpty ? message.senderAddress : "\(message.senderName)  <\(message.senderAddress)>")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(WispColor.textPrimary)
                    .textSelection(.enabled)
                Spacer()
                Text(message.receivedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(WispColor.textTertiary)
            }
            Text(MailInboxImportancePolicy.bodyForReading(message.bodyExcerpt))
                .font(.callout)
                .foregroundStyle(WispColor.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if message.bodyExcerpt.count >= MailInboxLimits.bodyExcerptCharacterCount {
                Text("Wisp only keeps the start of long emails. Open in Mail for the rest.")
                    .font(.caption)
                    .foregroundStyle(WispColor.textTertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(WispColor.surface1))
    }
}

// MARK: - Settings

private struct MailInboxSettingsSheet: View {
    @Binding var isPresented: Bool

    @ObservedObject private var preferences = MailInboxPreferences.shared
    @ObservedObject private var engine = MailInboxEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Inbox settings")
                .font(.title3.weight(.semibold))
            SettingRow(title: "Write replies ahead", detail: "For important mail that asks you something. Never sent.") {
                Toggle("Write replies ahead", isOn: $preferences.draftsAhead).labelsHidden().toggleStyle(.switch)
            }
            SettingRow(
                title: "Use Wisp's chat model",
                detail: !preferences.usesChatModel
                    ? "Off: mail is read by the local model on this Mac."
                    : BuddyChatProviderSelection.current.sendsScreenshotsOffThisMachine
                        ? "Your email goes to \(BuddyChatProviderSelection.current.displayName) to be sorted and answered."
                        : "On: \(BuddyChatProviderSelection.current.displayName) reads your mail, still on this Mac."
            ) {
                Toggle("Use Wisp's chat model", isOn: $preferences.usesChatModel).labelsHidden().toggleStyle(.switch)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("What matters to you").font(.body.weight(.medium))
                settingsTextEditor(text: $preferences.userRules, placeholder: "Anything from my professors. Invoices are not important.", height: 64)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("How you write").font(.body.weight(.medium))
                settingsTextEditor(text: $preferences.styleNotes, placeholder: "Short and warm. Sign off with “Best”.", height: 48)
            }
            Divider()
            HStack {
                Button("Turn off Inbox") {
                    preferences.isEnabled = false
                    isPresented = false
                }
                .buttonStyle(WispPillButtonStyle(isProminent: false))
                .pointerCursor()
                Button("Forget stored mail") { engine.clearStoredMail() }
                    .buttonStyle(WispPillButtonStyle(isProminent: false))
                    .help("Removes Wisp's copy of your recent mail and drafts. Your mail in Mail isn't touched.")
                    .pointerCursor()
                Spacer()
                Button("Done") { isPresented = false }
                    .buttonStyle(WispPillButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .pointerCursor()
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    /// A multi-line field drawn as a field (fill + hairline), like the Brain's paste box, with a
    /// grey example inside while it's empty.
    private func settingsTextEditor(text: Binding<String>, placeholder: String, height: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.callout)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: WispRadius.small, style: .continuous)
                    .fill(WispColor.groupedCardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: WispRadius.small, style: .continuous)
                    .strokeBorder(WispColor.cardSeparator, lineWidth: 0.5)
            )
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(.callout)
                        .foregroundStyle(WispColor.textTertiary)
                        .padding(.top, 7).padding(.leading, 11)
                        .allowsHitTesting(false)
                }
            }
    }
}
