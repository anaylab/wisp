//
//  ChromeSiteHelpers.swift
//  leanring-buddy
//
//  The hub of the site helpers (phase 10): it follows the Wisp Tabs extension's
//  tab events to know which Chrome tab is showing and which tabs are Canvas
//  assignments or calls, publishes that for the phrase router, and runs the
//  commands the router recognises ("add this to today", "plan this", "what did
//  I miss").
//
//  The Canvas work is in CanvasPageHelper.swift and the caption summary in
//  MeetingCaptionsHelper.swift; this file only wires them to the extension.
//
//  The router (`ChromeTabCommandRouter`) is nonisolated, so what it may assume is
//  kept behind a lock, like `ChromeTabSessionStore.savedSessionNamesForRouting`.
//

import AppKit
import Combine
import Foundation

@MainActor
final class ChromeSiteHelpers {
    static let shared = ChromeSiteHelpers()

    private var tabState = ChromeSiteHelperTabState()
    private var eventSubscription: AnyCancellable?
    private var connectionSubscription: AnyCancellable?
    private var frontmostApplicationSubscription: AnyCancellable?
    private var hasStarted = false

    private nonisolated static let availabilityLock = NSLock()
    private nonisolated(unsafe) static var lockedAvailability = ChromeSiteHelperAvailability.nothing

    /// What the phrase router may assume right now. Safe from any thread.
    nonisolated static var availabilityForRouting: ChromeSiteHelperAvailability {
        availabilityLock.lock()
        defer { availabilityLock.unlock() }
        return lockedAvailability
    }

    private init() {}

    /// Called once from `NotchWindowController.show()`, beside the other Chrome features.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        let bridge = ChromeExtensionBridge.shared

        eventSubscription = bridge.extensionEventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] extensionEvent in
                MainActor.assumeIsolated { self?.handle(extensionEvent) }
            }

        // On every (re)connection or permission change, start again from the tabs
        // Chrome really has: events sent while Wisp wasn't listening are gone.
        connectionSubscription = bridge.$connectionState.combineLatest(bridge.$grantedCapabilities)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                MainActor.assumeIsolated { self?.reseedFromChrome() }
            }

        // "Plan this" only means the assignment while Chrome is the app in front.
        frontmostApplicationSubscription = FrontmostAppTracker.shared.$lastExternalApplication
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.publishAvailability() }
            }

        CanvasPageHelper.shared.start()
    }

    // MARK: - Running a command

    func perform(_ command: ChromeSiteHelperCommand, modelProvider: any ModelProvider) async -> (replyText: String, didSucceed: Bool) {
        switch command {
        case .canvasStatus:
            return await CanvasPageHelper.shared.statusOfShowingAssignment()
        case .canvasAddToToday:
            return await CanvasPageHelper.shared.addShowingAssignmentToToday()
        case .canvasPlan:
            return await CanvasPageHelper.shared.planShowingAssignment()
        case .meetingCaptions(let meetingRequest):
            return await MeetingCaptionsHelper.summarize(meetingRequest, modelProvider: modelProvider)
        }
    }

    // MARK: - What's open in Chrome

    /// The Canvas assignment the user is looking at, on a host Wisp trusts.
    func showingCanvasAssignment() -> (tabID: Int, reference: CanvasAssignmentPageReference)? {
        tabState.showingCanvasAssignment(savedCanvasFeedHost: CanvasPageHelper.savedCanvasFeedHost())
    }

    func urlString(forTabID tabID: Int) -> String? { tabState.urlString(forTabID: tabID) }

    private func handle(_ extensionEvent: ChromeExtensionEvent) {
        switch extensionEvent.eventName {
        case "tab.created", "tab.updated":
            guard let tabPayload = extensionEvent.decodePayload(as: ChromeExtensionTabEventPayload.self) else { return }
            tabState.tabChanged(tabID: tabPayload.id, windowID: tabPayload.windowId, url: tabPayload.url, isActive: tabPayload.active)
        case "tab.activated":
            guard let tabPayload = extensionEvent.decodePayload(as: ChromeExtensionTabEventPayload.self) else { return }
            tabState.tabActivated(tabID: tabPayload.id, windowID: tabPayload.windowId, url: tabPayload.url)
        case "tab.removed":
            guard let removedPayload = extensionEvent.decodePayload(as: RemovedTabPayload.self) else { return }
            tabState.tabRemoved(tabID: removedPayload.id)
            CanvasPageHelper.shared.tabWasClosed(tabID: removedPayload.id)
        case "window.focused":
            guard let focusPayload = extensionEvent.decodePayload(as: FocusedWindowPayload.self) else { return }
            tabState.windowFocused(windowID: focusPayload.focusedWindowId)
        case "site.canvasAssignmentOpened":
            guard let openedPayload = extensionEvent.decodePayload(as: CanvasAssignmentOpenedPayload.self) else { return }
            tabState.tabChanged(tabID: openedPayload.tabId, windowID: openedPayload.windowId ?? -1, url: openedPayload.url, isActive: nil)
            CanvasPageHelper.shared.assignmentOpened(openedPayload)
        case "site.meetingCaptionsAvailable":
            guard let captionsPayload = extensionEvent.decodePayload(as: MeetingCaptionsAvailablePayload.self) else { return }
            tabState.tabChanged(tabID: captionsPayload.tabId, windowID: captionsPayload.windowId ?? -1, url: captionsPayload.url, isActive: nil)
        default:
            return
        }
        publishAvailability()
    }

    private func reseedFromChrome() {
        let bridge = ChromeExtensionBridge.shared
        guard bridge.isExtensionConnected, bridge.hasCapability(.pagesRead) else {
            tabState.clear()
            publishAvailability()
            return
        }
        Task { [weak self] in
            guard let snapshot = try? await ChromeTabOrganizer.fetchSnapshot() else { return }
            guard let self else { return }
            self.tabState.reset(
                tabs: snapshot.tabs.map { (id: $0.id, windowID: $0.windowId, url: $0.url, isActive: $0.active) },
                focusedWindowID: snapshot.focusedWindowId
            )
            self.publishAvailability()
        }
    }

    private func publishAvailability() {
        let bridge = ChromeExtensionBridge.shared
        var availability = ChromeSiteHelperAvailability.nothing
        if bridge.isExtensionConnected, bridge.hasCapability(.pagesRead) {
            availability.hasMeetingTab = !tabState.meetingTabIDs.isEmpty
            let frontmostBundleIdentifier = FrontmostAppTracker.shared.lastExternalApplication?.bundleIdentifier ?? ""
            availability.isShowingCanvasAssignment = showingCanvasAssignment() != nil
                && ChromePageReader.isConnectedExtension(inBrowserWithBundleIdentifier: frontmostBundleIdentifier)
        }
        Self.availabilityLock.lock()
        Self.lockedAvailability = availability
        Self.availabilityLock.unlock()
    }

    private struct RemovedTabPayload: Decodable {
        let id: Int
    }

    private struct FocusedWindowPayload: Decodable {
        let focusedWindowId: Int?
    }

    // MARK: - Requests

    /// A site-helper request, with the same plain-words errors as page reading.
    static func sendRequest<Parameters: Encodable, Result: Decodable>(
        method: String,
        parameters: Parameters,
        resultType: Result.Type,
        timeoutSeconds: Double = ChromePageReader.toolReadTimeoutSeconds
    ) async throws -> Result {
        let bridge = ChromeExtensionBridge.shared
        guard bridge.isExtensionConnected else { throw ChromePageReader.ReaderError.extensionNotConnected }
        guard bridge.hasCapability(.pagesRead) else { throw ChromePageReader.ReaderError.pagesReadNotAllowed }
        do {
            return try await bridge.sendRequest(
                method: method,
                parameters: parameters,
                resultType: resultType,
                timeoutSeconds: timeoutSeconds
            )
        } catch ChromeExtensionBridge.BridgeError.extensionReportedError(let extensionMessage) {
            if extensionMessage.contains("missing capability pages.read") {
                throw ChromePageReader.ReaderError.pagesReadNotAllowed
            }
            throw SiteHelperError(message: extensionMessage)
        } catch ChromeExtensionBridge.BridgeError.extensionNotConnected {
            throw ChromePageReader.ReaderError.extensionNotConnected
        }
    }

    /// The extension's own words (already lowercase and plain, e.g. "there's no
    /// google meet or zoom call open in chrome").
    struct SiteHelperError: LocalizedError {
        let message: String
        var errorDescription: String? { message.hasSuffix(".") ? message : message + "." }
    }
}
