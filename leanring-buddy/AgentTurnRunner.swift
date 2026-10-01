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

    /// Tools that legitimately run for minutes. A browser task drives a real
    /// site across many pages — and may stop mid-way to ask about a purchase —
    /// so the flat per-tool budget would kill it part-way through a form. It is
    /// still bounded, and the user can stop it at any time by talking.
    private static let longRunningToolTimeoutSeconds: [String: TimeInterval] = [
        "browser_task": 10 * 60,
        // Waits for a peer buddy's whole run, plus the approval a model
        // boundary can require first.
        BuddyDelegationToolNames.askBuddy: ToolConfirmationCoordinator.confirmationTimeoutSeconds
            + BuddyDelegationPolicy.answerTimeoutSeconds + 15,
        // A shortcut can call the network or other apps. Its own run is
        // bounded by `ShortcutsBridge.runTimeoutSeconds`; this outlasts that
        // plus the confirmation window, so the bridge's clearer "still
        // running after…" message wins over a generic timeout.
        "run_shortcut": ToolConfirmationCoordinator.confirmationTimeoutSeconds
            + ShortcutsBridge.runTimeoutSeconds + 15,
    ]

    private static func timeoutSeconds(forToolNamed toolName: String) -> TimeInterval {
        longRunningToolTimeoutSeconds[toolName] ?? perToolTimeoutSeconds
    }

    struct Outcome {
        /// The final reply, with any tool tags removed — this is what's spoken.
        let terminalText: String
        let steps: [AgentStepRecord]
        let hitIterationCap: Bool
        /// Everything this turn added to the conversation, in order: the user's
        /// message, then each assistant message and the tool results that
        /// answered it, through to the final reply.
        ///
        /// Returned rather than kept private because the caller is what owns
        /// the conversation across turns, and a runner that reports only its
        /// last sentence forces the caller to reconstruct the rest from
        /// nothing — which is how a transcript ends up recording an answer
        /// that seems to arrive from thin air. Images are still here; dropping
        /// them is the caller's decision to make, not this loop's.
        let messages: [BuddyChatMessage]
    }

    private let modelProvider: any ModelProvider
    private let toolRegistry: AgentToolRegistry
    /// Speaks a confirmation question. Supplied by the caller so this type
    /// doesn't need to know which text-to-speech provider is in use.
    private let speakConfirmation: @MainActor (String) async -> Void
    /// Whether this turn is something the user is waiting on. Background runs
    /// stand aside whenever a conversation needs the model.
    private let priority: ModelAccessGate.Priority
    /// Tools hidden from, or added to, this run alone (see `AgentRunToolkit`).
    private let toolkit: AgentRunToolkit

    init(
        modelProvider: any ModelProvider,
        toolRegistry: AgentToolRegistry = .shared,
        priority: ModelAccessGate.Priority = .interactive,
        toolkit: AgentRunToolkit = .none,
        speakConfirmation: @escaping @MainActor (String) async -> Void
    ) {
        self.modelProvider = modelProvider
        self.toolRegistry = toolRegistry
        self.priority = priority
        self.toolkit = toolkit
        self.speakConfirmation = speakConfirmation
    }

    /// Whether this run shares the one resident local model. A cloud model has
    /// no such copy to protect, so its calls neither queue behind the local
    /// model nor make it wait — that is what lets cloud buddies run in parallel
    /// with each other and with a live conversation on the local model.
    private var sharesLocalModelGate: Bool {
        !modelProvider.deployment.sendsDataOffThisMachine
    }

    /// Runs the request to a final answer.
    ///
    /// - Parameters:
    ///   - onNarration: Progress text for the model's between-tool remarks.
    ///     Shown, never spoken — speaking every intermediate thought would
    ///     make a multi-step request unbearable to listen to.
    ///   - onStep: Called as each step completes, for the dashboard timeline.
    ///   - screenContextText: Extra per-turn context about the screen (the
    ///     Accessibility element list), carried as its own text block on the
    ///     first user message, beside the screenshot. Kept out of `userText` so
    ///     the tool router ranks tools against what the user said, not against
    ///     a list of on-screen button names.
    func run(
        userText: String,
        images: [(data: Data, label: String)],
        screenContextText: String? = nil,
        systemPrompt: String,
        conversationHistory: [BuddyChatMessage],
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
        let runToolkit = toolkit
        let tools = toolRegistry.definitions(forRequest: userText, isToolPermitted: { runToolkit.permits($0) })
            + toolkit.additionalTools.map(\.definition)

        var steps: [AgentStepRecord] = []

        // The conversation as typed messages, prior turns included. History
        // arrives already in this shape — the caller holds the canonical
        // transcript — so nothing is lifted out of strings here, and tool
        // exchanges are appended below as real `toolUse` / `toolResult` blocks
        // rather than as more prose. What the model is told matches what
        // actually happened.
        var messages: [BuddyChatMessage] = conversationHistory

        // Where this turn's own record begins, so `Outcome.messages` can hand
        // back what this run added without the history it was given.
        let indexOfFirstMessageInThisTurn = messages.count

        // The screenshot rides on the first user message and nowhere else.
        var firstUserBlocks: [BuddyContentBlock] = images.map {
            .image(data: $0.data, label: $0.label)
        }
        firstUserBlocks.append(.text(userText))
        if let screenContextText, !screenContextText.isEmpty {
            firstUserBlocks.append(.text(screenContextText))
        }
        messages.append(BuddyChatMessage(role: .user, blocks: firstUserBlocks))

        for iteration in 0..<Self.maximumIterations {
            try Task.checkCancellation()

            let isFinalIteration = iteration == Self.maximumIterations - 1

            // Between steps, background work steps aside for anyone talking.
            // No-op when nothing is waiting.
            if priority == .background && sharesLocalModelGate {
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
            // The screenshot goes out on the first pass and no other. Later
            // passes send a projection of the same conversation with the
            // images dropped — roughly 6.3 seconds of prompt evaluation each
            // time one goes over the wire, and the model has already looked at
            // it. Editing `messages` in place would be cheaper still, but then
            // the record this turn returns would claim no screenshot was ever
            // attached; a request is allowed to carry less than the
            // conversation holds, and this is where that gets decided rather
            // than inside a provider, where the guarantee would only ever be
            // as good as that one provider.
            //
            // Except for a provider that signs its reasoning against the whole
            // conversation so far (Claude): there, dropping the screenshot
            // would edit history mid-loop and void the thinking behind the
            // pending tool call, so the request stays append-only and the
            // screenshot is resent — which its prompt cache makes cheap.
            let dropsImagesOnLaterPasses = iteration > 0
                && !modelProvider.capabilities.requiresAppendOnlyHistoryWithinTurn
            let request = ModelRequest(
                systemPrompt: systemPrompt,
                messages: dropsImagesOnLaterPasses ? messages.map(\.withoutImages) : messages,
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
            let streamModelTurn = { [modelProvider] in
                try await modelProvider.streamTurn(request) { delta in
                    iterationDeltas.append(delta)
                    onModelTextDelta(delta)
                }
            }
            let turn = sharesLocalModelGate
                ? try await ModelAccessGate.shared.withAccess(priority: priority, operation: streamModelTurn)
                : try await streamModelTurn()

            try Task.checkCancellation()

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
                // The closing message is recorded as the model produced it,
                // calls and all. Hitting the iteration cap with calls still
                // outstanding is exactly the case where that matters: the
                // transcript should show that the model was still asking, not
                // that it stopped and answered.
                messages.append(BuddyChatMessage(role: .assistant, blocks: turn.content))
                return Outcome(
                    terminalText: turn.text,
                    steps: steps,
                    hitIterationCap: isFinalIteration && !requestedCalls.isEmpty,
                    messages: Array(messages[indexOfFirstMessageInThisTurn...])
                )
            }

            // Anything said before the tool call is progress, not the answer.
            if !turn.text.isEmpty {
                onNarration(turn.text)
            }

            // The assistant's message is the turn's own content, verbatim —
            // its prose and its calls, each still where the model put them.
            // Rebuilding it as "all the text, then all the calls" was the old
            // shape, and it quietly rewrote history: a model that narrates
            // between two calls was replayed as if it had narrated before
            // both.
            //
            // Nothing here encodes how any provider writes a tool call on the
            // wire. `OllamaProvider` renders a `.toolUse` block back into the
            // `[TOOL:name:{json}]` text this model was trained to read; that
            // reconstruction is a compatibility detail of that one transport.
            // A provider with native tool calls carries these blocks through
            // as structured data and never materialises the tag at all.
            let assistantBlocks = turn.content
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
        return Outcome(
            terminalText: "",
            steps: steps,
            hitIterationCap: true,
            messages: Array(messages[indexOfFirstMessageInThisTurn...])
        )
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
        let runToolkit = toolkit
        // A tool this run isn't permitted is refused by name too: the model
        // can call a tool it was never shown, and hiding the definition alone
        // would not stop it. (A run-only tool is the run's own, so it's exempt.)
        if runToolkit.additionalTool(named: name) == nil && !runToolkit.permits(name) {
            return AgentToolRegistry.Outcome(
                content: "the \(name) tool isn't available to you.",
                isError: true, wasDeclined: false
            )
        }
        return await withTaskGroup(of: AgentToolRegistry.Outcome?.self) { group in
            group.addTask { @MainActor in
                if let runTool = runToolkit.additionalTool(named: name) {
                    return AgentToolRegistry.Outcome(content: await runTool.run(input), isError: false, wasDeclined: false)
                }
                return await registry.invoke(name: name, input: input)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(Self.timeoutSeconds(forToolNamed: name) * 1_000_000_000))
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
