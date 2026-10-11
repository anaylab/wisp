//
//  main.swift
//  AgentRuntimeIntegration
//
//  Integration tests for the migrated agent loop.
//
//  Unlike the ModelProvider contract suite, these link the real application
//  sources — the real AgentTurnRunner, the real AgentToolRegistry, the real
//  ToolConfirmationCoordinator — because the properties under test are about
//  how those collaborate. The model is the only thing faked, so that a turn
//  can be scripted precisely.
//
//  Run with ./Tests/AgentRuntimeIntegration/run.sh
//

import Foundation

final class Tally: @unchecked Sendable { var passed = 0; var failed = 0 }
let tally = Tally()
func section(_ name: String) { print("\n── \(name) ──") }
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { tally.passed += 1; print("  PASS  \(name)") }
    else { tally.failed += 1; let d = detail(); print("  FAIL  \(name)\(d.isEmpty ? "" : "\n        → \(d)")") }
}

// MARK: - Test doubles

/// A model whose replies are decided by the test.
///
/// Records every request it is handed, so the suite can assert what the
/// runtime actually asked for — which is how "the image is attached to the
/// first pass only" becomes observable.
final class ScriptedProvider: ModelProvider, @unchecked Sendable {
    let identifier = "scripted"
    let capabilities = ModelCapabilities(
        supportsVision: true, supportsTools: true, supportsNativeToolCalls: false,
        supportsStreaming: true, contextWindowTokens: 16384)
    let deployment = ModelDeployment(location: .onThisMachine)

    private let scripted: [BuddyChatTurn]
    private let deltasPerTurn: [[String]]
    private let delayBetweenDeltas: TimeInterval
    private(set) var receivedRequests: [ModelRequest] = []
    /// Signalled after the first delta, so a test can prove text is observable
    /// before the turn finishes.
    var onFirstDelta: (@MainActor @Sendable () -> Void)?

    init(turns: [BuddyChatTurn], deltas: [[String]] = [], delayBetweenDeltas: TimeInterval = 0) {
        self.scripted = turns
        self.deltasPerTurn = deltas
        self.delayBetweenDeltas = delayBetweenDeltas
    }

    func streamTurn(_ request: ModelRequest,
                    onTextDelta: @escaping @MainActor @Sendable (String) -> Void)
    async throws -> BuddyChatTurn {
        let index = receivedRequests.count
        receivedRequests.append(request)
        let deltas = index < deltasPerTurn.count ? deltasPerTurn[index] : []
        for (offset, delta) in deltas.enumerated() {
            try Task.checkCancellation()
            await onTextDelta(delta)
            if offset == 0 { await onFirstDelta?() }
            if delayBetweenDeltas > 0 {
                try await Task.sleep(nanoseconds: UInt64(delayBetweenDeltas * 1_000_000_000))
            }
        }
        try Task.checkCancellation()
        return index < scripted.count ? scripted[index] : BuddyChatTurn(text: "done")
    }
}


// MARK: - A second provider, with native structured tool calls
//
// The point of this type is to fail if anything Ollama-specific has leaked
// into the generic layer. It models a cloud-style provider: tool calls arrive
// as structured data rather than as [TOOL:...] text, it has its own reply
// ceiling, its own token accounting, and it must never need to import or
// consult LocalOllamaAPI. It drives the REAL AgentTurnRunner — a second copy
// of the loop would prove nothing.
final class NativeToolCallProvider: ModelProvider, @unchecked Sendable {
    let identifier = "fake-native/v1"
    let capabilities = ModelCapabilities(
        supportsVision: true,
        supportsTools: true,
        // The distinguishing fact: no text protocol, no echo guard, no tags.
        supportsNativeToolCalls: true,
        supportsStreaming: true,
        supportsStructuredOutput: true,
        contextWindowTokens: 200_000)
    let deployment = ModelDeployment(location: .remote(serviceName: "fake-cloud"),
                                     approximateOutputTokensPerSecond: 120)

    /// This provider's own default ceiling. Nothing outside it knows this
    /// number, which is the property being tested.
    static let ownDefaultMaxOutputTokens = 4096

    struct ScriptedTurn {
        let text: String
        let deltas: [String]
        let toolCalls: [(id: String, name: String, input: JSONValue)]
        let promptTokens: Int
        let outputTokens: Int
        init(text: String, deltas: [String] = [],
             toolCalls: [(id: String, name: String, input: JSONValue)] = [],
             promptTokens: Int = 100, outputTokens: Int = 20) {
            self.text = text; self.deltas = deltas; self.toolCalls = toolCalls
            self.promptTokens = promptTokens; self.outputTokens = outputTokens
        }
    }

    private let script: [ScriptedTurn]
    private(set) var receivedRequests: [ModelRequest] = []
    /// The ceiling this provider resolved for each request, so a test can see
    /// that nil really did fall through to its own default.
    private(set) var resolvedCeilings: [Int] = []
    private let delayBetweenDeltas: TimeInterval

    init(script: [ScriptedTurn], delayBetweenDeltas: TimeInterval = 0) {
        self.script = script
        self.delayBetweenDeltas = delayBetweenDeltas
    }

    func streamTurn(_ request: ModelRequest,
                    onTextDelta: @escaping @MainActor @Sendable (String) -> Void)
    async throws -> BuddyChatTurn {
        try validateAgainstCapabilities(request)
        let index = receivedRequests.count
        receivedRequests.append(request)
        resolvedCeilings.append(request.maxOutputTokens ?? Self.ownDefaultMaxOutputTokens)

        guard index < script.count else { return BuddyChatTurn(text: "done") }
        let turn = script[index]
        for delta in turn.deltas {
            try Task.checkCancellation()
            await onTextDelta(delta)
            if delayBetweenDeltas > 0 {
                try await Task.sleep(nanoseconds: UInt64(delayBetweenDeltas * 1_000_000_000))
            }
        }
        try Task.checkCancellation()
        // Structured straight through: no text is parsed, and no tag is ever
        // built or stripped.
        return BuddyChatTurn(
            text: turn.text,
            toolUses: turn.toolCalls,
            stopReason: turn.toolCalls.isEmpty ? .endTurn : .toolUse,
            duration: 0.01,
            promptTokens: turn.promptTokens,
            outputTokens: turn.outputTokens)
    }
}

final class StubBroker: ToolPermissionBroker {
    var decision: ToolConfirmationCoordinator.Decision
    private(set) var askedAbout: [String] = []
    init(decision: ToolConfirmationCoordinator.Decision) { self.decision = decision }
    func requestApproval(toolName: String, argumentSummary: String)
    async -> ToolConfirmationCoordinator.Decision {
        askedAbout.append(toolName)
        return decision
    }
}

/// A broker whose user "edited" fields on the card before answering. Hands
/// back raw edits, as the real coordinator does — including, in the tests,
/// keys that must never be editable, to prove the registry drops them.
final class EditingStubBroker: ToolPermissionBroker {
    let decision: ToolConfirmationCoordinator.Decision
    let editedTextsByArgumentKey: [String: String]
    private(set) var askedAbout: [String] = []
    init(decision: ToolConfirmationCoordinator.Decision, editedTextsByArgumentKey: [String: String]) {
        self.decision = decision
        self.editedTextsByArgumentKey = editedTextsByArgumentKey
    }
    func requestApproval(toolName: String, argumentSummary: String) async -> ToolConfirmationCoordinator.Decision {
        askedAbout.append(toolName)
        return decision
    }
    func requestApprovalAllowingEdits(toolName: String, toolInput: JSONValue) async -> ToolApprovalOutcome {
        askedAbout.append(toolName)
        return ToolApprovalOutcome(decision: decision, editedTextsByArgumentKey: editedTextsByArgumentKey)
    }
}

final class CapturedInput: @unchecked Sendable { var value: JSONValue? }
final class RecordedSteps: @unchecked Sendable { var values: [AgentStepRecord] = [] }

func speechRun(_ provider: ScriptedProvider, _ registry: AgentToolRegistry)
async -> (observed: [String], speakable: [String]) {
    let observed = Deltas(); let speakable = Deltas()
    let runner = AgentTurnRunner(modelProvider: provider, toolRegistry: registry,
                                 speakConfirmation: { _ in })
    _ = try? await runner.run(
        userText: "do the thing", images: [], systemPrompt: "sys", conversationHistory: [],
        onNarration: { _ in }, onStep: { _ in },
        onModelTextDelta: { observed.values.append($0) },
        onSpeakableTextDelta: { speakable.values.append($0) })
    return (observed.values, speakable.values)
}

func toolCall(_ id: String, _ name: String, _ input: JSONValue = .object([:]))
-> (id: String, name: String, input: JSONValue) { (id: id, name: name, input: input) }

func definition(_ name: String, _ metadata: ToolMetadata) -> BuddyToolDefinition {
    BuddyToolDefinition(name: name, description: "test tool",
                        inputSchema: .object(["type": .string("object"),
                                              "properties": .object([:])]),
                        metadata: metadata)
}

@MainActor func run(_ runner: AgentTurnRunner, images: [(data: Data, label: String)] = [],
                    text: String = "do the thing",
                    history: [BuddyChatMessage] = [],
                    onDelta: @escaping @MainActor @Sendable (String) -> Void = { _ in })
async throws -> AgentTurnRunner.Outcome {
    try await runner.run(userText: text, images: images, systemPrompt: "sys",
                         conversationHistory: history, onNarration: { _ in }, onStep: { _ in },
                         onModelTextDelta: onDelta)
}

/// A readable one-line rendering of a run of messages: the role, then the kind
/// of each block in the order it appears.
///
/// Ordering is the whole point of these tests, so the assertions compare
/// shapes rather than probing for the presence of a block — a check that only
/// asks "is there a tool call in here somewhere" passes just as happily on a
/// history that put it in the wrong place.
func messageShape(_ messages: [BuddyChatMessage]) -> [String] {
    messages.map { message in
        let role = message.role == .user ? "user" : "assistant"
        let blocks = message.blocks.map { block -> String in
            switch block {
            case .text(let value): return "text(\(value))"
            case .toolUse(_, let name, _): return "toolUse(\(name))"
            case .toolResult(_, let name, _, _): return "toolResult(\(name))"
            case .image(_, let label): return "image(\(label))"
            case .providerReplay(let providerFamily, _): return "providerReplay(\(providerFamily))"
            }
        }
        return "\(role)[\(blocks.joined(separator: " "))]"
    }
}

// MARK: - Suite

@MainActor func suite() async {

    section("1. the injected registry is the one that executes")
    do {
        let injected = AgentToolRegistry.makeEmptyForTesting()
        let sharedRan = Ran(); let injectedRan = Ran()
        injected.setPermissionBroker(StubBroker(decision: .approved))
        injected.register(definition("probe", .reading())) { _ in injectedRan.value = true; return "injected ran" }
        // A tool of the SAME NAME on the singleton, so a fallback to .shared
        // would still "work" and would otherwise go unnoticed.
        AgentToolRegistry.shared.register(definition("probe", .reading())) { _ in
            sharedRan.value = true; return "shared ran"
        }
        let provider = ScriptedProvider(turns: [
            BuddyChatTurn(text: "checking.", toolUses: [toolCall("t1", "probe")], stopReason: .toolUse),
            BuddyChatTurn(text: "all done.", stopReason: .endTurn),
        ])
        let runner = AgentTurnRunner(modelProvider: provider, toolRegistry: injected,
                                     speakConfirmation: { _ in })
        let outcome = try? await run(runner)
        check("injected registry executed the tool", injectedRan.value)
        check("shared registry did NOT execute", !sharedRan.value,
              "the runner fell back to AgentToolRegistry.shared")
        check("turn completed on the second pass", outcome?.terminalText == "all done.")
    }

    section("2. permission boundary")
    do {
        // read-only: must not prompt
        let registry = AgentToolRegistry.makeEmptyForTesting()
        let broker = StubBroker(decision: .declined(reason: "should not be consulted"))
        registry.setPermissionBroker(broker)
        let ran = Ran()
        registry.register(definition("safe_read", .reading())) { _ in ran.value = true; return "read ok" }
        let provider = ScriptedProvider(turns: [
            BuddyChatTurn(text: "", toolUses: [toolCall("t1", "safe_read")], stopReason: .toolUse),
            BuddyChatTurn(text: "finished.", stopReason: .endTurn),
        ])
        _ = try? await run(AgentTurnRunner(modelProvider: provider, toolRegistry: registry,
                                           speakConfirmation: { _ in }))
        check("read-only tool ran", ran.value)
        check("read-only tool was NOT asked about", broker.askedAbout.isEmpty, broker.askedAbout.description)
    }
    do {
        // confirmation-required, approved
        let registry = AgentToolRegistry.makeEmptyForTesting()
        let broker = StubBroker(decision: .approved)
        registry.setPermissionBroker(broker)
        let ran = Ran()
        registry.register(definition("danger", .writing())) { _ in ran.value = true; return "did it" }
        let provider = ScriptedProvider(turns: [
            BuddyChatTurn(text: "", toolUses: [toolCall("t1", "danger")], stopReason: .toolUse),
            BuddyChatTurn(text: "finished.", stopReason: .endTurn),
        ])
        _ = try? await run(AgentTurnRunner(modelProvider: provider, toolRegistry: registry,
                                           speakConfirmation: { _ in }))
        check("confirmation-required tool WAS asked about", broker.askedAbout == ["danger"],
              broker.askedAbout.description)
        check("approved tool ran", ran.value)
    }
    do {
        // confirmation-required, denied
        let registry = AgentToolRegistry.makeEmptyForTesting()
        let broker = StubBroker(decision: .declined(reason: "user said no"))
        registry.setPermissionBroker(broker)
        let ran = Ran()
        registry.register(definition("danger", .writing())) { _ in ran.value = true; return "did it" }
        let provider = ScriptedProvider(turns: [
            BuddyChatTurn(text: "", toolUses: [toolCall("t1", "danger")], stopReason: .toolUse),
            BuddyChatTurn(text: "understood.", stopReason: .endTurn),
        ])
        let outcome = try? await run(AgentTurnRunner(modelProvider: provider, toolRegistry: registry,
                                                     speakConfirmation: { _ in }))
        check("denied tool was asked about", broker.askedAbout == ["danger"])
        check("denied tool did NOT execute", !ran.value, "implementation ran without approval")
        check("turn still completes after a denial", outcome?.terminalText == "understood.")
    }

    section("3. tool results feed the next iteration")
    do {
        let registry = AgentToolRegistry.makeEmptyForTesting()
        registry.setPermissionBroker(StubBroker(decision: .approved))
        registry.register(definition("lookup", .reading())) { _ in "the answer is 42" }
        let provider = ScriptedProvider(turns: [
            BuddyChatTurn(text: "one moment.", toolUses: [toolCall("t1", "lookup")], stopReason: .toolUse),
            BuddyChatTurn(text: "it is 42.", stopReason: .endTurn),
        ])
        let outcome = try? await run(AgentTurnRunner(modelProvider: provider, toolRegistry: registry,
                                                     speakConfirmation: { _ in }))
        check("two model passes happened", provider.receivedRequests.count == 2,
              "\(provider.receivedRequests.count)")
        let second = provider.receivedRequests.last
        let resultBlocks = second?.messages.flatMap(\.blocks).compactMap { block -> String? in
            if case .toolResult(_, let name, let content, _) = block { return "\(name):\(content)" }
            return nil
        } ?? []
        check("tool result reached the second request", resultBlocks == ["lookup:the answer is 42"],
              resultBlocks.description)
        check("prior tool call recorded on the assistant turn",
              second?.messages.flatMap(\.blocks).contains { if case .toolUse = $0 { return true }; return false } == true)
        check("final answer returned", outcome?.terminalText == "it is 42.")
    }

    section("4. image attaches to iteration 0 only")
    do {
        let registry = AgentToolRegistry.makeEmptyForTesting()
        registry.setPermissionBroker(StubBroker(decision: .approved))
        registry.register(definition("lookup", .reading())) { _ in "result" }
        let provider = ScriptedProvider(turns: [
            BuddyChatTurn(text: "looking.", toolUses: [toolCall("t1", "lookup")], stopReason: .toolUse),
            BuddyChatTurn(text: "done.", stopReason: .endTurn),
        ])
        _ = try? await run(AgentTurnRunner(modelProvider: provider, toolRegistry: registry,
                                           speakConfirmation: { _ in }),
                           images: [(data: Data([0x01, 0x02]), label: "screen 1")])
        func imageCount(_ request: ModelRequest?) -> Int {
            request?.messages.flatMap(\.blocks).filter { if case .image = $0 { return true }; return false }.count ?? -1
        }
        check("iteration 0 carries the image", imageCount(provider.receivedRequests.first) == 1,
              "\(imageCount(provider.receivedRequests.first))")
        check("iteration 1 does NOT resend it", imageCount(provider.receivedRequests.last) == 0,
              "\(imageCount(provider.receivedRequests.last)) — costs ~6.3s of prompt eval")
        check("the two requests differ", provider.receivedRequests.count == 2)
    }

    section("5. streaming plumbing")
    do {
        let registry = AgentToolRegistry.makeEmptyForTesting()
        let provider = ScriptedProvider(turns: [BuddyChatTurn(text: "Hi there. How are you?")],
                                        deltas: [["Hi", " there.", " How are you?"]],
                                        delayBetweenDeltas: 0.05)
        let seen = Deltas()
        let sawDeltaBeforeReturn = Ran()
        provider.onFirstDelta = { sawDeltaBeforeReturn.value = true }
        let outcome = try? await run(AgentTurnRunner(modelProvider: provider, toolRegistry: registry,
                                                     speakConfirmation: { _ in }),
                                     onDelta: { seen.values.append($0) })
        check("deltas reach the runtime", seen.values == ["Hi", " there.", " How are you?"],
              seen.values.description)
        check("deltas are increments, not snapshots", seen.values.joined() == "Hi there. How are you?")
        check("a delta is observed before the turn returns", sawDeltaBeforeReturn.value)
        check("terminal text still parsed from the whole reply",
              outcome?.terminalText == "Hi there. How are you?")
        // What the streamer WOULD speak, if speech were wired up.
        var spoken: [String] = []
        let streamer = SpokenSentenceStreamer(onSentence: { spoken.append($0) })
        for delta in seen.values { streamer.append(delta) }
        streamer.finish()
        check("streamer would speak clean sentences", spoken == ["Hi there.", "How are you?"],
              spoken.description)
    }

    section("6. speech safety — nothing speculative is ever spoken")
    do {
        // A tool-bearing iteration: its text is narration, never speech.
        let registry = AgentToolRegistry.makeEmptyForTesting()
        registry.setPermissionBroker(StubBroker(decision: .approved))
        registry.register(definition("lookup", .reading())) { _ in "42" }
        let provider = ScriptedProvider(
            turns: [
                BuddyChatTurn(text: "it's  right now.",
                              toolUses: [toolCall("t1", "lookup")], stopReason: .toolUse),
                BuddyChatTurn(text: "it is 42.", stopReason: .endTurn),
            ],
            deltas: [["it's ", " right now."], ["it is ", "42."]])
        let result = await speechRun(provider, registry)
        check("tool-bearing iteration deltas ARE observed", result.observed.contains("it's "))
        check("tool-bearing iteration is NEVER spoken",
              !result.speakable.contains { $0.contains("right now") },
              result.speakable.description)
        check("only the terminal answer is speakable",
              result.speakable == ["it is ", "42."], result.speakable.description)
    }
    do {
        // Malformed / ambiguous: the model tried to call a tool and failed, so
        // the surrounding text is not an answer.
        let registry = AgentToolRegistry.makeEmptyForTesting()
        let provider = ScriptedProvider(
            turns: [BuddyChatTurn(text: "hold on.", stopReason: .endTurn,
                                  malformedToolCallDescriptions: ["[TOOL:lookup:{not json}]"])],
            deltas: [["hold ", "on."]])
        let result = await speechRun(provider, registry)
        check("malformed output is still observed", result.observed == ["hold ", "on."])
        check("malformed/ambiguous output is NEVER spoken", result.speakable.isEmpty,
              result.speakable.description)
    }
    do {
        // Clean single-pass answer: speakable, and delivered as deltas.
        let registry = AgentToolRegistry.makeEmptyForTesting()
        let provider = ScriptedProvider(
            turns: [BuddyChatTurn(text: "Hi there. How are you?", stopReason: .endTurn)],
            deltas: [["Hi", " there.", " How are you?"]])
        let result = await speechRun(provider, registry)
        check("terminal tool-free answer IS speakable",
              result.speakable == ["Hi", " there.", " How are you?"], result.speakable.description)
        check("speakable text is delivered as deltas, not one blob",
              result.speakable.count == 3, "\(result.speakable.count)")
        var spoken: [String] = []
        let streamer = SpokenSentenceStreamer(onSentence: { spoken.append($0) })
        for delta in result.speakable { streamer.append(delta) }
        streamer.finish()
        check("sentence-by-sentence synthesis still works",
              spoken == ["Hi there.", "How are you?"], spoken.description)
    }
    do {
        // Hitting the iteration cap with calls outstanding is not a clean
        // answer, so it must not be spoken either.
        let registry = AgentToolRegistry.makeEmptyForTesting()
        registry.setPermissionBroker(StubBroker(decision: .approved))
        registry.register(definition("lookup", .reading())) { _ in "again" }
        let looping = BuddyChatTurn(text: "still checking.",
                                    toolUses: [toolCall("t", "lookup")], stopReason: .toolUse)
        let provider = ScriptedProvider(turns: Array(repeating: looping, count: 4),
                                        deltas: Array(repeating: ["still ", "checking."], count: 4))
        let result = await speechRun(provider, registry)
        check("iteration-cap text is NEVER spoken", result.speakable.isEmpty,
              result.speakable.description)
    }

    section("7. cancellation is not a provider failure")
    do {
        let registry = AgentToolRegistry.makeEmptyForTesting()
        let provider = ScriptedProvider(turns: [BuddyChatTurn(text: "long answer")],
                                        deltas: [Array(repeating: "word ", count: 100)],
                                        delayBetweenDeltas: 0.03)
        let runner = AgentTurnRunner(modelProvider: provider, toolRegistry: registry,
                                     speakConfirmation: { _ in })
        let task = Task { @MainActor in try await run(runner) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        do {
            _ = try await task.value
            check("cancelled run throws", false, "returned normally")
        } catch is CancellationError {
            check("cancellation surfaces as CancellationError", true)
        } catch {
            check("cancellation surfaces as CancellationError", false, "\(type(of: error))")
        }
    }

    section("8. second provider — native structured tool calls")
    do {
        // 1. normal text response
        let registry = AgentToolRegistry.makeEmptyForTesting()
        let provider = NativeToolCallProvider(script: [
            .init(text: "the answer is straightforward.", deltas: ["the answer ", "is straightforward."],
                  promptTokens: 812, outputTokens: 9)])
        let speakable = Deltas(); let observed = Deltas()
        let runner = AgentTurnRunner(modelProvider: provider, toolRegistry: registry,
                                     speakConfirmation: { _ in })
        let outcome = try? await runner.run(
            userText: "explain", images: [], systemPrompt: "sys", conversationHistory: [],
            onNarration: { _ in }, onStep: { _ in },
            onModelTextDelta: { observed.values.append($0) },
            onSpeakableTextDelta: { speakable.values.append($0) })
        check("native provider: plain answer returned",
              outcome?.terminalText == "the answer is straightforward.")
        check("native provider: deltas observed", observed.values.count == 2)
        check("native provider: clean answer IS speakable",
              speakable.values == ["the answer ", "is straightforward."], speakable.values.description)
        check("native provider: nil ceiling fell through to ITS OWN default",
              provider.resolvedCeilings == [NativeToolCallProvider.ownDefaultMaxOutputTokens],
              provider.resolvedCeilings.description)
        check("runner sent no ceiling at all",
              provider.receivedRequests.first?.maxOutputTokens == nil)
    }
    do {
        // 2-5. native tool call → registry execution → next iteration → terminal text
        let registry = AgentToolRegistry.makeEmptyForTesting()
        registry.setPermissionBroker(StubBroker(decision: .approved))
        let ran = Ran()
        registry.register(definition("fetch", .reading())) { input in
            ran.value = true
            if case .object(let o) = input, case .string(let q)? = o["query"] { return "result for \(q)" }
            return "result"
        }
        let provider = NativeToolCallProvider(script: [
            .init(text: "looking that up.",
                  toolCalls: [toolCall("call_abc", "fetch", .object(["query": .string("wisp")]))],
                  promptTokens: 900, outputTokens: 12),
            .init(text: "here is what I found.", deltas: ["here is ", "what I found."],
                  promptTokens: 1400, outputTokens: 15),
        ])
        let speakable = Deltas()
        let runner = AgentTurnRunner(modelProvider: provider, toolRegistry: registry,
                                     speakConfirmation: { _ in })
        let outcome = try? await runner.run(
            userText: "look it up", images: [], systemPrompt: "sys", conversationHistory: [],
            onNarration: { _ in }, onStep: { _ in },
            onSpeakableTextDelta: { speakable.values.append($0) })
        check("native tool call executed via the INJECTED registry", ran.value)
        check("two iterations ran", provider.receivedRequests.count == 2)
        check("terminal text follows tool execution",
              outcome?.terminalText == "here is what I found.")
        check("tool-bearing iteration NOT spoken",
              !speakable.values.contains { $0.contains("looking") }, speakable.values.description)
        check("only terminal text is speakable",
              speakable.values == ["here is ", "what I found."], speakable.values.description)
        // The structured round-trip: the tool call must survive as blocks.
        let second = provider.receivedRequests.last
        let blocks = second?.messages.flatMap(\.blocks) ?? []
        check("prior tool call preserved as a structured toolUse block",
              blocks.contains { if case .toolUse(let id, _, _) = $0 { return id == "call_abc" }; return false })
        check("tool result preserved as a structured toolResult block",
              blocks.contains { if case .toolResult(_, _, let c, _) = $0 { return c == "result for wisp" }; return false })
        check("tool input JSON survived the round trip",
              blocks.contains { if case .toolUse(_, _, let i) = $0,
                                   case .object(let o) = i, case .string(let q)? = o["query"] { return q == "wisp" }
                                return false })
    }
    do {
        // 6. cancellation with a native provider
        let registry = AgentToolRegistry.makeEmptyForTesting()
        let provider = NativeToolCallProvider(
            script: [.init(text: "long", deltas: Array(repeating: "tok ", count: 100))],
            delayBetweenDeltas: 0.03)
        let runner = AgentTurnRunner(modelProvider: provider, toolRegistry: registry,
                                     speakConfirmation: { _ in })
        let task = Task { @MainActor in try await run(runner) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        do { _ = try await task.value; check("native provider cancellation throws", false) }
        catch is CancellationError { check("native provider: CancellationError preserved", true) }
        catch { check("native provider: CancellationError preserved", false, "\(type(of: error))") }
    }
    do {
        // 9. image stripping, with a provider that would happily resend images
        let registry = AgentToolRegistry.makeEmptyForTesting()
        registry.setPermissionBroker(StubBroker(decision: .approved))
        registry.register(definition("fetch", .reading())) { _ in "ok" }
        let provider = NativeToolCallProvider(script: [
            .init(text: "looking.", toolCalls: [toolCall("c1", "fetch")]),
            .init(text: "done."),
        ])
        _ = try? await run(AgentTurnRunner(modelProvider: provider, toolRegistry: registry,
                                           speakConfirmation: { _ in }),
                           images: [(data: Data([9, 9]), label: "screen 1")])
        func images(_ r: ModelRequest?) -> Int {
            r?.messages.flatMap(\.blocks).filter { if case .image = $0 { return true }; return false }.count ?? -1
        }
        check("native provider: image on iteration 0", images(provider.receivedRequests.first) == 1)
        check("native provider: image NOT resent on iteration 1",
              images(provider.receivedRequests.last) == 0,
              "\(images(provider.receivedRequests.last))")
    }
    do {
        // 10. token accounting from a non-Ollama source
        let registry = AgentToolRegistry.makeEmptyForTesting()
        let provider = NativeToolCallProvider(script: [
            .init(text: "counted.", promptTokens: 4242, outputTokens: 77)])
        var lastStepDuration: TimeInterval = -1
        let runner = AgentTurnRunner(modelProvider: provider, toolRegistry: registry,
                                     speakConfirmation: { _ in })
        _ = try? await runner.run(userText: "x", images: [], systemPrompt: "sys",
                                  conversationHistory: [], onNarration: { _ in },
                                  onStep: { step in if case .modelCall = step.kind { lastStepDuration = step.durationSeconds } })
        check("duration from a non-Ollama provider reaches the step record",
              lastStepDuration > 0, "\(lastStepDuration)")
    }

    section("9. Phase 1 confirmation timeout preserved")
    check("per-tool timeout outlasts the confirmation window",
          AgentTurnRunner.perToolTimeoutSecondsForTesting
            > ToolConfirmationCoordinator.confirmationTimeoutSeconds,
          "\(AgentTurnRunner.perToolTimeoutSecondsForTesting) vs \(ToolConfirmationCoordinator.confirmationTimeoutSeconds)")
    check("timeout is confirmation window plus work allowance, not a flat 20s",
          AgentTurnRunner.perToolTimeoutSecondsForTesting
            == ToolConfirmationCoordinator.confirmationTimeoutSeconds + 20,
          "\(AgentTurnRunner.perToolTimeoutSecondsForTesting)")

    section("10. the canonical record of a turn")
    //
    // The runner is the only thing that watches a whole turn happen, so it is
    // the only thing that can say what the turn was. These tests are about
    // that record being faithful — the same blocks, in the same order the
    // model produced them, including the ones the requests themselves
    // deliberately left out.

    do {
        let registry = AgentToolRegistry.makeEmptyForTesting()
        registry.setPermissionBroker(StubBroker(decision: .approved))
        registry.register(definition("lookup", .reading())) { _ in "the answer is 42" }

        // Prose, then a call, then more prose. This is precisely the shape the
        // old representation could not describe: joined text plus a separate
        // list of calls flattens it to the same thing as a model that said
        // both sentences first and called the tool afterwards.
        let provider = ScriptedProvider(turns: [
            BuddyChatTurn(content: [
                .text("checking that now."),
                .toolUse(id: "t1", name: "lookup", input: .object([:])),
                .text("one second."),
            ], stopReason: .toolUse),
            BuddyChatTurn(text: "it is 42.", stopReason: .endTurn),
        ])
        let outcome = try? await run(AgentTurnRunner(modelProvider: provider, toolRegistry: registry,
                                                     speakConfirmation: { _ in }))

        check("the outcome records the whole turn, not just its last sentence",
              messageShape(outcome?.messages ?? []) == [
                  "user[text(do the thing)]",
                  "assistant[text(checking that now.) toolUse(lookup) text(one second.)]",
                  "user[toolResult(lookup)]",
                  "assistant[text(it is 42.)]",
              ],
              messageShape(outcome?.messages ?? []).description)

        // The record is only worth keeping if the next request is built from
        // it unaltered. The assistant message replayed on iteration 1 must be
        // the one the model actually produced.
        let secondRequest = provider.receivedRequests.last
        check("the replayed assistant turn keeps the model's own ordering",
              messageShape(secondRequest?.messages ?? []) == [
                  "user[text(do the thing)]",
                  "assistant[text(checking that now.) toolUse(lookup) text(one second.)]",
                  "user[toolResult(lookup)]",
              ],
              messageShape(secondRequest?.messages ?? []).description)
    }

    do {
        // A turn that produced no prose at all still has to record its call.
        // An assistant message with an empty text block would tell the model
        // it once answered with silence.
        let registry = AgentToolRegistry.makeEmptyForTesting()
        registry.setPermissionBroker(StubBroker(decision: .approved))
        registry.register(definition("lookup", .reading())) { _ in "result" }
        let provider = ScriptedProvider(turns: [
            BuddyChatTurn(content: [.toolUse(id: "t1", name: "lookup", input: .object([:]))],
                          stopReason: .toolUse),
            BuddyChatTurn(text: "done.", stopReason: .endTurn),
        ])
        let outcome = try? await run(AgentTurnRunner(modelProvider: provider, toolRegistry: registry,
                                                     speakConfirmation: { _ in }))
        check("a wordless tool call carries no empty text block",
              messageShape(outcome?.messages ?? []) == [
                  "user[text(do the thing)]",
                  "assistant[toolUse(lookup)]",
                  "user[toolResult(lookup)]",
                  "assistant[text(done.)]",
              ],
              messageShape(outcome?.messages ?? []).description)
    }

    do {
        // Section 4 pins that the image is sent once. This pins the other half
        // of that decision: the request carries less than the conversation
        // holds. Stripping the image from `messages` in place would satisfy
        // section 4 just as well and quietly leave the record claiming no
        // screenshot was ever attached.
        let registry = AgentToolRegistry.makeEmptyForTesting()
        registry.setPermissionBroker(StubBroker(decision: .approved))
        registry.register(definition("lookup", .reading())) { _ in "result" }
        let provider = ScriptedProvider(turns: [
            BuddyChatTurn(text: "looking.", toolUses: [toolCall("t1", "lookup")], stopReason: .toolUse),
            BuddyChatTurn(text: "done.", stopReason: .endTurn),
        ])
        let outcome = try? await run(AgentTurnRunner(modelProvider: provider, toolRegistry: registry,
                                                     speakConfirmation: { _ in }),
                                     images: [(data: Data([0x01, 0x02]), label: "screen 1")])
        check("the record keeps the screenshot the second request dropped",
              messageShape(outcome?.messages ?? []).first == "user[image(screen 1) text(do the thing)]",
              messageShape(outcome?.messages ?? []).first ?? "nothing")

        let imagesInSecondRequest = provider.receivedRequests.last?.messages
            .flatMap(\.blocks).filter { if case .image = $0 { return true }; return false }.count
        check("and the second request still does not resend it", imagesInSecondRequest == 0,
              "\(imagesInSecondRequest ?? -1)")
    }

    do {
        // History now arrives as typed messages rather than string pairs, so a
        // past turn can say more than "this was asked, that came back". What
        // the caller hands over must reach the provider unedited, and must not
        // be reported back as though this turn had produced it.
        let registry = AgentToolRegistry.makeEmptyForTesting()
        let priorTurn: [BuddyChatMessage] = [
            BuddyChatMessage(role: .user, text: "what is on my screen?"),
            BuddyChatMessage(role: .assistant, blocks: [
                .text("let me look."),
                .toolUse(id: "old", name: "read_page", input: .object([:])),
            ]),
            BuddyChatMessage(role: .user, blocks: [
                .toolResult(toolUseID: "old", toolName: "read_page",
                            content: "a settings window", isError: false),
            ]),
            BuddyChatMessage(role: .assistant, text: "a settings window."),
        ]
        let provider = ScriptedProvider(turns: [BuddyChatTurn(text: "understood.")])
        let outcome = try? await run(AgentTurnRunner(modelProvider: provider, toolRegistry: registry,
                                                     speakConfirmation: { _ in }),
                                     text: "and now?", history: priorTurn)

        check("history reaches the provider exactly as it was given",
              Array((messageShape(provider.receivedRequests.first?.messages ?? [])).prefix(4))
                == messageShape(priorTurn),
              messageShape(provider.receivedRequests.first?.messages ?? []).description)
        check("this turn's question follows the history",
              messageShape(provider.receivedRequests.first?.messages ?? []).last
                == "user[text(and now?)]")
        check("the outcome reports only what this turn added",
              messageShape(outcome?.messages ?? []) == [
                  "user[text(and now?)]",
                  "assistant[text(understood.)]",
              ],
              messageShape(outcome?.messages ?? []).description)
    }

    do {
        // Running out of iterations with calls still outstanding is the case
        // where an honest record matters most: the transcript should show that
        // the model was still asking, not that it stopped and answered.
        let registry = AgentToolRegistry.makeEmptyForTesting()
        registry.setPermissionBroker(StubBroker(decision: .approved))
        registry.register(definition("lookup", .reading())) { _ in "result" }
        let stillCalling = BuddyChatTurn(content: [
            .text("still working."),
            .toolUse(id: "t", name: "lookup", input: .object([:])),
        ], stopReason: .toolUse)
        let provider = ScriptedProvider(turns: Array(repeating: stillCalling, count: 8))
        let outcome = try? await run(AgentTurnRunner(modelProvider: provider, toolRegistry: registry,
                                                     speakConfirmation: { _ in }))
        check("hitting the cap is reported", outcome?.hitIterationCap == true)
        check("the closing message still shows the call that was never answered",
              messageShape(outcome?.messages ?? []).last
                == "assistant[text(still working.) toolUse(lookup)]",
              messageShape(outcome?.messages ?? []).last ?? "nothing")
    }

    section("11. edits on the confirmation card reach the tool that runs")
    do {
        // The user rewrote the subject and (via a buggy or hostile broker)
        // also "edited" the recipient. Only the subject may land.
        let registry = AgentToolRegistry.makeEmptyForTesting()
        let broker = EditingStubBroker(decision: .approved, editedTextsByArgumentKey: [
            "subject": "Lunch moved to 1pm",
            "to": "attacker@example.com",
        ])
        registry.setPermissionBroker(broker)
        let receivedInput = CapturedInput()
        registry.register(definition("gmail__send_email", .writing())) { input in
            receivedInput.value = input; return "sent."
        }
        let modelInput: JSONValue = .object([
            "to": .string("sam@example.com"), "subject": .string("Lunch"), "body": .string("See you at noon."),
        ])
        let provider = ScriptedProvider(turns: [
            BuddyChatTurn(text: "", toolUses: [toolCall("t1", "gmail__send_email", modelInput)], stopReason: .toolUse),
            BuddyChatTurn(text: "done.", stopReason: .endTurn),
        ])
        let recordedSteps = RecordedSteps()
        let outcome = try? await AgentTurnRunner(modelProvider: provider, toolRegistry: registry,
                                                 speakConfirmation: { _ in })
            .run(userText: "email sam", images: [], systemPrompt: "sys", conversationHistory: [],
                 onNarration: { _ in }, onStep: { recordedSteps.values.append($0) })
        check("the edited approval was asked for", broker.askedAbout == ["gmail__send_email"], broker.askedAbout.description)
        if case .object(let ranFields)? = receivedInput.value {
            check("the tool ran with the edited subject", ranFields["subject"] == .string("Lunch moved to 1pm"),
                  String(describing: ranFields["subject"]))
            check("an edit to the recipient was dropped", ranFields["to"] == .string("sam@example.com"),
                  String(describing: ranFields["to"]))
            check("the untouched body ran as written", ranFields["body"] == .string("See you at noon."))
        } else {
            check("the tool ran", false, "it did not")
        }
        let toolResultTexts = (outcome?.messages ?? []).flatMap(\.blocks).compactMap { block -> String? in
            if case .toolResult(_, _, let content, _) = block { return content }
            return nil
        }
        check("the model is told the user edited the subject",
              toolResultTexts.first.map { $0.hasPrefix("sent.") && $0.contains("subject: \"Lunch moved to 1pm\"") } == true,
              toolResultTexts.first ?? "no result")
        let toolStepDetail = recordedSteps.values.first { if case .tool = $0.kind { return true }; return false }?.detail ?? ""
        check("History records the input that ran, not the model's",
              toolStepDetail.contains("Lunch moved to 1pm") && !toolStepDetail.contains("attacker"), toolStepDetail)
    }
    do {
        // A broker with no editable card (every older stub) runs the call as asked.
        let registry = AgentToolRegistry.makeEmptyForTesting()
        registry.setPermissionBroker(StubBroker(decision: .approved))
        let receivedInput = CapturedInput()
        registry.register(definition("gmail__send_email", .writing())) { input in
            receivedInput.value = input; return "sent."
        }
        let modelInput: JSONValue = .object(["to": .string("sam@example.com"), "subject": .string("Lunch")])
        let provider = ScriptedProvider(turns: [
            BuddyChatTurn(text: "", toolUses: [toolCall("t1", "gmail__send_email", modelInput)], stopReason: .toolUse),
            BuddyChatTurn(text: "done.", stopReason: .endTurn),
        ])
        let outcome = try? await run(AgentTurnRunner(modelProvider: provider, toolRegistry: registry,
                                                     speakConfirmation: { _ in }))
        check("without edits the model's input runs unchanged", receivedInput.value == modelInput)
        let toolResultTexts = (outcome?.messages ?? []).flatMap(\.blocks).compactMap { block -> String? in
            if case .toolResult(_, _, let content, _) = block { return content }
            return nil
        }
        check("and the result carries no edit note", toolResultTexts == ["sent."], toolResultTexts.description)
    }
    do {
        // Edits never travel with a decline.
        let registry = AgentToolRegistry.makeEmptyForTesting()
        registry.setPermissionBroker(EditingStubBroker(decision: .declined(reason: "you declined"),
                                                       editedTextsByArgumentKey: ["subject": "x"]))
        let ran = Ran()
        registry.register(definition("gmail__send_email", .writing())) { _ in ran.value = true; return "sent." }
        let declinedOutcome = await registry.invoke(name: "gmail__send_email",
                                                    input: .object(["to": .string("a@b.com"), "subject": .string("Hi")]))
        check("a declined call with edits does not run", !ran.value && declinedOutcome.wasDeclined)
    }
    do {
        // Prepared input (send_imessage's path): edits apply to the prepared
        // input, so the resolved handle survives and the message is the user's.
        let registry = AgentToolRegistry.makeEmptyForTesting()
        registry.setPermissionBroker(EditingStubBroker(decision: .approved, editedTextsByArgumentKey: [
            "message": "running 10 min late", "handle": "+15550000000",
        ]))
        let receivedInput = CapturedInput()
        registry.register(
            definition("send_imessage", ToolMetadata(readOnly: false, externalSideEffect: true, dataSource: .localMachine)),
            preparingInputWith: { _ in
                .ready(.object(["to": .string("Mom"), "handle": .string("+15551234567"), "message": .string("running late")]))
            }
        ) { input in receivedInput.value = input; return "sent to Mom by imessage." }
        _ = await registry.invoke(name: "send_imessage", input: .object(["to": .string("mom"), "message": .string("running late")]))
        if case .object(let ranFields)? = receivedInput.value {
            check("prepared send ran with the edited message", ranFields["message"] == .string("running 10 min late"))
            check("prepared send kept the resolved handle", ranFields["handle"] == .string("+15551234567"))
        } else {
            check("prepared send ran", false, "it did not")
        }
    }

    await anthropicProviderSuite()
    await claudeSubscriptionProviderSuite()
    composioConnectionsSuite()
    await buddyBotSuite()
    await buddyRedesignSuite()

    print("\n\(String(repeating: "─", count: 52))")
    print("  \(tally.passed) passed, \(tally.failed) failed, \(tally.passed + tally.failed) total")
    exit(tally.failed == 0 ? 0 : 1)
}

final class Ran: @unchecked Sendable { var value = false }
final class Deltas: @unchecked Sendable { var values: [String] = [] }

await suite()
