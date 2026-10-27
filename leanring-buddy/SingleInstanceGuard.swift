//
//  SingleInstanceGuard.swift
//  leanring-buddy
//
//  Only one Wisp may run. Two copies (a DerivedData build beside an installed one, or the same
//  app launched from two paths) both install the push-to-talk event tap, so every question is
//  heard, answered and spoken twice, and both write the same files under Application Support.
//  LaunchServices only prevents a second copy launched from the *same* path.
//
//  The second copy tells the first to show its window (so double-clicking the app still does
//  something visible) and quits before it starts anything.
//

import AppKit

@MainActor
enum SingleInstanceGuard {
    /// Posted by a second copy on its way out; the running copy opens its window in response.
    /// Anyone can post a distributed notification, so the response must stay harmless.
    private static let secondCopyLaunchedNotificationName = Notification.Name("com.wisp.second-copy-launched")

    /// Another running Wisp with this bundle identifier, other than this process, if any.
    static func otherRunningInstance() -> NSRunningApplication? {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return nil }
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { $0.processIdentifier != ownProcessIdentifier && !$0.isTerminated }
    }

    static func notifyRunningInstanceThatSecondCopyLaunched() {
        DistributedNotificationCenter.default().postNotificationName(
            secondCopyLaunchedNotificationName,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// Called by the copy that keeps running.
    static func observeSecondCopyLaunches(_ handleSecondCopyLaunched: @escaping @MainActor () -> Void) {
        DistributedNotificationCenter.default().addObserver(
            forName: secondCopyLaunchedNotificationName,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { handleSecondCopyLaunched() }
        }
    }
}
