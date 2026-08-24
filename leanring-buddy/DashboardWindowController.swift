//
//  DashboardWindowController.swift
//  leanring-buddy
//
//  Hosts the dashboard in a real, resizable window.
//
//  Everything else in this app lives in borderless non-activating panels,
//  which is right for something momentary that must never steal focus. The
//  dashboard is the opposite: content you read, scroll, select text in, and
//  leave open beside your work, so it wants an ordinary window with a title
//  bar and the usual keyboard shortcuts.
//
//  That requires a temporary change of activation policy. The app runs as
//  an accessory (LSUIElement) with no dock icon and no menu bar of its own,
//  and an accessory app cannot own a normal key window with working ⌘W/⌘Q.
//  So the policy is raised to .regular while the dashboard is open and
//  dropped back to .accessory when it closes, leaving the menu-bar-only
//  behaviour intact the rest of the time.
//

import AppKit
import SwiftUI

@MainActor
final class DashboardWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let companionManager: CompanionManager

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
    }

    /// Opens the dashboard, or brings it forward if it's already open.
    func showDashboard() {
        if let existingWindow = window {
            activateForDashboard()
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        let dashboardView = DashboardView(
            companionManager: companionManager,
            taskRegistry: AgentTaskRegistry.shared,
            metricsRecorder: PerfMetricsRecorder.shared
        )

        let hostingView = NSHostingView(rootView: dashboardView)

        let dashboardWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        dashboardWindow.title = "Wisp"
        dashboardWindow.titlebarAppearsTransparent = true
        dashboardWindow.backgroundColor = NSColor(DS.Colors.background)
        dashboardWindow.contentView = hostingView
        dashboardWindow.minSize = NSSize(width: 720, height: 460)
        dashboardWindow.delegate = self
        dashboardWindow.isReleasedWhenClosed = false
        dashboardWindow.center()
        // Reopens where the user last left it rather than always centered.
        dashboardWindow.setFrameAutosaveName("WispDashboardWindow")

        window = dashboardWindow

        activateForDashboard()
        dashboardWindow.makeKeyAndOrderFront(nil)
    }

    func closeDashboard() {
        window?.close()
    }

    var isDashboardOpen: Bool {
        window?.isVisible ?? false
    }

    // MARK: - Activation policy

    private func activateForDashboard() {
        // .regular gives the window a dock icon and a real menu bar, which is
        // what makes ⌘W, ⌘Q and window cycling behave as users expect.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func returnToMenuBarOnlyMode() {
        // Back to accessory so Wisp disappears from the dock and app
        // switcher again — the menu bar item remains the only entry point.
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window = nil

        // Defer until the close completes, otherwise AppKit can leave a
        // stale dock icon behind.
        DispatchQueue.main.async { [weak self] in
            self?.returnToMenuBarOnlyMode()
        }
    }
}
