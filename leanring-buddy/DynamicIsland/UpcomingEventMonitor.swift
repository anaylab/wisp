//
//  UpcomingEventMonitor.swift
//  leanring-buddy
//
//  Feeds the notch's ambient "next meeting" countdown: the island wakes a
//  little before a timed event starts and shows "12m" beside the notch, so the
//  user sees it coming without opening anything.
//
//  Reads EventKit on this Mac through `CalendarDataProvider`, and only when
//  Calendar access has already been granted — it never asks, because a prompt
//  that appears on its own with no request behind it would be baffling. Polls
//  every 30 seconds, which keeps the minute countdown accurate without a clock
//  that redraws the resident notch every second.
//

import Combine
import Foundation

@MainActor
final class UpcomingEventMonitor: ObservableObject {
    static let shared = UpcomingEventMonitor()

    /// How long before an event starts the island begins showing it.
    static let leadTimeSeconds: TimeInterval = 15 * 60
    /// How long after it starts it stays, for joining a few minutes late.
    static let graceAfterStartSeconds: TimeInterval = 5 * 60
    private static let refreshIntervalSeconds: TimeInterval = 30

    /// The event to show, or nil when none is inside the window (or there is no
    /// Calendar access). Republished on every refresh so the countdown label,
    /// which is computed from the current time, re-renders.
    @Published private(set) var imminentEvent: CalendarGlanceEvent?

    private var refreshTimer: Timer?

    private init() {}

    /// Starts polling. Safe to call more than once.
    func start() {
        guard refreshTimer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: Self.refreshIntervalSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        // Tolerance lets macOS coalesce the wake-up with other timers.
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func refresh() {
        Task { @MainActor in
            let event = await CalendarDataProvider.shared.imminentTimedEventIfAuthorized(
                lookAheadInterval: Self.leadTimeSeconds,
                recentlyStartedInterval: Self.graceAfterStartSeconds
            )
            // Assign even when unchanged so the countdown text refreshes.
            self.imminentEvent = event
        }
    }

    /// The short countdown for the notch flank: "12m" before the start, "now"
    /// once it has begun.
    static func compactCountdownText(until startDate: Date, now: Date = Date()) -> String {
        let secondsUntilStart = startDate.timeIntervalSince(now)
        guard secondsUntilStart > 30 else { return "now" }
        let minutesUntilStart = Int((secondsUntilStart / 60).rounded(.up))
        return "\(minutesUntilStart)m"
    }

    /// The longer phrase that leads the hover panel's event line: "In 12 min" /
    /// "Started".
    static func countdownPhrase(until startDate: Date, now: Date = Date()) -> String {
        let secondsUntilStart = startDate.timeIntervalSince(now)
        guard secondsUntilStart > 30 else { return "Started" }
        let minutesUntilStart = Int((secondsUntilStart / 60).rounded(.up))
        return "In \(minutesUntilStart) min"
    }
}
