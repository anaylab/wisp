//
//  ChromePageWatchStore.swift
//  leanring-buddy
//
//  Runs Chrome page watchers (phase 08): "tell me when this tab says
//  Deployed", "when the price drops below $80", "check this page every 10
//  minutes and tell me when it says in stock". The watching itself happens in
//  the tab (the extension's content/page-watch.js); this store starts and
//  stops watches over the bridge, lists them for the notch, and turns the
//  extension's `watch.matched` / `watch.ended` events into the same endings a
//  screen watch has — a notification (silent in quiet mode), the island flash
//  and cue, and the line in the notch, spoken in voice mode, when Wisp is idle
//  (`CompanionManager.presentChromePageWatchEnding`). No model call.
//
//  The extension is the source of truth for which watches exist: they live in
//  Chrome's session storage and outlast a Wisp restart. So whenever the
//  extension connects, this store reads its list and takes it as its own —
//  adopting watches it didn't know about, and reporting the ones that ended
//  while it wasn't listening.
//
//  Local-only: everything goes over the loopback socket to the extension.
//

import Combine
import Foundation
import UserNotifications

/// A page watch that matched, for automations ("when my page watch fires …").
struct ChromePageWatchMatch: Equatable, Sendable {
    let watch: ActiveChromePageWatch
    let matchedText: String?
}

@MainActor
final class ChromePageWatchStore: ObservableObject {
    static let shared = ChromePageWatchStore()

    /// Mirrors the extension's MAXIMUM_ACTIVE_PAGE_WATCHES.
    static let maximumActiveWatchCount = 5
    static let requestTimeoutSeconds: Double = 15

    /// While any watch runs, the bridge keeps talking to the browser it runs
    /// in, so its `watch.matched` isn't dropped as another browser's event.
    @Published private(set) var activeWatches: [ActiveChromePageWatch] = [] {
        didSet {
            ChromeExtensionBridge.shared.setActiveBrowserHeld(!activeWatches.isEmpty, by: "page watches")
        }
    }

    /// Called when a watch ends on its own (matched, timed out, tab closed…) —
    /// not when the user stops it. Set once by `CompanionManager`.
    var onWatchEnded: ((ActiveChromePageWatch, ChromePageWatchEnding) -> Void)?
    /// Every match, for the `chromePageWatchMatched` automation trigger.
    let watchMatchedPublisher = PassthroughSubject<ChromePageWatchMatch, Never>()

    private var subscriptions: Set<AnyCancellable> = []
    private var hasStarted = false

    private init() {}

    enum StartOutcome: Equatable {
        case started(ActiveChromePageWatch)
        /// The same condition is already watched on that tab; left as is.
        case alreadyWatching(ActiveChromePageWatch)
        case tooManyWatches
    }

    enum WatchError: LocalizedError, Equatable {
        case extensionNotConnected
        case pagesReadNotAllowed
        case couldNotWatch(String)

        var errorDescription: String? {
            switch self {
            case .extensionNotConnected:
                return ChromePageReader.ReaderError.extensionNotConnected.errorDescription
            case .pagesReadNotAllowed:
                return "wisp isn't allowed to read pages in chrome yet, which watching a tab needs. to allow it, open wisp's settings → agent → chrome tabs → \"choose what wisp can do in chrome…\" and click allow next to read pages."
            case .couldNotWatch(let reason):
                return "i couldn't watch that tab: \(reason)."
            }
        }
    }

    // MARK: - Lifecycle

    /// Idempotent. Listens for the extension's watch events and re-reads its
    /// list on every connect.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        let bridge = ChromeExtensionBridge.shared
        bridge.extensionEventPublisher
            .filter { $0.eventName == "watch.matched" || $0.eventName == "watch.ended" }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] extensionEvent in
                MainActor.assumeIsolated { self?.handle(extensionEvent) }
            }
            .store(in: &subscriptions)

        bridge.$connectionState
            .map { connectionState -> Bool in
                if case .connected = connectionState { return true }
                return false
            }
            .removeDuplicates()
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.reconcileWithExtension() }
            }
            .store(in: &subscriptions)
    }

    /// Whether the app the user is in is Chrome with the extension connected —
    /// the app they were in, not Wisp, which a typed question activates.
    static var isChromeInFrontWithExtension: Bool {
        guard let frontmostBundleIdentifier = FrontmostAppTracker.shared.lastExternalApplication?.bundleIdentifier else { return false }
        return ChromePageReader.isConnectedExtension(inBrowserWithBundleIdentifier: frontmostBundleIdentifier)
    }

    // MARK: - Starting and stopping

    private struct StartParameters: Encodable {
        let tabId: Int?
        let condition: ChromePageWatchWireCondition
        let reloadEveryMinutes: Int?
        let label: String
    }

    private struct StopParameters: Encodable {
        let watchId: String?
        let all: Bool?
    }

    private struct NoParameters: Encodable {}

    /// Watches a tab — the showing one when `tabID` is nil — for `condition`.
    func startWatching(
        _ condition: ScreenWatchCondition,
        tabID: Int? = nil,
        reloadEveryMinutes: Int? = nil
    ) async throws -> StartOutcome {
        let bridge = ChromeExtensionBridge.shared
        guard bridge.isExtensionConnected else { throw WatchError.extensionNotConnected }
        guard bridge.hasCapability(.pagesRead) else { throw WatchError.pagesReadNotAllowed }
        guard activeWatches.count < Self.maximumActiveWatchCount else { return .tooManyWatches }
        if let tabID,
           let identicalWatch = activeWatches.first(where: { $0.tabID == tabID && $0.condition == condition && $0.reloadEveryMinutes == reloadEveryMinutes }) {
            return .alreadyWatching(identicalWatch)
        }

        let watchInfo: ChromePageWatchInfo
        do {
            watchInfo = try await bridge.sendRequest(
                method: "startPageWatch",
                parameters: StartParameters(
                    tabId: tabID,
                    condition: ChromePageWatchWireCondition(condition),
                    reloadEveryMinutes: reloadEveryMinutes,
                    label: condition.summaryText
                ),
                resultType: ChromePageWatchInfo.self,
                timeoutSeconds: Self.requestTimeoutSeconds
            )
        } catch ChromeExtensionBridge.BridgeError.extensionReportedError(let extensionMessage) {
            if extensionMessage.contains("missing capability pages.read") { throw WatchError.pagesReadNotAllowed }
            if extensionMessage.contains("already watching") { return .tooManyWatches }
            throw WatchError.couldNotWatch(extensionMessage)
        } catch ChromeExtensionBridge.BridgeError.extensionNotConnected {
            throw WatchError.extensionNotConnected
        }

        guard let newWatch = ActiveChromePageWatch(info: watchInfo, knownCondition: condition) else {
            throw WatchError.couldNotWatch("the extension's reply was unreadable")
        }
        // The showing tab was only known once the extension answered: a second
        // identical watch on it is dropped again.
        if reloadEveryMinutes == nil,
           let identicalWatch = activeWatches.first(where: { $0.tabID == newWatch.tabID && $0.condition == condition && $0.reloadEveryMinutes == nil }) {
            sendStopRequest(StopParameters(watchId: newWatch.id, all: nil))
            return .alreadyWatching(identicalWatch)
        }
        activeWatches.append(newWatch)
        // Asked now, while the user is here and expecting it, rather than at
        // the moment the watch fires.
        Self.requestNotificationAuthorizationIfNeeded()
        return .started(newWatch)
    }

    func stopWatching(watchID: String) {
        guard activeWatches.contains(where: { $0.id == watchID }) else { return }
        activeWatches.removeAll { $0.id == watchID }
        sendStopRequest(StopParameters(watchId: watchID, all: nil))
    }

    /// Stops every page watch. Returns how many Wisp knew of.
    @discardableResult
    func stopAllWatching() -> Int {
        let stoppedWatchCount = activeWatches.count
        activeWatches.removeAll()
        if ChromeExtensionBridge.shared.isExtensionConnected {
            sendStopRequest(StopParameters(watchId: nil, all: true))
        }
        return stoppedWatchCount
    }

    private func sendStopRequest(_ stopParameters: StopParameters) {
        Task { @MainActor in
            do {
                _ = try await ChromeExtensionBridge.shared.sendRequest(
                    method: "stopPageWatch",
                    parameters: stopParameters,
                    resultType: ChromePageWatchStopResult.self
                )
            } catch {
                // Already gone, or Chrome is closed: the next connect reconciles.
                print("👁️ Chrome page watch stop didn't reach the extension: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - The extension's side

    private func handle(_ extensionEvent: ChromeExtensionEvent) {
        switch extensionEvent.eventName {
        case "watch.matched":
            guard let matchedPayload = extensionEvent.decodePayload(as: ChromePageWatchMatchedPayload.self) else { return }
            endWatch(withID: matchedPayload.watchId, ending: .conditionMet(matchedText: matchedPayload.matchedText))
        case "watch.ended":
            guard let endedPayload = extensionEvent.decodePayload(as: ChromePageWatchEndedPayload.self) else { return }
            endWatch(withID: endedPayload.watchId, ending: ChromePageWatchEnding(extensionReason: endedPayload.reason, matchedText: nil))
        default:
            break
        }
    }

    /// Takes the extension's list as the truth after a (re)connect.
    func reconcileWithExtension() async {
        let extensionList: ChromePageWatchList
        do {
            extensionList = try await ChromeExtensionBridge.shared.sendRequest(
                method: "listPageWatches",
                parameters: NoParameters(),
                resultType: ChromePageWatchList.self
            )
        } catch {
            // An extension older than phase 08 doesn't know the method; it has no watches either.
            return
        }
        let outcome = ChromePageWatchReconciliation.reconcile(knownWatches: activeWatches, extensionList: extensionList)
        activeWatches = outcome.activeWatches
        for endedWatch in outcome.endedWatches {
            announceEnding(of: endedWatch.watch, ending: endedWatch.ending)
        }
    }

    private func endWatch(withID watchID: String, ending: ChromePageWatchEnding) {
        guard let endedWatch = activeWatches.first(where: { $0.id == watchID }) else { return }
        activeWatches.removeAll { $0.id == watchID }
        announceEnding(of: endedWatch, ending: ending)
    }

    private func announceEnding(of endedWatch: ActiveChromePageWatch, ending: ChromePageWatchEnding) {
        print("👁️ Chrome page watch ended (\(endedWatch.condition.summaryText)): \(ending)")
        Self.postNotification(for: endedWatch, ending: ending)
        if case .conditionMet(let matchedText) = ending {
            watchMatchedPublisher.send(ChromePageWatchMatch(watch: endedWatch, matchedText: matchedText))
        }
        onWatchEnded?(endedWatch, ending)
    }

    // MARK: - Notification

    private static func requestNotificationAuthorizationIfNeeded() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    /// The ending as a system notification, so it reaches the user in another
    /// app or Space. Silent in quiet mode (a call), like a screen watch's.
    private static func postNotification(for endedWatch: ActiveChromePageWatch, ending: ChromePageWatchEnding) {
        let notificationBody = ChromePageWatchWording.endingMessage(for: endedWatch, ending: ending)
        let notificationTitle = ending.isConditionMet ? "Page watch" : "Stopped watching"
        let shouldPlaySound = !QuietModeMonitor.shared.isQuiet

        Task {
            let notificationCenter = UNUserNotificationCenter.current()
            let isAuthorized = (try? await notificationCenter.requestAuthorization(options: [.alert, .sound])) ?? false
            guard isAuthorized else { return }

            let content = UNMutableNotificationContent()
            content.title = notificationTitle
            content.body = notificationBody.prefix(1).uppercased() + notificationBody.dropFirst()
            content.sound = shouldPlaySound ? .default : nil

            try? await notificationCenter.add(
                UNNotificationRequest(
                    identifier: "wisp.page-watch.\(endedWatch.id)",
                    content: content,
                    trigger: nil
                )
            )
        }
    }
}
