//
//  main.swift
//  ModelProviderContract
//
//  Contract and regression suite for the ModelProvider layer.
//
//  Run with ./Tests/ModelProviderContract/run.sh — it needs nothing installed
//  and nothing listening. It is deliberately not an XCTest: `leanring-buddy`
//  is a menu-bar app whose test bundle needs the whole module built, and these
//  assertions are about a handful of value types and one translator. Keeping
//  them runnable from a shell means they can be run in a second, on every
//  edit, without touching the app's TCC permissions.
//

import Foundation

let results = TestResults()

// A reply split exactly where the test wants it, so "exactly once" is provable.
let canonicalChunks = ["Hi", " there.", " How are you?"]
let canonicalReply = "Hi there. How are you?"

let server = FakeOllamaServer(script: .init(chunks: canonicalChunks))
server.start()

let provider = OllamaProvider(baseURL: server.baseURL, model: "qwen2.5vl:7b")

func request(
    _ text: String,
    tools: [BuddyToolDefinition] = [],
    image: Data? = nil,
    maxOutputTokens: Int? = nil
) -> ModelRequest {
    var blocks: [BuddyContentBlock] = []
    if let image { blocks.append(.image(data: image, label: "screen 1")) }
    blocks.append(.text(text))
    return ModelRequest(
        systemPrompt: "you are wisp.",
        messages: [BuddyChatMessage(role: .user, blocks: blocks)],
        tools: tools,
        maxOutputTokens: maxOutputTokens
    )
}

/// What the provider actually put in `options` on the wire.
func sentOption(_ server: FakeOllamaServer, _ key: String) -> Int? {
    guard let options = server.lastRequestJSON?["options"] as? [String: Any] else { return nil }
    return options[key] as? Int
}

let browserTool = BuddyToolDefinition(
    name: "browser_task",
    description: "Run a browser workflow.",
    inputSchema: .object([
        "type": .string("object"),
        "properties": .object(["site": .object(["type": .string("string")])]),
        "required": .array([.string("site")]),
    ]),
    metadata: .reading()
)
let readPageTool = BuddyToolDefinition(
    name: "read_page", description: "Read the page.",
    inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
    metadata: .reading()
)
let knownTools = [browserTool, readPageTool]

final class DeltaRecorder: @unchecked Sendable {
    var deltas: [String] = []
}

@MainActor
func runSuite() async {

    // ========================================================================
    results.section("1. accumulated → true deltas (the corruption guard)")
    // ========================================================================
    //
    // LocalOllamaAPI's legacy callback reports the whole reply so far, while
    // SpokenSentenceStreamer appends whatever it is handed. Wiring one to the
    // other without diffing produces 'HiHi there.Hi there.' — a real defect
    // this layer exists to prevent. These are the highest-value assertions in
    // the suite.

    server.setScript(.init(chunks: canonicalChunks))
    let recorder = DeltaRecorder()
    guard let turn = try? await provider.streamTurn(request("hello"), onTextDelta: {
        recorder.deltas.append($0)
    }) else {
        results.check("provider completed a turn", false)
        exit(results.summarise())
    }

    results.equal("each fragment delivered exactly once", recorder.deltas, canonicalChunks)
    results.equal("deltas join to the reply", recorder.deltas.joined(), canonicalReply)
    results.equal("delta count matches chunk count", recorder.deltas.count, canonicalChunks.count)
    results.check(
        "no delta repeats earlier text",
        !recorder.deltas.enumerated().contains { index, delta in
            index > 0 && delta.hasPrefix(recorder.deltas[0])
        },
        recorder.deltas.description
    )
    results.check(
        "no delta is a cumulative snapshot",
        !recorder.deltas.contains { $0.count >= canonicalReply.count && canonicalReply.count > 4 },
        recorder.deltas.description
    )

    // The end-to-end property, driven through the real SpokenSentenceStreamer.
    let streamer = SpokenSentenceStreamer(onSentence: { spoken.append($0) })
    for delta in recorder.deltas { streamer.append(delta) }
    streamer.finish()
    results.equal("real streamer speaks clean sentences", spoken, ["Hi there.", "How are you?"])
    results.check(
        "NO 'HiHi there.Hi there.' corruption",
        !spoken.contains { $0.contains("HiHi") || $0.contains("there.Hi") },
        spoken.description
    )
    results.check("nothing spoken twice", Set(spoken).count == spoken.count, spoken.description)

    // ========================================================================
    results.section("2. legacy path stays cumulative (must NOT be 'fixed')")
    // ========================================================================
    //
    // CompanionManager still calls analyzeImageStreaming. Changing what it
    // emits would change what the app speaks, so the old contract is pinned
    // here just as firmly as the new one.

    let legacyClient = LocalOllamaAPI(baseURL: server.baseURL, model: "qwen2.5vl:7b")
    let legacyRecorder = DeltaRecorder()
    let (legacyText, legacyDuration) = (try? await legacyClient.analyzeImageStreaming(
        images: [], systemPrompt: "sys", conversationHistory: [],
        userPrompt: "hello", onTextChunk: { legacyRecorder.deltas.append($0) }
    )) ?? ("", 0)

    results.equal("legacy callback is cumulative",
                  legacyRecorder.deltas, ["Hi", "Hi there.", "Hi there. How are you?"])
    results.equal("legacy returns the full reply", legacyText, canonicalReply)
    results.check("legacy reports a duration", legacyDuration > 0)
    results.check("the two contracts genuinely differ",
                  legacyRecorder.deltas != recorder.deltas)

    // ========================================================================
    results.section("3. ordinary terminal turn")
    // ========================================================================
    results.equal("text is the reply", turn.text, canonicalReply)
    results.check("stopReason is .endTurn", turn.stopReason == .endTurn)
    results.check("no toolUses", turn.toolUses.isEmpty)

    // ========================================================================
    results.section("4. token accounting and duration")
    // ========================================================================
    results.equal("prompt tokens preserved", turn.promptTokens, 1234)
    results.equal("output tokens preserved", turn.outputTokens, 7)
    results.check("duration recorded", turn.duration > 0, "\(turn.duration)")

    server.setScript(.init(chunks: ["ok."], promptTokens: nil, outputTokens: nil))
    let untracked = try? await provider.streamTurn(request("hi"), onTextDelta: { _ in })
    results.check("absent counts stay nil, not zero",
                  untracked?.promptTokens == nil && untracked?.outputTokens == nil)

    // ========================================================================
    results.section("5. tool calls")
    // ========================================================================
    server.setScript(.init(chunks: ["checking. ", "[TOOL:browser_task:", "{\"site\":\"a.com\"}]"]))
    let single = try? await provider.streamTurn(request("look it up", tools: knownTools),
                                                onTextDelta: { _ in })
    results.equal("one call surfaced", single?.toolUses.count, 1)
    results.equal("call name preserved", single?.toolUses.first?.name, "browser_task")
    results.check("stopReason is .toolUse", single?.stopReason == .toolUse)
    results.equal("narration kept as text", single?.text, "checking.")
    results.check("a tag split across deltas still parses",
                  single?.toolUses.count == 1,
                  "tags are parsed from the assembled reply, not per-delta")

    server.setScript(.init(chunks: ["one sec. [TOOL:browser_task:{\"site\":\"a.com\"}] [TOOL:read_page:{}]"]))
    let multiple = try? await provider.streamTurn(request("both", tools: knownTools),
                                                  onTextDelta: { _ in })
    results.equal("both calls surfaced", multiple?.toolUses.count, 2)
    results.equal("order preserved", multiple?.toolUses.map(\.name), ["browser_task", "read_page"])

    // ========================================================================
    results.section("6. malformed, unknown, echoed")
    // ========================================================================
    server.setScript(.init(chunks: ["hold on. [TOOL:browser_task:{not json}]"]))
    let malformed = try? await provider.streamTurn(request("x", tools: knownTools),
                                                   onTextDelta: { _ in })
    results.check("malformed yields no toolUse", malformed?.toolUses.isEmpty == true)
    results.check("malformed leaves .endTurn", malformed?.stopReason == .endTurn)
    results.check("malformed tag not spoken", malformed?.text.contains("[TOOL:") == false)

    server.setScript(.init(chunks: ["sure.\nlaunch_missiles: {\"target\":\"x\"}"]))
    let bareUnknown = try? await provider.streamTurn(request("x", tools: knownTools),
                                                     onTextDelta: { _ in })
    results.check("bare unknown name filtered by knownToolNames",
                  bareUnknown?.toolUses.isEmpty == true)

    server.setScript(.init(chunks: ["sure. [TOOL:launch_missiles:{\"target\":\"x\"}]"]))
    let bracketedUnknown = try? await provider.streamTurn(request("x", tools: knownTools),
                                                          onTextDelta: { _ in })
    // Deliberate: the registry answers an unknown name with "there is no tool
    // called X", which is how the model corrects itself. Filtering here would
    // silence that. Pinned so the behaviour is a decision, not an accident.
    results.equal("bracketed unknown passes through to the registry",
                  bracketedUnknown?.toolUses.count, 1)

    server.setScript(.init(chunks: ["sure, one moment. [TOOL:browser_task:{\"site\":\"…\"}]"]))
    let echoed = try? await provider.streamTurn(request("x", tools: knownTools),
                                                onTextDelta: { _ in })
    results.check("echoed prompt example rejected", echoed?.toolUses.isEmpty == true)
    results.check("echo leaves .endTurn", echoed?.stopReason == .endTurn)

    // Only the example's own tool can be an echo. cua-driver's
    // `list_windows {"on_screen_only": true}` is all-true like the example,
    // and dropping it ended a real turn with nothing done.
    server.setScript(.init(chunks: ["finding the window. [TOOL:read_page:{\"on_screen_only\":true}]"]))
    let allTrueOtherTool = try? await provider.streamTurn(request("x", tools: knownTools),
                                                          onTextDelta: { _ in })
    results.equal("an all-true call to a tool other than the example's is kept",
                  allTrueOtherTool?.toolUses.count, 1)
    results.check("that call ends the turn as a tool call", allTrueOtherTool?.stopReason == .toolUse)

    // ========================================================================
    results.section("7. exact JSON preservation")
    // ========================================================================
    server.setScript(.init(chunks: [
        "[TOOL:browser_task:{\"site\":\"a.com\",\"count\":3,\"deep\":true,\"nested\":{\"k\":[1,2]},\"none\":null}]"
    ]))
    let rich = try? await provider.streamTurn(request("x", tools: knownTools), onTextDelta: { _ in })
    if case .object(let input)? = rich?.toolUses.first?.input {
        results.check("string survives", { if case .string(let v)? = input["site"] { return v == "a.com" }; return false }())
        results.check("number survives", { if case .number(let v)? = input["count"] { return v == 3 }; return false }())
        results.check("bool stays bool, not 1", { if case .bool(let v)? = input["deep"] { return v }; return false }())
        results.check("nested object and array survive", {
            if case .object(let n)? = input["nested"], case .array(let a)? = n["k"] { return a.count == 2 }
            return false }())
        results.check("null survives", { if case .null? = input["none"] { return true }; return false }())
        results.equal("round-trips to the same JSON",
                      input["count"]?.untypedValue as? Int, 3)
    } else {
        results.check("tool input parsed as an object", false)
    }

    // ========================================================================
    results.section("8. [TOOL:...] never escapes the provider")
    // ========================================================================
    for (label, candidate) in [("single", single), ("multiple", multiple),
                               ("malformed", malformed), ("echoed", echoed), ("rich", rich)] {
        results.check("no tag residue in \(label) turn",
                      candidate.map { !$0.text.contains("[TOOL:") } ?? false,
                      candidate?.text ?? "nil")
    }

    // ========================================================================
    results.section("9. image preservation")
    // ========================================================================
    server.setScript(.init(chunks: ["a screenshot."]))
    let pixels = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    _ = try? await provider.streamTurn(request("what is this?", image: pixels),
                                       onTextDelta: { _ in })
    let sent = server.lastRequestJSON
    let sentMessages = sent?["messages"] as? [[String: Any]]
    let userMessage = sentMessages?.last
    let sentImages = userMessage?["images"] as? [String]
    results.equal("exactly one image on the wire", sentImages?.count, 1)
    results.equal("image bytes survive translation intact",
                  sentImages?.first, pixels.base64EncodedString())
    results.check("image label reaches the model",
                  (userMessage?["content"] as? String)?.contains("screen 1") == true,
                  (userMessage?["content"] as? String) ?? "nil")
    results.check("provider does NOT apply the caller's screenshot heuristic",
                  sentImages?.count == 1,
                  "a conversational prompt with an image must still send it")

    // A text-only request must not invent an images key.
    server.setScript(.init(chunks: ["no picture."]))
    _ = try? await provider.streamTurn(request("just talking"), onTextDelta: { _ in })
    let textOnly = (server.lastRequestJSON?["messages"] as? [[String: Any]])?.last
    results.check("no images key when none were supplied", textOnly?["images"] == nil)

    // ========================================================================
    results.section("10. capabilities and vision refusal")
    // ========================================================================
    results.equal("identifier names the model", provider.identifier, "ollama/qwen2.5vl:7b")
    results.check("declares vision", provider.capabilities.supportsVision)
    results.check("declares tools", provider.capabilities.supportsTools)
    results.check("does NOT claim native tool calls", !provider.capabilities.supportsNativeToolCalls)
    results.check("declares streaming", provider.capabilities.supportsStreaming)
    results.check("deployment is on this machine", !provider.deployment.sendsDataOffThisMachine)
    // Deployment is a separate type from ModelCapabilities, so "is this local"
    // cannot be asked of capabilities at all. That is enforced by the compiler
    // rather than by an assertion here — a runtime check would only be able to
    // assert `true`, which proves nothing.

    // A vision-incapable provider must refuse rather than drop the image.
    struct BlindProvider: ModelProvider {
        let identifier = "blind"
        let capabilities = ModelCapabilities(
            supportsVision: false, supportsTools: false, supportsNativeToolCalls: false,
            supportsStreaming: true, contextWindowTokens: 8192)
        let deployment = ModelDeployment(location: .onThisMachine)
        func streamTurn(_ request: ModelRequest,
                        onTextDelta: @escaping @MainActor @Sendable (String) -> Void)
        async throws -> BuddyChatTurn {
            try validateAgainstCapabilities(request)
            return BuddyChatTurn(text: "unreachable")
        }
    }
    do {
        _ = try await BlindProvider().streamTurn(request("see this?", image: pixels),
                                                 onTextDelta: { _ in })
        results.check("vision-incapable provider refuses an image", false)
    } catch BuddyChatError.visionUnsupported {
        results.check("vision-incapable provider refuses an image", true)
    } catch {
        results.check("vision-incapable provider refuses an image", false, "\(error)")
    }

    // ========================================================================
    results.section("11. output ceiling: nil defers, explicit is honoured")
    // ========================================================================
    //
    // The generic layer must not need to know Ollama's reply limit, and Ollama
    // must not lose ownership of its own default. Both are checked against
    // what actually reached the wire.

    server.setScript(.init(chunks: ["ok."]))
    _ = try? await provider.streamTurn(request("hi"), onTextDelta: { _ in })
    results.equal("nil ceiling uses the client's own default",
                  sentOption(server, "num_predict"), LocalOllamaAPI.activeReplyTokenLimit)

    server.setScript(.init(chunks: ["ok."]))
    _ = try? await provider.streamTurn(request("hi", maxOutputTokens: 37), onTextDelta: { _ in })
    results.equal("explicit ceiling reaches the transport verbatim",
                  sentOption(server, "num_predict"), 37)

    server.setScript(.init(chunks: ["ok."]))
    _ = try? await provider.streamTurn(request("hi"), onTextDelta: { _ in })
    results.equal("an explicit ceiling does not persist to the next request",
                  sentOption(server, "num_predict"), LocalOllamaAPI.activeReplyTokenLimit)
    results.equal("num_ctx is unaffected by the ceiling",
                  sentOption(server, "num_ctx"), LocalOllamaAPI.activeContextWindowTokens)

    // ========================================================================
    results.section("12. malformed tool calls are reported, not swallowed")
    // ========================================================================
    server.setScript(.init(chunks: ["hold on. [TOOL:browser_task:{not json}]"]))
    let mangled = try? await provider.streamTurn(request("x", tools: knownTools),
                                                 onTextDelta: { _ in })
    results.equal("malformed tag surfaced to the caller",
                  mangled?.malformedToolCallDescriptions.count, 1)
    results.check("malformed text is carried verbatim",
                  mangled?.malformedToolCallDescriptions.first?.contains("not json") == true,
                  mangled?.malformedToolCallDescriptions.description ?? "nil")
    results.check("malformed produces no executable call", mangled?.toolUses.isEmpty == true)
    results.check("a mangled turn is NOT an unambiguous final answer",
                  mangled?.isUnambiguousFinalAnswer == false)

    server.setScript(.init(chunks: ["octopuses have three hearts."]))
    let clean = try? await provider.streamTurn(request("x", tools: knownTools),
                                               onTextDelta: { _ in })
    results.check("a clean reply IS an unambiguous final answer",
                  clean?.isUnambiguousFinalAnswer == true)
    server.setScript(.init(chunks: ["checking. [TOOL:browser_task:{\"site\":\"a.com\"}]"]))
    let calling = try? await provider.streamTurn(request("x", tools: knownTools),
                                                 onTextDelta: { _ in })
    results.check("a tool-calling reply is NOT an unambiguous final answer",
                  calling?.isUnambiguousFinalAnswer == false)

    // ========================================================================
    results.section("13. an unreachable server is providerUnavailable")
    // ========================================================================
    // Port 1 on loopback: reserved, and nothing will ever be listening.
    let deadProvider = OllamaProvider(baseURL: "http://127.0.0.1:1", model: "qwen2.5vl:7b")
    do {
        _ = try await deadProvider.streamTurn(request("hello"), onTextDelta: { _ in })
        results.check("unreachable server throws", false, "returned normally")
    } catch BuddyChatError.providerUnavailable(let name, _) {
        results.check("unreachable server maps to providerUnavailable", true)
        results.equal("error names the provider", name, "ollama/qwen2.5vl:7b")
        results.check("providerUnavailable is retryable",
                      BuddyChatError.providerUnavailable(providerName: name,
                                                         underlyingDescription: nil).isWorthRetrying)
    } catch {
        results.check("unreachable server maps to providerUnavailable", false,
                      "got \(type(of: error)): \(error)")
    }

    // ========================================================================
    results.section("14. cancellation stays CancellationError")
    // ========================================================================
    //
    // URLSession reports an interrupted request as URLError.cancelled (-999).
    // CompanionManager catches CancellationError to abandon a turn quietly, so
    // an untranslated -999 would surface user interruption as a failure.

    server.setScript(.init(chunks: Array(repeating: "word ", count: 60),
                           delayBetweenChunks: 0.05))
    let cancellable = Task { @MainActor in
        try await provider.streamTurn(request("say a lot"), onTextDelta: { _ in })
    }
    try? await Task.sleep(nanoseconds: 300_000_000)
    cancellable.cancel()
    do {
        _ = try await cancellable.value
        results.check("cancelled turn throws", false, "returned normally")
    } catch is CancellationError {
        results.check("cancellation surfaces as CancellationError", true)
    } catch {
        let ns = error as NSError
        results.check("cancellation surfaces as CancellationError", false,
                      "got \(type(of: error)) domain=\(ns.domain) code=\(ns.code)")
    }

    // ========================================================================
    results.section("15. canonical content preserves the model's own ordering")
    // ========================================================================
    //
    // The turn's `content` is the record the conversation is built from. Text
    // and calls pulled into two separate fields cannot say which came first,
    // and a history rebuilt from them replays a turn the model never took.

    func blockShape(_ blocks: [BuddyContentBlock]) -> [String] {
        blocks.map { block in
            switch block {
            case .text(let value): return "text(\(value))"
            case .toolUse(_, let name, _): return "toolUse(\(name))"
            case .toolResult(_, let name, _, _): return "toolResult(\(name))"
            case .image(_, let label): return "image(\(label))"
            case .providerReplay(let providerFamily, _): return "providerReplay(\(providerFamily))"
            }
        }
    }

    server.setScript(.init(chunks: [
        "checking that now. [TOOL:read_page:{}] here is what it says."
    ]))
    let interleaved = try? await provider.streamTurn(request("x", tools: knownTools),
                                                     onTextDelta: { _ in })
    results.equal("prose before and after a call stay on their own sides",
                  blockShape(interleaved?.content ?? []),
                  ["text(checking that now.)", "toolUse(read_page)", "text(here is what it says.)"])
    results.equal("text still reads as the whole reply",
                  interleaved?.text, "checking that now. here is what it says.")
    results.equal("toolUses still reads as the calls",
                  interleaved?.toolUses.map(\.name), ["read_page"])

    server.setScript(.init(chunks: [
        "one. [TOOL:browser_task:{\"site\":\"a.com\"}] two. [TOOL:read_page:{}] three."
    ]))
    let twoCalls = try? await provider.streamTurn(request("x", tools: knownTools),
                                                  onTextDelta: { _ in })
    results.equal("narration between two calls keeps its position",
                  blockShape(twoCalls?.content ?? []),
                  ["text(one.)", "toolUse(browser_task)", "text(two.)",
                   "toolUse(read_page)", "text(three.)"])

    // A tag at the end — where the prompt tells the model to put it — must not
    // leave a blank text block behind for the history to carry.
    server.setScript(.init(chunks: ["on it. [TOOL:read_page:{}]"]))
    let trailingTag = try? await provider.streamTurn(request("x", tools: knownTools),
                                                     onTextDelta: { _ in })
    results.equal("a trailing tag leaves no empty text block",
                  blockShape(trailingTag?.content ?? []),
                  ["text(on it.)", "toolUse(read_page)"])

    // A bare tool call carries no prose at all, so nothing empty reaches the
    // assistant message the runner builds from this.
    server.setScript(.init(chunks: ["[TOOL:read_page:{}]"]))
    let bareCall = try? await provider.streamTurn(request("x", tools: knownTools),
                                                  onTextDelta: { _ in })
    results.equal("a call with no narration produces only the call",
                  blockShape(bareCall?.content ?? []), ["toolUse(read_page)"])

    // The echo guard drops the call and nothing else: the words around it are
    // an ordinary reply and must survive where the model wrote them.
    server.setScript(.init(chunks: [
        "sure, one moment. [TOOL:browser_task:{\"site\":\"\(StructuredTextToolProtocol.examplePlaceholderText)\"}] all set."
    ]))
    let echoedInPlace = try? await provider.streamTurn(request("x", tools: knownTools),
                                                       onTextDelta: { _ in })
    results.check("echoed example produces no call", echoedInPlace?.toolUses.isEmpty == true)
    results.equal("text around an echoed example survives in place",
                  blockShape(echoedInPlace?.content ?? []),
                  ["text(sure, one moment.)", "text(all set.)"])

    // A plain reply is one block, not an empty list and not a blank one.
    server.setScript(.init(chunks: ["  just an answer.  "]))
    let plain = try? await provider.streamTurn(request("x"), onTextDelta: { _ in })
    results.equal("a plain reply is a single text block",
                  blockShape(plain?.content ?? []), ["text(just an answer.)"])

    // The convenience initialiser must land on the same canonical shape a
    // structured provider builds by hand, or two providers would disagree
    // about what a turn is.
    let assembled = BuddyChatTurn(text: "hold on.",
                                  toolUses: [(id: "c1", name: "read_page", input: .object([:]))])
    results.equal("text+toolUses initialiser produces canonical blocks",
                  blockShape(assembled.content), ["text(hold on.)", "toolUse(read_page)"])
    let callOnly = BuddyChatTurn(text: "",
                                 toolUses: [(id: "c1", name: "read_page", input: .object([:]))])
    results.equal("empty text contributes no block",
                  blockShape(callOnly.content), ["toolUse(read_page)"])

    // ========================================================================
    results.section("16. the transcript stores more than it sends")
    // ========================================================================

    var transcript = ConversationTranscript()
    transcript.append(ConversationTranscript.Turn(messages: [
        BuddyChatMessage(role: .user, text: "what is on my screen?"),
        BuddyChatMessage(role: .assistant, blocks: [
            .text("checking."),
            .toolUse(id: "c1", name: "read_page", input: .object([:])),
        ]),
        BuddyChatMessage(role: .user, blocks: [
            .toolResult(toolUseID: "c1", toolName: "read_page",
                        content: String(repeating: "long page text. ", count: 200),
                        isError: false),
        ]),
        BuddyChatMessage(role: .assistant, text: "a settings window."),
    ]))

    results.equal("the record keeps every message", transcript.messages.count, 4)
    results.check("the record keeps the tool call",
                  transcript.messages.flatMap(\.blocks).contains {
                      if case .toolUse = $0 { return true }
                      return false
                  })

    let follow = transcript.messagesForFollowUpRequest()
    results.equal("the request carries one exchange per turn", follow.count, 2)
    results.equal("the request carries the question", follow.first?.combinedText,
                  "what is on my screen?")
    results.equal("the request carries the answer", follow.last?.combinedText,
                  "a settings window.")
    results.check("the request leaves the tool traffic behind",
                  !follow.flatMap(\.blocks).contains {
                      if case .toolResult = $0 { return true }
                      return false
                  })
    results.check("projecting did not edit the record", transcript.messages.count == 4)

    let pairs = ConversationTranscript.legacyStringPairs(from: follow)
    results.equal("legacy pairs are one per turn", pairs.count, 1)
    results.equal("legacy pair keeps the question", pairs.first?.userPlaceholder,
                  "what is on my screen?")
    results.equal("legacy pair keeps the answer", pairs.first?.assistantResponse,
                  "a settings window.")

    // A turn still in flight has no reply yet. Dropping its question would
    // hide from the model that it was ever asked.
    let unanswered = ConversationTranscript.legacyStringPairs(from: [
        BuddyChatMessage(role: .user, text: "first"),
        BuddyChatMessage(role: .user, text: "second"),
    ])
    results.equal("an unanswered question is not dropped",
                  unanswered.map(\.userPlaceholder), ["first", "second"])

    transcript.trimToRecentTurns(0)
    results.equal("trimming removes whole turns", transcript.turns.count, 0)

    let nestedComposioReply = "let me pull today's events. [TOOL:COMPOSIO_MULTI_EXECUTE_TOOL:{\"tools\":[{\"tool_slug\":\"X\",\"arguments\":{\"note\":\"a ]} b\"}}],\"session\":{\"generate_id\":true}}]"
    let nestedParse = StructuredTextToolProtocol.parse(nestedComposioReply)
    results.equal("a tag with nested arrays keeps its whole body", nestedParse.toolCalls.count, 1)
    results.equal("nothing of a nested tag leaks into the prose", nestedParse.spokenText,
                  "let me pull today's events.")

    server.stop()
    exit(results.summarise())
}

var spoken: [String] = []
await runSuite()
