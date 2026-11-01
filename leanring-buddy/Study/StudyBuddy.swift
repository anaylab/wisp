//
//  StudyBuddy.swift
//  leanring-buddy
//
//  The pure side of Study mode's companion: how the buddy feels, what it says, and when it
//  speaks up on its own (a nudge, sometimes with a one-tap offer). No timers, no UI and no
//  clock: every call is handed the session and the time, so the rules are testable.
//

import Foundation

enum StudyBuddyFeeling: Equatable {
    case idle
    case focused
    case resting
    case sleepy
    case waiting
    case cheering

    static func feeling(for session: StudySession?, isCheering: Bool) -> StudyBuddyFeeling {
        guard let session else { return isCheering ? .cheering : .idle }
        if isCheering { return .cheering }
        if session.isPaused { return .sleepy }
        if session.isAwaitingStart { return .waiting }
        return session.phase.isBreak ? .resting : .focused
    }
}

/// What the buddy can do for the user if they tap its chip.
enum StudyBuddyOffer: Equatable {
    case extend
    case resume
    case startNext

    var buttonTitle: String {
        switch self {
        case .extend: return "+5 min"
        case .resume: return "Resume"
        case .startNext: return "Start"
        }
    }
}

struct StudyBuddyMessage: Equatable, Identifiable {
    let id = UUID()
    let text: String
    let offer: StudyBuddyOffer?

    /// A line with an offer stays up longer, so there is time to take it.
    var lifetimeSeconds: TimeInterval { offer == nil ? 8 : 20 }
}

enum StudyBuddyNudgeKind: Hashable {
    case halfway
    case lastStretch
    case longPause
    case breakEnding
    case awaitingStart
}

struct StudyBuddyNudge: Equatable {
    let kind: StudyBuddyNudgeKind
    let text: String
    let offer: StudyBuddyOffer?
}

/// Decides, on every tick, whether the buddy has something worth saying. Each kind speaks once
/// per phase (`alreadyShown`), and the caller only asks while the buddy is not already talking.
enum StudyBuddyNudgePlanner {
    static let longPauseSeconds: TimeInterval = 180
    static let lastStretchSeconds: TimeInterval = 120
    /// A short block isn't worth offering more time on.
    static let minimumPhaseSecondsForLastStretchOffer: TimeInterval = 15 * 60
    static let breakEndingSeconds: TimeInterval = 30

    static func nextNudge(
        session: StudySession,
        now: Date,
        pausedSince: Date?,
        alreadyShown: Set<StudyBuddyNudgeKind>
    ) -> StudyBuddyNudge? {
        guard !session.isFinished else { return nil }

        if session.isAwaitingStart {
            guard !alreadyShown.contains(.awaitingStart) else { return nil }
            let text = session.phase == .focus
                ? "Break's over. Ready for round \(session.focusRound)?"
                : "Nice round! Time for a break?"
            return StudyBuddyNudge(kind: .awaitingStart, text: text, offer: .startNext)
        }

        if session.isPaused {
            guard let pausedSince,
                  now.timeIntervalSince(pausedSince) >= longPauseSeconds,
                  !alreadyShown.contains(.longPause) else { return nil }
            return StudyBuddyNudge(kind: .longPause, text: "Still there? Your block is waiting.", offer: .resume)
        }

        let remainingSeconds = session.remainingSeconds(at: now)
        guard remainingSeconds > 0 else { return nil }

        if session.phase.isBreak {
            guard remainingSeconds <= breakEndingSeconds, !alreadyShown.contains(.breakEnding) else { return nil }
            return StudyBuddyNudge(kind: .breakEnding, text: "Almost time. One more deep breath.", offer: nil)
        }

        if remainingSeconds <= lastStretchSeconds,
           session.phaseDurationSeconds >= minimumPhaseSecondsForLastStretchOffer,
           !alreadyShown.contains(.lastStretch) {
            return StudyBuddyNudge(kind: .lastStretch, text: "Going well? I can add five more minutes.", offer: .extend)
        }

        if session.progress(at: now) >= 0.5, !alreadyShown.contains(.halfway) {
            let remainingText = StudyTimeFormatter.duration(remainingSeconds)
            return StudyBuddyNudge(kind: .halfway, text: "Halfway there. \(remainingText) to go.", offer: nil)
        }
        return nil
    }
}

/// What the buddy says. `variant` picks between lines, so a caller that counts up never repeats back to back.
enum StudyBuddyVoice {
    private static func pick(_ lines: [String], _ variant: Int) -> String {
        lines[abs(variant) % lines.count]
    }

    static func startLine(goal: String, round: Int, totalRounds: Int, variant: Int) -> String {
        if round == 1, !goal.isEmpty { return "Let's do it: \(goal)." }
        if round == totalRounds, totalRounds > 1 { return "Last round. Finish strong." }
        return pick(["Round \(round). You've got this.", "Focus mode on. I'll guard the door.", "Here we go. Round \(round) of \(totalRounds)."], variant)
    }

    static func breakLine(isLong: Bool, variant: Int) -> String {
        if isLong { return "Long break. Walk around, drink some water." }
        return pick(["Break time. Look away from the screen.", "Stretch! You earned it.", "Breathe. Roll your shoulders."], variant)
    }

    static func heldBackLine(detail: String) -> String {
        "Not now! \(detail)."
    }

    static func pokeLine(phase: StudyPhase, isPaused: Bool, variant: Int) -> String {
        if isPaused { return pick(["Zzz… tap Resume when you're ready.", "Taking five. I'll wait."], variant) }
        if phase.isBreak { return pick(["Enjoy the break!", "Hydrate. Seriously.", "Eyes off the screen for a bit."], variant) }
        return pick(["Eyes on the prize.", "You're doing great.", "One thing at a time.", "I've got the distractions."], variant)
    }

    static func finishedLine(rounds: Int, focusSeconds: TimeInterval) -> String {
        let roundsText = rounds == 1 ? "1 round" : "\(rounds) rounds"
        return "Nice! \(roundsText), \(StudyTimeFormatter.duration(focusSeconds)) of focus."
    }

    /// The launcher's line while nothing runs.
    static func greeting(todayRounds: Int, streakDays: Int, hour: Int) -> String {
        if todayRounds > 0 {
            return todayRounds == 1 ? "1 round grown today. One more?" : "\(todayRounds) rounds grown today. One more?"
        }
        if streakDays >= 3 { return "\(streakDays)-day streak. Let's keep it alive." }
        switch hour {
        case 5..<12: return "Morning! Plant the first round?"
        case 12..<18: return "Afternoon focus? I'm ready."
        default: return "Evening session? Let's keep it gentle."
        }
    }
}

/// Learns the user's usual block length from the log and points at the closest preset.
enum StudyBuddyAdvisor {
    static let entriesConsidered = 5

    static func recommendedPresetID(from log: [StudyLogEntry]) -> String {
        let recentEntries = log.suffix(entriesConsidered).filter { $0.completedRounds > 0 }
        guard !recentEntries.isEmpty else { return "classic" }
        let averageMinutesPerRound = recentEntries
            .map { $0.focusSeconds / Double($0.completedRounds) / 60 }
            .reduce(0, +) / Double(recentEntries.count)
        let closestPreset = StudyPlan.presets.min {
            abs(Double($0.plan.focusMinutes) - averageMinutesPerRound) < abs(Double($1.plan.focusMinutes) - averageMinutesPerRound)
        }
        return closestPreset?.id ?? "classic"
    }
}
