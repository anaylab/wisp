//
//  ConfirmationTimingTests.swift
//  AgentRuntimeIntegration
//
//  When the user answers the card relative to the spoken question. The card
//  shows the moment a request is made, but the wait only began once the
//  question had been said aloud — an answer in between was lost and the request
//  timed out as "no answer", with the island already flashing the approval.
//

import Foundation

@MainActor func confirmationTimingSuite() async {
    section("Confirmation answers: before, during and after the spoken question")

    // Allow pressed while the question is still being spoken.
    let allowWhileSpeakingCoordinator = ToolConfirmationCoordinator()
    let allowWhileSpeakingDecision = await allowWhileSpeakingCoordinator.requestApproval(
        toolName: "cua-driver__press_key",
        argumentSummary: "{\"key\":\"escape\"}",
        speak: { _ in allowWhileSpeakingCoordinator.approveFromUserInterface() }
    )
    check("Allow pressed while the question is spoken is kept",
          allowWhileSpeakingDecision == .approved, "\(allowWhileSpeakingDecision)")
    check("the card is cleared after that answer",
          !allowWhileSpeakingCoordinator.isAwaitingConfirmation)

    // Cancel pressed while the question is still being spoken.
    let cancelWhileSpeakingCoordinator = ToolConfirmationCoordinator()
    let cancelWhileSpeakingDecision = await cancelWhileSpeakingCoordinator.requestApproval(
        toolName: "cua-driver__click",
        argumentSummary: "{}",
        speak: { _ in cancelWhileSpeakingCoordinator.declineFromUserInterface() }
    )
    check("Cancel pressed while the question is spoken is kept",
          cancelWhileSpeakingDecision == .declined(reason: "you declined"), "\(cancelWhileSpeakingDecision)")

    // Allow pressed after the question was spoken: the usual path still works.
    let allowAfterSpeakingCoordinator = ToolConfirmationCoordinator()
    Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(50))
        allowAfterSpeakingCoordinator.approveFromUserInterface()
    }
    let allowAfterSpeakingDecision = await allowAfterSpeakingCoordinator.requestApproval(
        toolName: "cua-driver__hotkey",
        argumentSummary: "{}",
        speak: { _ in }
    )
    check("Allow pressed after the question is spoken still approves",
          allowAfterSpeakingDecision == .approved, "\(allowAfterSpeakingDecision)")

    // A stray answer with nothing pending must not answer the next request.
    let strayAnswerCoordinator = ToolConfirmationCoordinator()
    strayAnswerCoordinator.declineFromUserInterface()
    Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(50))
        strayAnswerCoordinator.approveFromUserInterface()
    }
    let afterStrayAnswerDecision = await strayAnswerCoordinator.requestApproval(
        toolName: "cua-driver__click",
        argumentSummary: "{}",
        speak: { _ in }
    )
    check("an answer given when nothing was asked doesn't carry over",
          afterStrayAnswerDecision == .approved, "\(afterStrayAnswerDecision)")
}
