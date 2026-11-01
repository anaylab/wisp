//
//  StudyModel.swift
//  leanring-buddy
//
//  The pure side of Study mode: the plan (focus / break lengths, rounds) and the
//  session state machine. No timers and no clock of its own: every call is given
//  the time, so the rules are testable and a laptop sleeping mid-session can't
//  quietly credit hours of "focus".
//

import Foundation

enum StudyPhase: String, Codable, Equatable {
    case focus
    case shortBreak
    case longBreak

    var isBreak: Bool { self != .focus }

    var title: String {
        switch self {
        case .focus: return "Focus"
        case .shortBreak: return "Short break"
        case .longBreak: return "Long break"
        }
    }
}

struct StudyPlan: Codable, Equatable {
    var focusMinutes = 25
    var shortBreakMinutes = 5
    var longBreakMinutes = 15
    /// How many focus rounds the session holds.
    var totalRounds = 4
    /// A long break replaces the short one after every this-many focus rounds.
    var roundsBeforeLongBreak = 4
    /// When off, a finished phase waits for the user to start the next one.
    var autoStartNextPhase = true

    static let focusMinutesRange = 5...120
    static let totalRoundsRange = 1...8

    struct Preset: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
        let plan: StudyPlan
    }

    static let presets: [Preset] = [
        Preset(id: "classic", title: "Classic", detail: "25 / 5",
               plan: StudyPlan(focusMinutes: 25, shortBreakMinutes: 5, longBreakMinutes: 15, totalRounds: 4)),
        Preset(id: "deep", title: "Deep work", detail: "50 / 10",
               plan: StudyPlan(focusMinutes: 50, shortBreakMinutes: 10, longBreakMinutes: 30, totalRounds: 3, roundsBeforeLongBreak: 3)),
        Preset(id: "sprint", title: "Sprint", detail: "15 / 3",
               plan: StudyPlan(focusMinutes: 15, shortBreakMinutes: 3, longBreakMinutes: 10, totalRounds: 4)),
        Preset(id: "marathon", title: "Marathon", detail: "90 / 20",
               plan: StudyPlan(focusMinutes: 90, shortBreakMinutes: 20, longBreakMinutes: 30, totalRounds: 2, roundsBeforeLongBreak: 2)),
    ]

    /// Keeps every value in a sensible range so a stored or dragged value can't break the session.
    func clamped() -> StudyPlan {
        var plan = self
        plan.focusMinutes = min(max(focusMinutes, Self.focusMinutesRange.lowerBound), Self.focusMinutesRange.upperBound)
        plan.shortBreakMinutes = min(max(shortBreakMinutes, 1), 30)
        plan.longBreakMinutes = min(max(longBreakMinutes, 1), 60)
        plan.totalRounds = min(max(totalRounds, Self.totalRoundsRange.lowerBound), Self.totalRoundsRange.upperBound)
        plan.roundsBeforeLongBreak = min(max(roundsBeforeLongBreak, 1), 8)
        return plan
    }

    func durationSeconds(of phase: StudyPhase) -> TimeInterval {
        switch phase {
        case .focus: return TimeInterval(focusMinutes * 60)
        case .shortBreak: return TimeInterval(shortBreakMinutes * 60)
        case .longBreak: return TimeInterval(longBreakMinutes * 60)
        }
    }

    /// Focus minutes the whole plan asks for, e.g. "4 × 25 min".
    var summary: String {
        "\(totalRounds) × \(focusMinutes) min"
    }

    /// The id of the preset this plan matches on lengths and rounds, if any.
    var matchingPresetID: String? {
        Self.presets.first {
            $0.plan.focusMinutes == focusMinutes
                && $0.plan.shortBreakMinutes == shortBreakMinutes
                && $0.plan.longBreakMinutes == longBreakMinutes
                && $0.plan.totalRounds == totalRounds
        }?.id
    }
}

enum StudyEvent: Equatable {
    /// A phase is over. `wasCompleted` is false when the user skipped it.
    case phaseEnded(StudyPhase, wasCompleted: Bool)
    case phaseBegan(StudyPhase)
    case finished
}

struct StudySession: Equatable {
    let plan: StudyPlan
    let goal: String
    let startedAt: Date

    private(set) var phase: StudyPhase = .focus
    /// 1-based number of the focus round the session is in (or just finished).
    private(set) var focusRound = 1
    /// The moment the running phase ends. Nil while paused or waiting for the user.
    private(set) var phaseEndsAt: Date?
    private(set) var pausedRemainingSeconds: TimeInterval?
    /// True when auto-start is off and the next phase waits for the user.
    private(set) var isAwaitingStart = false
    private(set) var isFinished = false
    private(set) var endedAt: Date?
    private(set) var completedFocusSeconds: TimeInterval = 0
    private(set) var completedFocusRounds = 0
    /// Minutes the user added to the running phase ("+5 min"); reset when the phase changes.
    private(set) var extraSeconds: TimeInterval = 0

    static let maximumExtraSeconds: TimeInterval = 60 * 60

    init(plan: StudyPlan, goal: String, startedAt: Date) {
        let clampedPlan = plan.clamped()
        self.plan = clampedPlan
        self.goal = goal
        self.startedAt = startedAt
        self.phaseEndsAt = startedAt.addingTimeInterval(clampedPlan.durationSeconds(of: .focus))
    }

    var isPaused: Bool { pausedRemainingSeconds != nil }
    var isRunning: Bool { phaseEndsAt != nil && !isFinished }

    var phaseDurationSeconds: TimeInterval { plan.durationSeconds(of: phase) + extraSeconds }

    func remainingSeconds(at now: Date) -> TimeInterval {
        if isFinished { return 0 }
        if let pausedRemainingSeconds { return pausedRemainingSeconds }
        guard let phaseEndsAt else { return phaseDurationSeconds }
        return max(0, phaseEndsAt.timeIntervalSince(now))
    }

    /// 0 at the start of the phase, 1 at its end.
    func progress(at now: Date) -> Double {
        guard phaseDurationSeconds > 0 else { return 1 }
        let elapsed = phaseDurationSeconds - remainingSeconds(at: now)
        return min(max(elapsed / phaseDurationSeconds, 0), 1)
    }

    /// Focus time earned so far including the part of a running focus phase.
    func focusSecondsEarned(at now: Date) -> TimeInterval {
        guard phase == .focus, !isFinished, !isAwaitingStart else { return completedFocusSeconds }
        return completedFocusSeconds + (phaseDurationSeconds - remainingSeconds(at: now))
    }

    // MARK: - Control

    mutating func pause(at now: Date) {
        guard isRunning, !isPaused else { return }
        pausedRemainingSeconds = remainingSeconds(at: now)
        phaseEndsAt = nil
    }

    mutating func resume(at now: Date) {
        guard let pausedRemainingSeconds, !isFinished else { return }
        phaseEndsAt = now.addingTimeInterval(pausedRemainingSeconds)
        self.pausedRemainingSeconds = nil
    }

    /// Adds time to the running phase (a focus block that is going well). Capped, and not while a phase waits to start.
    mutating func extend(bySeconds seconds: TimeInterval, at now: Date) {
        guard !isFinished, !isAwaitingStart, seconds > 0 else { return }
        let addableSeconds = min(seconds, Self.maximumExtraSeconds - extraSeconds)
        guard addableSeconds > 0 else { return }
        extraSeconds += addableSeconds
        if let pausedRemainingSeconds {
            self.pausedRemainingSeconds = pausedRemainingSeconds + addableSeconds
        } else if let phaseEndsAt {
            self.phaseEndsAt = phaseEndsAt.addingTimeInterval(addableSeconds)
        }
    }

    /// Call on every tick. Moves to the next phase once the running one has run out. One transition per
    /// call, and the next phase starts from `now`, so time the Mac spent asleep is never credited.
    mutating func advance(at now: Date) -> [StudyEvent] {
        guard !isFinished, !isPaused, let phaseEndsAt, now >= phaseEndsAt else { return [] }
        return finishCurrentPhase(wasCompleted: true, at: now)
    }

    /// Ends the current phase early. A skipped focus keeps the time actually spent.
    mutating func skipPhase(at now: Date) -> [StudyEvent] {
        guard !isFinished else { return [] }
        if isAwaitingStart {
            return startAwaitedPhase(at: now)
        }
        return finishCurrentPhase(wasCompleted: false, at: now)
    }

    /// Begins the next phase when auto-start is off.
    mutating func startAwaitedPhase(at now: Date) -> [StudyEvent] {
        guard isAwaitingStart, !isFinished else { return [] }
        isAwaitingStart = false
        phaseEndsAt = now.addingTimeInterval(phaseDurationSeconds)
        return [.phaseBegan(phase)]
    }

    /// Stops the session now. Time already spent in a running focus phase is kept.
    mutating func end(at now: Date) -> [StudyEvent] {
        guard !isFinished else { return [] }
        var events: [StudyEvent] = []
        if phase == .focus, !isAwaitingStart {
            completedFocusSeconds += phaseDurationSeconds - remainingSeconds(at: now)
            events.append(.phaseEnded(.focus, wasCompleted: false))
        }
        markFinished(at: now)
        events.append(.finished)
        return events
    }

    // MARK: - Transitions

    private mutating func finishCurrentPhase(wasCompleted: Bool, at now: Date) -> [StudyEvent] {
        var events: [StudyEvent] = []
        let endedPhase = phase
        if endedPhase == .focus {
            let earnedSeconds = wasCompleted ? phaseDurationSeconds : phaseDurationSeconds - remainingSeconds(at: now)
            completedFocusSeconds += earnedSeconds
            if wasCompleted { completedFocusRounds += 1 }
        }
        events.append(.phaseEnded(endedPhase, wasCompleted: wasCompleted))
        pausedRemainingSeconds = nil
        extraSeconds = 0

        // The last focus round ends the session; there is no break to wait through afterwards.
        if endedPhase == .focus && focusRound >= plan.totalRounds {
            markFinished(at: now)
            events.append(.finished)
            return events
        }

        if endedPhase == .focus {
            phase = focusRound % plan.roundsBeforeLongBreak == 0 ? .longBreak : .shortBreak
        } else {
            phase = .focus
            focusRound += 1
        }

        if plan.autoStartNextPhase {
            phaseEndsAt = now.addingTimeInterval(phaseDurationSeconds)
            events.append(.phaseBegan(phase))
        } else {
            phaseEndsAt = nil
            isAwaitingStart = true
        }
        return events
    }

    private mutating func markFinished(at now: Date) {
        isFinished = true
        phaseEndsAt = nil
        pausedRemainingSeconds = nil
        isAwaitingStart = false
        endedAt = now
    }
}

enum StudyTimeFormatter {
    /// "24:05", or "1:05:00" past an hour.
    static func clock(_ seconds: TimeInterval) -> String {
        let wholeSeconds = Int(seconds.rounded(.up))
        let hours = wholeSeconds / 3600
        let minutes = (wholeSeconds % 3600) / 60
        let remainder = wholeSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%02d:%02d", minutes, remainder)
    }

    /// "1 h 25 min", "40 min", "0 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int((seconds / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min" }
        return "\(minutes) min"
    }
}
