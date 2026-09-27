//
//  MCPStdioTransport.swift
//  leanring-buddy
//
//  The stdio MCP transport: spawns the server as a child process and speaks
//  JSON-RPC over its stdin/stdout as newline-delimited JSON. This is the
//  transport that `MCPServerConnection` used directly before the transport
//  protocol was introduced; the code here is that same logic, unchanged in
//  behavior, moved behind `MCPTransport`.
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

// MARK: - Transport

/// Speaks JSON-RPC to an MCP server over a child process's stdin and stdout.
///
/// An actor because the process handles and the outbound stream are shared
/// mutable state; the reading loop and any number of concurrent sends must not
/// race on them.
actor StdioMCPTransport: MCPTransport {
    private let command: String
    private let arguments: [String]
    private let environment: [String: String]

    private var process: Process?
    private var standardInput: FileHandle?
    private var readingTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?

    /// The stream handed to the connection, and the continuation the reading
    /// loop feeds. Created in `start`.
    private var messageStream: AsyncStream<String>?
    private var messageContinuation: AsyncStream<String>.Continuation?

    /// Recent stderr, kept because it's the only place startup failures appear.
    private var standardErrorLines: [String] = []
    private static let retainedErrorLineCount = 60

    init(command: String, arguments: [String], environment: [String: String]) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
    }

    // MARK: MCPTransport

    func start() async throws {
        guard let executablePath = LoginShellEnvironment.locateExecutable(named: command) else {
            throw MCPClientError.executableNotFound(
                command: command,
                searchedPath: LoginShellEnvironment.resolvedPath
            )
        }

        let childProcess = Process()
        childProcess.executableURL = URL(fileURLWithPath: executablePath)
        childProcess.arguments = arguments

        var mergedEnvironment = ProcessInfo.processInfo.environment
        mergedEnvironment["PATH"] = LoginShellEnvironment.resolvedPath
        for (key, value) in environment {
            mergedEnvironment[key] = value
        }
        childProcess.environment = mergedEnvironment

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

        // Unbounded buffering so any line the server emits before the
        // connection starts consuming (for instance the initialize reply that
        // races the reading loop) is held rather than dropped.
        let (stream, continuation) = AsyncStream<String>.makeStream(
            bufferingPolicy: .unbounded
        )
        messageStream = stream
        messageContinuation = continuation

        startReadingResponses(from: outputPipe)
        startCapturingErrors(from: errorPipe)
    }

    func send(_ messageJSON: Data) async throws {
        guard let standardInput else { throw MCPClientError.notConnected }
        var framed = messageJSON
        // Newline-delimited JSON: one message per line.
        framed.append(0x0A)
        try standardInput.write(contentsOf: framed)
    }

    func incomingMessages() -> AsyncStream<String> {
        messageStream ?? AsyncStream { $0.finish() }
    }

    func recentDiagnostics() -> [String] {
        standardErrorLines
    }

    func close() {
        readingTask?.cancel()
        readingTask = nil
        errorTask?.cancel()
        errorTask = nil

        messageContinuation?.finish()
        messageContinuation = nil

        try? standardInput?.close()
        standardInput = nil

        process?.terminate()
        process = nil
    }

    // MARK: Reading

    private func startReadingResponses(from pipe: Pipe) {
        let continuation = messageContinuation
        readingTask = Task {
            do {
                for try await line in pipe.fileHandleForReading.bytes.lines {
                    if Task.isCancelled { break }
                    continuation?.yield(line)
                }
            } catch {
                // The stream ends when the server exits; nothing more to read.
            }
            // Whether the stream ended cleanly or with an error, signal the end
            // so the connection can fail anything still waiting.
            continuation?.finish()
        }
    }

    private func startCapturingErrors(from pipe: Pipe) {
        errorTask = Task { [weak self] in
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
