//
//  MCPStdioTransport.swift
//  leanring-buddy
//
//  The stdio MCP transport: spawns the server as a child process and speaks
//  JSON-RPC over its stdin/stdout as newline-delimited JSON, behind
//  `MCPTransport`.
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
//  Both pipes are read with `readabilityHandler`, never `FileHandle.bytes`.
//  Reading stdout and stderr concurrently through `bytes.lines` stalls: once
//  the stderr reader is waiting on a quiet pipe, the stdout reader stops
//  delivering lines, so a server's reply sat unread in the pipe until the
//  request timed out ("didn't answer tools/list in time") even though the
//  server had answered in milliseconds.
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
        let chunks = Self.chunkStream(from: pipe.fileHandleForReading)
        readingTask = Task {
            var lineBuffer = NewlineDelimitedLineBuffer()
            for await chunk in chunks {
                if Task.isCancelled { break }
                for line in lineBuffer.appendAndExtractCompleteLines(chunk) {
                    continuation?.yield(line)
                }
            }
            if let lastLine = lineBuffer.flushRemainingLine() {
                continuation?.yield(lastLine)
            }
            // The chunk stream ends when the server exits; signal the end so
            // the connection can fail anything still waiting.
            continuation?.finish()
        }
    }

    private func startCapturingErrors(from pipe: Pipe) {
        let chunks = Self.chunkStream(from: pipe.fileHandleForReading)
        errorTask = Task { [weak self] in
            // Best effort: losing stderr costs diagnostics, not correctness.
            var lineBuffer = NewlineDelimitedLineBuffer()
            for await chunk in chunks {
                for line in lineBuffer.appendAndExtractCompleteLines(chunk) {
                    await self?.appendErrorLine(line)
                }
            }
            if let lastLine = lineBuffer.flushRemainingLine() {
                await self?.appendErrorLine(lastLine)
            }
        }
    }

    /// Delivers whatever bytes a pipe has as they arrive, finishing at end of
    /// file. `readabilityHandler` runs on a dispatch source, so a quiet pipe
    /// waits without holding a thread — see the note at the top of the file.
    private static func chunkStream(from fileHandle: FileHandle) -> AsyncStream<Data> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            fileHandle.readabilityHandler = { readableHandle in
                let chunk = readableHandle.availableData
                if chunk.isEmpty {
                    // Empty data means end of file: the server closed the pipe.
                    readableHandle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(chunk)
                }
            }
            continuation.onTermination = { _ in
                fileHandle.readabilityHandler = nil
            }
        }
    }

    private func appendErrorLine(_ line: String) {
        standardErrorLines.append(line)
        if standardErrorLines.count > Self.retainedErrorLineCount {
            standardErrorLines.removeFirst(standardErrorLines.count - Self.retainedErrorLineCount)
        }
    }
}

// MARK: - Line framing

/// Splits a byte stream into lines for newline-delimited JSON.
///
/// Pipe reads arrive in arbitrary chunks — half a message, or several at once
/// — so bytes after the last newline are held until the rest arrives. Blank
/// lines are dropped (nothing on either pipe needs them) and a trailing `\r`
/// is removed, so a server that writes CRLF still frames correctly.
struct NewlineDelimitedLineBuffer {
    private var bytesAfterLastNewline = Data()

    /// Adds a chunk and returns every line it completed, in order.
    mutating func appendAndExtractCompleteLines(_ chunk: Data) -> [String] {
        bytesAfterLastNewline.append(chunk)

        var completeLines: [String] = []
        while let newlineIndex = bytesAfterLastNewline.firstIndex(of: 0x0A) {
            let lineBytes = bytesAfterLastNewline[bytesAfterLastNewline.startIndex..<newlineIndex]
            bytesAfterLastNewline = Data(bytesAfterLastNewline[bytesAfterLastNewline.index(after: newlineIndex)...])
            if let line = Self.decodedLine(from: Data(lineBytes)) {
                completeLines.append(line)
            }
        }
        return completeLines
    }

    /// Returns the unterminated final line, if any — called at end of file so
    /// a server that exits without a trailing newline still has its last line
    /// read.
    mutating func flushRemainingLine() -> String? {
        let remainingBytes = bytesAfterLastNewline
        bytesAfterLastNewline = Data()
        return Self.decodedLine(from: remainingBytes)
    }

    private static func decodedLine(from lineBytes: Data) -> String? {
        var line = String(decoding: lineBytes, as: UTF8.self)
        if line.hasSuffix("\r") { line.removeLast() }
        return line.isEmpty ? nil : line
    }
}
