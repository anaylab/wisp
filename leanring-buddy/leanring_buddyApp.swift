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
        // The app delegate builds every real surface (notch, menu, Wisp window).
        // SwiftUI still insists on one scene, so this empty Settings scene stands
        // in; with LSUIElement set there is no app menu to open it from.
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
    /// Set when another copy was already running and this one is quitting without starting:
    /// it must not save anything on the way out over the running copy's files.
    private var isQuittingAsSecondCopy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if SingleInstanceGuard.otherRunningInstance() != nil {
            print("🎯 Wisp: another copy is already running; asking it to show its window and quitting")
            isQuittingAsSecondCopy = true
            SingleInstanceGuard.notifyRunningInstanceThatSecondCopyLaunched()
            NSApp.terminate(nil)
            return
        }
        SingleInstanceGuard.observeSecondCopyLaunches {
            WispWindowNavigator.open(.home)
        }

        print("🎯 Wisp: Starting...")
        print("🎯 Wisp: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        // Before anything schedules work: automations and buddy jobs read it to wait for a Mac
        // that is awake and online.
        SystemReadinessMonitor.shared.start()

        menuBarMenuController = MenuBarMenuController(companionManager: companionManager)

        // The notch HUD is the resident primary surface. It shows on launch and
        // stays put.
        notchWindowController = NotchWindowController(companionManager: companionManager)
        notchWindowController?.show()

        // Reached through `WispWindowNavigator.open(_:)`.
        wispWindowController = WispWindowController(companionManager: companionManager)

        companionManager.start()
        // Parakeet (dictation) and Kokoro (voice) download on first launch and
        // load in the background; until each is ready, Apple's on-device
        // recogniser and synthesizer stand in, so launch never waits on them.
        FluidAudioSpeechModels.shared.preloadConfiguredModelsInBackground()
        startBrainServicesIfEnabled()
        // Open the window only when the user still needs to do something, which
        // means one of the permissions is missing; Today leads with the checklist.
        if !companionManager.allPermissionsGranted {
            WispWindowNavigator.open(.home)
        }
        registerAsLoginItemIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !isQuittingAsSecondCopy else { return }
        companionManager.stop()
        // After stop(), so any task it cancelled is saved in its final state.
        AgentTaskRegistry.shared.saveHistoryImmediately()
        // The queue batches its saves; flush so a job added just before quit resumes.
        BrainIngestQueue.shared.saveQueueNow()
        UsageLogStore.shared.saveImmediately()
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

    /// Makes Wisp start at login. SMAppService lists it under System Settings >
    /// General > Login Items, where the user can switch it off again.
    private func registerAsLoginItemIfNeeded() {
        let loginItem = SMAppService.mainApp
        guard loginItem.status != .enabled else { return }

        do {
            try loginItem.register()
            print("🎯 Wisp: Registered as login item")
        } catch {
            print("⚠️ Wisp: Failed to register as login item: \(error)")
        }
    }

}
