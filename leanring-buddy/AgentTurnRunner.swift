//
//  AgentTurnRunner.swift
//  leanring-buddy
//
//  Runs one user request to completion, including any tools along the way.
//
//  The original pipeline made exactly one model call and spoke whatever came
//  back. This turns that into a loop: the model may ask for a tool, the tool
//  runs, its result is appended to the conversation, and the model is asked
//  again — until it answers instead of asking for another tool.
//
//  Three constraints shape the design, all of them measured on this machine
//  rather than assumed:
//
//  * Encoding a screenshot costs around six seconds, while generating a reply
//    costs under one. The image is therefore attached on the first pass only.
//    Later passes are text over an append-only message list, which also lets
//    the server reuse its cached prompt prefix and stay cheap.
//
//  * The keep-warm heartbeat sends its own throwaway request every ninety
//    seconds. Firing mid-loop displaces this conversation from that cache and
//    silently reintroduces the six-second cost on the next pass, so it is
//    suspended for the duration.
//
//  * A small local model sometimes emits a tool call it shouldn't. Tools are
//    read-only, unknown names come back as ordinary results the model can
//    recover from, and the loop is capped so it can never spin.
//

import Foundation

@MainActor
final class AgentTurnRunner {
    /// Ceiling on model calls per request. Reached only by a model that keeps
    /// asking for tools; a normal exchange finishes on the first or second.
    private static let maximumIterations = 4

    /// A tool that hasn't answered in this long is treated as failed, so one
    /// wedged tool can't hold the whole conversation open.
    /// How long one tool gets, including any permission prompt.
    ///
    /// This has to outlast the confirmation window, not merely the work.
    /// Permission is now asked inside the registry, so it happens *within* this
    /// timeout — at the previous flat 20s every prompt would have been
    /// abandoned after twenty seconds while the card on screen still showed
    /// forty-five counting down, and the user's approval would have landed on a
    /// turn that had already given up.
    private static let toolWorkTimeoutSeconds: TimeInterval = 20
    private static var perToolTimeoutSeconds: TimeInterval {
        ToolConfirmationCoordinator.confirmationTimeoutSeconds + toolWorkTimeoutSeconds
    }

    /// Exposed so a test can assert the ordering that keeps prompts alive.
    static var perToolTimeoutSecondsForTesting: TimeInterval { perToolTimeoutSeconds }

    struct Outcome {
        /// The final reply, with any tool tags removed — this is what's spoken.
        let terminalText: String
        let steps: [AgentStepRecord]
        let hitIterationCap: Bool
    }

    private let chatClient: any BuddyVisionChatClient
    private let toolRegistry: AgentToolRegistry
    /// Speaks a confirmation question. Supplied by the caller so this type
    /// doesn't need to know which text-to-speech provider is in use.
    private let speakConfirmation: @MainActor (String) async -> Void
    /// Whether this turn is something the user is waiting on. Background runs
    /// stand aside whenever a conversation needs the model.
    private let priority: ModelAccessGate.Priority

    init(
        chatClient: any BuddyVisionChatClient,
        toolRegistry: AgentToolRegistry = .shared,
        priority: ModelAccessGate.Priority = .interactive,
        speakConfirmation: @escaping @MainActor (String) async -> Void
    ) {
        self.chatClient = chatClient
        self.toolRegistry = toolRegistry
        self.priority = priority
        self.speakConfirmation = speakConfirmation
    }

    /// Runs the request to a final answer.
    ///
    /// - Parameters:
    ///   - onNarration: Progress text for the model's between-tool remarks.
    ///     Shown, never spoken — speaking every intermediate thought would
    ///     make a multi-step request unbearable to listen to.
    ///   - onStep: Called as each step completes, for the dashboard timeline.
    func run(
        userText: String,
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        onNarration: @MainActor (String) -> Void,
        onStep: @MainActor (AgentStepRecord) -> Void
    ) async throws -> Outcome {
        // Scoped to the request rather than the whole registry. All twelve
        // tools cost 698 prompt tokens and 2.65s of prompt evaluation per turn
        // against 262 and 0.36s for the handful that are relevant — and a 7B
        // model's tool choice degrades as the list grows, so the irrelevant
        // ones are worse than merely expensive.
        let tools = toolRegistry.definitions(forRequest: userText)
        let toolNames = toolRegistry.toolNames
        let systemPromptWithTools = systemPrompt + StructuredTextToolProtocol.promptInstructions(for: tools)

        var steps: [AgentStepRecord] = []
        // Tool exchanges are appended here as extra history entries, which is
        // how the model sees what its tools returned without the message model
        // needing to change.
        var workingHistory = conversationHistory
        var currentUserText = userText
        var isFirstIteration = true

        for iteration in 0..<Self.maximumIterations {
            try Task.checkCancellation()

            let isFinalIteration = iteration == Self.maximumIterations - 1

            // Between steps, background work steps aside for anyone talking.
            // No-op when nothing is waiting.
            if priority == .background {
                await ModelAccessGate.shared.yieldToInteractiveWorkIfNeeded()
                try Task.checkCancellation()
            }

            let modelCallStartedAt = Date()

            let (responseText, duration) = try await ModelAccessGate.shared.withAccess(priority: priority) {
                try await chatClient.analyzeImageStreaming(
                    images: isFirstIteration ? images : [],
                    systemPrompt: systemPromptWithTools,
                    conversationHistory: workingHistory,
                    userPrompt: currentUserText,
                    onTextChunk: { _ in }
                )
            }
            isFirstIteration = false

            try Task.checkCancellation()

            let modelStep = AgentStepRecord(
                kind: .modelCall,
                summary: iteration == 0 ? "Thinking" : "Thinking again (step \(iteration + 1))",
                startedAt: modelCallStartedAt,
                durationSeconds: duration
            )
            steps.append(modelStep)
            onStep(modelStep)

            let parsed = StructuredTextToolProtocol.parse(responseText, knownToolNames: toolNames)

            // Calls that merely echo the prompt's worked example are dropped:
            // they appear on turns needing no tool at all, and acting on one
            // would answer a request the user never made.
            let genuineCalls = parsed.toolCalls.filter { !StructuredTextToolProtocol.isEchoOfPromptExample($0) }

            // No tools wanted, or none left to give — this is the answer.
            if genuineCalls.isEmpty || isFinalIteration {
                return Outcome(
                    terminalText: parsed.spokenText,
                    steps: steps,
                    hitIterationCap: isFinalIteration && !genuineCalls.isEmpty
                )
            }

            // Anything said before the tool call is progress, not the answer.
            if !parsed.spokenText.isEmpty {
                onNarration(parsed.spokenText)
            }

            var resultsForModel: [String] = []
            for call in genuineCalls {
                try Task.checkCancellation()

                let toolStartedAt = Date()

                // No permission check here any more. The registry asks before
                // it runs anything that needs asking, so a second check would
                // prompt twice — and more importantly, a check here would only
                // protect this one caller.
                let outcome = await runToolWithTimeout(name: call.name, input: call.input)

                if outcome.wasDeclined {
                    let declinedStep = AgentStepRecord(
                        kind: .tool(name: call.name),
                        summary: "Not run — you didn't approve it",
                        detail: call.input.compactDescription,
                        startedAt: toolStartedAt,
                        durationSeconds: Date().timeIntervalSince(toolStartedAt)
                    )
                    steps.append(declinedStep)
                    onStep(declinedStep)

                    resultsForModel.append(
                        StructuredTextToolProtocol.resultMessageText(
                            toolName: call.name, content: outcome.content, isError: false
                        )
                    )
                    continue
                }

                let toolStep = AgentStepRecord(
                    kind: .tool(name: call.name),
                    summary: outcome.isError ? "Failed: \(outcome.content)" : summarize(outcome.content),
                    detail: call.input.compactDescription,
                    startedAt: toolStartedAt,
                    durationSeconds: Date().timeIntervalSince(toolStartedAt),
                    isError: outcome.isError
                )
                steps.append(toolStep)
                onStep(toolStep)

                resultsForModel.append(
                    StructuredTextToolProtocol.resultMessageText(
                        toolName: call.name,
                        content: outcome.content,
                        isError: outcome.isError
                    )
                )
            }

            // Record what was asked and what came back, then let the results
            // stand as the next thing the model is responding to.
            workingHistory.append(
                (userPlaceholder: currentUserText, assistantResponse: responseText)
            )
            currentUserText = resultsForModel.joined(separator: "\n\n")
        }

        // Unreachable: the final iteration always returns above.
        return Outcome(terminalText: "", steps: steps, hitIterationCap: true)
    }

    /// Runs one tool, giving up after `perToolTimeoutSeconds`.
    ///
    /// The timeout deliberately covers the permission prompt as well as the
    /// work: a question nobody answers should release the turn rather than hold
    /// it open indefinitely. The broker's own 45s expiry is the inner bound.
    private func runToolWithTimeout(name: String, input: JSONValue) async -> AgentToolRegistry.Outcome {
        await withTaskGroup(of: AgentToolRegistry.Outcome?.self) { group in
            group.addTask { @MainActor in
                await AgentToolRegistry.shared.invoke(name: name, input: input)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(Self.perToolTimeoutSeconds * 1_000_000_000))
                return nil
            }

            let first = await group.next() ?? nil
            group.cancelAll()

            return first ?? AgentToolRegistry.Outcome(
                content: "the \(name) tool took too long and was stopped.",
                isError: true, wasDeclined: false
            )
        }
    }

    /// Shortens a tool result for the dashboard's one-line step summary.
    private func summarize(_ content: String) -> String {
        let firstLine = content.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? content
        return firstLine.count > 90 ? String(firstLine.prefix(90)) + "…" : firstLine
    }
}
