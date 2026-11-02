//
//  ClaudeSubscriptionProviderTests.swift
//  AgentRuntimeIntegration
//
//  The subscription provider's pure parts: the command line that switches the
//  CLI's own agent off, the stdin message (history as a transcript, screenshot
//  inline), reply parsing into tool calls, and failure wording → errors.
//  A live round trip through the real `claude` CLI runs only when
//  WISP_LIVE_CLAUDE=1, since it needs a signed-in subscription and spends it.
//

import Foundation

@MainActor func claudeSubscriptionProviderSuite() async {
    section("Claude subscription: command line")
    do {
        let arguments = ClaudeSubscriptionProvider.commandLineArguments(
            systemPrompt: "SYS", modelChoice: .opus, effortLevel: .low
        )
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        check("built-in tools are off", value(after: "--tools") == "")
        check("no MCP servers", arguments.contains("--strict-mcp-config"))
        check("user and project settings are ignored", value(after: "--setting-sources") == "")
        check("turns stay out of the user's claude history", arguments.contains("--no-session-persistence"))
        check("Wisp's prompt replaces the CLI's", value(after: "--system-prompt") == "SYS")
        check("the model is pinned", value(after: "--model") == "claude-opus-5-5")
        check("effort is passed for Opus", value(after: "--effort") == "low")
        check("--bare is not used (it ignores the subscription login)", !arguments.contains("--bare"))
        let haikuArguments = ClaudeSubscriptionProvider.commandLineArguments(
            systemPrompt: "SYS", modelChoice: .haiku, effortLevel: .high
        )
        check("no effort for Haiku, which rejects it", !haikuArguments.contains("--effort"))
    }

    section("Claude Code session: command line")
    do {
        let sessionID = UUID()
        func arguments(_ session: ClaudeSubscriptionProvider.CLISession) -> [String] {
            ClaudeSubscriptionProvider.commandLineArguments(
                systemPrompt: "SYS", modelChoice: .haiku, effortLevel: .low, session: session
            )
        }
        func value(after flag: String, in arguments: [String]) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let startArguments = arguments(.start(sessionID))
        let resumeArguments = arguments(.resume(sessionID))
        check("a new session is saved under Wisp's id", value(after: "--session-id", in: startArguments) == sessionID.uuidString.lowercased())
        check("a kept session is resumed by id", value(after: "--resume", in: resumeArguments) == sessionID.uuidString.lowercased())
        check("a kept session is saved", !startArguments.contains("--no-session-persistence") && !resumeArguments.contains("--no-session-persistence"))
        check("a kept session renders the system prompt fresh", value(after: "--system-prompt-snapshot", in: resumeArguments) == "off")
        check("a kept session still has no CLI tools", value(after: "--tools", in: resumeArguments) == "" && resumeArguments.contains("--strict-mcp-config"))
        check("a one-off run takes no snapshot flag", !arguments(.none).contains("--system-prompt-snapshot"))
    }

    section("Claude subscription: stdin message")
    do {
        let screenshot = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])
        let request = ModelRequest(
            systemPrompt: "x",
            messages: [
                BuddyChatMessage(role: .user, text: "first question"),
                BuddyChatMessage(role: .assistant, text: "first answer"),
                BuddyChatMessage(role: .user, blocks: [.image(data: screenshot, label: "screen1"), .text("what is this?")]),
            ]
        )
        let line = try? ClaudeSubscriptionProvider.userMessageInputLine(for: request)
        check("one newline-terminated line", line?.last == 0x0A && line?.filter { $0 == 0x0A }.count == 1)
        let parsed = line.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let message = parsed?["message"] as? [String: Any]
        let content = message?["content"] as? [[String: Any]] ?? []
        check("a user message", parsed?["type"] as? String == "user" && message?["role"] as? String == "user")
        let imageBlock = content.first { $0["type"] as? String == "image" }
        let source = imageBlock?["source"] as? [String: Any]
        check("the screenshot is inline, base64", source?["data"] as? String == screenshot.base64EncodedString())
        check("a PNG is labelled as one", source?["media_type"] as? String == "image/png")
        let finalText = content.last?["text"] as? String ?? ""
        check("history is a transcript in the text", finalText.contains("User: first question") && finalText.contains("You: first answer"))
        check("the latest message ends the text", finalText.hasSuffix("what is this?"))
    }

    section("Claude subscription: usage and reported cost")
    do {
        let resultEvent = #"{"type":"result","result":"Hi.","is_error":false,"total_cost_usd":0.0421,"usage":{"input_tokens":10,"cache_creation_input_tokens":200,"cache_read_input_tokens":900,"output_tokens":33}}"#
        let (chunkStream, chunkContinuation) = AsyncStream<Data>.makeStream()
        chunkContinuation.yield(Data((resultEvent + "\n").utf8))
        chunkContinuation.finish()
        let streamOutcome = await ClaudeSubscriptionProvider.readEventStream(from: chunkStream, onTextDelta: { _ in })
        check("result event: input is fresh + cache write + cache read", streamOutcome.promptTokens == 1110, "\(streamOutcome.promptTokens ?? -1)")
        check("result event: cache read and write reported separately",
              streamOutcome.cacheReadTokens == 900 && streamOutcome.cacheWriteTokens == 200)
        check("result event: total_cost_usd carried", streamOutcome.reportedCostUSD == 0.0421)
        let usageTurn = try? ClaudeSubscriptionProvider.turn(
            from: streamOutcome, standardErrorText: "", exitStatus: 0, duration: 1,
            knownToolNames: [], providerName: "Claude")
        check("turn carries cache counts and reported cost",
              usageTurn?.cacheReadTokens == 900 && usageTurn?.cacheWriteTokens == 200 && usageTurn?.reportedCostUSD == 0.0421)
    }

    section("Claude subscription: reply → turn")
    do {
        var outcome = ClaudeSubscriptionProvider.StreamOutcome()
        outcome.finalResultText = "On it. [TOOL:sample_tool:{\"query\":\"cats\"}]"
        outcome.promptTokens = 120
        outcome.outputTokens = 12
        let turn = try? ClaudeSubscriptionProvider.turn(
            from: outcome, standardErrorText: "", exitStatus: 0, duration: 1,
            knownToolNames: ["sample_tool"], providerName: "Claude"
        )
        check("a text-tag call becomes a toolUse", turn?.toolUses.first?.name == "sample_tool")
        check("and the turn asks to continue", turn?.stopReason == .toolUse)
        check("token usage is carried", turn?.promptTokens == 120 && turn?.outputTokens == 12)

        var plain = ClaudeSubscriptionProvider.StreamOutcome()
        plain.finalResultText = "Hello there."
        let plainTurn = try? ClaudeSubscriptionProvider.turn(
            from: plain, standardErrorText: "", exitStatus: 0, duration: 1,
            knownToolNames: [], providerName: "Claude"
        )
        check("plain prose ends the turn", plainTurn?.stopReason == .endTurn && plainTurn?.text == "Hello there.")
    }

    section("Claude subscription: failures")
    do {
        func errorKind(_ text: String, rateLimited: Bool = false) -> String {
            switch ClaudeSubscriptionProvider.error(forFailureText: text, sawRateLimitRejection: rateLimited, providerName: "Claude") {
            case .authenticationFailed: return "auth"
            case .rateLimited: return "rate"
            case .providerUnavailable: return "unavailable"
            default: return "other"
            }
        }
        check("signed out → authentication", errorKind("Not logged in · Please run /login") == "auth")
        check("usage limit → rate limited", errorKind("5-hour usage limit reached") == "rate")
        check("a rejected rate-limit event → rate limited", errorKind("something", rateLimited: true) == "rate")
        check("anything else → unavailable with the text", errorKind("boom") == "unavailable")

        var failed = ClaudeSubscriptionProvider.StreamOutcome()
        failed.isError = true
        failed.finalResultText = "Not logged in · Please run /login"
        var threwAuth = false
        do {
            _ = try ClaudeSubscriptionProvider.turn(
                from: failed, standardErrorText: "", exitStatus: 1, duration: 1,
                knownToolNames: [], providerName: "Claude"
            )
        } catch BuddyChatError.authenticationFailed { threwAuth = true } catch {}
        check("an error result throws instead of becoming an answer", threwAuth)
    }

    if ProcessInfo.processInfo.environment["WISP_LIVE_CLAUDE"] == "1" {
        section("Claude subscription: live round trip (real claude CLI)")
        let provider = ClaudeSubscriptionProvider(modelChoice: .sonnet, effortLevel: .low)
        let deltas = Deltas()
        do {
            let turn = try await provider.streamTurn(
                ModelRequest(systemPrompt: "You are terse.", messages: [BuddyChatMessage(role: .user, text: "Reply with exactly the word: pong")]),
                onTextDelta: { deltas.values.append($0) }
            )
            check("live: answered", turn.text.lowercased().contains("pong"), turn.text)
            check("live: text streamed as deltas", !deltas.values.isEmpty)
            check("live: ended the turn", turn.stopReason == .endTurn)
        } catch {
            check("live: no error", false, "\(error.localizedDescription)")
        }

        section("Claude Code session: live (real claude CLI)")
        let sessionStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisp-session-test-\(UUID().uuidString)/buddy-sessions.json")
        let sessionStore = BuddySessionStore(fileURL: sessionStoreURL)
        let buddyID = UUID()
        let mainKey = BuddySessionKey(buddyID: buddyID, conversationID: nil)
        let sessionProvider = ClaudeCodeSessionProvider(
            modelChoice: .haiku, effortLevel: .low, sessionKey: mainKey, sessionStore: sessionStore
        )
        let systemPrompt = "You are Pip, a terse helper. Answer in one short line."
        do {
            let firstQuestion = BuddyChatMessage(role: .user, text: "Remember the word tangerine. Reply OK.")
            let firstTurn = try await sessionProvider.streamTurn(
                ModelRequest(systemPrompt: systemPrompt, messages: [firstQuestion]), onTextDelta: { _ in }
            )
            check("live session: a session was started", sessionStore.record(for: mainKey) != nil)

            // The stored history no longer says the word: only the session can.
            let secondTurn = try await sessionProvider.streamTurn(
                ModelRequest(systemPrompt: systemPrompt, messages: [
                    BuddyChatMessage(role: .user, text: "(earlier message)"),
                    BuddyChatMessage(role: .assistant, text: firstTurn.text),
                    BuddyChatMessage(role: .user, text: "Which word did I ask you to remember? Just the word."),
                ]),
                onTextDelta: { _ in }
            )
            check("live session: the resumed session remembers", secondTurn.text.lowercased().contains("tangerine"), secondTurn.text)
            check("live session: the same session was kept", sessionStore.record(for: mainKey)?.answeredCallCount == 2)

            let secretTool = BuddyToolDefinition(
                name: "get_secret_number", description: "Returns the user's secret number.",
                inputSchema: .object(["type": .string("object")]), metadata: .trivialAndReversible
            )
            let askForTool = BuddyChatMessage(role: .user, text: "Call get_secret_number, then tell me the number.")
            let toolTurn = try await sessionProvider.streamTurn(
                ModelRequest(systemPrompt: systemPrompt, messages: [askForTool], tools: [secretTool]), onTextDelta: { _ in }
            )
            check("live session: the tool is called as a [TOOL:] tag", toolTurn.toolUses.first?.name == "get_secret_number", toolTurn.text)
            if let toolUse = toolTurn.toolUses.first {
                let answerTurn = try await sessionProvider.streamTurn(
                    ModelRequest(systemPrompt: systemPrompt, messages: [
                        askForTool,
                        BuddyChatMessage(role: .assistant, blocks: toolTurn.content),
                        BuddyChatMessage(role: .user, blocks: [.toolResult(toolUseID: toolUse.id, toolName: toolUse.name, content: "4187", isError: false)]),
                    ], tools: [secretTool]),
                    onTextDelta: { _ in }
                )
                check("live session: the tool result reaches the session", answerTurn.text.contains("4187"), answerTurn.text)
            }

            // A record whose CLI session is gone starts a new one with the history.
            let lostKey = BuddySessionKey(buddyID: buddyID, conversationID: UUID())
            let lostSessionID = UUID()
            sessionStore.noteAnsweredCall(in: lostKey, sessionID: lostSessionID)
            let lostProvider = ClaudeCodeSessionProvider(
                modelChoice: .haiku, effortLevel: .low, sessionKey: lostKey, sessionStore: sessionStore
            )
            let recoveredTurn = try await lostProvider.streamTurn(
                ModelRequest(systemPrompt: systemPrompt, messages: [
                    BuddyChatMessage(role: .user, text: "My cat is called Biscuit."),
                    BuddyChatMessage(role: .assistant, text: "Noted."),
                    BuddyChatMessage(role: .user, text: "What is my cat called? Just the name."),
                ]),
                onTextDelta: { _ in }
            )
            check("live session: a gone session is replaced", sessionStore.record(for: lostKey).map { $0.sessionID != lostSessionID } ?? false)
            check("live session: the replacement got the history", recoveredTurn.text.lowercased().contains("biscuit"), recoveredTurn.text)
        } catch {
            check("live session: no error", false, "\(error.localizedDescription)")
        }
        // Removes the CLI's session files and the test buddy's workspace.
        sessionStore.forgetSessions(ofBuddyWithID: buddyID)
        BuddyWorkspace.deleteFolder(ofBuddyWithID: buddyID)
        try? FileManager.default.removeItem(at: sessionStoreURL.deletingLastPathComponent())
    }
}
