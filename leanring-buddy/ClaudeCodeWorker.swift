//
//  ClaudeCodeWorker.swift
//  leanring-buddy
//
//  Hands coding work to the Claude Code CLI, off the interactive path.
//
//  This is deliberately not a second brain for Wisp. Measured here, `claude -p`
//  takes about 7 seconds to answer "say hello" — process start, agent harness,
//  MCP servers, then a network round trip — against 0.5s for the local model.
//  As a conversational backend it would be a large regression, and it would
//  send every screenshot off the machine, which is the one thing this build
//  exists not to do.
//
//  What it is good at is the thing the local 7B cannot do at all: reading a
//  real codebase, editing files, running tests, using git. So it is a worker
//  for that and nothing else. Wisp stays responsive while it runs, progress
//  lands in the dashboard, and the spoken answer arrives when it finishes.
//
//  On using the subscription: this invokes Anthropic's own CLI on the user's
//  own machine to do the work that CLI is for, the same way they would from a
//  terminal. That is different in kind from extracting its credentials to
//  power a separate chat interface, which this does not do.
//

import Foundation

/// One step of progress, for the dashboard.
struct ClaudeCodeProgress: Sendable {
    let summary: String
}

struct ClaudeCodeResult: Sendable {
    let text: String
    let didSucceed: Bool
    let durationSeconds: Double
    let turnCount: Int
    /// Tools Claude Code asked for and was refused. Surfaced because a task
    /// that "finished" having been denied every edit is not a success, and the
    /// result text alone often does not make that obvious.
    let permissionDenials: [String]
}

enum ClaudeCodeWorkerError: LocalizedError {
    case notInstalled(searchedPath: String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "The Claude Code command line tool isn't installed, or isn't on the path Wisp can see."
        case .launchFailed(let detail):
            return detail
        }
    }
}

enum ClaudeCodeWorker {
    /// Tools Claude Code may use without being asked.
    ///
    /// Read-only by default. Wisp is a voice assistant: the user is not
    /// watching a terminal, cannot see a diff, and may be in another room. A
    /// misunderstood spoken instruction that edits files or runs shell commands
    /// unattended is a materially different risk from one that produces a wrong
    /// sentence, so writes require the caller to opt in explicitly.
    private static let readOnlyTools = ["Read", "Glob", "Grep", "WebFetch", "WebSearch"]
    private static let editingTools = readOnlyTools + ["Edit", "Write", "Bash", "TodoWrite"]

    /// Ceiling on wall-clock time.
    ///
    /// Generous, because real coding tasks legitimately take minutes, but not
    /// unbounded — an abandoned subprocess holding a model slot is exactly the
    /// kind of thing nobody notices until the machine is out of memory.
    private static let timeoutSeconds: TimeInterval = 15 * 60

    /// Runs `task` in `workingDirectory` and reports progress as it goes.
    static func run(
        task: String,
        workingDirectory: URL,
        allowEditing: Bool,
        onProgress: @escaping @Sendable (ClaudeCodeProgress) -> Void
    ) async throws -> ClaudeCodeResult {
        guard let executablePath = LoginShellEnvironment.locateExecutable(named: "claude") else {
            throw ClaudeCodeWorkerError.notInstalled(searchedPath: LoginShellEnvironment.resolvedPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.currentDirectoryURL = workingDirectory
        process.arguments = [
            "-p", task,
            "--output-format", "stream-json",
            "--verbose",
            "--allowedTools",
        ] + (allowEditing ? editingTools : readOnlyTools)

        // A menu bar app inherits a minimal PATH, so anything Claude Code
        // shells out to — node, git, a formatter — would not be found without
        // the login shell's version.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = LoginShellEnvironment.resolvedPath
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw ClaudeCodeWorkerError.launchFailed(error.localizedDescription)
        }

        // Kill the subprocess if the surrounding task is cancelled, otherwise a
        // cancelled background task leaves Claude Code running unattended.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            if process.isRunning { process.terminate() }
        }
        defer { watchdog.cancel() }

        let result = await withTaskCancellationHandler {
            await parseEventStream(from: outputPipe, onProgress: onProgress)
        } onCancel: {
            process.terminate()
        }

        process.waitUntilExit()

        guard let result else {
            let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ClaudeCodeWorkerError.launchFailed(
                stderr.isEmpty ? "Claude Code exited without producing a result." : String(stderr.prefix(300))
            )
        }
        return result
    }

    // MARK: - Event stream

    /// Reads the NDJSON stream, reporting progress and returning the result.
    ///
    /// Line-buffered rather than read-to-end so the dashboard fills in while
    /// the task runs; a five-minute task that shows nothing until it finishes
    /// is indistinguishable from a hung one.
    private static func parseEventStream(
        from pipe: Pipe,
        onProgress: @escaping @Sendable (ClaudeCodeProgress) -> Void
    ) async -> ClaudeCodeResult? {
        var finalResult: ClaudeCodeResult?

        // FileHandle.bytes.lines is an async sequence, so this yields between
        // lines instead of blocking a thread on availableData. That matters:
        // the whole point of running Claude Code in the background is that Wisp
        // stays responsive while it works.
        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                guard let data = line.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                if let progress = progressSummary(from: event) {
                    onProgress(ClaudeCodeProgress(summary: progress))
                }
                if let parsed = parseResult(event) {
                    finalResult = parsed
                }
            }
        } catch {
            // A truncated stream still leaves whatever result arrived before
            // it broke, which is more useful than discarding everything.
            print("⚠️ Claude Code stream ended early: \(error.localizedDescription)")
        }

        return finalResult
    }

    /// Turns an event into something worth showing, or nil for noise.
    ///
    /// Most of the stream is token-accounting chatter. What a person wants to
    /// see is which files are being touched and what is being run.
    private static func progressSummary(from event: [String: Any]) -> String? {
        guard event["type"] as? String == "assistant",
              let message = event["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return nil }

        for block in content where block["type"] as? String == "tool_use" {
            let toolName = block["name"] as? String ?? "tool"
            let input = block["input"] as? [String: Any] ?? [:]
            if let path = input["file_path"] as? String {
                return "\(toolName) \((path as NSString).lastPathComponent)"
            }
            if let command = input["command"] as? String {
                return "\(toolName): \(command.prefix(60))"
            }
            return toolName
        }
        return nil
    }

    private static func parseResult(_ event: [String: Any]) -> ClaudeCodeResult? {
        guard event["type"] as? String == "result" else { return nil }

        let denials = (event["permission_denials"] as? [[String: Any]] ?? [])
            .compactMap { $0["tool_name"] as? String }

        return ClaudeCodeResult(
            text: event["result"] as? String ?? "Finished, but returned nothing to say.",
            didSucceed: (event["is_error"] as? Bool) == false,
            durationSeconds: (event["duration_ms"] as? Double ?? 0) / 1000,
            turnCount: event["num_turns"] as? Int ?? 0,
            permissionDenials: denials
        )
    }
}
