//
//  ChatGPTSubscriptionProvider.swift
//  leanring-buddy
//
//  ChatGPT as the chat model, paid for by the user's ChatGPT subscription
//  (Plus, Pro, Business…) instead of an OpenAI API key.
//
//  The ChatGPT twin of `ClaudeSubscriptionProvider`: Wisp launches OpenAI's own
//  `codex` command line tool, which the user has installed and signed in to
//  with their ChatGPT account themselves (`codex login`), once per turn with
//  `codex exec`. Wisp never reads, copies or forwards the CLI's login (it lives
//  in `~/.codex/auth.json` or the Keychain) and never calls OpenAI's API with
//  it. If the CLI isn't installed or isn't signed in, the turn fails saying so.
//
//  The CLI is used as a bare model, not as an agent: its shell, image viewer,
//  web search and MCP servers are switched off, the user's config and rules
//  files aren't loaded, the sandbox is read-only, and it runs in an empty
//  folder with session files off. Wisp's system prompt rides as the CLI's
//  developer instructions, and tools are offered the way the local model gets
//  them, as `[TOOL:name:{…}]` text parsed back into `toolUse` blocks, so the
//  tool loop, confirmations and `ToolCallSafety` above this seam are unchanged
//  and the CLI never acts on the user's machine by itself.
//
//  `OPENAI_API_KEY`/`CODEX_API_KEY` are removed from the child's environment and
//  `forced_login_method = "chatgpt"` is set, so a key exported in the shell
//  can't quietly be billed instead of the subscription.
//
//  The screenshot goes as an `--image` file in a per-turn temporary folder that
//  is deleted when the turn ends. `codex exec --json` reports each finished
//  message rather than token deltas, so the reply arrives in one piece.
//

import Foundation

final class ChatGPTSubscriptionProvider: ModelProvider, @unchecked Sendable {
    init() {}

    /// The CLI picks the model the subscription offers by default; Wisp
    /// doesn't override it, so a new default model needs no Wisp update.
    var identifier: String { "chatgpt-subscription/\(Self.modelIdentifierForUsage)" }

    /// What the usage log and the status pill call the model.
    static let modelIdentifierForUsage = "codex-default"
    static let userFacingModelName = "ChatGPT (Codex default model)"

    private var userFacingName: String { "ChatGPT (your subscription)" }

    var capabilities: ModelCapabilities {
        ModelCapabilities(
            supportsVision: true,
            supportsTools: true,
            // Tools are text tags, same as the local model — see the header.
            supportsNativeToolCalls: false,
            supportsStreaming: true,
            supportsStructuredOutput: false,
            contextWindowTokens: 200_000
        )
    }

    var deployment: ModelDeployment {
        ModelDeployment(location: .remote(serviceName: "OpenAI (via the Codex CLI)"))
    }

    // MARK: - Running a turn

    func streamTurn(
        _ request: ModelRequest,
        onTextDelta: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> BuddyChatTurn {
        try validateAgainstCapabilities(request)

        guard let executablePath = LoginShellEnvironment.locateExecutable(named: "codex") else {
            throw BuddyChatError.providerUnavailable(
                providerName: userFacingName,
                underlyingDescription: "the Codex command line tool isn't installed. Install it (`npm install -g @openai/codex` or `brew install codex`), run `codex login` once to sign in with your ChatGPT account, then try again."
            )
        }

        let systemPrompt = await ClaudeSubscriptionProvider.systemPromptIncludingTools(for: request)

        // One folder per turn: the CLI's working directory (empty, so there is
        // no AGENTS.md or project to pull in) and where the screenshots go.
        let turnDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WispChatGPTSubscription", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: turnDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: turnDirectory) }

        let imageFileURLs = try Self.writeFinalUserMessageImages(of: request, into: turnDirectory)
        let promptText = Self.promptText(for: request)

        let processResult = try await Self.runCLI(
            executablePath: executablePath,
            arguments: Self.commandLineArguments(
                systemPrompt: systemPrompt,
                workingDirectory: turnDirectory,
                imageFileURLs: imageFileURLs
            ),
            workingDirectory: turnDirectory,
            standardInputText: promptText,
            providerName: userFacingName,
            onTextDelta: onTextDelta
        )

        return try Self.turn(
            from: processResult.outcome,
            standardErrorText: processResult.standardErrorText,
            exitStatus: processResult.exitStatus,
            duration: processResult.duration,
            knownToolNames: Set(request.tools.map(\.name)),
            exampleToolName: request.tools.first?.name,
            providerName: userFacingName
        )
    }

    // MARK: - Command line

    /// Everything that stops the CLI behaving as an agent of its own. Each `-c`
    /// overrides one `config.toml` value for this run only.
    static func commandLineArguments(
        systemPrompt: String,
        workingDirectory: URL,
        imageFileURLs: [URL]
    ) -> [String] {
        var arguments = [
            "exec",
            "--json",
            "--ephemeral",
            "--skip-git-repo-check",
            "--ignore-user-config",
            "--ignore-rules",
            "--sandbox", "read-only",
            "-C", workingDirectory.path,
            "-c", "forced_login_method=\"chatgpt\"",
            "-c", "approval_policy=\"never\"",
            "-c", "features.shell_tool=false",
            "-c", "features.unified_exec=false",
            "-c", "features.view_image=false",
            "-c", "web_search=\"disabled\"",
            "-c", "mcp_servers={}",
            "-c", "project_doc_max_bytes=0",
            "-c", "developer_instructions=\(tomlBasicString(systemPrompt))",
        ]
        for imageFileURL in imageFileURLs {
            arguments += ["--image", imageFileURL.path]
        }
        // `-` reads the prompt from stdin, so the conversation never sits in
        // the process list.
        arguments.append("-")
        return arguments
    }

    /// A TOML basic string, because `-c` values are parsed as TOML: a system
    /// prompt has quotes, backslashes and newlines that would otherwise break
    /// the value or be read as something else.
    static func tomlBasicString(_ text: String) -> String {
        var escaped = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    escaped += String(format: "\\u%04X", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        escaped += "\""
        return escaped
    }

    // MARK: - Request translation

    /// The whole conversation as one prompt. `codex exec` takes one user turn,
    /// so earlier turns are written in as a transcript, as the Claude
    /// subscription provider does.
    static func promptText(for request: ModelRequest) -> String {
        let messages = request.messages
        let finalUserIndex = messages.lastIndex { $0.role == .user }

        var transcriptLines: [String] = []
        for (index, message) in messages.enumerated() where index != finalUserIndex {
            let text = ClaudeSubscriptionProvider.renderedText(of: message)
            if text.isEmpty { continue }
            switch message.role {
            case .user: transcriptLines.append("User: \(text)")
            case .assistant: transcriptLines.append("You: \(text)")
            }
        }

        var promptText = ""
        if !transcriptLines.isEmpty {
            promptText += "Conversation so far:\n" + transcriptLines.joined(separator: "\n\n")
            promptText += "\n\nContinue the conversation. The user's latest message follows.\n\n"
        }
        if let finalUserIndex {
            let finalMessage = messages[finalUserIndex]
            let imageLabels = finalMessage.blocks.compactMap { block -> String? in
                guard case .image(_, let label) = block, !label.isEmpty else { return nil }
                return label
            }
            if !imageLabels.isEmpty {
                promptText += "Attached images, in order: " + imageLabels.joined(separator: "; ") + "\n\n"
            }
            promptText += ClaudeSubscriptionProvider.renderedText(of: finalMessage)
        }
        return promptText
    }

    /// Only the final user message's images are sent, like every other
    /// provider: the agent loop decides which pass carries the screenshot.
    static func writeFinalUserMessageImages(of request: ModelRequest, into directory: URL) throws -> [URL] {
        guard let finalUserMessage = request.messages.last(where: { $0.role == .user }) else { return [] }
        var imageFileURLs: [URL] = []
        for block in finalUserMessage.blocks {
            guard case .image(let imageData, _) = block else { continue }
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let fileExtension = imageData.prefix(4).elementsEqual(pngSignature) ? "png" : "jpg"
            let imageFileURL = directory.appendingPathComponent("screen-\(imageFileURLs.count + 1).\(fileExtension)")
            try imageData.write(to: imageFileURL)
            imageFileURLs.append(imageFileURL)
        }
        return imageFileURLs
    }

    // MARK: - Process

    struct ProcessResult: Sendable {
        let outcome: StreamOutcome
        let standardErrorText: String
        let exitStatus: Int32
        let duration: TimeInterval
    }

    static func runCLI(
        executablePath: String,
        arguments: [String],
        workingDirectory: URL,
        standardInputText: String,
        providerName: String,
        onTextDelta: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.currentDirectoryURL = workingDirectory
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = LoginShellEnvironment.resolvedPath
        // The point of this provider is the subscription; an exported key
        // would be billed instead.
        environment.removeValue(forKey: "OPENAI_API_KEY")
        environment.removeValue(forKey: "CODEX_API_KEY")
        process.environment = environment

        let standardInputPipe = Pipe()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardInput = standardInputPipe
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        // Drained through `readabilityHandler`, never `FileHandle.bytes` — see
        // the note in MCPStdioTransport.swift.
        let outputChunks = ClaudeSubscriptionProvider.chunkStream(from: standardOutputPipe.fileHandleForReading)
        let errorChunks = ClaudeSubscriptionProvider.chunkStream(from: standardErrorPipe.fileHandleForReading)
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
                providerName: providerName,
                underlyingDescription: error.localizedDescription
            )
        }

        standardInputPipe.fileHandleForWriting.write(Data(standardInputText.utf8))
        try? standardInputPipe.fileHandleForWriting.close()

        let outcome = await withTaskCancellationHandler {
            await Self.readEventStream(from: outputChunks, onTextDelta: onTextDelta)
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        process.waitUntilExit()
        let standardErrorText = await errorCapture.value

        if Task.isCancelled { throw CancellationError() }

        return ProcessResult(
            outcome: outcome,
            standardErrorText: standardErrorText,
            exitStatus: process.terminationStatus,
            duration: Date().timeIntervalSince(startDate)
        )
    }

    // MARK: - Event stream

    /// What `codex exec --json`'s events added up to.
    struct StreamOutcome: Sendable {
        /// Every finished `agent_message`, in order.
        var agentMessages: [String] = []
        var failureMessage: String?
        var promptTokens: Int?
        var cachedInputTokens: Int?
        var outputTokens: Int?
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
            case "item.completed":
                guard let item = event["item"] as? [String: Any],
                      item["type"] as? String == "agent_message",
                      let messageText = item["text"] as? String, !messageText.isEmpty else { return }
                // Deltas are new text only; a second message is a new paragraph.
                let delta = outcome.agentMessages.isEmpty ? messageText : "\n\n" + messageText
                outcome.agentMessages.append(messageText)
                await onTextDelta(delta)

            case "turn.completed":
                if let usage = event["usage"] as? [String: Any] {
                    // `input_tokens` already includes the cached part.
                    outcome.promptTokens = usage["input_tokens"] as? Int
                    outcome.cachedInputTokens = usage["cached_input_tokens"] as? Int
                    outcome.outputTokens = usage["output_tokens"] as? Int
                }

            case "turn.failed":
                let error = event["error"] as? [String: Any]
                outcome.failureMessage = (error?["message"] as? String) ?? "turn failed"

            case "error":
                // Non-final errors (a reconnect) are reported here too; only
                // keep one if nothing better arrives.
                if outcome.failureMessage == nil, let message = event["message"] as? String {
                    outcome.failureMessage = message
                }

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
        let replyText = outcome.agentMessages.joined(separator: "\n\n")

        if replyText.isEmpty {
            let failureText = outcome.failureMessage
                ?? (standardErrorText.isEmpty ? "" : standardErrorText)
            throw error(forFailureText: failureText, exitStatus: exitStatus, providerName: providerName)
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

        return BuddyChatTurn(
            content: content,
            stopReason: content.toolUses.isEmpty ? .endTurn : .toolUse,
            duration: duration,
            promptTokens: outcome.promptTokens,
            outputTokens: outcome.outputTokens,
            malformedToolCallDescriptions: parsed.malformedTags,
            cacheReadTokens: outcome.cachedInputTokens,
            cacheWriteTokens: nil,
            reportedCostUSD: nil
        )
    }

    /// The CLI reports failures as prose, so this matches wording.
    static func error(forFailureText failureText: String, exitStatus: Int32, providerName: String) -> BuddyChatError {
        let lowercasedText = failureText.lowercased()
        if lowercasedText.contains("not logged in")
            || lowercasedText.contains("codex login")
            || lowercasedText.contains("401")
            || lowercasedText.contains("unauthorized")
            || lowercasedText.contains("refresh token")
            || lowercasedText.contains("sign in again") {
            return .authenticationFailed(providerName: providerName)
        }
        if lowercasedText.contains("usage limit")
            || lowercasedText.contains("rate limit")
            || lowercasedText.contains("429")
            || lowercasedText.contains("too many requests") {
            return .rateLimited(providerName: providerName, retryAfter: nil)
        }
        let trimmedText = failureText.trimmingCharacters(in: .whitespacesAndNewlines)
        return .providerUnavailable(
            providerName: providerName,
            underlyingDescription: trimmedText.isEmpty
                ? "the Codex command line tool exited (status \(exitStatus)) without an answer."
                : String(trimmedText.suffix(300))
        )
    }
}

// MARK: - Sign-in status

/// Whether the `codex` CLI is installed and signed in with ChatGPT, for
/// Settings → Model. Asks the CLI (`codex login status`), never reads its
/// credentials.
enum ChatGPTSubscriptionStatus: Equatable, Sendable {
    case checking
    case notInstalled
    case signedOut
    /// Signed in, but with an API key or token rather than a ChatGPT account,
    /// so the subscription isn't what would pay.
    case signedInWithoutChatGPT
    case signedIn

    static func current() async -> ChatGPTSubscriptionStatus {
        guard let executablePath = LoginShellEnvironment.locateExecutable(named: "codex") else {
            return .notInstalled
        }
        return await Task.detached(priority: .utility) { () -> ChatGPTSubscriptionStatus in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = ["login", "status"]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = LoginShellEnvironment.resolvedPath
            environment.removeValue(forKey: "OPENAI_API_KEY")
            environment.removeValue(forKey: "CODEX_API_KEY")
            process.environment = environment
            // The status line goes to stderr; both are read.
            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            do { try process.run() } catch { return .signedOut }
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return status(fromLoginStatusOutput: String(decoding: outputData, as: UTF8.self))
        }.value
    }

    /// Pure, so it can be tested without the CLI.
    static func status(fromLoginStatusOutput output: String) -> ChatGPTSubscriptionStatus {
        let lowercasedOutput = output.lowercased()
        if lowercasedOutput.contains("not logged in") { return .signedOut }
        if lowercasedOutput.contains("logged in using chatgpt") { return .signedIn }
        if lowercasedOutput.contains("logged in") { return .signedInWithoutChatGPT }
        return .signedOut
    }
}
