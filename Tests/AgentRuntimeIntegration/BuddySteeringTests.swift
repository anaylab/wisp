//
//  BuddySteeringTests.swift
//
//  Steer mode through the real AgentTurnRunner: a message handed over at a
//  step reaches the next model call beside the tool results, is recorded as a
//  step, and a run that answers without another step never asks for it.
//

import Foundation

@MainActor func buddySteeringSuite() async {
    section("Steering: a message joins the run at its next step")
    do {
        let registry = AgentToolRegistry.makeEmptyForTesting()
        registry.setPermissionBroker(StubBroker(decision: .approved))
        registry.register(definition("look_up_week", .reading())) { _ in "Mon light, Fri busy" }
        let provider = ScriptedProvider(turns: [
            BuddyChatTurn(text: "checking.", toolUses: [toolCall("t1", "look_up_week")], stopReason: .toolUse),
            BuddyChatTurn(text: "Moved it to Monday.", stopReason: .endTurn),
        ])
        final class Handover: @unchecked Sendable {
            var waitingTexts = ["actually skip Friday"]
            var askedCount = 0
        }
        let handover = Handover()
        var toolkit = AgentRunToolkit()
        toolkit.takeSteeringMessages = {
            handover.askedCount += 1
            defer { handover.waitingTexts = [] }
            return handover.waitingTexts
        }
        var recordedSteps: [AgentStepRecord] = []
        let runner = AgentTurnRunner(modelProvider: provider, toolRegistry: registry, toolkit: toolkit, speakConfirmation: { _ in })
        let outcome = try? await runner.run(
            userText: "plan my week", images: [], systemPrompt: "sys", conversationHistory: [],
            onNarration: { _ in }, onStep: { recordedSteps.append($0) }
        )
        check("steering: the run finished", outcome?.terminalText == "Moved it to Monday.")
        check("steering: asked once, after the one step", handover.askedCount == 1, "\(handover.askedCount)")
        let secondRequestLastMessage = provider.receivedRequests.count == 2 ? provider.receivedRequests[1].messages.last : nil
        let lastBlocks = secondRequestLastMessage?.blocks ?? []
        let resultIndex = lastBlocks.firstIndex { if case .toolResult = $0 { return true } else { return false } }
        let steeringIndex = lastBlocks.firstIndex { if case .text(let text) = $0 { return text.contains("actually skip Friday") } else { return false } }
        check("steering: the message reaches the next model call", steeringIndex != nil, "\(lastBlocks)")
        check("steering: it comes after the tool result", (resultIndex ?? .max) < (steeringIndex ?? .min))
        check("steering: it is recorded as a step", recordedSteps.contains { $0.summary == "Took in your message" })
        let storedTurn = outcome?.messages ?? []
        check("steering: the stored turn keeps the message", storedTurn.contains { message in
            message.blocks.contains { if case .text(let text) = $0 { return text.contains("actually skip Friday") } else { return false } }
        })
    }

    section("Steering: an answer with no further step never takes it")
    do {
        let registry = AgentToolRegistry.makeEmptyForTesting()
        let provider = ScriptedProvider(turns: [BuddyChatTurn(text: "Here you go.", stopReason: .endTurn)])
        final class Counter: @unchecked Sendable { var askedCount = 0 }
        let counter = Counter()
        var toolkit = AgentRunToolkit()
        toolkit.takeSteeringMessages = { counter.askedCount += 1; return ["late message"] }
        let runner = AgentTurnRunner(modelProvider: provider, toolRegistry: registry, toolkit: toolkit, speakConfirmation: { _ in })
        let outcome = try? await runner.run(
            userText: "hi", images: [], systemPrompt: "sys", conversationHistory: [],
            onNarration: { _ in }, onStep: { _ in }
        )
        check("steering: a direct answer finishes", outcome?.terminalText == "Here you go.")
        check("steering: nothing is taken, so it stays queued for the next run", counter.askedCount == 0)
    }
}
