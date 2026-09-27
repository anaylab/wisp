//
//  ConversationWindowController.swift
//  leanring-buddy
//
//  Hosts the pop-out conversation window: the notch reply's "open in window"
//  button lifts the conversation out of the notch into a real, resizable window
//  (full screen capable) with the whole back-and-forth, a box for follow-ups,
//  and a side panel of the tasks Wisp is working on.
//
//  Like the dashboard it raises the app to `.regular` while open, so it gets a
//  dock icon, ⌘W and window cycling. `WispWindowActivation` makes the two
//  windows share that: closing one only drops back to menu-bar-only mode when
//  the other isn't open.
//

import AppKit
import SwiftUI

@MainActor
final class ConversationWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let companionManager: CompanionManager

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
    }

    /// Opens the conversation window, or brings it forward if it's already open.
    func showConversationWindow() {
        if let existingWindow = window {
            WispWindowActivation.activateForWindow()
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        let conversationView = ConversationWindowView(
            companionManager: companionManager,
            taskRegistry: AgentTaskRegistry.shared
        )

        let conversationWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        conversationWindow.title = "Wisp"
        conversationWindow.titlebarAppearsTransparent = true
        conversationWindow.contentView = NSHostingView(rootView: conversationView)
        conversationWindow.minSize = NSSize(width: 560, height: 420)
        // The green button takes it full screen, for when the conversation is
        // the thing being worked on.
        conversationWindow.collectionBehavior = [.fullScreenPrimary]
        conversationWindow.delegate = self
        conversationWindow.isReleasedWhenClosed = false
        conversationWindow.center()
        conversationWindow.setFrameAutosaveName("WispConversationWindow")

        window = conversationWindow

        WispWindowActivation.activateForWindow()
        conversationWindow.makeKeyAndOrderFront(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        let closingWindow = window
        window = nil
        // Deferred until the close completes, as the dashboard does, so AppKit
        // doesn't leave a stale dock icon behind.
        DispatchQueue.main.async {
            WispWindowActivation.returnToMenuBarOnlyModeIfNoWindowsRemain(excluding: closingWindow)
        }
    }
}

/// The activation-policy rules shared by Wisp's real windows (the dashboard and
/// the conversation window). A menu-bar app normally runs as `.accessory`; while
/// one of these windows is open it runs as `.regular` so the window behaves like
/// a normal Mac window. With two such windows, closing one must not drop the app
/// back to `.accessory` while the other is still on screen.
@MainActor
enum WispWindowActivation {
    static func activateForWindow() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Drops back to `.accessory` unless another titled, non-panel window is
    /// still visible. Panels (the notch, overlay, menu bar panel and text
    /// composer) don't count — they exist in menu-bar-only mode too.
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
