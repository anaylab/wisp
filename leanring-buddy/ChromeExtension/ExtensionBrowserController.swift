//
//  ExtensionBrowserController.swift
//  leanring-buddy
//
//  The browser agent's controller when the Wisp Tabs extension can do the job:
//  the same `BrowserController` contract as `AppleScriptBrowserController`,
//  carried over the loopback WebSocket to handlers/dom-controller.js and
//  content/dom-agent.js instead of AppleScript-injected JavaScript.
//
//  What that buys:
//  * Wisp's task tab can stay in the background. It is opened behind the
//    user's tab in a purple "Wisp" tab group (expanded while working, collapsed
//    when idle unless the user is looking at it), so the user keeps reading.
//  * The working tab is a real Chrome tab id — no Safari-style window+index
//    guesswork. A closed tab still means stop: `tab.removed` for that id (or a
//    request that finds it gone) ends the session with `.dedicatedTabClosed`.
//  * Cross-origin frames are read too (ids like `f4e3`).
//
//  The snapshot JSON is decoded by `BrowserPageSnapshotDecoding`, the same code
//  the AppleScript controller uses, so the page text the planners, validator
//  and prompts see is identical. `BrowserControllerSelector` decides per task
//  which controller serves it.
//
//  Calls are `async` (see the note on `BrowserController`): each is one request
//  through `ChromeExtensionBridge.sendRequest`, awaited on the main actor.
//

import AppKit
import Combine
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class ExtensionBrowserController: BrowserController {
    private let bridge: ChromeExtensionBridge

    /// Wisp's task tab, while it exists. Chrome tab ids last for the browser
    /// session only, so this is never persisted.
    private var dedicatedTabID: Int?
    /// The browser the task tab lives in. A tab id means nothing in another
    /// browser, so when the bridge has moved on to a different browser the
    /// remembered tab is forgotten instead of reused.
    private var dedicatedTabBrowserID: String?
    /// The name this controller holds the bridge's active browser under while
    /// a task drives its tab.
    private static let activeBrowserHolderName = "browser task tab"
    /// True for the duration of a browser task. Outside one, every operation
    /// targets the tab in front of the user, as `read_page` expects.
    private var isDrivingDedicatedTab = false
    /// Set when the working tab disappears mid-task. Every later operation in
    /// the session then fails rather than quietly acting in the user's tab.
    private var dedicatedTabWasLost = false
    private var tabRemovedSubscription: AnyCancellable?

    /// Screenshots for the vision fallback are capped like every other capture
    /// Wisp sends a model (see `CompanionScreenCaptureUtility`).
    private static let screenshotMaximumPixelSize = 896

    init(bridge: ChromeExtensionBridge = .shared) {
        self.bridge = bridge
        tabRemovedSubscription = bridge.extensionEventPublisher
            .filter { $0.eventName == "tab.removed" }
            .sink { [weak self] event in
                guard let removedTab = event.decodePayload(as: RemovedTabPayload.self) else { return }
                MainActor.assumeIsolated {
                    self?.handleTabRemoved(tabID: removedTab.id)
                }
            }
    }

    private struct RemovedTabPayload: Decodable {
        let id: Int
    }

    private func handleTabRemoved(tabID: Int) {
        guard tabID == dedicatedTabID else { return }
        dedicatedTabID = nil
        if isDrivingDedicatedTab { dedicatedTabWasLost = true }
    }

    // MARK: - Availability

    var browserName: String {
        if case .connected(_, let connectedBrowserName) = bridge.connectionState { return connectedBrowserName }
        return "Google Chrome"
    }

    func checkAvailability() -> BrowserAvailability {
        guard bridge.isExtensionConnected else { return .notRunning(browserName: browserName) }
        guard bridge.hasCapability(.pagesRead) else {
            return .extensionNeedsPermission(
                browserName: browserName,
                instructions: "Wisp can't read pages in Chrome yet: click the Wisp Tabs extension → Permissions… → Allow reading pages."
            )
        }
        return .ready(browserName: browserName)
    }

    // MARK: - Wisp's own tab

    func beginDedicatedTabSession() async throws -> BrowserTabDescription? {
        let availability = checkAvailability()
        guard availability.isReady else { throw BrowserControllerError.unavailable(availability) }

        // What the user had in front of them, so a task about "this page" can
        // still find it.
        let usersPage = try? await readUsersFrontPage()

        dedicatedTabWasLost = false
        bridge.setActiveBrowserHeld(true, by: Self.activeBrowserHolderName)
        if dedicatedTabBrowserID != bridge.activeBrowserID {
            dedicatedTabID = nil
        }
        do {
            if let existingTabID = dedicatedTabID, await regroupDedicatedTab(existingTabID, collapsed: false) {
                // A follow-up task continues in the same tab, like a conversation
                // continuing on the same page.
            } else {
                let openedTab = try await perform(
                    "openTab",
                    ["url": .string("about:blank"), "active": .bool(false), "inWispGroup": .bool(true)],
                    resultType: OpenedTabReply.self
                )
                guard openedTab.tabId >= 0 else {
                    throw BrowserControllerError.scriptFailed("Couldn't open a tab to work in.")
                }
                dedicatedTabID = openedTab.tabId
                dedicatedTabBrowserID = bridge.activeBrowserID
            }
        } catch {
            // `BrowserAgent` doesn't end a session that failed to begin.
            bridge.setActiveBrowserHeld(false, by: Self.activeBrowserHolderName)
            throw error
        }
        isDrivingDedicatedTab = true
        return usersPage
    }

    func endDedicatedTabSession() {
        // The tab is kept, holding the result, and reused by the next task. The
        // group folds away unless the user is looking at the tab.
        isDrivingDedicatedTab = false
        dedicatedTabWasLost = false
        // The browser stays held until the group is folded, so that last
        // request can't reach a browser the user switched to meanwhile.
        if let dedicatedTabID {
            Task { [weak self] in
                _ = await self?.regroupDedicatedTab(dedicatedTabID, collapsed: true)
                self?.bridge.setActiveBrowserHeld(false, by: Self.activeBrowserHolderName)
            }
        } else {
            bridge.setActiveBrowserHeld(false, by: Self.activeBrowserHolderName)
        }
    }

    func revealDedicatedTab() async {
        guard let dedicatedTabID, dedicatedTabBrowserID == bridge.activeBrowserID else { return }
        _ = try? await perform("focusTab", ["tabId": .number(Double(dedicatedTabID))], resultType: JSONValue.self)
    }

    private struct OpenedTabReply: Decodable {
        let tabId: Int
        let windowId: Int?
        let groupId: Int?
    }

    /// Puts the task tab (back) in the Wisp group. False when the tab is gone.
    private func regroupDedicatedTab(_ tabID: Int, collapsed: Bool) async -> Bool {
        do {
            _ = try await bridge.sendRequest(
                method: "getOrCreateWispGroup",
                parameters: JSONValue.object(["tabIds": .array([.number(Double(tabID))]), "collapsed": .bool(collapsed)]),
                resultType: JSONValue.self
            )
            return true
        } catch {
            return false
        }
    }

    private func readUsersFrontPage() async throws -> BrowserTabDescription? {
        let tabsSnapshot = try await perform("getTabs", [:], resultType: ChromeTabsSnapshot.self)
        guard let frontTab = tabsSnapshot.tabs.first(where: {
            $0.active && $0.windowId == tabsSnapshot.focusedWindowId
        }) ?? tabsSnapshot.tabs.first(where: \.active) else { return nil }
        guard frontTab.url.hasPrefix("http") else { return nil }
        return BrowserTabDescription(url: frontTab.url, title: frontTab.title)
    }

    // MARK: - Requests

    /// `tabId` for the tab operations should target: Wisp's own tab during a
    /// task, otherwise none (the extension then uses the user's front tab).
    private func targetTabParameters() throws -> [String: JSONValue] {
        guard isDrivingDedicatedTab else { return [:] }
        guard !dedicatedTabWasLost, let dedicatedTabID else { throw BrowserControllerError.dedicatedTabClosed }
        return ["tabId": .number(Double(dedicatedTabID))]
    }

    /// One request to the extension, with its failure turned into a
    /// `BrowserControllerError` — the lost-tab one when that is why.
    private func perform<Result: Decodable>(
        _ method: String,
        _ parameters: [String: JSONValue],
        resultType: Result.Type,
        timeoutSeconds: Double? = nil
    ) async throws -> Result {
        do {
            if let timeoutSeconds {
                return try await bridge.sendRequest(
                    method: method, parameters: JSONValue.object(parameters),
                    resultType: Result.self, timeoutSeconds: timeoutSeconds
                )
            }
            return try await bridge.sendRequest(method: method, parameters: JSONValue.object(parameters), resultType: Result.self)
        } catch let bridgeError as ChromeExtensionBridge.BridgeError {
            if isDrivingDedicatedTab,
               case .extensionReportedError(let message) = bridgeError,
               ExtensionBrowserReplies.isMissingTabErrorMessage(message) {
                dedicatedTabID = nil
                dedicatedTabWasLost = true
                throw BrowserControllerError.dedicatedTabClosed
            }
            throw BrowserControllerError.scriptFailed(bridgeError.localizedDescription)
        }
    }

    private struct ActionReply: Decodable {
        let status: String
    }

    private func performElementAction(
        _ method: String,
        elementID: String,
        action: ExtensionElementAction,
        extraParameters: [String: JSONValue] = [:]
    ) async throws {
        guard let safeElementID = ExtensionBrowserReplies.sanitizedElementID(elementID) else {
            throw BrowserControllerError.elementNotFound(elementID)
        }
        var parameters = try targetTabParameters()
        parameters["elementId"] = .string(safeElementID)
        parameters.merge(extraParameters) { _, extra in extra }
        let reply = try await perform(method, parameters, resultType: ActionReply.self)
        if let actionError = ExtensionBrowserReplies.error(forActionStatus: reply.status, action: action, elementID: elementID) {
            throw actionError
        }
    }

    // MARK: - Navigation

    func openURL(_ url: URL) async throws {
        // Inside a task, "open" means this task's tab.
        if isDrivingDedicatedTab {
            try await navigate(to: url)
            return
        }
        _ = try await perform(
            "openTab",
            ["url": .string(url.absoluteString), "active": .bool(true), "inWispGroup": .bool(false)],
            resultType: OpenedTabReply.self
        )
    }

    func navigate(to url: URL) async throws {
        var parameters = try targetTabParameters()
        parameters["url"] = .string(url.absoluteString)
        _ = try await perform("navigateTab", parameters, resultType: JSONValue.self)
    }

    func goBack() async throws {
        _ = try await perform("goBackInTab", try targetTabParameters(), resultType: JSONValue.self)
    }

    func goForward() async throws {
        _ = try await perform("goForwardInTab", try targetTabParameters(), resultType: JSONValue.self)
    }

    func currentURL() async throws -> String {
        try await targetTab().url
    }

    func pageTitle() async throws -> String {
        try await targetTab().title
    }

    /// The tab operations target, as `getTabs` describes it.
    private func targetTab() async throws -> ChromeTab {
        let targetTabID = try targetTabParameters()["tabId"]
        let tabsSnapshot = try await perform("getTabs", [:], resultType: ChromeTabsSnapshot.self)
        if case .number(let wantedTabID)? = targetTabID {
            guard let tab = tabsSnapshot.tabs.first(where: { Double($0.id) == wantedTabID }) else {
                dedicatedTabWasLost = true
                throw BrowserControllerError.dedicatedTabClosed
            }
            return tab
        }
        guard let frontTab = tabsSnapshot.tabs.first(where: { $0.active && $0.windowId == tabsSnapshot.focusedWindowId })
                ?? tabsSnapshot.tabs.first(where: \.active) else {
            throw BrowserControllerError.scriptFailed("No Chrome tab is open.")
        }
        return frontTab
    }

    // MARK: - Reading the page

    func snapshot(maximumTextCharacters: Int, elementLimit: Int) async throws -> BrowserPageSnapshot {
        var parameters = try targetTabParameters()
        parameters["maximumTextCharacters"] = .number(Double(maximumTextCharacters))
        parameters["elementLimit"] = .number(Double(elementLimit))
        let reply = try await perform("snapshotPage", parameters, resultType: JSONValue.self, timeoutSeconds: 15)
        guard let replyData = try? JSONEncoder().encode(reply),
              let pageSnapshot = BrowserPageSnapshotDecoding.snapshot(fromJSONData: replyData) else {
            throw BrowserControllerError.scriptFailed("The page returned something unreadable.")
        }
        return pageSnapshot
    }

    func findElements(matching query: String) async throws -> [BrowserElement] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var parameters = try targetTabParameters()
        parameters["query"] = .string(query)
        let reply = try await perform("findElements", parameters, resultType: JSONValue.self, timeoutSeconds: 15)
        guard let replyData = try? JSONEncoder().encode(reply) else { return [] }
        return BrowserPageSnapshotDecoding.elements(fromJSONData: replyData)
    }

    // MARK: - Acting

    func click(elementID: String) async throws {
        try await performElementAction("clickElement", elementID: elementID, action: .click)
    }

    func typeText(_ text: String, intoElementID elementID: String, pressEnter: Bool) async throws {
        try await performElementAction(
            "typeIntoElement", elementID: elementID, action: .typeText,
            extraParameters: ["text": .string(text), "pressEnter": .bool(pressEnter)]
        )
    }

    func hover(elementID: String) async throws {
        try await performElementAction("hoverElement", elementID: elementID, action: .hover)
    }

    func selectOption(_ optionLabel: String, inElementID elementID: String) async throws {
        try await performElementAction(
            "selectOption", elementID: elementID, action: .selectOption(optionLabel: optionLabel),
            extraParameters: ["optionLabel": .string(optionLabel)]
        )
    }

    func pressKey(_ keyName: String) async throws {
        // The same fixed list as the AppleScript controller.
        guard let canonicalKeyName = AppleScriptBrowserController.supportedKeyNames.first(where: {
            $0.lowercased() == keyName.lowercased().replacingOccurrences(of: " ", with: "")
        }) else {
            throw BrowserControllerError.scriptFailed(
                "Can't press \"\(keyName)\". Supported: \(AppleScriptBrowserController.supportedKeyNames.sorted().joined(separator: ", "))."
            )
        }
        var parameters = try targetTabParameters()
        parameters["key"] = .string(canonicalKeyName)
        let reply = try await perform("pressKey", parameters, resultType: ActionReply.self)
        if let keyError = ExtensionBrowserReplies.error(
            forActionStatus: reply.status, action: .pressKey(keyName: canonicalKeyName), elementID: ""
        ) {
            throw keyError
        }
    }

    func scroll(_ direction: BrowserScrollDirection) async throws {
        var parameters = try targetTabParameters()
        parameters["direction"] = .string(direction.rawValue)
        let reply = try await perform("scrollPage", parameters, resultType: ActionReply.self)
        if let scrollError = ExtensionBrowserReplies.error(forActionStatus: reply.status, action: .scroll, elementID: "") {
            throw scrollError
        }
    }

    // MARK: - Waiting

    private struct SettleReply: Decodable {
        let loaded: Bool
        let settled: Bool
    }

    func waitUntilLoaded(timeout: TimeInterval) async -> Bool {
        await waitForPage(timeout: timeout, requireQuiet: false)
    }

    func waitUntilSettled(timeout: TimeInterval) async -> Bool {
        await waitForPage(timeout: timeout, requireQuiet: true)
    }

    /// One request: the extension waits for load (and quiet) itself, rather
    /// than Wisp polling across the socket.
    private func waitForPage(timeout: TimeInterval, requireQuiet: Bool) async -> Bool {
        guard var parameters = try? targetTabParameters() else { return false }
        let timeouts = ExtensionBrowserReplies.settleRequestTimeouts(forWaitSeconds: timeout)
        parameters["waitSeconds"] = .number(timeouts.waitSeconds)
        parameters["requireQuiet"] = .bool(requireQuiet)
        guard let reply = try? await perform(
            "waitForSettled", parameters, resultType: SettleReply.self, timeoutSeconds: timeouts.requestTimeoutSeconds
        ) else { return false }
        return reply.loaded && reply.settled
    }

    // MARK: - Placing and capturing

    private struct PlacedElementsReply: Decodable {
        struct PlacedElement: Decodable {
            struct ScreenPoint: Decodable {
                let x: Double
                let y: Double
            }
            let id: String
            let screenPoint: ScreenPoint?
        }
        let elements: [PlacedElement]
    }

    func screenPoint(ofElementID elementID: String) async throws -> (point: CGPoint, displayFrame: CGRect)? {
        guard let safeElementID = ExtensionBrowserReplies.sanitizedElementID(elementID) else { return nil }
        var parameters = try targetTabParameters()
        parameters["elementId"] = .string(safeElementID)
        parameters["includeScreenPoint"] = .bool(true)
        let reply = try await perform("findElements", parameters, resultType: PlacedElementsReply.self)
        guard let screenPoint = reply.elements.first?.screenPoint else { return nil }

        let primaryDisplayHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
        guard let primaryDisplayHeight else { return nil }
        let appKitPoint = ExtensionBrowserReplies.appKitPoint(
            fromTopLeftScreenPoint: CGPoint(x: screenPoint.x, y: screenPoint.y),
            primaryDisplayHeight: primaryDisplayHeight
        )
        let display = NSScreen.screens.first(where: { $0.frame.contains(appKitPoint) }) ?? NSScreen.main
        guard let display else { return nil }
        return (appKitPoint, display.frame)
    }

    private struct CapturedTabReply: Decodable {
        let imageBase64: String
    }

    /// The tab as Chrome shows it. Chrome can only capture the visible tab, so
    /// the working tab is brought to the front first (as the agent loop does
    /// before asking), and a tab still in the background is an error rather
    /// than a picture of the wrong page.
    func captureScreenshot() async throws -> Data {
        var parameters = try targetTabParameters()
        parameters["quality"] = .number(70)
        let reply = try await perform("captureVisibleTab", parameters, resultType: CapturedTabReply.self, timeoutSeconds: 15)
        guard let imageData = Data(base64Encoded: reply.imageBase64) else {
            throw BrowserControllerError.scriptFailed("Chrome returned no picture.")
        }
        return Self.downscaledJPEG(imageData, maximumPixelSize: Self.screenshotMaximumPixelSize) ?? imageData
    }

    private static func downscaledJPEG(_ imageData: Data, maximumPixelSize: Int) -> Data? {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary) else { return nil }
        let outputData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(outputData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return outputData as Data
    }
}
