//
//  TextComposerWindowController.swift
//  leanring-buddy
//
//  The text composer: a small floating input that opens when the user taps the
//  Talk chord (instead of holding it to speak). It reuses the same turn pipeline
//  as voice — the typed question is answered aloud and pointed at on screen —
//  so it is purely an alternative input method for people who would rather type.
//
//  Unlike the notch HUD (which must never take focus), the composer needs the
//  keyboard, so its panel can become key and the app is activated while it is
//  up — the same pattern a Spotlight-style input uses.
//

import AppKit
import SwiftUI

@MainActor
final class TextComposerWindowController {
    private var panel: TextComposerPanel?
    private let onSubmit: (String) -> Void
    /// Whether a selected part of the screen is still the subject of the
    /// conversation, asked each time the composer opens.
    private let hasFocusedScreenRegion: () -> Bool
    /// The chip's ✕: forget the selection (and its highlight).
    private let onClearFocusedScreenRegion: () -> Void
    private var resignKeyObserver: NSObjectProtocol?

    private let composerSize = CGSize(width: 460, height: 104)

    init(
        onSubmit: @escaping (String) -> Void,
        hasFocusedScreenRegion: @escaping () -> Bool = { false },
        onClearFocusedScreenRegion: @escaping () -> Void = {}
    ) {
        self.onSubmit = onSubmit
        self.hasFocusedScreenRegion = hasFocusedScreenRegion
        self.onClearFocusedScreenRegion = onClearFocusedScreenRegion
    }

    deinit {
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
        }
    }

    /// Whether the composer is on screen right now.
    var isShowing: Bool { panel != nil }

    func show() {
        if panel == nil {
            createPanel()
        }
        positionPanel()
        // A background (LSUIElement) app's panel will not take keyboard focus
        // unless the app is active, so activate before making the panel key.
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
    }

    func hide() {
        // Destroy the panel (rather than just ordering it out) so the SwiftUI
        // view is recreated fresh next time — otherwise its `@State` text would
        // persist and the composer would reopen showing the previous query.
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
            self.resignKeyObserver = nil
        }
        panel?.orderOut(nil)
        panel = nil
    }

    private func createPanel() {
        let composerView = TextComposerView(
            hasFocusedScreenRegion: hasFocusedScreenRegion(),
            onClearFocusedScreenRegion: onClearFocusedScreenRegion,
            onSubmit: { [weak self] typedText in
                self?.hide()
                self?.onSubmit(typedText)
            },
            onCancel: { [weak self] in
                self?.hide()
            }
        )

        let hostingView = NSHostingView(rootView: composerView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let composerPanel = TextComposerPanel(
            contentRect: NSRect(origin: .zero, size: composerSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        composerPanel.isFloatingPanel = true
        composerPanel.level = .floating
        composerPanel.isOpaque = false
        composerPanel.backgroundColor = .clear
        composerPanel.hasShadow = true
        composerPanel.hidesOnDeactivate = false
        composerPanel.isExcludedFromWindowsMenu = true
        composerPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        composerPanel.contentView = hostingView
        self.panel = composerPanel

        // Dismiss when the user clicks away and the panel stops being key.
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: composerPanel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hide()
            }
        }
    }

    private func positionPanel() {
        guard let panel, let menuBarScreen = NSScreen.screens.first else { return }
        let screenFrame = menuBarScreen.frame
        let originX = screenFrame.midX - composerSize.width / 2
        // Sit a little below the top of the screen, just under the notch.
        let originY = screenFrame.maxY - 96 - composerSize.height
        panel.setFrame(
            NSRect(x: originX, y: originY, width: composerSize.width, height: composerSize.height),
            display: true
        )
    }
}

/// A panel that can become key (so the text field accepts typing) but never
/// becomes main.
final class TextComposerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct TextComposerView: View {
    let hasFocusedScreenRegion: Bool
    let onClearFocusedScreenRegion: () -> Void
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var typedText = ""
    @State private var isFocusedScreenRegionChipShown: Bool

    init(
        hasFocusedScreenRegion: Bool,
        onClearFocusedScreenRegion: @escaping () -> Void,
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.hasFocusedScreenRegion = hasFocusedScreenRegion
        self.onClearFocusedScreenRegion = onClearFocusedScreenRegion
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _isFocusedScreenRegionChipShown = State(initialValue: hasFocusedScreenRegion)
    }
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                WispMark(size: 16, animated: false)

                TextField("Ask Wisp…", text: $typedText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundColor(DS.Colors.textPrimary)
                    .focused($isFieldFocused)
                    .onSubmit(submit)
            }

            HStack(spacing: 12) {
                if isFocusedScreenRegionChipShown {
                    focusedRegionChip
                }
                // "About: selected text" etc. for a part of a Chrome page.
                ChromeAskAboutThisComposerChip()
                keyHint("return", meaning: "send")
                keyHint("esc", meaning: "dismiss")
                Spacer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
        .onExitCommand(perform: onCancel)
        .onAppear {
            // Defer a tick so the field is in the hierarchy before focusing.
            DispatchQueue.main.async {
                isFieldFocused = true
            }
        }
    }

    /// Says the question is about the part of the screen the user chose, and
    /// lets them drop it to ask about the whole screen again.
    private var focusedRegionChip: some View {
        Button {
            isFocusedScreenRegionChipShown = false
            onClearFocusedScreenRegion()
        } label: {
            HStack(spacing: 5) {
                Text("About: selected part")
                    .font(.system(size: 10, weight: .medium))
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundColor(DS.Colors.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule(style: .continuous).fill(DS.Colors.surface2))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel("Asking about the selected part of the screen. Clear selection.")
    }

    private func submit() {
        let trimmedText = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            onCancel()
            return
        }
        onSubmit(trimmedText)
    }

    private func keyHint(_ key: String, meaning: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .fill(DS.Colors.surface2)
                )
            Text(meaning)
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }
}
