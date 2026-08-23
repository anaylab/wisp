//
//  PerfMetricsRecorder.swift
//  leanring-buddy
//
//  Per-turn latency breakdown for the local model pipeline.
//
//  Local inference latency is dominated by a few large, highly variable
//  costs — vision encoding a screenshot, and cold-start recompilation of
//  GPU graphs after an idle period — and those costs are invisible from
//  inside a single `print` statement. Recording each phase separately is
//  what makes it possible to say "the screenshot cost six seconds" rather
//  than "it felt slow", and to notice a regression the moment it appears
//  rather than several changes later.
//

import Combine
import Foundation

/// One measured phase of a single voice interaction.
enum TurnPhase: String, Sendable, CaseIterable {
    case transcription = "Speech-to-text"
    case screenCapture = "Screen capture"
    case chat = "Model"
    case textToSpeechFirstSentence = "Voice (first sentence)"

    /// The order phases are displayed in, matching the order they run.
    var sortIndex: Int {
        switch self {
        case .transcription: return 0
        case .screenCapture: return 1
        case .chat: return 2
        case .textToSpeechFirstSentence: return 3
        }
    }
}

struct TurnMetrics: Sendable, Identifiable {
    let id: UUID
    let startedAt: Date
    var transcript: String
    /// Whether a screenshot was attached — the single biggest latency
    /// factor, so a turn's numbers are only comparable to another turn
    /// that made the same choice.
    var didAttachScreenshot: Bool
    var phaseDurations: [TurnPhase: TimeInterval]
    var modelName: String?

    init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        transcript: String = "",
        didAttachScreenshot: Bool = false,
        phaseDurations: [TurnPhase: TimeInterval] = [:],
        modelName: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.transcript = transcript
        self.didAttachScreenshot = didAttachScreenshot
        self.phaseDurations = phaseDurations
        self.modelName = modelName
    }

    var totalSeconds: TimeInterval {
        phaseDurations.values.reduce(0, +)
    }

    /// The phase that dominated this turn, if any.
    var slowestPhase: (phase: TurnPhase, seconds: TimeInterval)? {
        guard let entry = phaseDurations.max(by: { $0.value < $1.value }) else { return nil }
        return (phase: entry.key, seconds: entry.value)
    }
}

/// Collects `TurnMetrics` for the dashboard.
///
/// Deliberately in-memory and bounded: these numbers are for understanding
/// the current session's behaviour, not for long-term analytics, and they
/// should never be a reason to touch the disk on the hot path.
@MainActor
final class PerfMetricsRecorder: ObservableObject {
    static let shared = PerfMetricsRecorder()

    private static let maximumRetainedTurns = 50

    @Published private(set) var recentTurns: [TurnMetrics] = []

    private var turnInProgress: TurnMetrics?
    private var phaseStartTimes: [TurnPhase: Date] = [:]

    /// Starts a new turn, discarding any half-finished one (which happens
    /// whenever the user interrupts by speaking again).
    func beginTurn(transcript: String, modelName: String?) {
        turnInProgress = TurnMetrics(transcript: transcript, modelName: modelName)
        phaseStartTimes.removeAll()
    }

    func beginPhase(_ phase: TurnPhase) {
        phaseStartTimes[phase] = Date()
    }

    func endPhase(_ phase: TurnPhase) {
        guard let startTime = phaseStartTimes.removeValue(forKey: phase) else { return }
        turnInProgress?.phaseDurations[phase] = Date().timeIntervalSince(startTime)
    }

    func recordScreenshotDecision(didAttach: Bool) {
        turnInProgress?.didAttachScreenshot = didAttach
    }

    /// Finishes the turn and publishes it. Turns with no measured phases are
    /// dropped — they represent interactions abandoned before any work ran.
    func completeTurn() {
        guard let completedTurn = turnInProgress, !completedTurn.phaseDurations.isEmpty else {
            turnInProgress = nil
            phaseStartTimes.removeAll()
            return
        }

        recentTurns.insert(completedTurn, at: 0)
        if recentTurns.count > Self.maximumRetainedTurns {
            recentTurns.removeLast(recentTurns.count - Self.maximumRetainedTurns)
        }

        turnInProgress = nil
        phaseStartTimes.removeAll()
    }

    func abandonTurn() {
        turnInProgress = nil
        phaseStartTimes.removeAll()
    }

    // MARK: - Aggregates for the dashboard

    /// Median rather than mean: a single cold-start turn is several times
    /// slower than a warm one, and an average of the two describes neither.
    func medianSeconds(for phase: TurnPhase, screenshotAttached: Bool? = nil) -> TimeInterval? {
        let matchingTurns = recentTurns.filter { turn in
            guard let requiredScreenshotState = screenshotAttached else { return true }
            return turn.didAttachScreenshot == requiredScreenshotState
        }

        let durations = matchingTurns.compactMap { $0.phaseDurations[phase] }.sorted()
        guard !durations.isEmpty else { return nil }

        let middleIndex = durations.count / 2
        if durations.count.isMultiple(of: 2) {
            return (durations[middleIndex - 1] + durations[middleIndex]) / 2
        }
        return durations[middleIndex]
    }

    func clear() {
        recentTurns.removeAll()
        abandonTurn()
    }
}
