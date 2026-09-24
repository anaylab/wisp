//
//  WispTimerStore.swift
//  leanring-buddy
//
//  The source of truth for countdown timers started from a `[CARD:{"kind":
//  "timer",…}]` tag or the "set a timer for five minutes" fast path.
//
//  Timers deliberately live here, on the main actor, and not in the timer card.
//  The notch shows one glance card at a time, and the very next turn replaces
//  it — but "set a timer for ten minutes, then what's the weather" must still
//  ring in ten minutes. So the card only *names* a timer (`TimerCardState`) and
//  reads its live state from this store; the countdown, the completion
//  callback, and the system notification all belong to the store and survive
//  the card being dismissed.
//
//  The system notification is scheduled with the OS at start (a time-interval
//  trigger) rather than posted by the app at the end, so it is delivered on
//  time even if the Mac sleeps or Wisp is busy; cancelling removes it.
//

import Combine
import Foundation
import UserNotifications

/// Where a timer is in its life.
enum WispTimerStatus: Equatable {
    case running
    case finished
    case cancelled
}

/// One countdown timer. A value type; the store replaces it on each change.
struct WispTimer: Identifiable, Equatable {
    let id: UUID
    let label: String?
    let durationSeconds: Int
    let startDate: Date
    var status: WispTimerStatus

    var endDate: Date {
        startDate.addingTimeInterval(TimeInterval(durationSeconds))
    }

    /// Seconds left at `date`, never negative.
    func remainingSeconds(at date: Date) -> TimeInterval {
        max(0, endDate.timeIntervalSince(date))
    }

    /// How much of the timer is left at `date`, from 1 (just started) to 0.
    func fractionRemaining(at date: Date) -> Double {
        guard durationSeconds > 0 else { return 0 }
        return min(1, max(0, remainingSeconds(at: date) / TimeInterval(durationSeconds)))
    }
}

@MainActor
final class WispTimerStore: ObservableObject {
    static let shared = WispTimerStore()

    /// Every timer started this launch, by id, including finished and
    /// cancelled ones so a card that is still on screen can show "Done" or
    /// "Cancelled" rather than vanish. A handful of small values — not pruned.
    @Published private(set) var timersByID: [UUID: WispTimer] = [:]

    /// The sleeping task per running timer that fires its completion. Held so
    /// cancelling a timer can stop it.
    private var completionTasksByTimerID: [UUID: Task<Void, Never>] = [:]

    /// What to do when each running timer finishes (the island flash + sound
    /// cue). Supplied by the caller so this store does not reach into
    /// `CompanionManager`.
    private var finishHandlersByTimerID: [UUID: @MainActor () -> Void] = [:]

    private init() {}

    func timer(withID timerID: UUID) -> WispTimer? {
        timersByID[timerID]
    }

    /// Timers still counting down, soonest to finish first.
    var runningTimers: [WispTimer] {
        timersByID.values
            .filter { $0.status == .running }
            .sorted { $0.endDate < $1.endDate }
    }

    /// Starts a countdown and schedules its system notification.
    ///
    /// `onFinished` runs on the main actor when the timer reaches zero — not if
    /// it is cancelled. It runs whether or not any card is showing the timer.
    @discardableResult
    func startTimer(
        durationSeconds: Int,
        label: String?,
        onFinished: @escaping @MainActor () -> Void
    ) -> WispTimer {
        let newTimer = WispTimer(
            id: UUID(),
            label: label,
            durationSeconds: durationSeconds,
            startDate: Date(),
            status: .running
        )
        timersByID[newTimer.id] = newTimer
        finishHandlersByTimerID[newTimer.id] = onFinished

        let timerID = newTimer.id
        completionTasksByTimerID[timerID] = Task { [weak self] in
            // ContinuousClock-backed, so the wait keeps counting while the Mac
            // sleeps and the timer finishes at its real end time.
            try? await Task.sleep(for: .seconds(durationSeconds))
            guard !Task.isCancelled else { return }
            self?.finishTimer(withID: timerID)
        }

        Self.scheduleSystemNotification(for: newTimer)
        return newTimer
    }

    /// Stops a running timer without firing its completion, and withdraws its
    /// pending system notification. A no-op for a timer that already ended.
    func cancelTimer(withID timerID: UUID) {
        guard var cancelledTimer = timersByID[timerID], cancelledTimer.status == .running else { return }
        cancelledTimer.status = .cancelled
        timersByID[timerID] = cancelledTimer

        completionTasksByTimerID.removeValue(forKey: timerID)?.cancel()
        finishHandlersByTimerID.removeValue(forKey: timerID)

        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [Self.notificationIdentifier(forTimerID: timerID)]
        )
    }

    private func finishTimer(withID timerID: UUID) {
        guard var finishedTimer = timersByID[timerID], finishedTimer.status == .running else { return }
        finishedTimer.status = .finished
        timersByID[timerID] = finishedTimer

        completionTasksByTimerID.removeValue(forKey: timerID)
        let finishHandler = finishHandlersByTimerID.removeValue(forKey: timerID)
        // The system notification was scheduled at start and fires on its own;
        // this is the in-app half (island flash + sound cue).
        finishHandler?()
    }

    // MARK: - System notification

    private static func notificationIdentifier(forTimerID timerID: UUID) -> String {
        "wisp.timer.\(timerID.uuidString)"
    }

    /// Asks for notification permission (a no-op after the first time) and
    /// schedules the "timer done" notification for the timer's end.
    ///
    /// Scheduling up front means the alert still arrives if the card is gone,
    /// the notch is collapsed, or the user is in another Space entirely.
    private static func scheduleSystemNotification(for timer: WispTimer) {
        let notificationIdentifier = notificationIdentifier(forTimerID: timer.id)
        let notificationTitle = timer.label.map { "\($0.capitalizedFirstLetter) timer done" } ?? "Timer done"
        let notificationBody = "Your \(WispTimerDurationFormatter.spokenDurationText(totalSeconds: timer.durationSeconds)) timer is up."
        let secondsUntilEnd = TimeInterval(timer.durationSeconds)

        Task {
            let notificationCenter = UNUserNotificationCenter.current()
            let isAuthorized = (try? await notificationCenter.requestAuthorization(options: [.alert, .sound])) ?? false
            guard isAuthorized else { return }

            let content = UNMutableNotificationContent()
            content.title = notificationTitle
            content.body = notificationBody
            content.sound = .default

            // A time-interval trigger must be positive; the store already
            // guarantees at least one second.
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, secondsUntilEnd),
                repeats: false
            )
            try? await notificationCenter.add(
                UNNotificationRequest(
                    identifier: notificationIdentifier,
                    content: content,
                    trigger: trigger
                )
            )
        }
    }
}

// MARK: - Formatting

/// Turns timer lengths into the two strings Wisp shows and says: a countdown
/// clock ("4:59", "1:02:03") and a spoken length ("5 minutes").
enum WispTimerDurationFormatter {

    /// A countdown clock for the time left. Rounds *up*, so a timer shows
    /// "5:00" for its whole first second and reaches "0:00" exactly at the end.
    static func countdownText(remainingSeconds: TimeInterval) -> String {
        let wholeSecondsLeft = max(0, Int(remainingSeconds.rounded(.up)))
        let hours = wholeSecondsLeft / 3600
        let minutes = (wholeSecondsLeft % 3600) / 60
        let seconds = wholeSecondsLeft % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// A natural length: "45 seconds", "1 minute", "5 minutes", "1 hour 30
    /// minutes", "2 minutes 30 seconds". Zero-valued parts are left out.
    static func spokenDurationText(totalSeconds: Int) -> String {
        let clampedSeconds = max(0, totalSeconds)
        let hours = clampedSeconds / 3600
        let minutes = (clampedSeconds % 3600) / 60
        let seconds = clampedSeconds % 60

        var parts: [String] = []
        if hours > 0 { parts.append(pluralized(hours, unit: "hour")) }
        if minutes > 0 { parts.append(pluralized(minutes, unit: "minute")) }
        if seconds > 0 || parts.isEmpty { parts.append(pluralized(seconds, unit: "second")) }
        return parts.joined(separator: " ")
    }

    private static func pluralized(_ count: Int, unit: String) -> String {
        "\(count) \(unit)\(count == 1 ? "" : "s")"
    }
}

private extension String {
    /// "tea" → "Tea", leaving the rest of the string as written.
    var capitalizedFirstLetter: String {
        guard let firstCharacter = first else { return self }
        return firstCharacter.uppercased() + dropFirst()
    }
}
