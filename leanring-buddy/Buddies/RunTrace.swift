//
//  RunTrace.swift
//  leanring-buddy
//
//  The data behind a run's Trace window (OpenBot's "4 steps 11s ›"): how long
//  the run took, how many model and tool calls it made, whether anything
//  failed, and where each step sits on a shared time axis so the slowest one
//  stands out. Pure, so `Tests/BuddyThread` checks it without the app.
//

import Foundation

struct RunTraceRow: Identifiable, Equatable {
    let id: UUID
    let title: String
    let isModelCall: Bool
    let isError: Bool
    /// Where the step starts and how wide it is, as fractions (0...1) of the run.
    let offsetFraction: Double
    let widthFraction: Double
    let durationSeconds: TimeInterval
    /// The longest step of a run with more than one.
    var isSlowest: Bool
}

struct RunTrace: Equatable {
    let totalSeconds: TimeInterval
    let rows: [RunTraceRow]

    var stepCount: Int { rows.count }
    var modelCallCount: Int { rows.filter(\.isModelCall).count }
    var toolCallCount: Int { rows.filter { !$0.isModelCall }.count }
    var errorCount: Int { rows.filter(\.isError).count }
}

enum RunTraceBuilder {
    /// A bar is never thinner than this, so a near-instant step is still visible.
    static let minimumWidthFraction = 0.015

    static func trace(steps: [AgentStepRecord], runStartedAt: Date, runTotalSeconds: TimeInterval) -> RunTrace {
        let offsets = steps.map { max(0, $0.startedAt.timeIntervalSince(runStartedAt)) }
        let latestEnd = zip(steps, offsets).map { $1 + max(0, $0.durationSeconds) }.max() ?? 0
        // The run's own clock can end a moment before the last step is recorded.
        let totalSeconds = max(runTotalSeconds, latestEnd, 0.001)

        var rows = zip(steps, offsets).map { step, offset -> RunTraceRow in
            let isModelCall: Bool
            if case .modelCall = step.kind { isModelCall = true } else { isModelCall = false }
            let duration = max(0, step.durationSeconds)
            let offsetFraction = min(1, offset / totalSeconds)
            return RunTraceRow(
                id: step.id,
                title: step.summary,
                isModelCall: isModelCall,
                isError: step.isError,
                offsetFraction: offsetFraction,
                widthFraction: min(1 - offsetFraction, max(minimumWidthFraction, duration / totalSeconds)),
                durationSeconds: duration,
                isSlowest: false
            )
        }
        if rows.count > 1, let slowestIndex = rows.indices.max(by: { rows[$0].durationSeconds < rows[$1].durationSeconds }),
           rows[slowestIndex].durationSeconds > 0 {
            rows[slowestIndex].isSlowest = true
        }
        return RunTrace(totalSeconds: totalSeconds, rows: rows)
    }
}
