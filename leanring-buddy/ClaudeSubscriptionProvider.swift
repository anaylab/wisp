//
//  ClaudeSubscriptionProvider.swift
//  leanring-buddy
//
//  Claude as the chat model, paid for by the user's Claude subscription instead
//  of an API key.
//
//  This works by launching Anthropic's own `claude` command line tool, which
//  the user has installed and signed in to themselves, once per turn — exactly
//  as they would from a terminal. Wisp never reads, copies or forwards the
//  CLI's login (it lives in the CLI's own Keychain item) and never calls the
//  Messages API with it; extracting a subscription's credentials to power a
//  separate app is something Anthropic does not allow, and this is the
//  difference between that and driving the official client. If the CLI is not
//  installed or not signed in, the turn fails with a message saying so.
//
//  The CLI is used as a bare model, not as an agent: every built-in tool,
//  MCP server, slash command and settings file is switched off, and the
//  system prompt is Wisp's own. Tools are offered the way the local model gets
//  them, as `[TOOL:name:{…}]` text parsed back into `toolUse` blocks, so the
//  tool loop, confirmations and `ToolCallSafety` above this seam are
//  unchanged and the CLI can never act on the user's machine by itself.
//
//  The screenshot travels inline as an image block on the CLI's stdin
//  (`--input-format stream-json`), which keeps it to one model round trip
//  rather than the CLI reading a file with its own tool. Measured here:
//  about 4s end to end for a short vision answer, most of it CLI start-up.
//

import Foundation

final class ClaudeSubscriptionProvider: ModelProvider, @unchecked Sendable {
    private let modelChoice: AnthropicModelChoice
    private let effortLevel: AnthropicEffortLevel

    init(modelChoice: AnthropicModelChoice, effortLevel: AnthropicEffortLevel) {
        self.modelChoice = modelChoice
        self.effortLevel = effortLevel
    }

    var identifier: String { "claude-subscription/\(modelChoice.apiModelIdentifier)" }

    /// Shown in errors, where the raw identifier would read as noise.
    private var userFacingName: String { "Claude (your subscription)" }

    var capabilities: ModelCapabilities {
        ModelCapabilities(
            supportsVision: true,
            supportsTools: true,
            // Tools are text tags here, same as the local model — see the
            // header. Claude is far better at the convention than a 3B model,
            // but the runtime should still apply the echo guard.
            supportsNativeToolCalls: false,
            supportsStreaming: true,
            supportsStructuredOutput: false,
            contextWindowTokens: 200_000
        )
    }

    var deployment: ModelDeployment {
        ModelDeployment(location: .remote(serviceName: "Anthropic (via the Claude Code CLI)"))
    }

    // MARK: - Running a turn

    func streamTurn(
        _ request: ModelRequest,
        onTextDelta: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> BuddyChatTurn {
        try validateAgainstCapabilities(request)

        guard let executablePath = LoginShellEnvironment.locateExecutable(named: "claude") else {
            throw BuddyChatError.providerUnavailable(
                providerName: userFacingName,
                underlyingDescription: "the Claude Code command line tool isn't installed. Install it, run `claude` once to sign in with your subscription, then try again."
            )
        }

        let skills = request.tools.contains(where: { $0.name == "load_skill" })
            ? await SkillManager.shared.skills
            : []
        let systemPrompt = request.systemPrompt
            + StructuredTextToolProtocol.promptInstructions(for: request.tools)
            + SkillIndex.promptInstructions(for: skills)

        let inputLine = try Self.userMessageInputLine(for: request)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.currentDirectoryURL = Self.scratchWorkingDirectory()
        process.arguments = Self.commandLineArguments(
            systemPrompt: systemPrompt,
            modelChoice: modelChoice,
            effortLevel: effortLevel
        )

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = LoginShellEnvironment.resolvedPath
        // The point of this provider is the subscription. If an API key is
        // exported in the user's shell the CLI would quietly bill that
        // instead, so it is removed from this one child process.
        environment.removeValue(forKey: "ANTHROPIC_API_KEY")
        environment.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        process.environment = environment

        let standardInputPipe = Pipe()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardInput = standardInputPipe
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        // Both pipes are drained through `readabilityHandler`, never
        // `FileHandle.bytes` — see the note in MCPStdioTransport.swift.
        let outputChunks = Self.chunkStream(from: standardOutputPipe.fileHandleForReading)
        let errorChunks = Self.chunkStream(from: standardErrorPipe.fileHandleForReading)
        let errorCapture = Task { () -> String in
            var capturedText = ""
            for await chunk in errorChunks {
                capturedText += String(decoding: chunk, as: UTF8.self)
                if capturedText.count > 4000 { capturedText = String(capturedText.suffix(4000)) }
            }
            return capturedText
        }

        let startDate = Date()
        do {
            try process.run()
        } catch {
            errorCapture.cancel()
            throw BuddyChatError.providerUnavailable(
                providerName: userFacingName,
                underlyingDescription: error.localizedDescription
            )
        }

        standardInputPipe.fileHandleForWriting.write(inputLine)
        try? standardInputPipe.fileHandleForWriting.close()

        let outcome = await withTaskCancellationHandler {
            await Self.readEventStream(from: outputChunks, onTextDelta: onTextDelta)
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        process.waitUntilExit()
        let standardErrorText = await errorCapture.value

        // Cancellation must surface as itself so the pipeline abandons the
        // turn quietly instead of reporting the killed process as a failure.
        if Task.isCancelled { throw CancellationError() }

        return try Self.turn(
            from: outcome,
            standardErrorText: standardErrorText,
            exitStatus: process.terminationStatus,
            duration: Date().timeIntervalSince(startDate),
            knownToolNames: Set(request.tools.map(\.name)),
            exampleToolName: request.tools.first?.name,
            providerName: userFacingName
        )
    }

    // MARK: - Command line

    /// Everything that stops the CLI behaving as an agent of its own.
    ///
    /// `--tools ""` removes the built-in tools, `--strict-mcp-config` with no
    /// config removes MCP servers, `--setting-sources ""` ignores the user's
    /// and any project's settings and hooks, and `--no-session-persistence`
    /// keeps these turns out of the user's `claude` history. `--bare` is not
    /// used because it ignores the subscription login.
    static func commandLineArguments(
        systemPrompt: String,
        modelChoice: AnthropicModelChoice,
        effortLevel: AnthropicEffortLevel
    ) -> [String] {
        var arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--system-prompt", systemPrompt,
            "--tools", "",
            "--strict-mcp-config",
            "--disable-slash-commands",
            "--no-session-persistence",
            "--setting-sources", "",
            "--model", modelChoice.apiModelIdentifier,
        ]
        // Haiku rejects an effort level, same as on the API.
        if modelChoice.usesAdaptiveThinkingAndEffort {
            arguments += ["--effort", effortLevel.rawValue]
        }
        return arguments
    }

    /// An empty folder to run in, so the CLI finds no CLAUDE.md or project
    /// files to pull into context.
    private static func scratchWorkingDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WispClaudeSubscription", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Request translation

    /// The one stream-json user message carrying the whole conversation.
    ///
    /// The CLI's input format accepts user messages only, so earlier turns are
    /// written into the text as a transcript rather than sent as alternating
    /// roles. Only the final user message's images are attached, the same as
    /// the local provider, because the agent loop decides which pass carries
    /// the screenshot.
    static func userMessageInputLine(for request: ModelRequest) throws -> Data {
        let messages = request.messages
        let finalUserIndex = messages.lastIndex { $0.role == .user }

        var transcriptLines: [String] = []
        for (index, message) in messages.enumerated() where index != finalUserIndex {
            let text = renderedText(of: message)
            if text.isEmpty { continue }
            switch message.role {
            case .user: transcriptLines.append("User: \(text)")
            case .assistant: transcriptLines.append("You: \(text)")
            }
        }

        var contentBlocks: [[String: Any]] = []
        var finalMessageText = ""
        if let finalUserIndex {
            let finalMessage = messages[finalUserIndex]
            finalMessageText = renderedText(of: finalMessage)
            for block in finalMessage.blocks {
                guard case .image(let imageData, let label) = block else { continue }
                if !label.isEmpty {
                    contentBlocks.append(["type": "text", "text": label])
                }
                contentBlocks.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": mediaType(forImageData: imageData),
                        "data": imageData.base64EncodedString(),
                    ],
                ])
            }
        }

        var promptText = ""
        if !transcriptLines.isEmpty {
            promptText += "Conversation so far:\n" + transcriptLines.joined(separator: "\n\n")
            promptText += "\n\nContinue the conversation. The user's latest message follows.\n\n"
        }
        promptText += finalMessageText
        contentBlocks.append(["type": "text", "text": promptText])

        let envelope: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": contentBlocks],
        ]
        var line = try JSONSerialization.data(withJSONObject: envelope)
        line.append(0x0A)
        return line
    }

    private static func renderedText(of message: BuddyChatMessage) -> String {
        var parts: [String] = []
        for block in message.blocks {
            switch block {
            case .text(let value):
                parts.append(value)
            case .toolResult(_, let toolName, let content, let isError):
                parts.append(
                    StructuredTextToolProtocol.resultMessageText(
                        toolName: toolName, content: content, isError: isError
                    )
                )
            case .toolUse(_, let name, let input):
                parts.append("[TOOL:\(name):\(input.compactDescription)]")
            case .image, .providerReplay:
                continue
            }
        }
        return parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Screen captures are JPEG or PNG; sniffed from the bytes because the
    /// block carries no type and a wrong one makes the API reject the image.
    private static func mediaType(forImageData imageData: Data) -> String {
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        if imageData.prefix(4).elementsEqual(pngSignature) { return "image/png" }
        return "image/jpeg"
    }

    // MARK: - Event stream

    /// What the CLI's event stream added up to.
    struct StreamOutcome: Sendable {
        var accumulatedText = ""
        var finalResultText: String?
        var isError = false
        var stopReason: String?
        var promptTokens: Int?
        var outputTokens: Int?
        var cacheReadTokens: Int?
        var cacheWriteTokens: Int?
        /// `total_cost_usd` from the result event: what the turn would cost at
        /// API rates. Reported by the CLI itself, so used as-is.
        var reportedCostUSD: Double?
        var sawRateLimitRejection = false
    }

    static func readEventStream(
        from chunks: AsyncStream<Data>,
        onTextDelta: @escaping @MainActor @Sendable (String) -> Void
    ) async -> StreamOutcome {
        var outcome = StreamOutcome()
        var lineBuffer = NewlineDelimitedLineBuffer()

        func handle(line: String) async {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let eventType = event["type"] as? String else { return }

            switch eventType {
            case "stream_event":
                // Only text deltas are spoken or shown; thinking deltas stay
                // inside the CLI. Deltas are new text only, as the protocol
                // requires.
                guard let streamEvent = event["event"] as? [String: Any],
                      streamEvent["type"] as? String == "content_block_delta",
                      let delta = streamEvent["delta"] as? [String: Any],
                      delta["type"] as? String == "text_delta",
                      let newText = delta["text"] as? String, !newText.isEmpty else { return }
                outcome.accumulatedText += newText
                await onTextDelta(newText)

            case "rate_limit_event":
                if let info = event["rate_limit_info"] as? [String: Any],
                   let status = info["status"] as? String, status.hasPrefix("rejected") {
                    outcome.sawRateLimitRejection = true
                }

            case "result":
                outcome.finalResultText = event["result"] as? String
                outcome.isError = (event["is_error"] as? Bool) ?? false
                outcome.stopReason = event["stop_reason"] as? String
                if let usage = event["usage"] as? [String: Any] {
                    let freshInput = usage["input_tokens"] as? Int ?? 0
                    let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
                    let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                    outcome.promptTokens = freshInput + cacheCreation + cacheRead
                    outcome.outputTokens = usage["output_tokens"] as? Int
                    outcome.cacheReadTokens = cacheRead
                    outcome.cacheWriteTokens = cacheCreation
                }
                outcome.reportedCostUSD = (event["total_cost_usd"] as? NSNumber)?.doubleValue

            default:
                return
            }
        }

        for await chunk in chunks {
            for line in lineBuffer.appendAndExtractCompleteLines(chunk) {
                await handle(line: line)
            }
        }
        if let lastLine = lineBuffer.flushRemainingLine() {
            await handle(line: lastLine)
        }
        return outcome
    }

    /// Delivers whatever bytes a pipe has as they arrive, finishing at end of
    /// file.
    private static func chunkStream(from fileHandle: FileHandle) -> AsyncStream<Data> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            fileHandle.readabilityHandler = { readableHandle in
                let chunk = readableHandle.availableData
                if chunk.isEmpty {
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

    // MARK: - Response translation

    static func turn(
        from outcome: StreamOutcome,
        standardErrorText: String,
        exitStatus: Int32,
        duration: TimeInterval,
        knownToolNames: Set<String>,
        exampleToolName: String? = nil,
        providerName: String
    ) throws -> BuddyChatTurn {
        let replyText = outcome.finalResultText ?? outcome.accumulatedText

        if outcome.isError || (exitStatus != 0 && replyText.isEmpty) {
            throw error(
                forFailureText: replyText.isEmpty ? standardErrorText : replyText,
                sawRateLimitRejection: outcome.sawRateLimitRejection,
                providerName: providerName
            )
        }

        let parsed = StructuredTextToolProtocol.parse(replyText, knownToolNames: knownToolNames)
        let echoedCallIDs = Set(
            parsed.toolCalls
                .filter { StructuredTextToolProtocol.isEchoOfPromptExample($0, exampleToolName: exampleToolName) }
                .map(\.id)
        )
        let content = parsed.contentBlocks.filter { block in
            if case .toolUse(let id, _, _) = block { return !echoedCallIDs.contains(id) }
            return true
        }

        let stopReason: BuddyStopReason
        if !content.toolUses.isEmpty {
            stopReason = .toolUse
        } else if outcome.stopReason == "max_tokens" {
            stopReason = .maxTokens
        } else {
            stopReason = .endTurn
        }

        return BuddyChatTurn(
            content: content,
            stopReason: stopReason,
            duration: duration,
            promptTokens: outcome.promptTokens,
            outputTokens: outcome.outputTokens,
            malformedToolCallDescriptions: parsed.malformedTags,
            cacheReadTokens: outcome.cacheReadTokens,
            cacheWriteTokens: outcome.cacheWriteTokens,
            reportedCostUSD: outcome.reportedCostUSD
        )
    }

    /// Maps the CLI's failure wording onto the errors the rest of the app
    /// already knows how to present. Substring matching because the CLI
    /// reports these as prose, not codes.
    static func error(
        forFailureText failureText: String,
        sawRateLimitRejection: Bool,
        providerName: String
    ) -> BuddyChatError {
        let lowercasedText = failureText.lowercased()
        if lowercasedText.contains("not logged in")
            || lowercasedText.contains("please run /login")
            || lowercasedText.contains("invalid api key")
            || lowercasedText.contains("authentication") {
            return .authenticationFailed(providerName: providerName)
        }
        if sawRateLimitRejection
            || lowercasedText.contains("usage limit")
            || lowercasedText.contains("rate limit")
            || lowercasedText.contains("limit reached") {
            return .rateLimited(providerName: providerName, retryAfter: nil)
        }
        let trimmedText = failureText.trimmingCharacters(in: .whitespacesAndNewlines)
        return .providerUnavailable(
            providerName: providerName,
            underlyingDescription: trimmedText.isEmpty
                ? "the Claude Code command line tool exited without an answer."
                : String(trimmedText.prefix(300))
        )
    }
}

// MARK: - Sign-in status

/// Whether the `claude` CLI is installed and signed in, for Settings → Model.
/// Asks the CLI itself (`claude auth status`) and so never touches its
/// credentials.
enum ClaudeSubscriptionStatus: Equatable, Sendable {
    case checking
    case notInstalled
    case signedOut
    case signedIn(email: String?)

    static func current() async -> ClaudeSubscriptionStatus {
        guard let executablePath = LoginShellEnvironment.locateExecutable(named: "claude") else {
            return .notInstalled
        }
        return await Task.detached(priority: .utility) { () -> ClaudeSubscriptionStatus in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = ["auth", "status"]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = LoginShellEnvironment.resolvedPath
            process.environment = environment
            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = Pipe()
            do { try process.run() } catch { return .signedOut }
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let status = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any],
                  status["loggedIn"] as? Bool == true else { return .signedOut }
            return .signedIn(email: status["email"] as? String)
        }.value
    }
}
