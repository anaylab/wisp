//
//  FrontmostAppTracker.swift
//  leanring-buddy
//
//  Knows which app the user is working in, for the notch's app-aware routine
//  suggestions. It remembers the last app that was not Wisp itself, so opening
//  the dashboard or the text composer (both of which activate Wisp) doesn't
//  wipe out the suggestions for the app the user just came from.
//
//  Driven by NSWorkspace's activation notification — no polling.
//

import AppKit
import Combine

@MainActor
final class FrontmostAppTracker: ObservableObject {
    static let shared = FrontmostAppTracker()

    struct TrackedApplication: Equatable {
        let bundleIdentifier: String
        let displayName: String
    }

    /// The most recent frontmost app other than Wisp. Nil only before any other
    /// app has been seen (e.g. Wisp launched with nothing else open).
    @Published private(set) var lastExternalApplication: TrackedApplication?

    private var activationObserver: NSObjectProtocol?

    private init() {
        recordIfExternal(NSWorkspace.shared.frontmostApplication)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activatedApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                self?.recordIfExternal(activatedApplication)
            }
        }
    }

    private func recordIfExternal(_ application: NSRunningApplication?) {
        guard let application,
              let bundleIdentifier = application.bundleIdentifier,
              bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        lastExternalApplication = TrackedApplication(
            bundleIdentifier: bundleIdentifier,
            displayName: application.localizedName ?? bundleIdentifier
        )
    }
}
