//
//  CodingAgentHookEvent.swift
//  leanring-buddy
//
//  The pure side of coding-agent monitoring: one hook payload (the JSON Claude
//  Code, Gemini CLI or Antigravity hands its hook, forwarded to Wisp by the
//  relay script) turned into a typed event. No sockets, no state — so the
//  whole vocabulary is testable on its own.
//
//  Ported from Coucou (github.com/louis-cfm/coucou, MIT) — its HookServer and
//  nb-hook relay — and reworked for Wisp: sessions are kept per session id
//  rather than per agent, every terminal is accepted (Coucou only listened to
//  VS Code), and step labels are English.
//

import Foundation

/// Which coding agent a hook event came from. The relay tags Gemini CLI and
/// Antigravity events with `wisp_agent`; an event without a tag is Claude Code,
/// which is the agent whose hooks call the relay with no `--agent` argument.
nonisolated enum CodingAgentKind: Hashable, Sendable {
    case claudeCode
    case geminiCLI
    case antigravity
    /// Any other tool that talks to the socket and names itself.
    case other(name: String)

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .geminiCLI: return "Gemini CLI"
        case .antigravity: return "Antigravity"
        case .other(let name): return name
        }
    }

    /// Only Claude Code's permission hook can be answered: it waits for a
    /// decision and understands the reply. Other agents ask in their terminal.
    var supportsNotchApprovals: Bool {
        self == .claudeCode
    }

    /// Reads the agent from the relay's `wisp_agent` tag (also accepting
    /// Coucou's `coucou_agent`, so a relay copied from there keeps working).
    /// The name must be 1–24 lowercase letters, digits or hyphens; anything
    /// else — including a claim to be "claude" — is treated as Claude Code,
    /// so a malformed tag can't invent a label.
    static func from(agentTag rawAgentTag: String?) -> CodingAgentKind {
        guard let rawAgentTag, isValidAgentTag(rawAgentTag) else { return .claudeCode }
        switch rawAgentTag {
        case "gemini": return .geminiCLI
        case "antigravity": return .antigravity
        default: return .other(name: rawAgentTag)
        }
    }

    static func isValidAgentTag(_ agentTag: String) -> Bool {
        guard !agentTag.isEmpty, agentTag.count <= 24, agentTag != "claude" else { return false }
        return agentTag.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-"
        }
    }
}

/// Where the agent is running, so "Jump to terminal" can bring back the exact
/// window. Filled by the relay from the hook process's environment.
nonisolated struct CodingAgentTerminalContext: Equatable, Sendable {
    /// `TERM_PROGRAM`: "Apple_Terminal", "iTerm.app", "vscode", "ghostty", "WezTerm"…
    var terminalProgram: String
    /// `__CFBundleIdentifier` of the app the terminal lives in, when set —
    /// the only way to tell Cursor from VS Code (both say "vscode").
    var hostApplicationBundleIdentifier: String
    /// `ITERM_SESSION_ID`, e.g. "w0t1p0:6E1F…". The part after the colon is the
    /// session's unique id in iTerm's AppleScript dictionary.
    var iTermSessionIdentifier: String
    /// The controlling terminal device, e.g. "/dev/ttys004" — how Terminal.app
    /// names a tab in AppleScript. Empty when the relay couldn't read it.
    var terminalDevicePath: String

    static let unknown = CodingAgentTerminalContext(
        terminalProgram: "",
        hostApplicationBundleIdentifier: "",
        iTermSessionIdentifier: "",
        terminalDevicePath: ""
    )
}

/// What happened, in the agent's lifecycle.
nonisolated enum CodingAgentHookEventKind: Equatable, Sendable {
    case sessionStarted
    case promptSubmitted(promptText: String)
    case toolStarting(stepDescription: String)
    case toolFinished
    case toolFailed
    /// A notification the agent raised. Claude Code sends one when it is idle
    /// waiting for input, when it needs permission, and on rate limits.
    case notification(message: String, category: CodingAgentNotificationCategory)
    case stopped(finalMessage: String)
    case stoppedWithFailure
    case sessionEnded
    case subagentStarted
    case subagentStopped
    /// Claude Code wants permission to run a tool and is waiting for an answer.
    case permissionRequested(CodingAgentPermissionRequestDetails)
    /// An event name Wisp doesn't track; carried so the session still counts as alive.
    case unrecognized(eventName: String)
}

nonisolated enum CodingAgentNotificationCategory: Equatable, Sendable {
    case rateLimited
    case waitingForInput
    case informational
}

/// What a permission request is asking for, in a form the notch card can show.
nonisolated struct CodingAgentPermissionRequestDetails: Equatable, Sendable {
    let toolName: String
    /// One line naming what will happen: the shell command, the file, the URL.
    let actionSummary: String
    /// Claude Code offers "always allow" rules alongside some requests; when it
    /// does, the card shows "Always" and the relay passes them back.
    let offersAlwaysAllow: Bool
}

/// One parsed hook event.
nonisolated struct CodingAgentHookEvent: Equatable, Sendable {
    let agentKind: CodingAgentKind
    let sessionIdentifier: String
    /// The agent's working directory — the project.
    let workingDirectoryPath: String
    let terminalContext: CodingAgentTerminalContext
    let kind: CodingAgentHookEventKind

    /// The project's folder name, or "Session" when the agent sent no directory.
    var projectName: String {
        let folderName = URL(fileURLWithPath: workingDirectoryPath).lastPathComponent
        return folderName.isEmpty || workingDirectoryPath.isEmpty ? "Session" : folderName
    }
}

/// Turns a hook payload into a `CodingAgentHookEvent`.
nonisolated enum CodingAgentHookEventParser {
    /// Steps and prompts longer than this are cut — the notch has one line for them.
    static let maximumStepTextLength = 80

    static func parse(payload: [String: Any]) -> CodingAgentHookEvent {
        let agentTag = (payload["wisp_agent"] as? String) ?? (payload["coucou_agent"] as? String)
        let terminalContext = CodingAgentTerminalContext(
            terminalProgram: payload["term_program"] as? String ?? "",
            hostApplicationBundleIdentifier: payload["bundle_id"] as? String ?? "",
            iTermSessionIdentifier: payload["iterm_session_id"] as? String ?? "",
            terminalDevicePath: payload["tty"] as? String ?? ""
        )
        let eventName = payload["hook_event_name"] as? String ?? ""
        let toolName = payload["tool_name"] as? String ?? "Tool"
        let toolInput = payload["tool_input"] as? [String: Any] ?? [:]

        let eventKind: CodingAgentHookEventKind
        switch eventName {
        case "SessionStart":
            eventKind = .sessionStarted
        case "UserPromptSubmit":
            eventKind = .promptSubmitted(promptText: clipped(payload["prompt"] as? String ?? ""))
        case "PreToolUse":
            eventKind = .toolStarting(stepDescription: stepDescription(toolName: toolName, toolInput: toolInput))
        case "PostToolUse":
            eventKind = .toolFinished
        case "PostToolUseFailure":
            eventKind = .toolFailed
        case "Notification":
            let message = payload["message"] as? String ?? ""
            eventKind = .notification(message: clipped(message), category: notificationCategory(for: message))
        case "Stop":
            eventKind = .stopped(finalMessage: clipped(payload["message"] as? String ?? ""))
        case "StopFailure":
            eventKind = .stoppedWithFailure
        case "SessionEnd":
            eventKind = .sessionEnded
        case "SubagentStart":
            eventKind = .subagentStarted
        case "SubagentStop":
            eventKind = .subagentStopped
        case "PermissionRequest":
            let permissionSuggestions = payload["permission_suggestions"] as? [Any] ?? []
            eventKind = .permissionRequested(CodingAgentPermissionRequestDetails(
                toolName: toolName,
                actionSummary: permissionActionSummary(toolName: toolName, toolInput: toolInput),
                offersAlwaysAllow: !permissionSuggestions.isEmpty
            ))
        default:
            eventKind = .unrecognized(eventName: eventName)
        }

        return CodingAgentHookEvent(
            agentKind: CodingAgentKind.from(agentTag: agentTag),
            sessionIdentifier: (payload["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown",
            workingDirectoryPath: payload["cwd"] as? String ?? "",
            terminalContext: terminalContext,
            kind: eventKind
        )
    }

    /// Claude Code's own notification wording decides the category: rate
    /// limits are worth flagging, "waiting for your input" means the session
    /// is idle on the user, anything else is just shown.
    static func notificationCategory(for message: String) -> CodingAgentNotificationCategory {
        let lowercasedMessage = message.lowercased()
        if lowercasedMessage.contains("rate limit") || lowercasedMessage.contains("usage limit") {
            return .rateLimited
        }
        if lowercasedMessage.contains("waiting for your input")
            || lowercasedMessage.contains("needs your")
            || message.hasSuffix("?") {
            return .waitingForInput
        }
        return .informational
    }

    /// "Running · npm test", "Editing · CompanionManager.swift" — what the
    /// agent is doing, for the session's step list.
    static func stepDescription(toolName: String, toolInput: [String: Any]) -> String {
        let verbByToolName: [String: String] = [
            "Bash": "Running",
            "Read": "Reading",
            "Write": "Writing",
            "Edit": "Editing",
            "MultiEdit": "Editing",
            "NotebookEdit": "Editing notebook",
            "Glob": "Finding files",
            "Grep": "Searching",
            "LS": "Listing",
            "WebSearch": "Searching the web",
            "WebFetch": "Fetching",
            "TodoWrite": "Updating todos",
            "Task": "Starting a subagent",
            "Agent": "Starting a subagent",
            // Gemini CLI's tool names, as its hooks report them.
            "run_shell_command": "Running",
            "read_file": "Reading",
            "write_file": "Writing",
            "replace": "Editing",
            "glob": "Finding files",
            "search_file_content": "Searching",
            "google_web_search": "Searching the web",
            "web_fetch": "Fetching",
        ]
        let verb = verbByToolName[toolName] ?? toolName
        guard let target = primaryTarget(of: toolInput) else { return verb }
        return clipped("\(verb) · \(target)")
    }

    /// The single most telling argument of a tool call: its command, the file
    /// it touches (just the file name), the URL or the search.
    static func primaryTarget(of toolInput: [String: Any]) -> String? {
        if let command = toolInput["command"] as? String, !command.isEmpty {
            return command
        }
        for pathKey in ["file_path", "path", "notebook_path"] {
            if let path = toolInput[pathKey] as? String, !path.isEmpty {
                return URL(fileURLWithPath: path).lastPathComponent
            }
        }
        if let url = toolInput["url"] as? String, !url.isEmpty {
            return URL(string: url)?.host ?? url
        }
        for searchKey in ["query", "pattern", "description"] {
            if let searchText = toolInput[searchKey] as? String, !searchText.isEmpty {
                return searchText
            }
        }
        return nil
    }

    /// What a permission card names. For a shell command the whole command is
    /// the point, so it isn't shortened to a verb; for a file, its full path.
    static func permissionActionSummary(toolName: String, toolInput: [String: Any]) -> String {
        if let command = toolInput["command"] as? String, !command.isEmpty {
            return String(command.prefix(400))
        }
        for pathKey in ["file_path", "path", "notebook_path"] {
            if let path = toolInput[pathKey] as? String, !path.isEmpty {
                return "\(toolName) \(path)"
            }
        }
        if let url = toolInput["url"] as? String, !url.isEmpty {
            return "\(toolName) \(url)"
        }
        return stepDescription(toolName: toolName, toolInput: toolInput)
    }

    private static func clipped(_ text: String) -> String {
        let singleLineText = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLineText.count > maximumStepTextLength else { return singleLineText }
        return String(singleLineText.prefix(maximumStepTextLength - 1)) + "…"
    }
}
