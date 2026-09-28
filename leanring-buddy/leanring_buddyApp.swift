//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No Dock icon by default: Wisp lives in the
//  notch (where you use it), a menu bar menu, and the Wisp window (where you
//  manage it), which gives the app a Dock icon only while it's open.
//

import ServiceManagement
import SwiftUI

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app's surfaces (notch, menu, Wisp window) are managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the notch, the menu bar menu and
/// the Wisp window, and starts the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarMenuController: MenuBarMenuController?
    private var notchWindowController: NotchWindowController?
    private let companionManager = CompanionManager()
    private var wispWindowController: WispWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Wisp: Starting...")
        print("🎯 Wisp: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        WispAnalytics.configure()
        WispAnalytics.trackAppOpened()

        menuBarMenuController = MenuBarMenuController(companionManager: companionManager)

        // The notch HUD is the resident primary surface. It shows on launch and
        // stays put.
        notchWindowController = NotchWindowController(companionManager: companionManager)
        notchWindowController?.show()

        // Reached through `WispWindowNavigator.open(_:)`.
        wispWindowController = WispWindowController(companionManager: companionManager)

        companionManager.start()
        // Open the window only when the user still needs to do something, which
        // means one of the permissions is missing; Today leads with the checklist.
        if !companionManager.allPermissionsGranted {
            WispWindowNavigator.open(.home)
        }
        registerAsLoginItemIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
        // After stop(), so any task it cancelled is saved in its final state.
        AgentTaskRegistry.shared.saveHistoryImmediately()
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
