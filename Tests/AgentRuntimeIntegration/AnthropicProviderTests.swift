//
//  AnthropicProviderTests.swift
//  AgentRuntimeIntegration
//
//  The Claude provider against a stubbed network: what it sends (caching,
//  adaptive thinking, effort, web tools, refusal fallback, no sampling
//  parameters on models that reject them) and how it reads Claude's stream
//  (signed thinking blocks kept for replay, web search pauses resumed,
//  refusals and fallbacks handled). Real `AnthropicProvider`, real
//  `AgentTurnRunner`; only `URLSession`'s transport is faked.
//

import Foundation

// MARK: - Stubbed transport

/// Serves scripted SSE bodies in order and records every request it receives.
nonisolated final class StubbedAnthropicTransport: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queuedResponseBodies: [Data] = []
    nonisolated(unsafe) private static var capturedRequests: [(headers: [String: String], body: [String: Any])] = []

    static func reset(responses: [Data]) {
        lock.lock(); defer { lock.unlock() }
        queuedResponseBodies = responses
        capturedRequests = []
    }

    static var requests: [(headers: [String: String], body: [String: Any])] {
        lock.lock(); defer { lock.unlock() }
        return capturedRequests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession moves the body into a stream before a protocol sees it.
        var bodyData = request.httpBody ?? Data()
        if bodyData.isEmpty, let bodyStream = request.httpBodyStream {
            bodyStream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while bodyStream.hasBytesAvailable {
                let readCount = bodyStream.read(&buffer, maxLength: buffer.count)
                if readCount <= 0 { break }
                bodyData.append(buffer, count: readCount)
            }
            bodyStream.close()
        }
        let parsedBody = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] ?? [:]

        Self.lock.lock()
        Self.capturedRequests.append((request.allHTTPHeaderFields ?? [:], parsedBody))
        let responseBody = Self.queuedResponseBodies.isEmpty ? Data() : Self.queuedResponseBodies.removeFirst()
        Self.lock.unlock()

        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

func stubbedAnthropicSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubbedAnthropicTransport.self]
    return URLSession(configuration: configuration)
}

/// Renders SSE events the way the Messages API streams them.
func anthropicSSE(_ events: [[String: Any]]) -> Data {
    var text = ""
    for event in events {
        let eventData = try! JSONSerialization.data(withJSONObject: event)
        text += "event: \(event["type"] as! String)\ndata: \(String(data: eventData, encoding: .utf8)!)\n\n"
    }
    return Data(text.utf8)
}

/// A complete streamed message made of the given content blocks, each given as
/// (start payload, deltas).
func anthropicMessageStream(
    blocks: [(start: [String: Any], deltas: [[String: Any]])],
    stopReason: String
) -> Data {
    var events: [[String: Any]] = [[
        "type": "message_start",
        "message": ["usage": ["input_tokens": 10, "cache_read_input_tokens": 900, "cache_creation_input_tokens": 0]]
    ]]
    for (index, block) in blocks.enumerated() {
        events.append(["type": "content_block_start", "index": index, "content_block": block.start])
        for delta in block.deltas {
            events.append(["type": "content_block_delta", "index": index, "delta": delta])
        }
        events.append(["type": "content_block_stop", "index": index])
    }
    events.append(["type": "message_delta", "delta": ["stop_reason": stopReason], "usage": ["output_tokens": 42]])
    events.append(["type": "message_stop"])
    return anthropicSSE(events)
}

func textBlock(_ text: String) -> (start: [String: Any], deltas: [[String: Any]]) {
    (["type": "text", "text": ""], [["type": "text_delta", "text": text]])
}

func thinkingBlock(signature: String) -> (start: [String: Any], deltas: [[String: Any]]) {
    (["type": "thinking", "thinking": ""], [["type": "signature_delta", "signature": signature]])
}

func clientToolUseBlock(id: String, name: String, argumentsJSON: String) -> (start: [String: Any], deltas: [[String: Any]]) {
    (["type": "tool_use", "id": id, "name": name, "input": [String: Any]()],
     [["type": "input_json_delta", "partial_json": argumentsJSON]])
}

/// The content blocks of every message in a captured request body.
func contentBlockTypes(ofMessage message: [String: Any]) -> [String] {
    (message["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String }
}

func sampleTool() -> BuddyToolDefinition {
    BuddyToolDefinition(
        name: "lookup",
        description: "Looks something up.",
        inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
        metadata: .reading()
    )
}

// MARK: - Suite

@MainActor func anthropicProviderSuite() async {
    section("Claude: request shape (Opus 5.5, agent turn)")
    do {
        StubbedAnthropicTransport.reset(responses: [
            anthropicMessageStream(blocks: [textBlock("hello")], stopReason: "end_turn")
        ])
        let provider = AnthropicProvider(apiKey: "test-key", modelChoice: .opus, effortLevel: .low,
                                         isWebAccessEnabled: true, session: stubbedAnthropicSession())
        _ = try? await provider.streamTurn(
            ModelRequest(systemPrompt: "You are Wisp.", messages: [BuddyChatMessage(role: .user, text: "hi")],
                         tools: [sampleTool()], temperature: 0),
            onTextDelta: { _ in }
        )
        let sent = StubbedAnthropicTransport.requests.first
        let body = sent?.body ?? [:]
        let thinking = body["thinking"] as? [String: Any]
        let blockBinding = thinking?["block_binding"] as? [String: Any]
        let toolTypes = (body["tools"] as? [[String: Any]] ?? []).map { $0["type"] as? String ?? "custom:\($0["name"] as? String ?? "")" }
        let systemBlocks = body["system"] as? [[String: Any]]
        let betaHeader = sent?.headers["anthropic-beta"] ?? ""

        check("uses claude-opus-5-5", body["model"] as? String == "claude-opus-5-5", "\(body["model"] ?? "nil")")
        check("thinking is adaptive", thinking?["type"] as? String == "adaptive")
        check("stale thinking is dropped, not a 400",
              blockBinding?["prefix_mismatch_behavior"] as? String == "drop_block")
        check("effort is sent", (body["output_config"] as? [String: Any])?["effort"] as? String == "low")
        check("refusal fallback opted in", body["fallbacks"] as? String == "default")
        check("no temperature (Opus 5.5 rejects it)", body["temperature"] == nil)
        check("max_tokens leaves room for thinking", body["max_tokens"] as? Int == 4096 + 16_000,
              "\(body["max_tokens"] ?? "nil")")
        check("automatic caching on", (body["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        check("system prompt carries a cache breakpoint",
              (systemBlocks?.first?["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        check("web search + fetch offered alongside tools",
              toolTypes == ["custom:lookup", "web_search_20260209", "web_fetch_20260209"], toolTypes.description)
        check("beta header names binding controls and fallback",
              betaHeader.contains("thinking-binding-controls-2026-08-01")
                && betaHeader.contains("server-side-fallback-2026-07-01"), betaHeader)
    }

    section("Claude: request shape (no tools, and Haiku)")
    do {
        StubbedAnthropicTransport.reset(responses: [
            anthropicMessageStream(blocks: [textBlock("a")], stopReason: "end_turn"),
            anthropicMessageStream(blocks: [textBlock("b")], stopReason: "end_turn"),
        ])
        let opus = AnthropicProvider(apiKey: "k", modelChoice: .opus, session: stubbedAnthropicSession())
        _ = try? await opus.streamTurn(
            ModelRequest(systemPrompt: "s", messages: [BuddyChatMessage(role: .user, text: "summarize")],
                         maxOutputTokens: 120),
            onTextDelta: { _ in })
        let haiku = AnthropicProvider(apiKey: "k", modelChoice: .haiku, session: stubbedAnthropicSession())
        _ = try? await haiku.streamTurn(
            ModelRequest(systemPrompt: "s", messages: [BuddyChatMessage(role: .user, text: "hi")],
                         tools: [sampleTool()], temperature: 0),
            onTextDelta: { _ in })
        let noToolsBody = StubbedAnthropicTransport.requests.first?.body ?? [:]
        let haikuRequest = StubbedAnthropicTransport.requests.last
        let haikuBody = haikuRequest?.body ?? [:]
        let haikuToolTypes = (haikuBody["tools"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String }

        check("no web tools on a tool-less request", noToolsBody["tools"] == nil)
        check("a caller's reply ceiling gets the thinking allowance on top",
              noToolsBody["max_tokens"] as? Int == 120 + 16_000)
        check("Haiku: no thinking, effort or fallback",
              haikuBody["thinking"] == nil && haikuBody["output_config"] == nil && haikuBody["fallbacks"] == nil)
        check("Haiku: temperature honoured", haikuBody["temperature"] as? Int == 0)
        check("Haiku: basic web tool versions", haikuToolTypes == ["web_search_20250305", "web_fetch_20250910"],
              haikuToolTypes.description)
        check("Haiku: no beta header", haikuRequest?.headers["anthropic-beta"] == nil)
    }

    section("Claude: thinking survives the tool loop")
    do {
        StubbedAnthropicTransport.reset(responses: [
            anthropicMessageStream(blocks: [
                thinkingBlock(signature: "sig-abc"),
                clientToolUseBlock(id: "toolu_1", name: "lookup", argumentsJSON: "{\"q\":\"x\"}"),
            ], stopReason: "tool_use"),
            anthropicMessageStream(blocks: [textBlock("it is 42.")], stopReason: "end_turn"),
        ])
        let registry = AgentToolRegistry.makeEmptyForTesting()
        registry.setPermissionBroker(StubBroker(decision: .approved))
        registry.register(sampleTool()) { _ in "the answer is 42" }
        let provider = AnthropicProvider(apiKey: "k", modelChoice: .opus, isWebAccessEnabled: false,
                                         session: stubbedAnthropicSession())
        let outcome = try? await run(
            AgentTurnRunner(modelProvider: provider, toolRegistry: registry, speakConfirmation: { _ in }),
            images: [(data: Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]), label: "screen")]
        )
        let secondMessages = StubbedAnthropicTransport.requests.last?.body["messages"] as? [[String: Any]] ?? []
        let assistantMessage = secondMessages.first { $0["role"] as? String == "assistant" }
        let replayedThinking = (assistantMessage?["content"] as? [[String: Any]])?.first
        let firstUserTypes = secondMessages.first.map(contentBlockTypes(ofMessage:)) ?? []

        check("two requests were made", StubbedAnthropicTransport.requests.count == 2)
        check("final answer returned", outcome?.terminalText == "it is 42.", outcome?.terminalText ?? "nil")
        check("thinking replayed first, before the tool call",
              assistantMessage.map(contentBlockTypes(ofMessage:)) == ["thinking", "tool_use"],
              assistantMessage.map(contentBlockTypes(ofMessage:))?.description ?? "none")
        check("signature replayed unchanged", replayedThinking?["signature"] as? String == "sig-abc")
        check("screenshot kept on the second pass (append-only)", firstUserTypes.contains("image"),
              firstUserTypes.description)
        let recordedForHistory = (outcome?.messages ?? []).map(\.withoutProviderReplayBlocks)
        check("replay blocks are stripped for the stored transcript",
              !recordedForHistory.flatMap(\.blocks).contains { if case .providerReplay = $0 { return true }; return false })
    }

    section("Claude: web search pause is resumed")
    do {
        let serverToolUse: (start: [String: Any], deltas: [[String: Any]]) = (
            ["type": "server_tool_use", "id": "srvtoolu_1", "name": "web_search", "input": [String: Any]()],
            [["type": "input_json_delta", "partial_json": "{\"query\":\"weather\"}"]]
        )
        let searchResult: (start: [String: Any], deltas: [[String: Any]]) = (
            ["type": "web_search_tool_result", "tool_use_id": "srvtoolu_1",
             "content": [["type": "web_search_result", "url": "https://example.com", "title": "Example",
                          "encrypted_content": "enc"]]],
            []
        )
        StubbedAnthropicTransport.reset(responses: [
            anthropicMessageStream(blocks: [serverToolUse, searchResult], stopReason: "pause_turn"),
            anthropicMessageStream(blocks: [textBlock("Sunny.")], stopReason: "end_turn"),
        ])
        let provider = AnthropicProvider(apiKey: "k", modelChoice: .opus, session: stubbedAnthropicSession())
        let turn = try? await provider.streamTurn(
            ModelRequest(systemPrompt: "s", messages: [BuddyChatMessage(role: .user, text: "weather?")],
                         tools: [sampleTool()]),
            onTextDelta: { _ in })
        let continuation = StubbedAnthropicTransport.requests.last?.body["messages"] as? [[String: Any]] ?? []
        let resumedAssistant = continuation.last
        let resumedToolUse = (resumedAssistant?["content"] as? [[String: Any]])?.first

        check("resumed with a second request", StubbedAnthropicTransport.requests.count == 2)
        check("the paused content is sent back as the assistant turn",
              resumedAssistant.map(contentBlockTypes(ofMessage:)) == ["server_tool_use", "web_search_tool_result"],
              resumedAssistant.map(contentBlockTypes(ofMessage:))?.description ?? "none")
        check("server tool input reassembled",
              ((resumedToolUse?["input"] as? [String: Any])?["query"] as? String) == "weather")
        check("merged turn ends with the answer", turn?.text == "Sunny.", turn?.text ?? "nil")
        check("a search is not a client tool call", turn?.toolUses.isEmpty == true && turn?.stopReason == .endTurn)
    }

    section("Claude: refusals and fallbacks")
    do {
        StubbedAnthropicTransport.reset(responses: [
            anthropicMessageStream(blocks: [textBlock("partial ans")], stopReason: "refusal"),
            anthropicMessageStream(blocks: [
                thinkingBlock(signature: "declined-model-sig"),
                textBlock("Let me "),
                (["type": "fallback", "from": ["model": "claude-opus-5-5"], "to": ["model": "claude-opus-5"]], []),
                textBlock("help."),
            ], stopReason: "end_turn"),
        ])
        let provider = AnthropicProvider(apiKey: "k", modelChoice: .opus, session: stubbedAnthropicSession())
        let refused = try? await provider.streamTurn(
            ModelRequest(systemPrompt: "s", messages: [BuddyChatMessage(role: .user, text: "q")]),
            onTextDelta: { _ in })
        let fellBack = try? await provider.streamTurn(
            ModelRequest(systemPrompt: "s", messages: [BuddyChatMessage(role: .user, text: "q")]),
            onTextDelta: { _ in })

        check("a refusal's partial output is discarded",
              refused?.text == "Claude declined to help with that request.", refused?.text ?? "nil")
        check("a refusal is not a clean end", refused?.stopReason == .other("refusal"))
        check("after a fallback the declined model's thinking is dropped",
              !(fellBack?.content ?? []).contains { if case .providerReplay = $0 { return true }; return false })
        check("text on both sides of the fallback is kept", fellBack?.text == "Let me help.", fellBack?.text ?? "nil")
    }
}
