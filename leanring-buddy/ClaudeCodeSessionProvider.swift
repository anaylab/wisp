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

        if let existingRecord = sessionStore.record(for: sessionKey) {
            let newMessages = BuddySessionPolicy.messagesNotYetInSession(request.messages)
            // Nothing new for the session (shouldn't happen): resend everything
            // in a new session rather than send it an empty message.
            if newMessages.contains(where: { $0.role == .user }) {
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
                let failureText = (processResult.outcome.finalResultText ?? "") + "\n" + processResult.standardErrorText
                let sessionIsGone = (processResult.outcome.isError || processResult.exitStatus != 0)
                    && BuddySessionPolicy.isMissingSessionFailure(failureText)
                if !sessionIsGone {
                    let turn = try turn(from: processResult, request: request)
                    sessionStore.noteAnsweredCall(in: sessionKey, sessionID: existingRecord.sessionID)
                    return turn
                }
                print("🧵 Buddy session \(existingRecord.sessionID) is gone; starting a new one with the history")
            }
            sessionStore.forgetSession(for: sessionKey)
        }

        // A new session gets the whole conversation so far as its handoff.
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
        sessionStore.noteAnsweredCall(in: sessionKey, sessionID: newSessionID)
        return turn
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
