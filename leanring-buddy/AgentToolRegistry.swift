//
//  AgentToolRegistry.swift
//  leanring-buddy
//
//  The tools the assistant can run, and the dispatch that runs them.
//
//  Everything here is read-only by design. A local model that occasionally
//  invents a tool call — which measurement showed this one does — must not be
//  able to change anything as a result. Tools that alter state can be added
//  later behind the `requiresConfirmation` flag and a spoken confirmation
//  step, but nothing ships that way until that flow exists.
//
//  The set is also deliberately small. A model of this size picks the right
//  tool far less reliably once there are more than a handful to choose from,
//  and every tool description shares a context window with a screenshot that
//  costs seconds to encode, so each addition has a real price.
//

import AppKit
import Combine
import Foundation

@MainActor
final class AgentToolRegistry: ObservableObject {
    /// The app's own name, read from the bundle rather than hardcoded, so
    /// window listings keep excluding our own windows across any future rename.
    private static let ownAppName: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        ?? "Wisp"

    static let shared = AgentToolRegistry()

    /// A tool's implementation. Returns the text handed back to the model, so
    /// results should read like something a person would say — small models
    /// follow plain language far more reliably than a JSON envelope.
    typealias ToolImplementation = @MainActor (JSONValue) async throws -> String

    private struct RegisteredTool {
        let definition: BuddyToolDefinition
        let implementation: ToolImplementation
    }

    @Published private var toolsByName: [String: RegisteredTool] = [:]

    /// Who is asked before a tool that changes anything runs.
    ///
    /// Injectable so the boundary can be tested without speech or a user, and
    /// so a test proving that denial blocks execution is possible at all.
    private var permissionBroker: ToolPermissionBroker = ToolConfirmationCoordinator.shared

    /// Replaces the broker. Tests only.
    func setPermissionBroker(_ broker: ToolPermissionBroker) {
        permissionBroker = broker
    }

    private init(registeringBuiltInTools: Bool = true) {
        if registeringBuiltInTools { registerBuiltInTools() }
    }

    /// A registry with nothing registered, so a test can install its own tool
    /// and observe which instance actually ran it.
    ///
    /// Needed because the runner takes an injected registry but used to
    /// execute against the singleton regardless; proving that is fixed
    /// requires two distinguishable registries. Matches the `...ForTesting`
    /// convention already used by `AgentTurnRunner`.
    static func makeEmptyForTesting() -> AgentToolRegistry {
        AgentToolRegistry(registeringBuiltInTools: false)
    }

    /// The tools to actually show the model for this request.
    ///
    /// Registered and exposed are separate concerns: everything registered is
    /// callable, but only what is exposed appears in the prompt and therefore
    /// costs tokens and competes for the model's attention.
    func definitions(forRequest transcript: String) -> [BuddyToolDefinition] {
        // Apple Shortcuts are matched by name against the cached list — never
        // a fresh process spawn on the turn's critical path; a stale cache is
        // refreshed in the background for the next turn instead. See
        // `ShortcutsToolRouting` for why only matching names reach the prompt.
        ShortcutsBridge.shared.refreshInBackgroundIfStale()
        let shortcutsRoutingHints = ShortcutsToolRouting.routingHints(
            forRequest: transcript,
            knownShortcutNames: ShortcutsBridge.shared.cachedShortcutNames
        )
        let selectedDefinitions = AgentToolRouter.select(
            from: definitions,
            for: transcript,
            limit: AgentToolScope.maximumExposedTools,
            boostedToolNames: shortcutsRoutingHints.boostedToolNames
        )
        return ShortcutsToolRouting.applyingMatchingShortcutNames(
            shortcutsRoutingHints.matchingShortcutNames,
            to: selectedDefinitions
        )
    }

    var definitions: [BuddyToolDefinition] {
        toolsByName.values.map(\.definition).sorted { $0.name < $1.name }
    }

    var toolNames: Set<String> {
        Set(toolsByName.keys)
    }

    /// Whether this tool must be approved before it runs.
    ///
    /// An unknown name answers true. That case means the model asked for
    /// something that doesn't exist, and the safe reading of an unrecognised
    /// request is that it might do something.
    func requiresConfirmation(forToolNamed name: String) -> Bool {
        toolsByName[name]?.definition.requiresConfirmation ?? true
    }

    func register(_ definition: BuddyToolDefinition, implementation: @escaping ToolImplementation) {
        toolsByName[definition.name] = RegisteredTool(definition: definition, implementation: implementation)
    }

    /// Removes a previously registered tool, if present.
    ///
    /// Needed so a server that is disabled or uninstalled from the marketplace
    /// stops offering its tools without restarting the app — and so reconnecting
    /// a server doesn't leave a stale copy of every tool behind.
    func unregister(toolNamed name: String) {
        toolsByName.removeValue(forKey: name)
    }

    /// What happened when a tool was asked to run.
    ///
    /// Declining is not an error. The model asked for something reasonable and
    /// the user said no, and the turn should continue with that as an ordinary
    /// result rather than ending in a failure the user then has to interpret.
    struct Outcome: Sendable {
        let content: String
        let isError: Bool
        let wasDeclined: Bool
    }

    /// Runs a tool by name, asking permission first when the tool needs it.
    ///
    /// **This is the only path to a tool's implementation.** The check lives
    /// here rather than in the caller because callers multiply: an agent turn
    /// today, a cloud runtime, a Job, a Skill tomorrow. A boundary enforced by
    /// every caller remembering to enforce it is not a boundary — it is a
    /// convention, and the first caller that forgets is a model executing
    /// something nobody approved.
    ///
    /// An unknown name is a normal outcome, not an exception: models
    /// occasionally invent tools, and the useful response is to tell the model
    /// so it can correct itself on the next turn.
    func invoke(name: String, input: JSONValue) async -> Outcome {
        guard let tool = toolsByName[name] else {
            let available = toolNames.sorted().joined(separator: ", ")
            return Outcome(
                content: "there is no tool called \"\(name)\". available tools: \(available)",
                isError: true, wasDeclined: false
            )
        }

        if tool.definition.metadata.requiresConfirmation {
            let decision = await permissionBroker.requestApproval(
                toolName: name,
                toolInput: input
            )
            guard decision.isApproved else {
                let reason: String
                if case .declined(let declineReason) = decision { reason = declineReason }
                else { reason = "not approved" }
                return Outcome(
                    content: "the user did not approve this (\(reason)). tell them briefly and don't try it again.",
                    isError: false, wasDeclined: true
                )
            }
        }

        do {
            let result = try await tool.implementation(input)
            return Outcome(content: result, isError: false, wasDeclined: false)
        } catch {
            return Outcome(content: error.localizedDescription, isError: true, wasDeclined: false)
        }
    }

    // MARK: - Built-in tools

    /// The browser, driven through the DOM rather than the vision model.
    /// Internal so CompanionManager's direct browser-command route drives the
    /// same controller — and so the same dedicated tab — as `browser_task`.
    let browserController = AppleScriptBrowserController()

    /// Flies the on-screen cursor to elements the tier-2 browser loop acts on,
    /// so the user watches the work. Set by CompanionManager at startup; weak so
    /// the registry singleton never keeps the manager alive.
    weak var browserCursorGuide: BrowserCursorGuide?

    /// Registers the deterministic browser tools.
    ///
    /// Kept out of the model's way as much as possible: reading a page returns
    /// element ids, and acting takes an id, so the model never reasons about
    /// pixel positions and never needs a screenshot to browse. Measured here, a
    /// trimmed page snapshot costs about 300 prompt tokens against 1097 for a
    /// screenshot of the same page — and 1.1s of prompt evaluation against 6.3s.
    private func registerBrowserTools() {
        register(
            BuddyToolDefinition(
                name: "browser_task",
                description: "Operate the user's web browser to complete a whole task — research, compare, find and read something, fill in a form, work through a site across many pages — then report back. Hand over the complete goal in one call with every detail the user gave (names, dates, quantities, preferences); it works autonomously and asks the user itself before buying, sending or deleting anything. Prefer this over open_url plus read_page for anything that takes more than one step.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["request": .object([
                        "type": .string("string"),
                        "description": .string("The whole task in plain words, with every detail needed, e.g. \"find the cheapest direct flight from SFO to JFK on Oct 12 on google flights and tell me the airline and price\"")
                    ])]),
                    "required": .array([.string("request")])
                ]),
                // Drives the user's real browser and can navigate anywhere.
                metadata: ToolMetadata(readOnly: false, externalSideEffect: true, dataSource: .network)
            )
        ) { [weak self] input in
            guard let self,
                  case .object(let arguments) = input,
                  case .string(let request)? = arguments["request"] else { return "i need to know what to do." }

            // BrowserAgent tries the deterministic planner first and only falls
            // back to a planning call when the request is not recognised.
            // The selected provider decides the strategy: a cloud model drives
            // the long observe-act loop, the local model keeps its plan-once
            // tiers. Either way the local model is still what the tiers use.
            let cursorGuide = self.browserCursorGuide
            let outcome = await BrowserAgent.run(
                request: request,
                controller: self.browserController,
                chatClient: BuddyVisionChatClientFactory.makeDefaultProvider(),
                modelProvider: ModelProviderFactory.make(),
                cursorGuide: cursorGuide,
                onStep: { stepText in cursorGuide?.reportBrowserProgress(stepText) }
            )
            cursorGuide?.endCursorGuidance()

            if let authURL = outcome.authenticationRequiredAt {
                return "that page wants you to sign in first (\(authURL)). ask the user to log in in their browser, then try again — never try to get past it."
            }

            return outcome.result.promptRepresentation()
        }

        register(
            BuddyToolDefinition(
                name: "read_page",
                description: "Read the current browser page as text, including every clickable element with an id. Use this instead of looking at the screen whenever the question is about a web page.",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
                metadata: .reading(.network)
            )
        ) { [weak self] _ in
            guard let self else { return "couldn't read the page." }
            do {
                return try self.browserController.snapshot().promptRepresentation()
            } catch {
                return error.localizedDescription
            }
        }

        register(
            BuddyToolDefinition(
                name: "open_url",
                description: "Open a web address in the browser.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["url": .object([
                        "type": .string("string"),
                        "description": .string("A full web address, including https://")
                    ])]),
                    "required": .array([.string("url")])
                ]),
                requiresConfirmation: true
            )
        ) { [weak self] input in
            guard let self,
                  case .object(let arguments) = input,
                  case .string(let text)? = arguments["url"] else { return "i need a web address." }
            let normalized = text.hasPrefix("http") ? text : "https://" + text
            guard let url = URL(string: normalized) else { return "that doesn't look like a web address." }
            try? self.browserController.openURL(url)
            return "opened \(normalized)."
        }

        register(
            BuddyToolDefinition(
                name: "click_element",
                description: "Click an element on the page by the id from read_page, for example e7.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["element_id": .object([
                        "type": .string("string"),
                        "description": .string("An id from read_page, like e3")
                    ])]),
                    "required": .array([.string("element_id")])
                ]),
                requiresConfirmation: true
            )
        ) { [weak self] input in
            guard let self,
                  case .object(let arguments) = input,
                  case .string(let elementID)? = arguments["element_id"] else { return "i need an element id." }
            do {
                try self.browserController.click(elementID: elementID)
                return "clicked \(elementID)."
            } catch {
                return error.localizedDescription
            }
        }
    }

    /// Hands a coding task to the Claude Code CLI, in the background.
    ///
    /// Background because it is slow — measured at 5-7s for even a trivial
    /// task, and minutes for a real one — and Wisp must stay answerable while
    /// it runs. Confirmation because it reads the user's source tree, and
    /// because it is the one tool here that leaves the machine.
    private func registerClaudeCodeTool() {
        register(
            BuddyToolDefinition(
                name: "delegate_coding_task",
                description: "Hand a real programming task — reading a codebase, finding a bug, writing or changing code, running tests — to Claude Code. Slow, runs in the background, reports back when done. Do not use for general questions about programming; answer those yourself.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "task": .object([
                            "type": .string("string"),
                            "description": .string("The task, written so it stands alone without the conversation.")
                        ]),
                        "allow_editing": .object([
                            "type": .string("boolean"),
                            "description": .string("True only if the user asked for files to be changed. Defaults to read-only.")
                        ])
                    ]),
                    "required": .array([.string("task")])
                ]),
                requiresConfirmation: true
            )
        ) { input in
            guard case .object(let arguments) = input,
                  case .string(let task)? = arguments["task"],
                  !task.trimmingCharacters(in: .whitespaces).isEmpty else {
                return "i need to know what the task is."
            }

            var allowEditing = false
            if case .bool(let flag)? = arguments["allow_editing"] { allowEditing = flag }

            let configuredPath = AgentSettingsStore.resolvedWorkingDirectoryPath()
            let directory = URL(fileURLWithPath: (configuredPath as NSString).expandingTildeInPath)

            guard FileManager.default.fileExists(atPath: directory.path) else {
                return "i can't find the project folder at \(directory.path)."
            }

            let taskID = AgentTaskRegistry.shared.beginTask(
                title: "Claude Code: \(task.prefix(60))", kind: .background
            )

            let work = Task { @MainActor in
                do {
                    let outcome = try await ClaudeCodeWorker.run(
                        task: task,
                        workingDirectory: directory,
                        allowEditing: allowEditing,
                        onProgress: { progress in
                            Task { @MainActor in
                                AgentTaskRegistry.shared.appendStep(
                                    AgentStepRecord(kind: .tool(name: "claude-code"), summary: progress.summary),
                                    to: taskID
                                )
                            }
                        }
                    )

                    // A task that "succeeded" having been refused every edit it
                    // wanted is not a success, and the result text usually does
                    // not say so.
                    var finalText = outcome.text
                    if !outcome.permissionDenials.isEmpty {
                        finalText += "\n\n(Blocked from using: \(Set(outcome.permissionDenials).sorted().joined(separator: ", ")))"
                    }

                    AgentTaskRegistry.shared.finishTask(
                        taskID,
                        status: outcome.didSucceed ? .succeeded : .failed(finalText),
                        finalText: finalText
                    )
                } catch {
                    AgentTaskRegistry.shared.finishTask(
                        taskID, status: .failed(error.localizedDescription)
                    )
                }
            }
            AgentTaskRegistry.shared.attachRunningTask(work, to: taskID)

            let mode = allowEditing ? "and can edit files" : "read-only"
            return "started that in the background (\(mode)). i'll let you know when it's done."
        }
    }

    /// Lets the model pull the full body of a user-authored skill into
    /// context by name. Only the name and one-line description ever sit in
    /// the prompt unconditionally — see `SkillIndex` — so this is the one
    /// call that actually spends tokens on a skill's content, and only when
    /// asked for.
    private func registerSkillTools() {
        SkillManager.shared.loadSkills()

        register(
            BuddyToolDefinition(
                name: "load_skill",
                description: "Reads the full instructions for one of your available skills, listed below, by name.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["name": .object([
                        "type": .string("string"),
                        "description": .string("The skill's name, exactly as listed.")
                    ])]),
                    "required": .array([.string("name")])
                ]),
                metadata: .reading(.localMachine)
            )
        ) { input in
            guard case .object(let arguments) = input,
                  case .string(let name)? = arguments["name"] else {
                return "i need to know which skill to load."
            }

            guard let body = SkillManager.shared.body(forSkillNamed: name) else {
                let available = SkillManager.shared.skills.map(\.name).sorted().joined(separator: ", ")
                return available.isEmpty
                    ? "there are no skills installed."
                    : "no skill named \"\(name)\". available skills: \(available)"
            }
            return body
        }
    }

    /// Lets the model add to and remove from the user's memory file,
    /// `~/.wisp/memory.md` (see `MemoryStore`).
    ///
    /// Both ask first. They only touch a local text file, but that file is fed
    /// into every future prompt, so a fact the model invents — or one planted
    /// by a web page it read — would otherwise quietly shape every later
    /// answer. The confirmation card shows the exact fact, which is the
    /// user's chance to catch that.
    private func registerMemoryTools() {
        register(
            BuddyToolDefinition(
                name: "remember",
                description: "Save one lasting fact about the user to their memory, when they ask you to remember something (their name, a preference, a project). One short sentence per call.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["fact": .object([
                        "type": .string("string"),
                        "description": .string("The fact as one short sentence, e.g. \"prefers metric units\"")
                    ])]),
                    "required": .array([.string("fact")])
                ]),
                // A recoverable local write: the user can edit the file back.
                metadata: .writing(.localMachine)
            )
        ) { input in
            guard case .object(let arguments) = input,
                  case .string(let fact)? = arguments["fact"] else {
                return "i need the fact to remember."
            }
            switch try MemoryStore.shared.remember(fact) {
            case .added(let savedFact):
                return "remembered: \(savedFact)"
            case .alreadyKnown(let knownFact):
                return "that's already in memory: \(knownFact)"
            case .nothingToRemember:
                return "there was nothing to remember in that."
            }
        }

        register(
            BuddyToolDefinition(
                name: "forget",
                description: "Remove a fact from the user's memory when they ask you to forget it. Describe it with a few words that appear in the fact.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["fact": .object([
                        "type": .string("string"),
                        "description": .string("Words from the fact to remove, e.g. \"metric units\"")
                    ])]),
                    "required": .array([.string("fact")])
                ]),
                // Deleting a line the user may have written by hand.
                metadata: ToolMetadata(readOnly: false, destructive: true, dataSource: .localMachine)
            )
        ) { input in
            guard case .object(let arguments) = input,
                  case .string(let query)? = arguments["fact"] else {
                return "i need to know which fact to forget."
            }
            switch try MemoryStore.shared.forget(matching: query) {
            case .removed(let removedFacts):
                return "forgot: " + removedFacts.joined(separator: "; ")
            case .nothingMatched:
                return "nothing in memory matches \"\(query)\"."
            case .tooManyMatches(let matchingFacts):
                return "that matches several facts (" + matchingFacts.joined(separator: "; ")
                    + "). ask the user which one they mean."
            }
        }
    }

    /// Lets the model add a reminder to the user's Reminders, on this Mac.
    ///
    /// A write, so its metadata makes it ask first: the confirmation card shows
    /// the exact title/due/list before anything is saved. Local only — EventKit
    /// syncs through the user's own iCloud as Reminders always does, but Wisp
    /// itself sends nothing anywhere.
    private func registerReminderTools() {
        register(
            BuddyToolDefinition(
                name: "create_reminder",
                description: "Add a reminder to the user's Reminders app. Use when the user asks to be reminded of something or to add a to-do.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "title": .object([
                            "type": .string("string"),
                            "description": .string("What to be reminded of, short, e.g. \"call the dentist\"")
                        ]),
                        "due": .object([
                            "type": .string("string"),
                            "description": .string("Optional due date/time in ISO 8601, e.g. \"2026-09-25T15:00\" or \"2026-09-25\" for a whole day. Omit if the user gave no time.")
                        ]),
                        "list": .object([
                            "type": .string("string"),
                            "description": .string("Optional Reminders list name. Omit to use the default list.")
                        ])
                    ]),
                    "required": .array([.string("title")])
                ]),
                metadata: .writing(.localMachine)
            )
        ) { input in
            guard case .object(let arguments) = input,
                  case .string(let rawTitle)? = arguments["title"],
                  !rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "i need a title for the reminder."
            }
            let reminderTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)

            var parsedDueDate: ReminderDueDateParser.ParsedDueDate?
            if case .string(let rawDueDateText)? = arguments["due"],
               !rawDueDateText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // A due date the model wrote but that cannot be read is sent
                // back rather than silently dropped, so the reminder is never
                // saved without the time the user asked for.
                guard let readableDueDate = ReminderDueDateParser.parse(rawDueDateText) else {
                    return "i couldn't read the due date \"\(rawDueDateText)\". use ISO 8601, like 2026-09-25T15:00."
                }
                parsedDueDate = readableDueDate
            }

            var requestedListName: String?
            if case .string(let rawListName)? = arguments["list"],
               !rawListName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                requestedListName = rawListName
            }

            let savedListName = try await RemindersDataProvider.shared.createReminder(
                title: reminderTitle,
                dueDate: parsedDueDate?.date,
                dueDateIncludesTimeOfDay: parsedDueDate?.includesTimeOfDay ?? false,
                listName: requestedListName
            )

            guard let parsedDueDate else {
                return "added \"\(reminderTitle)\" to the \(savedListName) list."
            }
            let dueDateFormatter = DateFormatter()
            dueDateFormatter.dateStyle = .medium
            dueDateFormatter.timeStyle = parsedDueDate.includesTimeOfDay ? .short : .none
            return "added \"\(reminderTitle)\" to the \(savedListName) list, due \(dueDateFormatter.string(from: parsedDueDate.date))."
        }
    }

    private func registerBuiltInTools() {
        registerBrowserTools()
        registerClaudeCodeTool()
        registerSkillTools()
        registerMemoryTools()
        registerReminderTools()
        registerScreenTextTools()
        registerShortcutsTools()
        registerChromeTabTools()
        register(
            BuddyToolDefinition(
                name: "read_clipboard",
                description: "Read what is currently on the user's clipboard. Use when the user refers to something they copied.",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
                metadata: .reading(.localMachine)
            )
        ) { _ in
            guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
                return "the clipboard is empty, or holds something that isn't text."
            }
            // Long clipboards are truncated: the whole result is pushed back
            // into a context window shared with a screenshot.
            let limit = 2000
            return text.count > limit
                ? String(text.prefix(limit)) + "\n…(truncated, \(text.count) characters total)"
                : text
        }

        register(
            BuddyToolDefinition(
                name: "list_windows",
                description: "List the apps and window titles currently open on screen. Use to find out what the user is working in.",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
                metadata: .reading(.localMachine)
            )
        ) { _ in
            let openWindows = Self.listVisibleWindows()
            guard !openWindows.isEmpty else { return "no ordinary windows are open right now." }
            return openWindows.prefix(25).joined(separator: "\n")
        }

        register(
            BuddyToolDefinition(
                name: "get_current_time",
                description: "Get the current date and time. Use for anything time-related, since you cannot otherwise know it.",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
                metadata: .reading(.none)
            )
        ) { _ in
            let formatter = DateFormatter()
            formatter.dateStyle = .full
            formatter.timeStyle = .short
            return formatter.string(from: Date())
        }
    }

    /// Visible, named windows belonging to ordinary apps.
    ///
    /// Filters to layer 0 so menu-bar items, overlays and the desktop don't
    /// crowd out the windows the user is actually looking at — including
    /// Wisp's own full-screen overlay.
    private static func listVisibleWindows() -> [String] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: AnyObject]] else {
            return []
        }

        var seen = Set<String>()
        var described: [String] = []

        for window in windowList {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let owner = window[kCGWindowOwnerName as String] as? String,
                  owner != Self.ownAppName else { continue }

            let title = (window[kCGWindowName as String] as? String) ?? ""
            let line = title.isEmpty ? owner : "\(owner) — \(title)"
            if seen.insert(line).inserted {
                described.append(line)
            }
        }

        return described
    }
}
