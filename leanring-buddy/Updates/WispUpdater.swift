//
//  WispUpdater.swift
//  leanring-buddy
//
//  Automatic updates through Sparkle. Started at launch; it does nothing at all unless this copy may
//  update itself (`WispUpdatePolicy`), so a copy built in Xcode never contacts the feed.
//
//  Wisp lives in the menu bar and rarely quits, and Sparkle would normally open an alert in front of
//  whatever the user is doing. So scheduled checks stay quiet ("gentle reminders"): an update downloads
//  in the background and installs the next time Wisp quits. If Wisp is still running at a later check,
//  the menu bar gets an "Update to Wisp 0.2…" item and one notification. A check the user asked for
//  still shows Sparkle's own window straight away.
//

import AppKit
import Combine
import Sparkle
import UserNotifications

@MainActor
final class WispUpdater: NSObject, ObservableObject {
    static let shared = WispUpdater()

    private static let lastNotifiedVersionUserDefaultsKey = "wisp.updates.lastNotifiedVersion"

    let availability: WispUpdateAvailability

    /// False while Sparkle is already checking or showing an update.
    @Published private(set) var canCheckForUpdates = false
    /// An update waiting for the user, found by a scheduled check. Nil once they've seen it.
    @Published private(set) var pendingUpdateVersion: String?
    @Published private(set) var lastUpdateCheckDate: Date?

    private var updaterController: SPUStandardUpdaterController?
    private var canCheckForUpdatesCancellable: AnyCancellable?

    private override init() {
        availability = WispUpdatePolicy.availability(
            publicEDKey: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            feedURLString: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            isDemoMode: WispDemoMode.isOn,
            bundlePath: Bundle.main.bundlePath
        )
        super.init()
    }

    var versionDescription: String {
        WispUpdatePolicy.versionDescription(
            shortVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    /// Safe to call once at launch; a copy that may not update stops here.
    func startIfAvailable() {
        guard availability == .available, updaterController == nil else {
            print("🔄 Updates: off (\(availability))")
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        updaterController = controller
        canCheckForUpdatesCancellable = controller.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canCheckForUpdates in
                self?.canCheckForUpdates = canCheckForUpdates
            }
        controller.startUpdater()
        lastUpdateCheckDate = controller.updater.lastUpdateCheckDate
    }

    /// Also how a pending update comes back into focus: Sparkle shows the one it already holds.
    func checkForUpdates() {
        guard let updaterController else { return }
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(nil)
    }

    /// Off means Wisp never contacts the feed unless the user presses Check Now.
    var automaticallyChecksForUpdates: Bool {
        get { updaterController?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            updaterController?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { updaterController?.updater.automaticallyDownloadsUpdates ?? false }
        set {
            objectWillChange.send()
            updaterController?.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    private func notifyAboutPendingUpdateIfNeeded(pendingVersion: String) {
        let userDefaults = UserDefaults.standard
        guard WispUpdatePolicy.shouldNotifyAboutPendingUpdate(
            pendingVersion: pendingVersion,
            lastNotifiedVersion: userDefaults.string(forKey: Self.lastNotifiedVersionUserDefaultsKey),
            isQuietModeActive: QuietModeMonitor.shared.isQuiet
        ) else { return }
        userDefaults.set(pendingVersion, forKey: Self.lastNotifiedVersionUserDefaultsKey)

        Task {
            let notificationCenter = UNUserNotificationCenter.current()
            let isAuthorized = (try? await notificationCenter.requestAuthorization(options: [.alert])) ?? false
            guard isAuthorized else { return }

            let content = UNMutableNotificationContent()
            content.title = "Wisp \(pendingVersion) is ready"
            content.body = "Update from the Wisp menu in the menu bar, or it installs the next time Wisp quits."
            try? await notificationCenter.add(
                UNNotificationRequest(identifier: "wisp.update.\(pendingVersion)", content: content, trigger: nil)
            )
        }
    }
}

// MARK: - Sparkle's update cycle

extension WispUpdater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        lastUpdateCheckDate = updater.lastUpdateCheckDate
    }
}

// MARK: - Sparkle's update window

extension WispUpdater: SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Never for a scheduled check: Wisp's own quiet cues replace Sparkle's alert. Sparkle doesn't ask
    /// about a check the user started; it shows those itself.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        pendingUpdateVersion = update.displayVersionString
        notifyAboutPendingUpdateIfNeeded(pendingVersion: update.displayVersionString)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        pendingUpdateVersion = nil
    }

    /// Dismissed, skipped or failed: the next scheduled check brings it back if it still applies.
    func standardUserDriverWillFinishUpdateSession() {
        pendingUpdateVersion = nil
    }
}
