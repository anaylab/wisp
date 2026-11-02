//
//  ClaudeCodeSessionProvider.swift
//  leanring-buddy
//
//  A buddy's own Claude Code session (`BuddyRuntimeKind.claudeCodeSession`).
//
//  Like `ClaudeSubscriptionProvider` this drives the user's signed-in `claude`
//  CLI with every CLI tool, MCP server, slash command and settings source off,
//  and tools offered as `[TOOL:]` text, so the agent loop and its confirmation
//  cards above this seam are unchanged. The difference is memory: instead of
//  one throwaway CLI run per call with the whole conversation flattened into
//  it, each buddy conversation keeps one saved session. The first call starts
//  it under an id Wisp chooses (`--session-id`) and hands it the history so
//  far; every later call resumes it (`--resume`) and sends only what the
//  session hasn't seen (`BuddySessionPolicy.messagesNotYetInSession`).
//
//  If the session can't be resumed (its file is gone), the call starts a new
//  one with the full history, the same handoff OpenBot gives a replacement
//  session, so a lost session costs one bigger prompt, never the conversation.
//
//  The CLI compacts a long session by itself, so Wisp doesn't. It records how
//  full each session's context is after every call (shown in the buddy's
//  settings) and starts the conversation over in a new session only as a
//  safety net: when the last call left it at least 95% full, or the CLI says
//  the prompt no longer fits.
//
//  Sessions are saved by the CLI itself, under `~/.claude/projects/`, in a
//  project named after the buddy's workspace folder. Clearing or deleting the
//  buddy removes those files again (`ClaudeCodeSessionFiles`).
//

import Foundation

final class ClaudeCodeSessionProvider: ModelProvider, @unchecked Sendable {
    private let modelChoice: AnthropicModelChoice
    private let effortLevel: AnthropicEffortLevel
    private let sessionKey: BuddySessionKey
    private let sessionStore: BuddySessionStore

    init(
        modelChoice: AnthropicModelChoice,
        effortLevel: AnthropicEffortLevel,
        sessionKey: BuddySessionKey,
        sessionStore: BuddySessionStore = .shared
    ) {
        self.modelChoice = modelChoice
        self.effortLevel = effortLevel
        self.sessionKey = sessionKey
        self.sessionStore = sessionStore
    }

    /// The same identifier as the one-off subscription provider, so the usage
    /// log files these turns as subscription turns ("included in subscription").
    var identifier: String { "claude-subscription/\(modelChoice.apiModelIdentifier)" }

    private var userFacingName: String { "Claude Code (your subscription)" }

    var capabilities: ModelCapabilities {
        ModelCapabilities(
            supportsVision: true,
            supportsTools: true,
            supportsNativeToolCalls: false,
            supportsStreaming: true,
            supportsStructuredOutput: false,
            contextWindowTokens: 200_000
        )
    }

    var deployment: ModelDeployment {
        ModelDeployment(location: .remote(serviceName: "Anthropic (via a Claude Code session)"))
    }

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

        let systemPrompt = await ClaudeSubscriptionProvider.systemPromptIncludingTools(for: request)
        let workspaceURL = BuddyWorkspace.preparedFolderURL(forBuddyWithID: sessionKey.buddyID)

        // How often this conversation has been started over before, carried
        // to the replacement session's record.
        var restartCount: Int?

        if let existingRecord = sessionStore.record(for: sessionKey) {
            let newMessages = BuddySessionPolicy.messagesNotYetInSession(request.messages)
            if BuddySessionPolicy.shouldStartOverBeforeResuming(existingRecord) {
                print("🧵 Buddy session \(existingRecord.sessionID) is nearly full; starting over with the recent history")
                restartCount = (existingRecord.restartCount ?? 0) + 1
            } else if newMessages.contains(where: { $0.role == .user }) {
                // (Nothing new for the session shouldn't happen; if it does,
                // everything is resent in a new session below rather than an
                // empty message.)
                let resumeRequest = ModelRequest(
                    systemPrompt: request.systemPrompt,
                    messages: newMessages,
                    tools: request.tools,
                    maxOutputTokens: request.maxOutputTokens,
                    temperature: request.temperature
                )
                let processResult = try await runOnce(
                    executablePath: executablePath,
                    systemPrompt: systemPrompt,
                    session: .resume(existingRecord.sessionID),
                    workspaceURL: workspaceURL,
                    inputLine: try ClaudeSubscriptionProvider.userMessageInputLine(for: resumeRequest),
                    onTextDelta: onTextDelta
                )
                let failed = processResult.outcome.isError || processResult.exitStatus != 0
                let failureText = (processResult.outcome.finalResultText ?? "") + "\n" + processResult.standardErrorText
                if failed && BuddySessionPolicy.isMissingSessionFailure(failureText) {
                    print("🧵 Buddy session \(existingRecord.sessionID) is gone; starting a new one with the history")
                    restartCount = existingRecord.restartCount
                } else if failed && BuddySessionPolicy.isContextOverflowFailure(failureText) {
                    print("🧵 Buddy session \(existingRecord.sessionID) overflowed; starting over with the recent history")
                    restartCount = (existingRecord.restartCount ?? 0) + 1
                } else {
                    let turn = try turn(from: processResult, request: request)
                    noteAnsweredCall(sessionID: existingRecord.sessionID, processResult: processResult)
                    return turn
                }
            } else {
                restartCount = existingRecord.restartCount
            }
            sessionStore.forgetSession(for: sessionKey)
        }

        // A new session gets the conversation so far as its handoff: the
        // thread's recent exchanges and everything of this run.
        let newSessionID = UUID()
        let processResult = try await runOnce(
            executablePath: executablePath,
            systemPrompt: systemPrompt,
            session: .start(newSessionID),
            workspaceURL: workspaceURL,
            inputLine: try ClaudeSubscriptionProvider.userMessageInputLine(for: request),
            onTextDelta: onTextDelta
        )
        let turn = try turn(from: processResult, request: request)
        noteAnsweredCall(sessionID: newSessionID, processResult: processResult, restartCount: restartCount)
        return turn
    }

    private func noteAnsweredCall(
        sessionID: UUID,
        processResult: ClaudeSubscriptionProvider.ProcessResult,
        restartCount: Int? = nil
    ) {
        sessionStore.noteAnsweredCall(
            in: sessionKey,
            sessionID: sessionID,
            contextTokens: processResult.outcome.promptTokens,
            contextWindowTokens: processResult.outcome.contextWindowTokens,
            restartCount: restartCount
        )
    }

    private func runOnce(
        executablePath: String,
        systemPrompt: String,
        session: ClaudeSubscriptionProvider.CLISession,
        workspaceURL: URL,
        inputLine: Data,
        onTextDelta: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> ClaudeSubscriptionProvider.ProcessResult {
        try await ClaudeSubscriptionProvider.runCLI(
            executablePath: executablePath,
            arguments: ClaudeSubscriptionProvider.commandLineArguments(
                systemPrompt: systemPrompt,
                modelChoice: modelChoice,
                effortLevel: effortLevel,
                session: session
            ),
            workingDirectory: workspaceURL,
            inputLine: inputLine,
            providerName: userFacingName,
            onTextDelta: onTextDelta
        )
    }

    private func turn(
        from processResult: ClaudeSubscriptionProvider.ProcessResult,
        request: ModelRequest
    ) throws -> BuddyChatTurn {
        try ClaudeSubscriptionProvider.turn(
            from: processResult.outcome,
            standardErrorText: processResult.standardErrorText,
            exitStatus: processResult.exitStatus,
            duration: processResult.duration,
            knownToolNames: Set(request.tools.map(\.name)),
            exampleToolName: request.tools.first?.name,
            providerName: userFacingName
        )
    }
}
