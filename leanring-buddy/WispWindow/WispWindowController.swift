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
import SwiftUI

@MainActor
final class WispWindowController: NSObject, NSWindowDelegate {
    /// The one instance, created by the app delegate at launch. Reached through
    /// `WispWindowNavigator.open(_:)` rather than directly.
    private(set) static weak var shared: WispWindowController?

    private var window: NSWindow?
    private let companionManager: CompanionManager

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

        // A hosting *controller* (not a bare hosting view) so SwiftUI can bridge
        // the page's navigation title and toolbar into the real window toolbar.
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.sceneBridgingOptions = [.title, .toolbars]

        let wispWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        wispWindow.contentViewController = hostingController
        wispWindow.title = "Wisp"
        wispWindow.toolbarStyle = .unified
        wispWindow.minSize = NSSize(width: 780, height: 520)
        wispWindow.setContentSize(NSSize(width: 1040, height: 700))
        wispWindow.collectionBehavior = [.fullScreenPrimary]
        wispWindow.delegate = self
        wispWindow.isReleasedWhenClosed = false
        wispWindow.center()
        // Reopens where the user last left it rather than always centered.
        wispWindow.setFrameAutosaveName("WispMainWindow")

        window = wispWindow

        WispWindowActivation.activateForWindow()
        wispWindow.makeKeyAndOrderFront(nil)
    }

    func closeWindow() {
        window?.close()
    }

    // MARK: - NSWindowDelegate

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
