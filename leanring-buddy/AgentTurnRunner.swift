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

/// Holds one iteration's deltas until the turn is known to be safe to speak.
///
/// A reference type because the provider's delta callback is `@Sendable` and
/// so cannot capture a mutable local.
private final class CollectedDeltas: @unchecked Sendable {
    private(set) var values: [String] = []
    func append(_ delta: String) { values.append(delta) }
}

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

    private let modelProvider: any ModelProvider
    private let toolRegistry: AgentToolRegistry
    /// Speaks a confirmation question. Supplied by the caller so this type
    /// doesn't need to know which text-to-speech provider is in use.
    private let speakConfirmation: @MainActor (String) async -> Void
    /// Whether this turn is something the user is waiting on. Background runs
    /// stand aside whenever a conversation needs the model.
    private let priority: ModelAccessGate.Priority

    init(
        modelProvider: any ModelProvider,
        toolRegistry: AgentToolRegistry = .shared,
        priority: ModelAccessGate.Priority = .interactive,
        speakConfirmation: @escaping @MainActor (String) async -> Void
    ) {
        self.modelProvider = modelProvider
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
        onStep: @MainActor (AgentStepRecord) -> Void,
        onModelTextDelta: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        onSpeakableTextDelta: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) async throws -> Outcome {
        // Scoped to the request rather than the whole registry. All twelve
        // tools cost 698 prompt tokens and 2.65s of prompt evaluation per turn
        // against 262 and 0.36s for the handful that are relevant — and a 7B
        // model's tool choice degrades as the list grows, so the irrelevant
        // ones are worse than merely expensive.
        let tools = toolRegistry.definitions(forRequest: userText)

        var steps: [AgentStepRecord] = []

        // The conversation as typed messages. Prior turns arrive as string
        // pairs from the caller and are lifted here; tool exchanges are then
        // appended as real `toolUse` / `toolResult` blocks rather than as
        // more prose, so what the model is told matches what actually
        // happened.
        var messages: [BuddyChatMessage] = []
        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(BuddyChatMessage(role: .user, text: userPlaceholder))
            messages.append(BuddyChatMessage(role: .assistant, text: assistantResponse))
        }

        // The screenshot rides on the first user message and nowhere else.
        // Only the final user message's images are put on the wire, so once a
        // tool result becomes the last message the image stops being sent —
        // the ~6.3s of prompt evaluation it costs is paid once per turn.
        var firstUserBlocks: [BuddyContentBlock] = images.map {
            .image(data: $0.data, label: $0.label)
        }
        firstUserBlocks.append(.text(userText))
        messages.append(BuddyChatMessage(role: .user, blocks: firstUserBlocks))

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

            // No reply ceiling is set. The right one is a property of the
            // model — a local 7B is capped short because speech synthesis time
            // scales with characters, a cloud model's limit is a billing
            // decision — and this loop knows about neither. Leaving it nil
            // hands the choice to the provider, which is also what keeps this
            // file free of any particular provider's configuration.
            let request = ModelRequest(
                systemPrompt: systemPrompt,
                messages: messages,
                tools: tools
            )

            // Two channels, and the difference between them is the whole
            // point.
            //
            // `onModelTextDelta` is observation: it fires as text arrives, for
            // metrics and diagnostics, and is never spoken.
            //
            // Speech is held back, because nothing can be known about a reply
            // until it ends. The tool tag is written last, so text arriving
            // before it is indistinguishable from a finished answer — on this
            // model it is routinely a half-answer with a gap where the tool
            // result belongs ("it's  right now."). That is true of every
            // iteration, including the one after a tool has run, since the
            // model may ask for another. So deltas are collected here and
            // released to speech only once the turn has proved to be an
            // unambiguous final answer.
            //
            // Speech therefore starts no earlier than it does today. What this
            // buys is that it starts *correctly*, and that the terminal answer
            // is still delivered as increments so sentence-by-sentence
            // synthesis keeps working.
            let iterationDeltas = CollectedDeltas()
            let turn = try await ModelAccessGate.shared.withAccess(priority: priority) {
                try await modelProvider.streamTurn(request) { delta in
                    iterationDeltas.append(delta)
                    onModelTextDelta(delta)
                }
            }

            try Task.checkCancellation()

            // The screenshot has now been sent once. Strip it from the record
            // so no later pass can resend it — roughly 6.3 seconds of prompt
            // evaluation each time it goes over the wire. Relying on the
            // provider to drop it would make the guarantee specific to this
            // one provider: a model with native image blocks would happily
            // resend every image in the history, once per iteration.
            messages = messages.map { message in
                guard message.blocks.contains(where: {
                    if case .image = $0 { return true }
                    return false
                }) else { return message }
                var withoutImages = message
                withoutImages.blocks = message.blocks.filter {
                    if case .image = $0 { return false }
                    return true
                }
                return withoutImages
            }

            let modelStep = AgentStepRecord(
                kind: .modelCall,
                summary: iteration == 0 ? "Thinking" : "Thinking again (step \(iteration + 1))",
                startedAt: modelCallStartedAt,
                durationSeconds: turn.duration
            )
            steps.append(modelStep)
            onStep(modelStep)

            // Tool calls arrive already parsed and already filtered — the
            // echoed-example guard and the known-name check live in the
            // provider, alongside the tag syntax they belong to. This loop
            // never sees a [TOOL:...] tag.
            let requestedCalls = turn.toolUses

            // A reply the model mangled a tool call into is not an answer.
            // Recorded so it is visible, and so the text around it is never
            // mistaken for something worth speaking.
            if !turn.malformedToolCallDescriptions.isEmpty {
                let malformedStep = AgentStepRecord(
                    kind: .modelCall,
                    summary: "Ignored a malformed tool call",
                    detail: turn.malformedToolCallDescriptions.joined(separator: " "),
                    startedAt: modelCallStartedAt,
                    durationSeconds: 0,
                    isError: true
                )
                steps.append(malformedStep)
                onStep(malformedStep)
            }

            // No tools wanted, or none left to give — this is the answer.
            if requestedCalls.isEmpty || isFinalIteration {
                // Released to speech only now, and only if the model neither
                // asked for a tool nor tried and failed to. Hitting the
                // iteration cap with calls outstanding is not a clean answer
                // either, so that text is returned but never handed to speech.
                if turn.isUnambiguousFinalAnswer {
                    for delta in iterationDeltas.values { onSpeakableTextDelta(delta) }
                }
                return Outcome(
                    terminalText: turn.text,
                    steps: steps,
                    hitIterationCap: isFinalIteration && !requestedCalls.isEmpty
                )
            }

            // Anything said before the tool call is progress, not the answer.
            if !turn.text.isEmpty {
                onNarration(turn.text)
            }

            // Rebuilt as real message blocks: the assistant's turn records the
            // calls it made, and the following user turn carries their results.
            //
            // This is the canonical shape — assistant text and tool-execution
            // metadata are kept as separate, structured blocks, and nothing
            // here encodes how any provider writes a tool call on the wire.
            // `OllamaProvider` currently renders a `.toolUse` block back into
            // the `[TOOL:name:{json}]` text this model was trained to read;
            // that reconstruction is a compatibility detail of that one
            // transport, not part of the abstraction. A provider with native
            // tool calls carries these blocks through as structured data and
            // never materialises the tag at all.
            var assistantBlocks: [BuddyContentBlock] = turn.text.isEmpty ? [] : [.text(turn.text)]
            var resultBlocks: [BuddyContentBlock] = []
            for call in requestedCalls {
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

                    assistantBlocks.append(.toolUse(id: call.id, name: call.name, input: call.input))
                    resultBlocks.append(
                        .toolResult(toolUseID: call.id, toolName: call.name,
                                    content: outcome.content, isError: false)
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

                assistantBlocks.append(.toolUse(id: call.id, name: call.name, input: call.input))
                resultBlocks.append(
                    .toolResult(toolUseID: call.id, toolName: call.name,
                                content: outcome.content, isError: outcome.isError)
                )
            }

            // Record what was asked and what came back. The results become the
            // last user message, so they are what the model answers next — and
            // because they carry no image, the screenshot is not resent.
            messages.append(BuddyChatMessage(role: .assistant, blocks: assistantBlocks))
            messages.append(BuddyChatMessage(role: .user, blocks: resultBlocks))
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
        // The *injected* registry, not the shared one. These were different
        // objects: the registry supplied to `init` decided which tools were
        // offered, while execution always went to the singleton — so a caller
        // that passed its own registry got its tool list honoured and its
        // implementations ignored, and no test could observe what actually ran.
        let registry = toolRegistry
        return await withTaskGroup(of: AgentToolRegistry.Outcome?.self) { group in
            group.addTask { @MainActor in
                await registry.invoke(name: name, input: input)
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
