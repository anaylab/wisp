//
//  MCPClient.swift
//  leanring-buddy
//
//  A Model Context Protocol client, speaking JSON-RPC 2.0 over a child
//  process's stdin and stdout.
//
//  Only four calls are needed to expose a server's tools — initialize, the
//  initialized notification, tools/list and tools/call — which is little
//  enough to implement directly. Taking the official SDK instead would pull
//  its own concurrency model and dependency tree into an app that currently
//  has neither, for a saving of a few hundred lines. The type below is shaped
//  like that SDK's client so swapping later stays mechanical.
//
//  Two details cause most of the trouble in practice, and both are handled
//  here rather than left for the user to discover:
//
//  * A GUI app launched at login inherits only /usr/bin:/bin:/usr/sbin:/sbin.
//    Servers are usually started with npx or uvx, which live in Homebrew's
//    directories, so they simply aren't found — while working perfectly when
//    the user tries the same command in a terminal. The login shell's PATH is
//    therefore resolved once and handed to every child.
//
//  * MCP servers report their problems on stderr, not over the protocol. A
//    server that fails to start says why there and nowhere else, so stderr is
//    captured and kept instead of discarded.
//

import Foundation

// MARK: - Configuration

struct MCPServerConfiguration: Sendable {
    let name: String
    let command: String
    let arguments: [String]
    let environment: [String: String]
    let isEnabled: Bool
    /// When non-empty, only these tools are offered to the model. Useful
    /// because a small model's tool choice degrades quickly as the list grows.
    let allowedToolNames: Set<String>

    init(
        name: String,
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        isEnabled: Bool = true,
        allowedToolNames: Set<String> = []
    ) {
        self.name = name
        self.command = command
        self.arguments = arguments
        self.environment = environment
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

// MARK: - Environment

enum LoginShellEnvironment {
    /// PATH as the user's login shell defines it.
    ///
    /// Resolved once and cached: it requires spawning a shell, and it does not
    /// change while the app runs.
    static let resolvedPath: String = {
        let fallback = "/usr/bin:/bin:/usr/sbin:/sbin"

        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        // Interactive + login so the user's profile is actually sourced, which
        // is where Homebrew and version managers add themselves.
        process.arguments = ["-ilc", "printf '%s' \"$PATH\""]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return fallback
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? fallback : path
    }()

    /// Finds an executable, accepting either a bare name or an absolute path.
    static func locateExecutable(named command: String) -> String? {
        if command.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: command) ? command : nil
        }

        for directory in resolvedPath.split(separator: ":") {
            let candidate = "\(directory)/\(command)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

// MARK: - Connection

/// One connected MCP server.
///
/// An actor because a JSON-RPC connection is a single stream shared by many
/// in-flight requests: ids must be issued without collision and replies routed
/// back to the right caller.
actor MCPServerConnection {
    struct DiscoveredTool: Sendable {
        let name: String
        let description: String
        let inputSchema: JSONValue
    }

    let configuration: MCPServerConfiguration

    private var process: Process?
    private var standardInput: FileHandle?
    private var readingTask: Task<Void, Never>?

    private var nextRequestID = 1
    private var pendingRequests: [Int: CheckedContinuation<JSONValue, Error>] = [:]

    /// Recent stderr, kept because it's the only place startup failures appear.
    private var standardErrorLines: [String] = []
    private static let retainedErrorLineCount = 60

    private(set) var discoveredTools: [DiscoveredTool] = []
    private(set) var isConnected = false

    private static let requestTimeoutSeconds: TimeInterval = 25

    init(configuration: MCPServerConfiguration) {
        self.configuration = configuration
    }

    var recentErrorOutput: [String] { standardErrorLines }

    // MARK: Lifecycle

    func connect() async throws {
        guard let executablePath = LoginShellEnvironment.locateExecutable(named: configuration.command) else {
            throw MCPClientError.executableNotFound(
                command: configuration.command,
                searchedPath: LoginShellEnvironment.resolvedPath
            )
        }

        let childProcess = Process()
        childProcess.executableURL = URL(fileURLWithPath: executablePath)
        childProcess.arguments = configuration.arguments

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = LoginShellEnvironment.resolvedPath
        for (key, value) in configuration.environment {
            environment[key] = value
        }
        childProcess.environment = environment

        let inputPipe = Pipe(), outputPipe = Pipe(), errorPipe = Pipe()
        childProcess.standardInput = inputPipe
        childProcess.standardOutput = outputPipe
        childProcess.standardError = errorPipe

        do {
            try childProcess.run()
        } catch {
            throw MCPClientError.processFailedToStart(error.localizedDescription)
        }

        process = childProcess
        standardInput = inputPipe.fileHandleForWriting

        startReadingResponses(from: outputPipe)
        startCapturingErrors(from: errorPipe)

        // MCP's handshake: declare the protocol version and this client, then
        // confirm with a notification before making any request.
        let initializeResult = try await sendRequest(
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
        _ = initializeResult

        sendNotification(method: "notifications/initialized", parameters: .object([:]))
        isConnected = true

        try await refreshTools()
    }

    func disconnect() {
        readingTask?.cancel()
        readingTask = nil

        // Fail anything still waiting, so no caller is left suspended forever.
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: MCPClientError.notConnected)
        }
        pendingRequests.removeAll()

        try? standardInput?.close()
        standardInput = nil

        process?.terminate()
        process = nil
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

            if !configuration.allowedToolNames.isEmpty,
               !configuration.allowedToolNames.contains(name) {
                return nil
            }

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
        guard let standardInput else { throw MCPClientError.notConnected }

        let requestID = nextRequestID
        nextRequestID += 1

        let payload: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(requestID)),
            "method": .string(method),
            "params": parameters
        ])

        let responseTask = Task { () -> JSONValue in
            try await withCheckedThrowingContinuation { continuation in
                pendingRequests[requestID] = continuation
                do {
                    try writeMessage(payload, to: standardInput)
                } catch {
                    pendingRequests.removeValue(forKey: requestID)
                    continuation.resume(throwing: error)
                }
            }
        }

        // A server that never answers must not hold a conversation open.
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(Self.requestTimeoutSeconds * 1_000_000_000))
            await self.failPendingRequest(requestID, with: MCPClientError.timedOut(method: method))
        }

        defer { timeoutTask.cancel() }
        return try await responseTask.value
    }

    private func failPendingRequest(_ requestID: Int, with error: Error) {
        guard let continuation = pendingRequests.removeValue(forKey: requestID) else { return }
        continuation.resume(throwing: error)
    }

    private func sendNotification(method: String, parameters: JSONValue) {
        guard let standardInput else { return }
        let payload: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": parameters
        ])
        try? writeMessage(payload, to: standardInput)
    }

    private func writeMessage(_ message: JSONValue, to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: message.untypedValue)
        // Newline-delimited JSON: one message per line.
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private func startReadingResponses(from pipe: Pipe) {
        readingTask = Task { [weak self] in
            do {
                for try await line in pipe.fileHandleForReading.bytes.lines {
                    guard !Task.isCancelled else { return }
                    await self?.handleIncomingLine(line)
                }
            } catch {
                // The stream ends when the server exits. Anything still
                // waiting is failed rather than left suspended.
                await self?.handleStreamEnded()
                return
            }

            // Clean end of stream — same handling.
            await self?.handleStreamEnded()
        }
    }

    /// Called when the server's output stream closes, for any reason.
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

    private func startCapturingErrors(from pipe: Pipe) {
        Task { [weak self] in
            // Best effort: losing stderr costs diagnostics, not correctness.
            try? await {
                for try await line in pipe.fileHandleForReading.bytes.lines {
                    await self?.appendErrorLine(line)
                }
            }()
        }
    }

    private func appendErrorLine(_ line: String) {
        standardErrorLines.append(line)
        if standardErrorLines.count > Self.retainedErrorLineCount {
            standardErrorLines.removeFirst(standardErrorLines.count - Self.retainedErrorLineCount)
        }
    }
}
