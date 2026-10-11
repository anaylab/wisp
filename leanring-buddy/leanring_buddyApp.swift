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
import AppIntents

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

    override init() {
        super.init()
        // Siri, Spotlight and Shortcuts run Wisp's App Intents in this process
        // (`WispAppIntents.swift`); they reach the live companion through this.
        // Registered at init, before any intent can be performed.
        let liveCompanionManager = companionManager
        AppDependencyManager.shared.add(dependency: liveCompanionManager)
    }

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
        startBrainServicesIfEnabled()
        // Siri's phrases that name a routine or buddy use their current names.
        WispAppShortcuts.updateAppShortcutParameters()
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
        // The queue batches its saves; flush so a job added just before quit resumes.
        BrainIngestQueue.shared.saveQueueNow()
    }

    /// Opens the brain (`~/.wisp/brain/`) and starts the services that keep
    /// it: the ingest queue (and its inbox watcher), the conversation digest,
    /// the activity recorder (which itself stays off unless the user opted
    /// in) and the periodic lint. None of them runs while the brain's master
    /// switch is off — "off" means nothing reads from or writes to it.
    ///
    /// The one-time move of memory.md's facts into the me page runs first, so
    /// the first turn's "about the user" block already has them.
    private func startBrainServicesIfEnabled() {
        guard BrainPreferences.shared.isBrainEnabled else { return }
        // Touching the store creates the vault on first launch and loads it.
        _ = BrainStore.shared
        BrainMemoryMigration.migrateIfNeeded()
        BrainIngestQueue.shared.start()
        BrainConversationDigester.shared.start()
        BrainActivityRecorder.shared.start()
        BrainMaintenance.shared.start()
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
