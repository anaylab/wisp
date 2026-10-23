//
//  ChromeBrowsingActivityMonitor.swift
//  leanring-buddy
//
//  The live feed behind the browser automation triggers (phase 08): which
//  site each Chrome tab is on, which tab is showing in the focused window,
//  whether Chrome is the frontmost app and whether the user is at the Mac.
//  From that it announces a tab arriving on a site ("when I open youtube")
//  and keeps `ChromeTimeOnSiteAccumulator` up to date ("if I'm on reddit for
//  30 minutes").
//
//  Fed only by the extension's tab events (phase 01, the `tabs` capability —
//  no page access needed) and a 15-second tick; it never reads a page. Started
//  by the automation wiring only once an automation uses a Chrome trigger, so
//  nobody else pays for it. Nothing is stored: hosts and minutes live in memory.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

@MainActor
final class ChromeBrowsingActivityMonitor {
    static let shared = ChromeBrowsingActivityMonitor()

    /// Between tab events, how often the time on the current site is counted.
    static let sampleIntervalSeconds: TimeInterval = 15
    /// No keyboard or pointer input this long and the user is away — unless
    /// the showing tab is playing sound (a video holds attention without input).
    static let idleThresholdSeconds: TimeInterval = 5 * 60

    /// A tab arrived on a site (its host changed to this one), as a host
    /// without "www.". Opening YouTube, or following a link to it, both count;
    /// moving around inside YouTube doesn't.
    let siteOpenedPublisher = PassthroughSubject<String, Never>()

    private struct TrackedTab {
        var windowID: Int
        var host: String?
        var isAudible: Bool
    }

    private struct FocusedWindowPayload: Decodable {
        let focusedWindowId: Int?
    }

    private struct RemovedTabPayload: Decodable {
        let id: Int
    }

    private var accumulator = ChromeTimeOnSiteAccumulator()
    private var tabsByID: [Int: TrackedTab] = [:]
    private var activeTabIDByWindowID: [Int: Int] = [:]
    private var focusedWindowID: Int?
    private var subscriptions: Set<AnyCancellable> = []
    private var sampleTimer: Timer?
    private var hasStarted = false

    private init() {}

    // MARK: - Lifecycle

    /// Idempotent.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        let bridge = ChromeExtensionBridge.shared
        bridge.extensionEventPublisher
            .filter { ["tab.created", "tab.updated", "tab.activated", "tab.removed", "window.focused"].contains($0.eventName) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] extensionEvent in
                MainActor.assumeIsolated { self?.handle(extensionEvent) }
            }
            .store(in: &subscriptions)

        bridge.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connectionState in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if case .connected = connectionState {
                        Task { @MainActor [weak self] in await self?.seedFromCurrentTabs() }
                    } else {
                        self.forgetTabs()
                    }
                }
            }
            .store(in: &subscriptions)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.recordSample() }
            }
            .store(in: &subscriptions)

        let timer = Timer(timeInterval: Self.sampleIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.recordSample() }
        }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        sampleTimer = timer
    }

    // MARK: - Reading

    /// The current visit to a site, counted up to now.
    func currentVisit(toSite siteHost: String, now: Date = Date()) -> ChromeSiteVisit? {
        recordSample(at: now)
        return accumulator.currentVisit(toSite: siteHost, now: now)
    }

    // MARK: - Tab state

    private func handle(_ extensionEvent: ChromeExtensionEvent) {
        switch extensionEvent.eventName {
        case "tab.created", "tab.updated", "tab.activated":
            guard let tabPayload = extensionEvent.decodePayload(as: ChromeExtensionTabEventPayload.self) else { return }
            let newHost = tabPayload.url.flatMap(ChromeSiteMatching.host(ofURL:))
            let previousHost = tabsByID[tabPayload.id]?.host
            // A tab.updated without its url in changedFields still carries
            // the url; only a real change of site is an arrival.
            if extensionEvent.eventName != "tab.activated", let newHost, newHost != previousHost {
                siteOpenedPublisher.send(newHost)
            }
            tabsByID[tabPayload.id] = TrackedTab(
                windowID: tabPayload.windowId,
                host: newHost,
                isAudible: tabPayload.audible ?? tabsByID[tabPayload.id]?.isAudible ?? false
            )
            if extensionEvent.eventName == "tab.activated" || tabPayload.active == true {
                activeTabIDByWindowID[tabPayload.windowId] = tabPayload.id
            }
        case "tab.removed":
            guard let removedPayload = extensionEvent.decodePayload(as: RemovedTabPayload.self) else { return }
            tabsByID.removeValue(forKey: removedPayload.id)
        case "window.focused":
            guard let focusedPayload = extensionEvent.decodePayload(as: FocusedWindowPayload.self) else { return }
            focusedWindowID = focusedPayload.focusedWindowId
        default:
            return
        }
        recordSample()
    }

    /// What is open right now, without announcing any of it as "opened".
    private func seedFromCurrentTabs() async {
        guard let snapshot = try? await ChromeTabOrganizer.fetchSnapshot() else { return }
        tabsByID = Dictionary(snapshot.tabs.map { tab in
            (tab.id, TrackedTab(windowID: tab.windowId, host: ChromeSiteMatching.host(ofURL: tab.url), isAudible: tab.audible))
        }, uniquingKeysWith: { first, _ in first })
        activeTabIDByWindowID = Dictionary(snapshot.tabs.filter(\.active).map { ($0.windowId, $0.id) }, uniquingKeysWith: { first, _ in first })
        focusedWindowID = snapshot.focusedWindowId
        recordSample()
    }

    private func forgetTabs() {
        recordSample()
        tabsByID.removeAll()
        activeTabIDByWindowID.removeAll()
        focusedWindowID = nil
        recordSample()
    }

    // MARK: - Sampling

    private func recordSample(at date: Date = Date()) {
        let showingTab = focusedWindowID
            .flatMap { activeTabIDByWindowID[$0] }
            .flatMap { tabsByID[$0] }
        let isChromeFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.hasPrefix("com.google.Chrome") == true
        let secondsSinceLastInput = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            // kCGAnyInputEventType: any keyboard, mouse or trackpad event.
            eventType: CGEventType(rawValue: ~0)!
        )
        let isUserIdle = secondsSinceLastInput >= Self.idleThresholdSeconds && showingTab?.isAudible != true
        accumulator.record(
            ChromeBrowsingSample(activeHost: showingTab?.host, isChromeFrontmost: isChromeFrontmost, isUserIdle: isUserIdle),
            at: date
        )
    }
}
