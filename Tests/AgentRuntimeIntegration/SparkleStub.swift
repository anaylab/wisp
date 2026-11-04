// A compile-time stand-in for the Sparkle package, so the suites that compile every app source can
// keep using plain swiftc (no SwiftPM checkout, no xcodebuild). It declares only what
// Updates/WispUpdater.swift uses, with the same shapes as Sparkle 2.9.0's Swift interface. Nothing
// here updates anything, and these suites never start the updater.
//
// When WispUpdater starts using more of Sparkle, add it here or the suites stop compiling.

import Foundation

public final class SUAppcastItem: NSObject {
    public var displayVersionString: String { "" }
}

public final class SPUUserUpdateState: NSObject {}

public enum SPUUpdateCheck: Int {
    case updates
    case updatesInBackground
    case updateInformation
}

public final class SPUUpdater: NSObject {
    @objc public dynamic var canCheckForUpdates: Bool { false }
    public var automaticallyChecksForUpdates = false
    public var automaticallyDownloadsUpdates = false
    public var lastUpdateCheckDate: Date? { nil }
}

public protocol SPUUpdaterDelegate: NSObjectProtocol {
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?)
}

public protocol SPUStandardUserDriverDelegate: NSObjectProtocol {
    var supportsGentleScheduledUpdateReminders: Bool { get }
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    )
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem)
    func standardUserDriverWillFinishUpdateSession()
}

public final class SPUStandardUpdaterController: NSObject {
    public let updater = SPUUpdater()

    public init(
        startingUpdater: Bool,
        updaterDelegate: (any SPUUpdaterDelegate)?,
        userDriverDelegate: (any SPUStandardUserDriverDelegate)?
    ) {}

    public func startUpdater() {}
    public func checkForUpdates(_ sender: Any?) {}
}
