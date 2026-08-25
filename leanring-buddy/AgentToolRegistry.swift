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

    private init() {
        registerBuiltInTools()
    }

    /// The tools to actually show the model for this request.
    ///
    /// Registered and exposed are separate concerns: everything registered is
    /// callable, but only what is exposed appears in the prompt and therefore
    /// costs tokens and competes for the model's attention.
    func definitions(forRequest transcript: String) -> [BuddyToolDefinition] {
        let scope = AgentToolScope.forRequest(transcript)
        let scoped = definitions
            .filter { scope.includes(toolNamed: $0.name) }
            .sorted { $0.name < $1.name }

        if scoped.isEmpty { return definitions }
        return Array(scoped.prefix(AgentToolScope.maximumExposedTools))
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

    /// Runs a tool by name.
    ///
    /// An unknown name is a normal outcome, not an exception: models
    /// occasionally invent tools, and the useful response is to tell the model
    /// so it can correct itself on the next turn.
    func invoke(name: String, input: JSONValue) async -> (content: String, isError: Bool) {
        guard let tool = toolsByName[name] else {
            let available = toolNames.sorted().joined(separator: ", ")
            return ("there is no tool called \"\(name)\". available tools: \(available)", true)
        }

        do {
            let result = try await tool.implementation(input)
            return (result, false)
        } catch {
            return (error.localizedDescription, true)
        }
    }

    // MARK: - Built-in tools

    /// The browser, driven through the DOM rather than the vision model.
    private let browserController = AppleScriptBrowserController()

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
                name: "read_page",
                description: "Read the current browser page as text, including every clickable element with an id. Use this instead of looking at the screen whenever the question is about a web page.",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
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

            let configuredPath = AppBundleConfiguration.stringValue(forKey: "CodeProjectDirectory")
                ?? "~/Downloads/clicky"
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

    private func registerBuiltInTools() {
        registerBrowserTools()
        registerClaudeCodeTool()
        register(
            BuddyToolDefinition(
                name: "read_clipboard",
                description: "Read what is currently on the user's clipboard. Use when the user refers to something they copied.",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
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
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
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
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
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
