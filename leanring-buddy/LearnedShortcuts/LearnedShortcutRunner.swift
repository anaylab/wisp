//
//  LearnedShortcutRunner.swift
//  leanring-buddy
//
//  Runs a matched learned shortcut's steps in order. The tool call itself is injected
//  (`invokeTool`): the real caller passes `AgentToolRegistry.invoke`, which is the one path to
//  any tool, so confirmation cards, the `ToolCallSafety` floor and editable fields behave exactly
//  as in a model turn. "Learned" never means pre-approved.
//
//  What this file decides is only what happens around those calls:
//    - every step is checked and filled in *before* the first one runs, so a bad shortcut stops
//      with nothing done;
//    - a step the user declines ends the run and is not a failure;
//    - a failure on the first step, before anything happened, may fall back to the model; a
//      failure after a side effect may not (the model would repeat what already happened).
//

import Foundation

/// What one tool call came back with, in the shape the runner needs.
struct LearnedShortcutToolOutcome: Sendable {
    let content: String
    let isError: Bool
    let wasDeclined: Bool
    /// The input the tool actually ran with (after the user's card edits), if it ran.
    let executedToolInput: JSONValue?
}

struct LearnedShortcutStepResult: Equatable, Sendable {
    let toolName: String
    let inputRan: JSONValue
    let content: String
    let failed: Bool
    let durationSeconds: TimeInterval
}

enum LearnedShortcutRunResult: Equatable, Sendable {
    case completed(steps: [LearnedShortcutStepResult])
    /// The user said no to a step's confirmation. Not a failure of the shortcut.
    case declined(steps: [LearnedShortcutStepResult], atStepIndex: Int)
    /// The task was cancelled (a newer request started).
    case cancelled(steps: [LearnedShortcutStepResult])
    case failed(steps: [LearnedShortcutStepResult], atStepIndex: Int, reason: String, canFallBackToModel: Bool)

    var stepResults: [LearnedShortcutStepResult] {
        switch self {
        case .completed(let steps), .cancelled(let steps): return steps
        case .declined(let steps, _): return steps
        case .failed(let steps, _, _, _): return steps
        }
    }
}

enum LearnedShortcutRunner {
    static func run(
        _ shortcut: LearnedShortcut,
        slotValues: [String: String],
        invokeTool: (String, JSONValue) async -> LearnedShortcutToolOutcome
    ) async -> LearnedShortcutRunResult {
        // Check and fill in everything first. The shortcut file is the user's and can be edited
        // by hand, so a step on no allow-list, or one whose blank can't be filled, is refused
        // here rather than discovered halfway through.
        var inputsToRun: [JSONValue] = []
        for (stepIndex, step) in shortcut.steps.enumerated() {
            guard ShortcutReplayability.replayableTools[step.toolName] != nil else {
                return .failed(steps: [], atStepIndex: stepIndex, reason: "\(step.toolName) can't be replayed.", canFallBackToModel: true)
            }
            guard let inputToRun = step.toolInput(fillingSlotsWith: slotValues) else {
                return .failed(steps: [], atStepIndex: stepIndex, reason: "a blank couldn't be filled in.", canFallBackToModel: true)
            }
            inputsToRun.append(inputToRun)
        }

        var stepResults: [LearnedShortcutStepResult] = []
        for (stepIndex, step) in shortcut.steps.enumerated() {
            if Task.isCancelled { return .cancelled(steps: stepResults) }

            let stepStartedAt = Date()
            let outcome = await invokeTool(step.toolName, inputsToRun[stepIndex])
            let stepFailed = outcome.isError
                || (!outcome.wasDeclined && ShortcutToolResultJudgement.looksLikeFailure(outcome.content))
            stepResults.append(LearnedShortcutStepResult(
                toolName: step.toolName,
                inputRan: outcome.executedToolInput ?? inputsToRun[stepIndex],
                content: outcome.content,
                failed: stepFailed || outcome.wasDeclined,
                durationSeconds: Date().timeIntervalSince(stepStartedAt)
            ))

            if outcome.wasDeclined {
                return .declined(steps: stepResults, atStepIndex: stepIndex)
            }
            if stepFailed {
                return .failed(
                    steps: stepResults,
                    atStepIndex: stepIndex,
                    reason: outcome.content,
                    canFallBackToModel: stepIndex == 0
                )
            }
        }
        return .completed(steps: stepResults)
    }
}

/// Several of the replayable tools report "I couldn't" as an ordinary result instead of
/// throwing (`arrange_windows`, `control_music`, `create_reminder`), so a replay that only
/// checked for a thrown error would call a no-op a success. This reads their wording.
/// It errs toward "failed": a false failure turns a shortcut off after two in a row, a false
/// success would claim "done." for something that did nothing.
enum ShortcutToolResultJudgement {
    private static let failurePrefixes = [
        "i couldn't", "i can't", "i need ", "i don't", "no single running app", "macos blocked",
        "there is no tool", "chrome has no", "failed", "error",
    ]

    /// `arrange_windows` with two windows can say "done — Safari left. but Xcode has no open window."
    private static let partialFailureFragments = [". but "]

    static func looksLikeFailure(_ resultText: String) -> Bool {
        let comparableText = resultText
            .lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if failurePrefixes.contains(where: { comparableText.hasPrefix($0) }) { return true }
        return partialFailureFragments.contains { comparableText.contains($0) }
    }
}

/// The line shown (and spoken in voice mode) when a replay ends.
enum LearnedShortcutReplyText {
    static func reply(for runResult: LearnedShortcutRunResult, shortcut: LearnedShortcut) -> String {
        let totalStepCount = shortcut.steps.count
        switch runResult {
        case .completed:
            return shortcut.spokenConfirmation
        case .declined(let steps, _):
            let stepsRunSuccessfully = steps.filter { !$0.failed }.count
            return stepsRunSuccessfully == 0
                ? "okay, i didn't run that."
                : "okay, i stopped after \(stepsRunSuccessfully) of \(totalStepCount) steps."
        case .cancelled:
            return ""
        case .failed(let steps, _, let reason, _):
            let stepsRunSuccessfully = steps.filter { !$0.failed }.count
            let reasonLine = String(reason.prefix(140))
            return stepsRunSuccessfully == 0
                ? "that shortcut didn't work: \(reasonLine)"
                : "i did \(stepsRunSuccessfully) of \(totalStepCount) steps, then: \(reasonLine)"
        }
    }
}
