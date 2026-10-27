//
//  EmailComposerWindowController.swift
//  leanring-buddy
//
//  The email composer: a floating panel with To / Cc / Subject / Body that
//  opens the moment the user says "draft an email…". The model writes the
//  draft into it while it is up, every field stays editable, and Send (⌘↩)
//  hands it to the Mail app. Nothing is sent by Wisp on its own — the user's
//  click on Send, on a draft they can see, is the consent.
//
//  Like the text composer it needs the keyboard, so the panel can become key
//  and the app is activated while it is up. Unlike the text composer it does
//  not close when it loses focus: people switch apps to look something up
//  while writing an email, and a draft that vanished would lose their edits.
//

import AppKit
import Combine
import SwiftUI

/// The composer's state, shared by the controller (which fills it) and the view.
@MainActor
final class EmailComposerModel: ObservableObject {
    enum Phase: Equatable {
        /// The model is writing; subject and body wait for it.
        case writing
        case ready
        /// Mail has the draft; buttons are held until it answers.
        case sending
    }

    @Published var draftFields: EmailDraftFields
    @Published var phase: Phase
    /// A problem or notice shown above the buttons ("“sam” isn't an email address").
    @Published var noticeText: String?
    @Published var isCcFieldShown: Bool
    @Published var isConfirmingDiscard = false
    @Published var didJustCopy = false

    /// What Wisp last put in the fields. Edits are anything different, and only
    /// then does Esc ask before throwing the draft away.
    private var lastFilledDraftFields: EmailDraftFields

    /// Set while a failed draft can be written again.
    var retryWriting: (() -> Void)?

    init(draftFields: EmailDraftFields, isWriting: Bool) {
        self.draftFields = draftFields
        self.lastFilledDraftFields = draftFields
        self.phase = isWriting ? .writing : .ready
        self.isCcFieldShown = !draftFields.ccField.isEmpty
    }

    var hasUserEdits: Bool { draftFields != lastFilledDraftFields }

    /// Puts the model's draft in, keeping anything the user already typed in
    /// To while it was writing.
    func fillWrittenDraft(subject: String, body: String, toAddressFromScreen: String?) {
        if draftFields.toField.trimmingCharacters(in: .whitespaces).isEmpty, let toAddressFromScreen {
            draftFields.toField = toAddressFromScreen
        }
        if draftFields.subject.isEmpty { draftFields.subject = subject }
        draftFields.body = body
        lastFilledDraftFields = draftFields
        noticeText = nil
        retryWriting = nil
        phase = .ready
    }

    func showWritingFailure(_ failureText: String, retry: (() -> Void)?) {
        noticeText = failureText
        retryWriting = retry
        phase = .ready
    }
}

@MainActor
final class EmailComposerWindowController {
    static let shared = EmailComposerWindowController()

    private var panel: TextComposerPanel?
    private(set) var model: EmailComposerModel?
    /// The model call writing the current draft; cancelled if the user
    /// discards the draft before it finishes.
    var draftWritingTask: Task<Void, Never>?

    /// Told after Mail accepted a send, so the notch can say so.
    var onEmailSent: ((EmailDraftFields) -> Void)?

    private let initialComposerSize = CGSize(width: 560, height: 500)
    private let minimumComposerSize = CGSize(width: 420, height: 340)

    var isShowing: Bool { panel != nil }

    /// Opens a fresh composer. A draft already open is replaced: the newest
    /// request is the one the user is talking about.
    @discardableResult
    func open(with initialDraftFields: EmailDraftFields, isWriting: Bool) -> EmailComposerModel {
        close()
        let composerModel = EmailComposerModel(draftFields: initialDraftFields, isWriting: isWriting)
        model = composerModel
        createPanel(for: composerModel)
        positionPanel()
        // A background (LSUIElement) app's panel will not take keyboard focus
        // unless the app is active, so activate before making the panel key.
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        return composerModel
    }

    func close() {
        draftWritingTask?.cancel()
        draftWritingTask = nil
        panel?.orderOut(nil)
        panel = nil
        model = nil
    }

    // MARK: - Actions

    fileprivate func send() {
        guard let model, model.phase == .ready else { return }
        if let problemBeforeSending = EmailAddressList.problemBeforeSending(model.draftFields) {
            model.noticeText = problemBeforeSending
            return
        }
        model.phase = .sending
        model.noticeText = nil
        let draftFieldsToSend = model.draftFields
        Task { @MainActor [weak self] in
            // Let "Sending…" draw before AppleScript holds the main thread —
            // Mail can take a few seconds to launch the first time.
            try? await Task.sleep(nanoseconds: 60_000_000)
            do {
                try MailAppSender.send(draftFieldsToSend)
                self?.close()
                self?.onEmailSent?(draftFieldsToSend)
            } catch {
                model.phase = .ready
                model.noticeText = error.localizedDescription
            }
        }
    }

    fileprivate func openInMail() {
        guard let model, model.phase == .ready else { return }
        do {
            try MailAppSender.openInMail(model.draftFields)
            close()
        } catch {
            model.noticeText = error.localizedDescription
        }
    }

    fileprivate func openInGmail() {
        guard let model, let gmailComposeURL = EmailComposeLinks.gmailComposeURL(for: model.draftFields) else { return }
        NSWorkspace.shared.open(gmailComposeURL)
        close()
    }

    fileprivate func copyDraftText() {
        guard let model else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(EmailComposeLinks.plainText(for: model.draftFields), forType: .string)
        model.didJustCopy = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            model.didJustCopy = false
        }
    }

    /// Esc: closes an untouched draft at once, and asks first once the user
    /// has changed anything.
    fileprivate func requestDiscard() {
        guard let model else { return }
        if model.hasUserEdits && !model.isConfirmingDiscard {
            model.isConfirmingDiscard = true
        } else {
            close()
        }
    }

    // MARK: - Panel

    private func createPanel(for composerModel: EmailComposerModel) {
        let composerView = EmailComposerView(
            model: composerModel,
            onSend: { [weak self] in self?.send() },
            onOpenInMail: { [weak self] in self?.openInMail() },
            onOpenInGmail: { [weak self] in self?.openInGmail() },
            onCopy: { [weak self] in self?.copyDraftText() },
            onRequestDiscard: { [weak self] in self?.requestDiscard() },
            onDiscard: { [weak self] in self?.close() }
        )

        let hostingView = NSHostingView(rootView: composerView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let composerPanel = TextComposerPanel(
            contentRect: NSRect(origin: .zero, size: initialComposerSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        composerPanel.isFloatingPanel = true
        composerPanel.level = .floating
        composerPanel.isOpaque = false
        composerPanel.backgroundColor = .clear
        composerPanel.hasShadow = true
        composerPanel.hidesOnDeactivate = false
        composerPanel.isMovableByWindowBackground = true
        composerPanel.isExcludedFromWindowsMenu = true
        composerPanel.minSize = minimumComposerSize
        composerPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        composerPanel.contentView = hostingView
        panel = composerPanel
    }

    private func positionPanel() {
        guard let panel, let targetScreen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visibleFrame = targetScreen.visibleFrame
        let originX = visibleFrame.midX - initialComposerSize.width / 2
        // Just under the notch, where the answer to the request appeared.
        let originY = visibleFrame.maxY - 48 - initialComposerSize.height
        panel.setFrame(
            NSRect(x: originX, y: max(originY, visibleFrame.minY), width: initialComposerSize.width, height: initialComposerSize.height),
            display: true
        )
    }
}

// MARK: - View

struct EmailComposerView: View {
    @ObservedObject var model: EmailComposerModel
    let onSend: () -> Void
    let onOpenInMail: () -> Void
    let onOpenInGmail: () -> Void
    let onCopy: () -> Void
    let onRequestDiscard: () -> Void
    let onDiscard: () -> Void

    private enum ComposerField: Hashable {
        case to, cc, subject, body
    }
    @FocusState private var focusedField: ComposerField?

    private var isWriting: Bool { model.phase == .writing }
    private var isSending: Bool { model.phase == .sending }

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            addressRow(label: "To", text: $model.draftFields.toField, field: .to, showsCcToggle: !model.isCcFieldShown)
            if model.isCcFieldShown {
                hairline
                addressRow(label: "Cc", text: $model.draftFields.ccField, field: .cc, showsCcToggle: false)
            }
            hairline
            subjectRow
            hairline
            bodyEditor
            if let noticeText = model.noticeText {
                noticeBanner(noticeText)
            }
            if model.isConfirmingDiscard {
                discardConfirmation
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous))
        .onExitCommand(perform: onRequestDiscard)
        .onAppear {
            // Defer a tick so the fields are in the hierarchy before focusing.
            DispatchQueue.main.async {
                focusedField = model.draftFields.toField.isEmpty ? .to : (isWriting ? nil : .body)
            }
        }
        .onChange(of: model.phase) { _, newPhase in
            if newPhase == .ready, focusedField == nil || focusedField == .subject {
                focusedField = model.draftFields.toField.isEmpty ? .to : .body
            }
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(DS.Colors.borderSubtle)
            .frame(height: 1)
    }

    private var header: some View {
        HStack(spacing: 9) {
            WispMark(state: isWriting ? .thinking : (isSending ? .acting : .idle), size: 16)
            Text("New email")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            if isWriting {
                Text("Writing…")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer()
            Button(action: onRequestDiscard) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(DS.Colors.surface2))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Discard draft (esc)")
            .accessibilityLabel("Discard draft")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func addressRow(label: String, text: Binding<String>, field: ComposerField, showsCcToggle: Bool) -> some View {
        HStack(spacing: 10) {
            fieldLabel(label)
            // Verbatim: as a localized key the address would render as a link.
            TextField(text: text, prompt: Text(verbatim: "name@example.com").foregroundColor(DS.Colors.textTertiary)) { EmptyView() }
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
                .focused($focusedField, equals: field)
                .disabled(isSending)
            if showsCcToggle {
                Button("Cc") {
                    model.isCcFieldShown = true
                    DispatchQueue.main.async { focusedField = .cc }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .pointerCursor()
                .help("Add Cc")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private var subjectRow: some View {
        HStack(spacing: 10) {
            fieldLabel("Subject")
            TextField(isWriting ? "" : "Subject", text: $model.draftFields.subject)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .focused($focusedField, equals: .subject)
                .disabled(isSending)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func fieldLabel(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 12))
            .foregroundColor(DS.Colors.textTertiary)
            .frame(width: 52, alignment: .leading)
    }

    private var bodyEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $model.draftFields.body)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
                .scrollContentBackground(.hidden)
                .focused($focusedField, equals: .body)
                .disabled(isWriting || isSending)
                .opacity(isWriting ? 0 : 1)
            if isWriting {
                writingPlaceholder
            } else if model.draftFields.body.isEmpty {
                Text("Write your email…")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Soft lines standing in for the text while the model writes it.
    private var writingPlaceholder: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach([0.35, 0.92, 0.84, 0.6], id: \.self) { lineWidthFraction in
                GeometryReader { geometry in
                    Capsule()
                        .fill(DS.Colors.surface2)
                        .frame(width: geometry.size.width * lineWidthFraction, height: 9)
                }
                .frame(height: 9)
            }
        }
        .padding(.horizontal, 5)
        .padding(.top, 6)
        .accessibilityLabel("Wisp is writing the draft")
    }

    private func noticeBanner(_ noticeText: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .foregroundColor(DS.Colors.warningText)
            Text(noticeText)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let retryWriting = model.retryWriting {
                Button("Try again", action: retryWriting)
                    .buttonStyle(WispPillButtonStyle(isProminent: false))
                    .controlSize(.small)
                    .pointerCursor()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(DS.Colors.surface2)
    }

    private var discardConfirmation: some View {
        HStack(spacing: 8) {
            Text("Discard this draft?")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
            Spacer()
            Button("Keep editing") { model.isConfirmingDiscard = false }
                .buttonStyle(WispPillButtonStyle(isProminent: false))
                .controlSize(.small)
                .pointerCursor()
            Button("Discard", action: onDiscard)
                .buttonStyle(WispPillButtonStyle.destructive)
                .controlSize(.small)
                .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(DS.Colors.surface2)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Open in Mail", action: onOpenInMail)
                Button("Open in Gmail", action: onOpenInGmail)
                Divider()
                Button(model.didJustCopy ? "Copied" : "Copy Text", action: onCopy)
            } label: {
                Text("More")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .disabled(isWriting || isSending)
            .pointerCursor(isEnabled: !(isWriting || isSending))

            Text(model.didJustCopy ? "Copied" : "Sends from your Mail account")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)

            Spacer()

            Button("Discard", action: onRequestDiscard)
                .buttonStyle(WispPillButtonStyle(isProminent: false))
                .disabled(isSending)
                .pointerCursor(isEnabled: !isSending)

            Button(action: onSend) {
                HStack(spacing: 6) {
                    if isSending {
                        ProgressView().controlSize(.small)
                    }
                    Text(isSending ? "Sending…" : "Send")
                    if !isSending {
                        Text("⌘↩")
                            .font(.system(size: 10, weight: .medium))
                            .opacity(0.7)
                    }
                }
            }
            .buttonStyle(WispPillButtonStyle())
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(isWriting || isSending)
            .pointerCursor(isEnabled: !(isWriting || isSending))
            .accessibilityLabel("Send email")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
