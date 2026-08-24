//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import ServiceManagement
import SwiftUI

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()
    private var dashboardWindowController: DashboardWindowController?
    private var openDashboardObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Wisp: Starting...")
        print("🎯 Wisp: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        WispAnalytics.configure()
        WispAnalytics.trackAppOpened()

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)

        let dashboardController = DashboardWindowController(companionManager: companionManager)
        dashboardWindowController = dashboardController
        openDashboardObserver = NotificationCenter.default.addObserver(
            forName: .wispOpenDashboard,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                NotificationCenter.default.post(name: .wispDismissPanel, object: nil)
                dashboardController.showDashboard()
            }
        }

        companionManager.start()
        // Auto-open the panel only when the user still needs to do something,
        // which now means one of the permissions is missing.
        if !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        registerAsLoginItemIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 Wisp: Registered as login item")
            } catch {
                print("⚠️ Wisp: Failed to register as login item: \(error)")
            }
        }
    }

}
