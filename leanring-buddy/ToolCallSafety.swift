//
//  ToolCallSafety.swift
//  leanring-buddy
//
//  The destructive-action floor under session auto-approve.
//
//  Session auto-approve exists so a long agent task does not stop to ask about
//  every read and every small, recoverable write. It was never meant as consent
//  to speak in the user's name, spend their money, or destroy their data — and
//  once MCP servers and Composio toolkits are installed, the agent can do all
//  three. So a small set of tool calls always goes to the confirmation card,
//  even with auto-approve on: sending, posting, deleting, paying, sharing,
//  inviting, running arbitrary commands, and writing files outside the agent's
//  working folder.
//
//  Modeled on `BrowserActionSafety`: deterministic word matching on the tool's
//  name plus a look at a few argument shapes, with no model involved. It errs
//  towards asking. A false positive costs one tap or one "yes"; a false
//  negative is an email the user never approved.
//

import Foundation

enum ToolCallSafety {

    // MARK: - Vocabulary

    /// Verbs that commit something the user cannot take back, wherever they
    /// appear in a tool's name — `GMAIL_SEND_EMAIL`, `delete_file`,
    /// `stripe_create_refund`, `github_merge_pull_request`.
    static let alwaysIrreversibleWords: Set<String> = [
        "send", "forward", "reply", "tweet", "retweet", "publish",
        "delete", "remove", "trash", "purge", "destroy", "erase", "wipe",
        "unlink", "rm", "rmdir", "permanent", "permanently",
        "pay", "payment", "purchase", "buy", "checkout", "transfer", "refund",
        "withdraw", "deposit", "donate", "charge",
        "invite", "merge", "deploy", "unsubscribe", "cancel", "revoke", "terminate",
    ]

    /// Words that are irreversible as a verb but just as often a noun in a
    /// read-only tool — `create_post` publishes, `get_post` reads. These count
    /// only when the name carries no reading verb.
    static let irreversibleUnlessReadingWords: Set<String> = [
        "post", "comment", "order", "share", "submit", "book", "reserve", "subscribe",
    ]

    /// Verbs that mark a tool as observing rather than acting.
    static let readingWords: Set<String> = [
        "get", "list", "search", "read", "fetch", "find", "query", "view", "show",
        "describe", "lookup", "check", "count", "preview", "retrieve", "inspect", "peek",
    ]

    /// Tools that run arbitrary commands or code. What they do cannot be judged
    /// from their name, so they are treated as able to do anything.
    private static let arbitraryExecutionWords: Set<String> = [
        "shell", "bash", "zsh", "terminal", "applescript", "osascript",
    ]
    private static let executionVerbWords: Set<String> = ["run", "execute", "exec", "eval"]
    private static let executionObjectWords: Set<String> = ["command", "commands", "script", "code", "shortcut", "shortcuts"]

    /// Tools that always ask, by bare name, whatever their arguments say.
    ///
    /// `run_shortcut` runs one of the user's Apple Shortcuts, and what a
    /// shortcut does cannot be told from its name or its input — "Morning
    /// Routine" may only read the weather or may text half the user's
    /// contacts. Listed by name so the guarantee does not depend on word
    /// matching (though "run" + "shortcut" would also catch it).
    static let alwaysAskBareToolNames: Set<String> = ["run_shortcut"]

    /// Verbs that write to the file system. Deletion is already in
    /// `alwaysIrreversibleWords`, so these are the recoverable-inside-the-agent-
    /// folder writes whose safety depends on *where* they land.
    private static let fileWritingWords: Set<String> = [
        "write", "edit", "create", "move", "rename", "overwrite", "save", "append",
        "put", "update", "copy", "replace", "patch", "modify", "mkdir", "touch", "upload",
    ]

    private static let calendarWords: Set<String> = ["event", "events", "meeting", "calendar"]

    /// Composio gateway meta-tools that only look things up or manage the
    /// user's own connections. Every other Composio meta-tool either executes
    /// app tools (unwrapped and judged below) or runs code remotely, and the
    /// latter is always asked about.
    private static let benignComposioMetaWords: Set<String> = [
        "search", "get", "schemas", "wait", "connections", "feedback", "list",
    ]

    // MARK: - The floor

    /// Whether this call must be confirmed even while session auto-approve is on.
    ///
    /// - Parameter agentWorkingDirectoryPath: The folder file writes are allowed
    ///   to land in without asking. Writes anywhere else still ask.
    static func mustAskEvenWithSessionAutoApprove(
        toolName: String,
        toolInput: JSONValue,
        agentWorkingDirectoryPath: String
    ) -> Bool {
        let bareName = ToolCallInspection.bareToolName(toolName)

        if alwaysAskBareToolNames.contains(bareName) { return true }

        if ToolCallInspection.isComposioMetaTool(bareToolName: bareName) {
            if ToolCallInspection.isComposioExecuteMetaTool(bareToolName: bareName) {
                // A wrapper whose contents cannot be read cannot be shown to be
                // safe, so it asks.
                guard let executedActions = ToolCallInspection.composioExecutedActions(in: toolInput) else {
                    return true
                }
                return executedActions.contains { executedAction in
                    isIrreversible(action: executedAction, agentWorkingDirectoryPath: agentWorkingDirectoryPath)
                }
            }
            let metaToolWords = Set(ToolCallInspection.words(inIdentifier: bareName)).subtracting(["composio", "tool", "tools"])
            // Remote bash, the workbench, running a skill — anything that is not
            // a known lookup — asks.
            return metaToolWords.isDisjoint(with: benignComposioMetaWords)
        }

        let inspectedActions = ToolCallInspection.inspectedActions(toolName: toolName, toolInput: toolInput)
        return inspectedActions.contains { inspectedAction in
            isIrreversible(action: inspectedAction, agentWorkingDirectoryPath: agentWorkingDirectoryPath)
        }
    }

    /// Whether one concrete action is irreversible or outward-facing.
    static func isIrreversible(action: InspectedToolAction, agentWorkingDirectoryPath: String) -> Bool {
        let actionNameWords = Set(action.actionNameWords)

        if namesIrreversibleAction(actionNameWords: actionNameWords) { return true }
        if runsArbitraryCommands(actionNameWords: actionNameWords) { return true }
        if sendsCalendarInvitations(actionNameWords: actionNameWords, arguments: action.arguments) { return true }
        if writesFilesOutsideDirectory(
            actionNameWords: actionNameWords,
            arguments: action.arguments,
            agentWorkingDirectoryPath: agentWorkingDirectoryPath
        ) {
            return true
        }
        return false
    }

    /// The name alone says the action commits something: an always-irreversible
    /// verb, or an irreversible-unless-reading word with no reading verb.
    static func namesIrreversibleAction(actionNameWords: Set<String>) -> Bool {
        if !actionNameWords.isDisjoint(with: alwaysIrreversibleWords) { return true }
        let isReading = !actionNameWords.isDisjoint(with: readingWords)
        if !isReading && !actionNameWords.isDisjoint(with: irreversibleUnlessReadingWords) { return true }
        return false
    }

    /// Whether the name reads as a reading tool (`get_…`, `list_…`, `search_…`).
    static func namesReadingAction(actionNameWords: Set<String>) -> Bool {
        !actionNameWords.isDisjoint(with: readingWords)
    }

    private static func runsArbitraryCommands(actionNameWords: Set<String>) -> Bool {
        if !actionNameWords.isDisjoint(with: arbitraryExecutionWords) { return true }
        // A tool named only by the verb — `exec`, `run`, `eval` — runs whatever
        // it is handed.
        if !actionNameWords.isEmpty && actionNameWords.isSubset(of: executionVerbWords) { return true }
        return !actionNameWords.isDisjoint(with: executionVerbWords)
            && !actionNameWords.isDisjoint(with: executionObjectWords)
    }

    /// Creating or updating a calendar event that has guests emails every one
    /// of them an invitation, which is speaking in the user's name.
    private static func sendsCalendarInvitations(actionNameWords: Set<String>, arguments: JSONValue) -> Bool {
        guard !actionNameWords.isDisjoint(with: calendarWords),
              !namesReadingAction(actionNameWords: actionNameWords) else { return false }
        return ToolCallInspection.stringValue(
            forAnyOf: ["attendees", "invitees", "guests", "participants"],
            in: arguments
        ) != nil
    }

    /// A file write whose path lands outside the agent's working folder.
    ///
    /// Inside that folder a write is the kind of recoverable change auto-approve
    /// is for. Outside it the agent could be overwriting anything the user owns,
    /// and whether the file already exists cannot be told without touching the
    /// disk — so every write out there is treated as a possible overwrite.
    private static func writesFilesOutsideDirectory(
        actionNameWords: Set<String>,
        arguments: JSONValue,
        agentWorkingDirectoryPath: String
    ) -> Bool {
        guard !actionNameWords.isDisjoint(with: fileWritingWords) else { return false }
        let pathArgumentValues = ToolCallInspection.pathLikeArgumentValues(in: arguments)
        return pathArgumentValues.contains { pathArgumentValue in
            !ToolCallInspection.isPath(pathArgumentValue, insideDirectory: agentWorkingDirectoryPath)
        }
    }
}
