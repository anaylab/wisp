//
//  MCPClient over a scripted transport: `callTool` (used by callers that
//  parse a server's text themselves) is unchanged by structured content, and
//  `callToolReturningContent` hands both halves to the renderer.
//

import Foundation

/// A fake MCP server: answers initialize and tools/list, and answers every
/// tools/call with the canned result it was built with.
actor ScriptedMCPTransport: MCPTransport {
    private let toolCallResult: JSONValue
    private var messageContinuation: AsyncStream<String>.Continuation?
    private var messageStream: AsyncStream<String>?

    init(toolCallResult: JSONValue) {
        self.toolCallResult = toolCallResult
    }

    func start() async throws {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        messageStream = stream
        messageContinuation = continuation
    }

    func send(_ messageJSON: Data) async throws {
        guard let request = try JSONSerialization.jsonObject(with: messageJSON) as? [String: Any],
              let requestID = request["id"],
              let method = request["method"] as? String else { return }
        let result: Any
        switch method {
        case "initialize":
            result = ["protocolVersion": "2024-11-05", "capabilities": [:], "serverInfo": ["name": "scripted"]]
        case "tools/list":
            result = ["tools": [["name": "get_window_state", "inputSchema": ["type": "object"]]]]
        default:
            result = toolCallResult.untypedValue
        }
        let reply: [String: Any] = ["jsonrpc": "2.0", "id": requestID, "result": result]
        let replyData = try JSONSerialization.data(withJSONObject: reply)
        messageContinuation?.yield(String(decoding: replyData, as: UTF8.self))
    }

    func incomingMessages() async -> AsyncStream<String> {
        messageStream ?? AsyncStream { $0.finish() }
    }

    func recentDiagnostics() async -> [String] { [] }

    func close() async {
        messageContinuation?.finish()
    }
}

func runScriptedTransportChecks(structuredToolResult: JSONValue) async {
    section("MCPClient: callTool keeps returning only the text blocks")
    let structuredConnection = MCPServerConnection(
        configuration: MCPServerConfiguration(name: "scripted", command: "unused"),
        transport: ScriptedMCPTransport(toolCallResult: structuredToolResult)
    )
    do {
        try await structuredConnection.connect()
        let plainText = try await structuredConnection.callTool(name: "get_window_state", arguments: .object([:]))
        check(plainText.hasPrefix("(image content)\nwindow_id=777"), "callTool is the old flattened text, got \(plainText.prefix(40))")
        check(!plainText.contains("s1a2b3c4d:1"), "callTool does not mix structured content in")

        section("MCPClient: callToolReturningContent carries structuredContent through")
        let toolCallContent = try await structuredConnection.callToolReturningContent(name: "get_window_state", arguments: .object([:]))
        check(toolCallContent.flattenedContentText == plainText, "same flattened text")
        check(toolCallContent.structuredContent != nil, "structured content kept")
        let modelText = MCPToolResultRendering.modelText(
            flattenedContentText: toolCallContent.flattenedContentText,
            structuredContent: toolCallContent.structuredContent
        )
        check(modelText.contains("s1a2b3c4d:1 Button \"Send\""), "the model text carries the tokens")
    } catch {
        check(false, "scripted structured connection failed: \(error)")
    }
    await structuredConnection.disconnect()

    section("MCPClient: a text-only server's result reaches the model unchanged")
    let textOnlyConnection = MCPServerConnection(
        configuration: MCPServerConfiguration(name: "scripted", command: "unused"),
        transport: ScriptedMCPTransport(toolCallResult: .object([
            "content": .array([.object(["type": .string("text"), "text": .string("3 issues open")])]),
        ]))
    )
    do {
        try await textOnlyConnection.connect()
        let toolCallContent = try await textOnlyConnection.callToolReturningContent(name: "get_window_state", arguments: .object([:]))
        check(toolCallContent.structuredContent == nil, "no structured content invented")
        let modelText = MCPToolResultRendering.modelText(
            flattenedContentText: toolCallContent.flattenedContentText,
            structuredContent: toolCallContent.structuredContent
        )
        check(modelText == "3 issues open", "model text is exactly the server's text, got \(modelText)")
    } catch {
        check(false, "scripted text-only connection failed: \(error)")
    }
    await textOnlyConnection.disconnect()
}
