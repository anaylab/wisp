//
//  WispIntentBridge.swift
//  leanring-buddy
//
//  What Wisp's App Intents (Siri, Spotlight, Shortcuts — Phase 4 of
//  `docs/siri-style-plan.md`) need from the running app: ask a question or
//  run a routine and wait for the answer, so the intent can hand it back
//  ("Ask Wisp" in Shortcuts returns the answer as text; Siri reads it).
//
//  A request goes through exactly the path a typed question takes — fast
//  commands, the calendar and reminder routes, personal context, the model —
//  and every one of those records its answer in History
//  (`AgentTaskRegistry`). So rather than each route reporting back, the
//  bridge waits for the History record the request started, by title and
//  start time, to finish, and returns its answer with Wisp's machine tags
//  removed. A request that's still going (a confirmation the user hasn't
//  answered, a long agent task) returns a "still working" line at the
//  timeout instead of holding Shortcuts forever; the answer still lands in
//  the notch.
//

import Foundation

/// The answer to hand back to an intent.
struct WispIntentAnswer: Sendable {
    let text: String
    /// False when the request was still running at the timeout.
    let isFinished: Bool
}

extension CompanionManager {

    /// How long an intent waits for an answer. Long enough for a cold local
    /// model and a confirmation card; short enough not to hang a Shortcut.
    static let intentAnswerTimeoutSeconds: Double = 75

    /// Asks `question` as if it were typed into Ask Wisp, and waits for the answer.
    func answerForIntent(question: String) async -> WispIntentAnswer {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty else {
            return WispIntentAnswer(text: "Ask me something.", isFinished: true)
        }
        let requestedAt = Date()
        askTypedQuestion(trimmedQuestion)
        return await waitForHistoryAnswer(titled: trimmedQuestion, startedAfter: requestedAt)
    }

    /// Runs a routine and waits for its answer.
    func answerForIntent(runningRoutineWithID routineID: UUID) async -> WispIntentAnswer {
        guard let routine = RoutineStore.shared.routine(withID: routineID) else {
            return WispIntentAnswer(text: "That routine no longer exists.", isFinished: true)
        }
        guard allPermissionsGranted else {
            return WispIntentAnswer(text: "Wisp needs its permissions first — open Wisp to finish setting up.", isFinished: true)
        }
        let requestedAt = Date()
        runRoutine(withID: routineID)
        return await waitForHistoryAnswer(
            titled: AgentTaskRecord.routineRunTitlePrefix + routine.name,
            startedAfter: requestedAt
        )
    }

    /// Polls History for the record a request started, until it finishes or
    /// the timeout passes. The record is matched by its title and by starting
    /// after the request (less a second for clock rounding), so an earlier run
    /// of the same question is never mistaken for this one.
    private func waitForHistoryAnswer(titled expectedTitle: String, startedAfter requestedAt: Date) async -> WispIntentAnswer {
        let deadline = Date().addingTimeInterval(Self.intentAnswerTimeoutSeconds)
        let earliestAcceptedStart = requestedAt.addingTimeInterval(-1)
        while Date() < deadline {
            // Newest records are at the front.
            let matchingRecord = AgentTaskRegistry.shared.records.first { record in
                record.title == expectedTitle && record.startedAt >= earliestAcceptedStart
            }
            if let matchingRecord, matchingRecord.status.isTerminal {
                let cleanedAnswer = AnswerDisplayText.cleaned(matchingRecord.finalText ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return WispIntentAnswer(
                    text: cleanedAnswer.isEmpty ? "Done." : cleanedAnswer,
                    isFinished: true
                )
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return WispIntentAnswer(
            text: "Still working on it — the answer will show in Wisp's notch.",
            isFinished: false
        )
    }
}
