//
//  MCPClient.swift
//  leanring-buddy
//
//  A Model Context Protocol client, speaking JSON-RPC 2.0 to one server.
//
//  Only four calls are needed to expose a server's tools — initialize, the
//  initialized notification, tools/list and tools/call — which is little
//  enough to implement directly. Taking the official SDK instead would pull
//  its own concurrency model and dependency tree into an app that currently
//  has neither, for a saving of a few hundred lines. The type below is shaped
//  like that SDK's client so swapping later stays mechanical.
//
//  How the bytes actually travel — a child process's stdin/stdout, or a
//  Streamable HTTP connection to a remote server — lives behind `MCPTransport`
//  (see MCPTransport.swift, MCPStdioTransport.swift). Everything in this file
//  is transport-agnostic: id issuing, the pending-request table, timeouts, and
//  the MCP handshake. That split is what lets Wisp reach remote MCP servers
//  without duplicating any of this machinery.
//

import Foundation

// MARK: - Configuration

/// How a server's bytes travel. Stdio spawns a local child process; Streamable
/// HTTP reaches a hosted server over the network.
enum MCPTransportKind: String, Sendable {
    case stdio
    case streamableHttp
}

struct MCPServerConfiguration: Sendable {
    let name: String
    let transport: MCPTransportKind
    let command: String
    let arguments: [String]
    let environment: [String: String]
    /// Endpoint for a remote (Streamable HTTP) server. Nil for stdio.
    let url: URL?
    /// Extra HTTP headers for a remote server — for instance an `x-api-key` or
    /// `Authorization`. Ignored for stdio.
    let headers: [String: String]
    let isEnabled: Bool
    /// When non-empty, only these tools are offered to the model. Useful
    /// because a small model's tool choice degrades quickly as the list grows.
    let allowedToolNames: Set<String>

    /// A local stdio server spawned from a command.
    init(
        name: String,
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        isEnabled: Bool = true,
        allowedToolNames: Set<String> = []
    ) {
        self.name = name
        self.transport = .stdio
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.url = nil
        self.headers = [:]
        self.isEnabled = isEnabled
        self.allowedToolNames = allowedToolNames
    }

    /// A remote server reached over Streamable HTTP.
    init(
        name: String,
        url: URL,
        headers: [String: String] = [:],
        isEnabled: Bool = true,
        allowedToolNames: Set<String> = []
    ) {
        self.name = name
        self.transport = .streamableHttp
        self.command = ""
        self.arguments = []
        self.environment = [:]
        self.url = url
        self.headers = headers
        self.isEnabled = isEnabled
        self.allowedToolNames = allowedToolNames
    }
}

// MARK: - Errors

enum MCPClientError: LocalizedError {
    case executableNotFound(command: String, searchedPath: String)
    case processFailedToStart(String)
    case notConnected
    case timedOut(method: String)
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let command, let searchedPath):
            return "couldn't find \"\(command)\". searched: \(searchedPath)"
        case .processFailedToStart(let reason):
            return "the server didn't start: \(reason)"
        case .notConnected:
            return "not connected to the server."
        case .timedOut(let method):
            return "the server didn't answer \(method) in time."
        case .serverError(let message):
            return message
        }
    }
}

// MARK: - Connection

/// One connected MCP server.
///
/// An actor because a JSON-RPC connection is a single logical stream shared by
/// many in-flight requests: ids must be issued without collision and replies
/// routed back to the right caller. The underlying byte transport is chosen at
/// construction and hidden behind `MCPTransport`.
actor MCPServerConnection {
    struct DiscoveredTool: Sendable {
        let name: String
        let description: String
        let inputSchema: JSONValue
    }

    let configuration: MCPServerConfiguration
    private let transport: MCPTransport

    private var readingTask: Task<Void, Never>?

    private var nextRequestID = 1
    private var pendingRequests: [Int: CheckedContinuation<JSONValue, Error>] = [:]

    private(set) var discoveredTools: [DiscoveredTool] = []
    private(set) var isConnected = false

    private static let requestTimeoutSeconds: TimeInterval = 25

    init(configuration: MCPServerConfiguration) {
        self.configuration = configuration
        self.transport = Self.makeTransport(for: configuration)
    }

    /// Constructs a connection over a caller-supplied transport. Used by tests
    /// and by future remote transports; the convenience initializer builds the
    /// transport from the configuration.
    init(configuration: MCPServerConfiguration, transport: MCPTransport) {
        self.configuration = configuration
        self.transport = transport
    }

    /// Chooses the transport for a configuration: a remote Streamable HTTP
    /// transport when the configuration carries a URL, a local stdio transport
    /// otherwise.
    private static func makeTransport(for configuration: MCPServerConfiguration) -> MCPTransport {
        if configuration.transport == .streamableHttp, let url = configuration.url {
            return MCPStreamableHTTPTransport(url: url, headers: configuration.headers)
        }
        return StdioMCPTransport(
            command: configuration.command,
            arguments: configuration.arguments,
            environment: configuration.environment
        )
    }

    /// Recent diagnostic output from the transport (a stdio server's stderr).
    /// It's the only place startup failures appear, so the dashboard reads it
    /// when a connection fails.
    var recentErrorOutput: [String] {
        get async { await transport.recentDiagnostics() }
    }

    // MARK: Lifecycle

    func connect() async throws {
        try await transport.start()

        // Consume the transport's message stream before any request is sent, so
        // no reply is missed.
        startReadingLoop()

        // MCP's handshake: declare the protocol version and this client, then
        // confirm with a notification before making any request.
        _ = try await sendRequest(
            method: "initialize",
            parameters: .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object(["tools": .object([:])]),
                "clientInfo": .object([
                    "name": .string("Wisp"),
                    "version": .string("1.0")
                ])
            ])
        )

        // Awaited so it is written before tools/list — some servers require the
        // initialized notification to arrive first.
        await sendNotification(method: "notifications/initialized", parameters: .object([:]))
        isConnected = true

        try await refreshTools()
    }

    func disconnect() async {
        readingTask?.cancel()
        readingTask = nil

        // Fail anything still waiting, so no caller is left suspended forever.
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: MCPClientError.notConnected)
        }
        pendingRequests.removeAll()

        await transport.close()
        isConnected = false
    }

    // MARK: Tools

    func refreshTools() async throws {
        let result = try await sendRequest(method: "tools/list", parameters: .object([:]))

        guard case .object(let resultObject) = result,
              case .array(let toolValues)? = resultObject["tools"] else {
            discoveredTools = []
            return
        }

        discoveredTools = toolValues.compactMap { toolValue in
            guard case .object(let tool) = toolValue,
                  case .string(let name)? = tool["name"] else { return nil }

            var description = ""
            if case .string(let text)? = tool["description"] { description = text }

            let schema = tool["inputSchema"] ?? .object([
                "type": .string("object"),
                "properties": .object([:])
            ])

            // Every tool the server offers is discovered here; the per-server
            // allow-list and the global budget are applied by MCPManager when it
            // decides which to expose, so the dashboard can still show the full
            // list for per-tool enabling.
            return DiscoveredTool(name: name, description: description, inputSchema: schema)
        }
    }

    /// Calls a tool and flattens the response into text for the model.
    func callTool(name: String, arguments: JSONValue) async throws -> String {
        let result = try await sendRequest(
            method: "tools/call",
            parameters: .object(["name": .string(name), "arguments": arguments])
        )

        guard case .object(let resultObject) = result else { return "(no result)" }

        // A tool may report failure in-band; surface it as text so the model
        // can respond to it rather than the turn erroring out.
        if case .bool(true)? = resultObject["isError"] {
            let message = Self.flattenContent(resultObject["content"])
            throw MCPClientError.serverError(message.isEmpty ? "the tool reported an error." : message)
        }

        let text = Self.flattenContent(resultObject["content"])
        return text.isEmpty ? "(the tool returned nothing)" : text
    }

    /// MCP returns content as typed blocks; only text is usable in a spoken
    /// assistant, so other kinds are named rather than dropped silently.
    private static func flattenContent(_ content: JSONValue?) -> String {
        guard case .array(let blocks)? = content else { return "" }

        return blocks.compactMap { block -> String? in
            guard case .object(let blockObject) = block else { return nil }
            if case .string(let text)? = blockObject["text"] { return text }
            if case .string(let type)? = blockObject["type"] { return "(\(type) content)" }
            return nil
        }
        .joined(separator: "\n")
    }

    // MARK: JSON-RPC

    private func sendRequest(method: String, parameters: JSONValue) async throws -> JSONValue {
        let requestID = nextRequestID
        nextRequestID += 1

        let payload: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(requestID)),
            "method": .string(method),
            "params": parameters
        ])
        let messageData = try JSONSerialization.data(withJSONObject: payload.untypedValue)

        // A server that never answers must not hold a conversation open.
        let timeoutTask = Task { [weak self] in
            try await Task.sleep(nanoseconds: UInt64(Self.requestTimeoutSeconds * 1_000_000_000))
            await self?.failPendingRequest(requestID, with: MCPClientError.timedOut(method: method))
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            // Register before sending so the reply can never arrive before the
            // caller is waiting for it.
            pendingRequests[requestID] = continuation
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.transport.send(messageData)
                } catch {
                    await self.failPendingRequest(requestID, with: error)
                }
            }
        }
    }

    private func failPendingRequest(_ requestID: Int, with error: Error) {
        guard let continuation = pendingRequests.removeValue(forKey: requestID) else { return }
        continuation.resume(throwing: error)
    }

    private func sendNotification(method: String, parameters: JSONValue) async {
        let payload: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": parameters
        ])
        guard let data = try? JSONSerialization.data(withJSONObject: payload.untypedValue) else { return }
        try? await transport.send(data)
    }

    private func startReadingLoop() {
        readingTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.transport.incomingMessages()
            for await line in stream {
                if Task.isCancelled { break }
                await self.handleIncomingLine(line)
            }
            // The stream finishes when the transport closes, for any reason.
            // Anything still waiting is failed rather than left suspended.
            await self.handleStreamEnded()
        }
    }

    /// Called when the transport's message stream closes, for any reason.
    private func handleStreamEnded() {
        guard !pendingRequests.isEmpty else { return }
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: MCPClientError.notConnected)
        }
        pendingRequests.removeAll()
        isConnected = false
    }

    private func handleIncomingLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else { return }

        let message = JSONValue(untypedValue: parsed)
        guard case .object(let messageObject) = message else { return }

        // Notifications carry no id and nothing here waits on them.
        guard case .number(let identifier)? = messageObject["id"] else { return }
        let requestID = Int(identifier)

        guard let continuation = pendingRequests.removeValue(forKey: requestID) else { return }

        if case .object(let errorObject)? = messageObject["error"] {
            var description = "the server reported an error."
            if case .string(let text)? = errorObject["message"] { description = text }
            continuation.resume(throwing: MCPClientError.serverError(description))
            return
        }

        continuation.resume(returning: messageObject["result"] ?? .null)
    }
}
