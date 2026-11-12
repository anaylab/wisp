//
//  ReplyPanelWindowController.swift
//  leanring-buddy
//
//  Where Wisp's answers appear: a card at the right edge of the screen, under
//  the menu bar, instead of dropping out of the notch. The island stays small
//  (state only) so a long reply no longer crowds it. The panel is
//  non-activating, so the user's app keeps focus while they read; it opens when
//  a reply or glance card lands and goes away on ✕, Esc-free click, or when
//  the next push-to-talk turn clears the screen.
//

import AppKit
import Combine
import SwiftUI

/// Whether answers open in the on-screen reply panel (default) or, as before,
/// in the notch island.
@MainActor
final class ReplyPanelPreference: ObservableObject {
    static let shared = ReplyPanelPreference()

    private static let userDefaultsKey = "wisp.replyPanel.isEnabled"

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.userDefaultsKey) }
    }

    private init() {
        // On unless the user switched it off.
        if UserDefaults.standard.object(forKey: Self.userDefaultsKey) == nil {
            isEnabled = true
        } else {
            isEnabled = UserDefaults.standard.bool(forKey: Self.userDefaultsKey)
        }
    }
}

@MainActor
final class ReplyPanelWindowController {
    private var panel: ReplyPanel?
    private let companionManager: CompanionManager
    private var cancellables = Set<AnyCancellable>()
    private var dismissObserver: NSObjectProtocol?
    /// The reply the user closed, so a card refresh of the same answer doesn't
    /// pop the panel back open.
    private var dismissedReplyText: String?

    private static let panelWidth: CGFloat = 380
    private static let edgeMargin: CGFloat = 14
    private static let maxPanelHeight: CGFloat = 560

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    deinit {
        if let dismissObserver {
            NotificationCenter.default.removeObserver(dismissObserver)
        }
    }

    func start() {
        Publishers.CombineLatest3(
            companionManager.$currentReplyText.removeDuplicates(),
            companionManager.$resolvedGlanceCard.map { $0 != nil }.removeDuplicates(),
            ReplyPanelPreference.shared.$isEnabled.removeDuplicates()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] replyText, hasCard, isEnabled in
            self?.update(replyText: replyText, hasCard: hasCard, isEnabled: isEnabled)
        }
        .store(in: &cancellables)

        // Push-to-talk clears Wisp's surfaces so they aren't in the screenshot.
        dismissObserver = NotificationCenter.default.addObserver(
            forName: .wispDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func update(replyText: String, hasCard: Bool, isEnabled: Bool) {
        let trimmed = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnabled, !trimmed.isEmpty || hasCard else {
            if trimmed.isEmpty { dismissedReplyText = nil }
            hide()
            return
        }
        if let dismissedReplyText, dismissedReplyText == trimmed { return }
        show()
    }

    private func show() {
        if panel == nil { createPanel() }
        guard let panel else { return }
        position(panel, height: panel.frame.height)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 1
            }
        }
    }

    private func hide() {
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func close() {
        dismissedReplyText = companionManager.currentReplyText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        companionManager.currentReplyText = ""
        companionManager.resolvedGlanceCard = nil
        hide()
    }

    private func createPanel() {
        let rootView = ReplyPanelView(
            companionManager: companionManager,
            onClose: { [weak self] in self?.close() },
            onContentHeight: { [weak self] height in self?.resize(toContentHeight: height) }
        )
        .frame(width: Self.panelWidth)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let replyPanel = ReplyPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        replyPanel.isFloatingPanel = true
        replyPanel.level = .floating
        replyPanel.isOpaque = false
        replyPanel.backgroundColor = .clear
        replyPanel.hasShadow = true
        replyPanel.hidesOnDeactivate = false
        replyPanel.isExcludedFromWindowsMenu = true
        replyPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        replyPanel.contentView = hostingView
        self.panel = replyPanel
    }

    private func resize(toContentHeight contentHeight: CGFloat) {
        guard let panel else { return }
        let height = min(max(contentHeight, 80), Self.maxPanelHeight)
        position(panel, height: height)
    }

    /// Top-right of the menu bar screen, just under the menu bar.
    private func position(_ panel: NSPanel, height: CGFloat) {
        guard let screen = NSScreen.screens.first else { return }
        let visibleFrame = screen.visibleFrame
        let frame = NSRect(
            x: visibleFrame.maxX - Self.panelWidth - Self.edgeMargin,
            y: visibleFrame.maxY - height - Self.edgeMargin,
            width: Self.panelWidth,
            height: height
        )
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
    }
}

/// Never takes focus, so the app the user is working in stays active.
final class ReplyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct ReplyPanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ReplyPanelBodyHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ReplyPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    let onClose: () -> Void
    let onContentHeight: (CGFloat) -> Void

    @State private var copied = false
    @State private var bodyHeight: CGFloat = 40

    private var hasReplyText: Bool {
        !companionManager.currentReplyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if hasReplyText {
                        NotchReplyText(replyText: companionManager.currentReplyText)
                    }
                    glanceCard
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 2)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ReplyPanelBodyHeightKey.self, value: proxy.size.height)
                    }
                )
            }
            .frame(height: min(max(bodyHeight, 1), 420))
            .onPreferenceChange(ReplyPanelBodyHeightKey.self) { bodyHeight = $0 }
            .scrollBounceBehavior(.basedOnSize)
            if hasReplyText { actions }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(WispColor.Island.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
        // The natural height of the card, so the window hugs a short answer.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ReplyPanelHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(ReplyPanelHeightKey.self) { onContentHeight($0) }
    }

    private var header: some View {
        HStack(spacing: 7) {
            WispMark(state: companionManager.islandState.markState, size: 15)
            Text("Wisp")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(WispColor.Island.textPrimary)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(WispColor.Island.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(WispColor.Island.controlFill))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            actionButton(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(companionManager.currentReplyText, forType: .string)
                copied = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.6))
                    copied = false
                }
            }
            actionButton("Open chat", systemImage: "bubble.left.and.text.bubble.right") {
                WispWindowNavigator.open(.chat)
            }
            Spacer(minLength: 0)
        }
    }

    private func actionButton(_ title: String, systemImage: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(WispColor.Island.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule(style: .continuous).fill(WispColor.Island.controlFill))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var glanceCard: some View {
        if let resolvedCard = companionManager.resolvedGlanceCard {
            switch resolvedCard {
            case let .generic(card): GlanceCardView(card: card)
            case let .weather(state): WeatherCardView(state: state)
            case let .calendar(state): CalendarCardView(state: state)
            case let .nowPlaying(state): NowPlayingCardView(state: state)
            case let .places(state): PlacesCardView(state: state)
            case let .source(state): SourceCardView(state: state)
            case let .reminders(state): RemindersCardView(state: state)
            case let .timer(state): TimerCardView(state: state)
            }
        }
    }
}
