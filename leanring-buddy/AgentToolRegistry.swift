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

    private func registerBuiltInTools() {
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
