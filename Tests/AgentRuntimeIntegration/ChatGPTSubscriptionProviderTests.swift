//
//  ChatGPTSubscriptionProviderTests.swift
//  AgentRuntimeIntegration
//
//  The ChatGPT subscription provider's pure parts: the `codex exec` command
//  line that switches the CLI's own agent off, the TOML escaping of Wisp's
//  system prompt, the stdin prompt, the JSONL event stream, failure wording,
//  and `codex login status` parsing. A live round trip through the real
//  `codex` CLI runs only when WISP_LIVE_CODEX=1, since it needs a ChatGPT
//  sign-in and spends the plan's limits.
//

import Foundation

@MainActor func chatGPTSubscriptionProviderSuite() async {
    section("ChatGPT subscription: command line")
    do {
        let workingDirectory = URL(fileURLWithPath: "/tmp/wisp-turn")
        let arguments = ChatGPTSubscriptionProvider.commandLineArguments(
            systemPrompt: "SYS",
            workingDirectory: workingDirectory,
            imageFileURLs: [URL(fileURLWithPath: "/tmp/wisp-turn/screen-1.jpg")]
        )
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let overrides = arguments.indices.filter { arguments[$0] == "-c" }.map { arguments[$0 + 1] }
        check("runs codex exec with JSONL events", arguments.first == "exec" && arguments.contains("--json"))
        check("no session files are kept", arguments.contains("--ephemeral"))
        check("the user's config and rules aren't loaded", arguments.contains("--ignore-user-config") && arguments.contains("--ignore-rules"))
        check("read-only sandbox", value(after: "--sandbox") == "read-only")
        check("runs in the empty turn folder", value(after: "-C") == workingDirectory.path)
        check("the shell tool is off", overrides.contains("features.shell_tool=false") && overrides.contains("features.unified_exec=false"))
        check("web search is off", overrides.contains("web_search=\"disabled\""))
        check("no MCP servers", overrides.contains("mcp_servers={}"))
        check("only a ChatGPT login is used", overrides.contains("forced_login_method=\"chatgpt\""))
        check("Wisp's prompt is the developer instructions", overrides.contains("developer_instructions=\"SYS\""))
        check("the screenshot is attached", value(after: "--image") == "/tmp/wisp-turn/screen-1.jpg")
        check("the prompt is read from stdin", arguments.last == "-")
    }

    section("ChatGPT subscription: TOML escaping")
    do {
        let escaped = ChatGPTSubscriptionProvider.tomlBasicString("say \"hi\"\nC:\\path\ttab\u{01}")
        check("quotes, newlines, backslashes, tabs and controls are escaped",
              escaped == #""say \"hi\"\nC:\\path\ttab\u0001""#, escaped)
    }

    section("ChatGPT subscription: stdin prompt")
    do {
        let request = ModelRequest(
            systemPrompt: "x",
            messages: [
                BuddyChatMessage(role: .user, text: "first question"),
                BuddyChatMessage(role: .assistant, text: "first answer"),
                BuddyChatMessage(role: .user, blocks: [.image(data: Data([0xFF, 0xD8]), label: "screen1"), .text("what is this?")]),
            ]
        )
        let prompt = ChatGPTSubscriptionProvider.promptText(for: request)
        check("history is a transcript", prompt.contains("User: first question") && prompt.contains("You: first answer"))
        check("the image is named", prompt.contains("screen1"))
        check("the latest message ends the prompt", prompt.hasSuffix("what is this?"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = (try? ChatGPTSubscriptionProvider.writeFinalUserMessageImages(of: request, into: directory)) ?? []
        check("one JPEG written for the final message's image", files.count == 1 && files.first?.pathExtension == "jpg")
        try? FileManager.default.removeItem(at: directory)
    }

    section("ChatGPT subscription: event stream")
    do {
        let lines = [
            #"{"type":"thread.started","thread_id":"t"}"#,
            #"{"type":"item.completed","item":{"id":"item_0","type":"reasoning","text":"thinking"}}"#,
            #"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"Opening Notes now."}}"#,
            #"{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"[TOOL:open_app:{\"name\":\"Notes\"}]"}}"#,
            #"{"type":"turn.completed","usage":{"input_tokens":1200,"cached_input_tokens":800,"output_tokens":40}}"#,
        ]
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        continuation.yield(Data((lines.joined(separator: "\n") + "\n").utf8))
        continuation.finish()
        let streamed = Deltas()
        let outcome = await ChatGPTSubscriptionProvider.readEventStream(from: stream, onTextDelta: { streamed.values.append($0) })
        check("reasoning isn't a message", outcome.agentMessages.count == 2)
        check("only the final message is streamed, once", streamed.values == [#"[TOOL:open_app:{"name":"Notes"}]"#], "\(streamed.values)")
        check("usage is read", outcome.promptTokens == 1200 && outcome.cachedInputTokens == 800 && outcome.outputTokens == 40)
        let turn = try? ChatGPTSubscriptionProvider.turn(
            from: outcome, standardErrorText: "", exitStatus: 0, duration: 1,
            knownToolNames: ["open_app"], providerName: "ChatGPT")
        check("a [TOOL:] tag becomes a tool call", turn?.stopReason == .toolUse && turn?.toolUses.first?.name == "open_app")
        check("the preamble isn't part of the reply", !(turn?.text.contains("Opening Notes now") ?? true))

        let failed = ChatGPTSubscriptionProvider.StreamOutcome(failureMessage: "You've hit your usage limit. Try again later.")
        do {
            _ = try ChatGPTSubscriptionProvider.turn(from: failed, standardErrorText: "", exitStatus: 1, duration: 1, knownToolNames: [], providerName: "ChatGPT")
            check("a usage limit throws", false)
        } catch BuddyChatError.rateLimited {
            check("a usage limit is a rate limit", true)
        } catch {
            check("a usage limit is a rate limit", false, "\(error)")
        }
        let signedOut = ChatGPTSubscriptionProvider.error(forFailureText: "Not logged in. Run codex login.", exitStatus: 1, providerName: "ChatGPT")
        if case .authenticationFailed = signedOut { check("not logged in is an auth failure", true) } else { check("not logged in is an auth failure", false) }
    }

    section("ChatGPT subscription: login status")
    do {
        check("ChatGPT login", ChatGPTSubscriptionStatus.status(fromLoginStatusOutput: "Logged in using ChatGPT\n") == .signedIn)
        check("API key login isn't the subscription",
              ChatGPTSubscriptionStatus.status(fromLoginStatusOutput: "Logged in using an API key - sk-***abcd") == .signedInWithoutChatGPT)
        check("signed out", ChatGPTSubscriptionStatus.status(fromLoginStatusOutput: "Not logged in") == .signedOut)
        check("a provider kind that needs no key", !BuddyChatProviderKind.chatGPTSubscription.requiresAPIKey
              && BuddyChatProviderKind.chatGPTSubscription.sendsScreenshotsOffThisMachine)
        check("usage log reads its identifier",
              UsageProviderIdentifier.parse(ChatGPTSubscriptionProvider().identifier)?.providerKind == .chatGPTSubscription)
    }

    if ProcessInfo.processInfo.environment["WISP_LIVE_CODEX"] == "1" {
        section("ChatGPT subscription: live round trip (real codex CLI)")
        let provider = ChatGPTSubscriptionProvider()
        let status = await ChatGPTSubscriptionStatus.current()
        check("live: codex is signed in with ChatGPT", status == .signedIn, "\(status)")
        let systemPrompt = "You are Wisp, a helpful companion on the user's Mac. Be brief."
        do {
            let deltas = Deltas()
            let turn = try await provider.streamTurn(
                ModelRequest(systemPrompt: systemPrompt, messages: [BuddyChatMessage(role: .user, text: "Reply with exactly the word: pong")]),
                onTextDelta: { deltas.values.append($0) }
            )
            check("live: answered", turn.text.lowercased().contains("pong"), turn.text)
            check("live: the reply was delivered", deltas.values.joined() == turn.text)
            check("live: usage reported", (turn.promptTokens ?? 0) > 0 && (turn.outputTokens ?? 0) > 0)

            // A real screenshot of this Mac, like a push-to-talk turn sends.
            let screenshotURL = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-live-\(UUID().uuidString).jpg")
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-t", "jpg", screenshotURL.path]
            try? capture.run(); capture.waitUntilExit()
            if let screenshot = try? Data(contentsOf: screenshotURL) {
                let visionTurn = try await provider.streamTurn(
                    ModelRequest(systemPrompt: systemPrompt, messages: [BuddyChatMessage(role: .user, blocks: [
                        .image(data: screenshot, label: "screen1"),
                        .text("In a few words, what is on this screen?"),
                    ])]),
                    onTextDelta: { _ in }
                )
                check("live: describes the screenshot", !visionTurn.text.isEmpty && !visionTurn.text.lowercased().contains("can't see"), visionTurn.text)
                try? FileManager.default.removeItem(at: screenshotURL)
            }

            let secretTool = BuddyToolDefinition(
                name: "get_secret_number", description: "Returns the user's secret number.",
                inputSchema: .object(["type": .string("object")]), metadata: .trivialAndReversible
            )
            let askForTool = BuddyChatMessage(role: .user, text: "Call get_secret_number, then tell me the number.")
            let toolTurn = try await provider.streamTurn(
                ModelRequest(systemPrompt: systemPrompt, messages: [askForTool], tools: [secretTool]), onTextDelta: { _ in }
            )
            check("live: the tool is called as a [TOOL:] tag", toolTurn.toolUses.first?.name == "get_secret_number", toolTurn.text)
            if let toolUse = toolTurn.toolUses.first {
                let answerTurn = try await provider.streamTurn(
                    ModelRequest(systemPrompt: systemPrompt, messages: [
                        askForTool,
                        BuddyChatMessage(role: .assistant, blocks: toolTurn.content),
                        BuddyChatMessage(role: .user, blocks: [.toolResult(toolUseID: toolUse.id, toolName: toolUse.name, content: "4187", isError: false)]),
                    ], tools: [secretTool]),
                    onTextDelta: { _ in }
                )
                check("live: the tool result is used", answerTurn.text.contains("4187"), answerTurn.text)
            }

            let shellTurn = try await provider.streamTurn(
                ModelRequest(systemPrompt: systemPrompt, messages: [BuddyChatMessage(role: .user, text: "Run `ls ~` in a shell and paste the output.")]),
                onTextDelta: { _ in }
            )
            check("live: the CLI can't run commands itself", !shellTurn.text.contains("Downloads") && !shellTurn.text.contains("Library"), shellTurn.text)
        } catch {
            check("live: no error", false, "\(error.localizedDescription)")
        }
    }
}
