//
//  WispWindowController.swift
//  leanring-buddy
//
//  Hosts the Wisp window: one real, resizable Mac window for everything that
//  isn't momentary — today's overview, the conversation, buddies, routines,
//  history, connections and settings.
//
//  Everything else in this app lives in borderless non-activating panels, which
//  is right for something momentary that must never steal focus. This window is
//  the opposite: content you read, scroll, select text in and leave open beside
//  your work, so it's an ordinary window with a unified toolbar and the usual
//  keyboard shortcuts.
//
//  That requires a temporary change of activation policy. The app runs as an
//  accessory (LSUIElement) with no Dock icon, and an accessory app cannot own a
//  normal key window with working ⌘W/⌘Q. So the policy is raised to .regular
//  while the window is open and dropped back to .accessory when it closes.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class WispWindowController: NSObject, NSWindowDelegate {
    /// The one instance, created by the app delegate at launch. Reached through
    /// `WispWindowNavigator.open(_:)` rather than directly.
    private(set) static weak var shared: WispWindowController?

    private var window: NSWindow?
    private let companionManager: CompanionManager
    private var appearanceObservation: AnyCancellable?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        Self.shared = self
    }

    var isWindowOpen: Bool {
        window?.isVisible ?? false
    }

    /// Opens the window at the router's current page, or brings it forward.
    func showWindow() {
        if let existingWindow = window {
            WispWindowActivation.activateForWindow()
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        let rootView = WispWindowView(
            companionManager: companionManager,
            taskRegistry: AgentTaskRegistry.shared,
            metricsRecorder: PerfMetricsRecorder.shared,
            router: WispWindowRouter.shared
        )

        // The shell draws its own top bar in place of the title bar, so nothing
        // from SwiftUI is bridged into the window's title or toolbar.
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.sceneBridgingOptions = []

        let wispWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        wispWindow.contentViewController = hostingController
        wispWindow.title = "Wisp"
        wispWindow.titleVisibility = .hidden
        wispWindow.titlebarAppearsTransparent = true
        wispWindow.minSize = NSSize(width: 780, height: 520)
        wispWindow.setContentSize(NSSize(width: 1040, height: 700))
        wispWindow.collectionBehavior = [.fullScreenPrimary]
        wispWindow.delegate = self
        wispWindow.isReleasedWhenClosed = false
        wispWindow.center()
        // Reopens where the user last left it rather than always centered.
        wispWindow.setFrameAutosaveName("WispMainWindow")

        window = wispWindow
        positionTrafficLights()

        // Light, dark or system, for this window only.
        // A theme made for dark (Midnight) also holds the window dark, so the choice
        // is re-applied whenever the theme changes as well as the mode.
        appearanceObservation = WispAppearancePreference.shared.$mode
            .combineLatest(
                NotificationCenter.default.publisher(for: .wispThemeDidChange)
                    .map { _ in () }
                    .prepend(())
            )
            .sink { [weak wispWindow] mode, _ in
                wispWindow?.appearance = WispAppearancePreference.effectiveAppearance(
                    for: mode,
                    theme: WispThemeStore.currentThemeNow
                )
            }

        WispWindowActivation.activateForWindow()
        wispWindow.makeKeyAndOrderFront(nil)
    }

    /// Centres the traffic lights on the top bar. The system sizes the title bar
    /// for 28pt and puts the buttons in it; the bar is taller, so the title bar's
    /// container is grown to match and the buttons re-centred. AppKit resets this
    /// whenever the window lays out, so it runs again on resize and when the
    /// window becomes key.
    private func positionTrafficLights() {
        guard let window,
              let closeButton = window.standardWindowButton(.closeButton),
              let titlebarView = closeButton.superview,
              let titlebarContainer = titlebarView.superview else { return }
        let barHeight = WispWindowView.topBarHeight
        titlebarContainer.frame = NSRect(
            x: titlebarContainer.frame.origin.x,
            y: window.frame.height - barHeight,
            width: titlebarContainer.frame.width,
            height: barHeight
        )
        titlebarView.frame = NSRect(x: 0, y: 0, width: titlebarContainer.frame.width, height: barHeight)
        for buttonKind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(buttonKind) else { continue }
            button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: (barHeight - button.frame.height) / 2))
        }
    }

    func closeWindow() {
        window?.close()
    }

    // MARK: - NSWindowDelegate

    func windowDidResize(_ notification: Notification) { positionTrafficLights() }
    func windowDidBecomeKey(_ notification: Notification) { positionTrafficLights() }

    func windowWillClose(_ notification: Notification) {
        let closingWindow = window
        window = nil

        // Defer until the close completes, otherwise AppKit can leave a stale
        // Dock icon behind.
        DispatchQueue.main.async {
            WispWindowActivation.returnToMenuBarOnlyModeIfNoWindowsRemain(excluding: closingWindow)
        }
    }
}

/// The activation-policy rules for Wisp's real windows. A menu-bar app normally
/// runs as `.accessory`; while a titled window is open it runs as `.regular` so
/// the window behaves like a normal Mac window.
@MainActor
enum WispWindowActivation {
    static func activateForWindow() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Drops back to `.accessory` unless another titled, non-panel window is
    /// still visible. Panels (the notch, overlay and text composer) don't count —
    /// they exist in menu-bar-only mode too.
    static func returnToMenuBarOnlyModeIfNoWindowsRemain(excluding closingWindow: NSWindow?) {
        let isAnotherWindowStillOpen = NSApp.windows.contains { candidateWindow in
            candidateWindow !== closingWindow
                && candidateWindow.isVisible
                && candidateWindow.styleMask.contains(.titled)
                && !(candidateWindow is NSPanel)
        }
        guard !isAnotherWindowStillOpen else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}
