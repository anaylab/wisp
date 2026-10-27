//
//  LearnedShortcutReplayTests.swift
//  AgentRuntimeIntegration
//
//  A learned shortcut replays through the real tool registry, so a step that needs the user's
//  OK still asks, a "no" runs nothing, and "learned" never means pre-approved.
//

import Foundation

@MainActor func learnedShortcutReplaySuite() async {
    section("Learned shortcuts: replay goes through the approval boundary")

    let shortcut = LearnedShortcut(
        phraseTemplate: "put {app} on the left",
        slots: [LearnedShortcutSlot(name: "app", kind: .applicationName)],
        steps: [LearnedShortcutStep(
            toolName: "arrange_windows",
            toolInput: .object(["app": .string("Safari"), "placement": .string("left_half")]),
            slotBindings: [LearnedShortcutSlotBinding(argumentPath: [.key("app")], slotName: "app")]
        )]
    )

    func replay(through registry: AgentToolRegistry) async -> LearnedShortcutRunResult {
        await LearnedShortcutRunner.run(shortcut, slotValues: ["app": "Xcode"]) { toolName, toolInput in
            let registryOutcome = await registry.invoke(name: toolName, input: toolInput)
            return LearnedShortcutToolOutcome(
                content: registryOutcome.content,
                isError: registryOutcome.isError,
                wasDeclined: registryOutcome.wasDeclined,
                executedToolInput: registryOutcome.executedToolInput
            )
        }
    }

    do {
        // A tool that needs confirmation, approved: it is asked about, then runs with the blank filled.
        let registry = AgentToolRegistry.makeEmptyForTesting()
        let broker = StubBroker(decision: .approved)
        registry.setPermissionBroker(broker)
        let capturedInput = CapturedInput()
        registry.register(definition("arrange_windows", .writing())) { input in
            capturedInput.value = input
            return "done — Xcode left."
        }
        let result = await replay(through: registry)
        check("replay of a confirmation-required step asked the broker", broker.askedAbout == ["arrange_windows"], broker.askedAbout.description)
        check("the approved step ran with the blank filled",
              capturedInput.value == .object(["app": .string("Xcode"), "placement": .string("left_half")]))
        if case .completed = result { check("replay completed", true) } else { check("replay completed", false, "\(result)") }
    }
    do {
        // Declined: nothing runs, and it is a decline, not a failure of the shortcut.
        let registry = AgentToolRegistry.makeEmptyForTesting()
        let broker = StubBroker(decision: .declined(reason: "user said no"))
        registry.setPermissionBroker(broker)
        let ran = Ran()
        registry.register(definition("arrange_windows", .writing())) { _ in ran.value = true; return "done." }
        let result = await replay(through: registry)
        check("a declined replay step did NOT run", !ran.value)
        if case .declined(_, let index) = result { check("…and is reported as declined at step 0", index == 0) }
        else { check("…and is reported as declined", false, "\(result)") }
    }
    do {
        // A tool that needs no confirmation runs without asking, exactly as in a model turn.
        let registry = AgentToolRegistry.makeEmptyForTesting()
        let broker = StubBroker(decision: .declined(reason: "should not be consulted"))
        registry.setPermissionBroker(broker)
        let ran = Ran()
        registry.register(definition("arrange_windows", .reading())) { _ in ran.value = true; return "done." }
        _ = await replay(through: registry)
        check("a step that never needed approval does not ask", ran.value && broker.askedAbout.isEmpty)
    }
    do {
        // A tool that is not registered any more is a failure the model can take over.
        let registry = AgentToolRegistry.makeEmptyForTesting()
        let result = await replay(through: registry)
        if case .failed(_, _, _, let canFallBack) = result { check("a missing tool fails and may fall back", canFallBack) }
        else { check("a missing tool fails", false, "\(result)") }
    }
}
