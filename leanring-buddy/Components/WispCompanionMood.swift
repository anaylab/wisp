//
//  WispCompanionMood.swift
//  leanring-buddy
//
//  The pure side of Wisp's companion — the little cloud with eyes that lives
//  in the notch. What it feels is decided here from what Wisp is doing (the
//  island's activity, a coding agent waiting on you, how long it's been quiet)
//  and from how the user has just treated it (a hover, a poke, three pokes).
//  No SwiftUI, no timers, so the whole personality is testable.
//
//  The *feeling* is inspired by Coucou's notch character (a companion that
//  breathes, blinks, watches your cursor, minds being poked and celebrates
//  finished work); the character itself — its look, faces and motion — is
//  Wisp's own cloud from `BuddyAvatar`, not Coucou's.
//

import CoreGraphics
import Foundation

/// What the companion is feeling right now; the face draws one per mood.
nonisolated enum WispCompanionMood: Equatable, Sendable {
    /// Awake and content, eyes open and following the cursor.
    case content
    /// Hearing the user: eyes wide.
    case listening
    /// Waiting on the model: eyes drift up and aside.
    case thinking
    /// Carrying something out (a browser task, background work, a coding
    /// agent busy): narrowed, focused eyes and a small bob.
    case working
    /// Something is blocked on the user (a permission card): wide eyes, a hop.
    case needsYou
    /// Something just went well: closed "^ ^" eyes, a hop, blush.
    case happy
    /// Something just went wrong: drooping eyes, a small sink.
    case sad
    /// Nothing has happened for a long while: eyes shut, breathing slowly.
    case sleepy
    /// Hello on launch: happy eyes and a little wave.
    case greeting
    /// Poked: squeezed "> <" eyes and a quick shake.
    case annoyed
    /// Poked several times in a row: spinning eyes and a wobble.
    case dizzy
}

/// A short-lived reaction that overrides the mood derived from Wisp's state.
nonisolated struct WispCompanionReaction: Equatable, Sendable {
    let mood: WispCompanionMood
    let endsAt: Date
}

/// Wisp's activity, as the companion cares about it — a mirror of
/// `WispIslandState` kept here so this file stays free of the UI types.
nonisolated enum WispCompanionActivity: Equatable, Sendable {
    case idle
    case listening
    case thinking
    case working
    case answerShowing
    case awaitingConfirmation
    case succeeded
    case failed
}

/// Everything the mood is decided from, at one moment.
nonisolated struct WispCompanionSignals: Equatable, Sendable {
    var activity: WispCompanionActivity
    /// A coding agent (Claude Code) is blocked on a permission card.
    var hasPendingCodingAgentApproval: Bool
    /// Coding agents or background tasks currently working.
    var busyWorkCount: Int
    /// How long since anything happened (a turn, an event, a hover).
    var secondsSinceLastActivity: TimeInterval
    /// A reaction still playing (greeting, poke, celebration), if any.
    var activeReaction: WispCompanionReaction?
}

nonisolated enum WispCompanionMoodResolver {
    /// Quiet this long and the companion dozes off.
    static let secondsBeforeSleepy: TimeInterval = 10 * 60

    /// The mood for the moment. Order matters: something that needs the user
    /// beats a reaction to a poke, which beats ordinary activity.
    static func mood(for signals: WispCompanionSignals, at now: Date) -> WispCompanionMood {
        if signals.hasPendingCodingAgentApproval || signals.activity == .awaitingConfirmation {
            return .needsYou
        }
        if let activeReaction = signals.activeReaction, activeReaction.endsAt > now {
            return activeReaction.mood
        }
        switch signals.activity {
        case .listening: return .listening
        case .thinking: return .thinking
        case .working: return .working
        case .succeeded: return .happy
        case .failed: return .sad
        case .awaitingConfirmation: return .needsYou
        case .answerShowing: return .content
        case .idle:
            if signals.busyWorkCount > 0 { return .working }
            return signals.secondsSinceLastActivity >= secondsBeforeSleepy ? .sleepy : .content
        }
    }
}

/// Counts pokes: one poke annoys the companion, several in quick succession
/// make it dizzy (and it needs a moment to recover).
nonisolated struct WispCompanionPokeTracker: Equatable, Sendable {
    /// Pokes this close together count as one burst.
    static let burstWindowSeconds: TimeInterval = 1.2
    /// Pokes in a burst that make it dizzy.
    static let pokesBeforeDizzy = 3
    static let annoyedSeconds: TimeInterval = 1.1
    static let dizzySeconds: TimeInterval = 3.0

    private(set) var recentPokeDates: [Date] = []

    /// Records a poke and returns the reaction it causes.
    mutating func registerPoke(at pokeDate: Date) -> WispCompanionReaction {
        recentPokeDates = recentPokeDates.filter { pokeDate.timeIntervalSince($0) <= Self.burstWindowSeconds }
        recentPokeDates.append(pokeDate)
        if recentPokeDates.count >= Self.pokesBeforeDizzy {
            recentPokeDates.removeAll()
            return WispCompanionReaction(mood: .dizzy, endsAt: pokeDate.addingTimeInterval(Self.dizzySeconds))
        }
        return WispCompanionReaction(mood: .annoyed, endsAt: pokeDate.addingTimeInterval(Self.annoyedSeconds))
    }
}

/// Where the pupils sit inside the eye, as a fraction of how far they can
/// travel (-1…1 on each axis), looking from the face toward the cursor.
nonisolated enum WispCompanionGaze {
    /// The cursor is this far away (in points) before the eyes reach their
    /// edge; closer than that they track proportionally, so a cursor resting
    /// on the face looks straight on.
    static let fullDeflectionDistance: CGFloat = 220

    static func pupilOffset(faceCenter: CGPoint, cursorLocation: CGPoint) -> CGVector {
        let horizontalDistance = cursorLocation.x - faceCenter.x
        // Screen coordinates grow upward on macOS; the face's y grows downward.
        let verticalDistance = faceCenter.y - cursorLocation.y
        let distance = (horizontalDistance * horizontalDistance + verticalDistance * verticalDistance).squareRoot()
        guard distance > 0.5 else { return CGVector(dx: 0, dy: 0) }
        let reach = min(distance / fullDeflectionDistance, 1)
        return CGVector(dx: horizontalDistance / distance * reach, dy: verticalDistance / distance * reach)
    }
}

/// When the companion blinks: every few seconds, at a slightly irregular
/// rhythm so it doesn't look mechanical, each blink lasting a fraction of a second.
nonisolated enum WispCompanionBlink {
    static let blinkDurationSeconds: TimeInterval = 0.14

    /// How open the eyes are (0 shut … 1 open) at a moment.
    static func eyeOpenness(at timeSinceReferenceDate: TimeInterval) -> CGFloat {
        // Blink cycles of 3.1–5.3 s, the length varying with the cycle number.
        let cycleLengths: [TimeInterval] = [4.2, 3.1, 5.3, 3.7, 4.8]
        let totalLength = cycleLengths.reduce(0, +)
        var timeInCycle = timeSinceReferenceDate.truncatingRemainder(dividingBy: totalLength)
        for cycleLength in cycleLengths {
            if timeInCycle < cycleLength {
                let timeUntilCycleEnd = cycleLength - timeInCycle
                guard timeUntilCycleEnd < blinkDurationSeconds else { return 1 }
                // Close then reopen over the blink: a V shape in openness.
                let blinkProgress = 1 - timeUntilCycleEnd / blinkDurationSeconds
                return CGFloat(abs(blinkProgress * 2 - 1))
            }
            timeInCycle -= cycleLength
        }
        return 1
    }
}
