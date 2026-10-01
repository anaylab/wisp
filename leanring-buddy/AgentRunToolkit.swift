//
//  AgentRunToolkit.swift
//  leanring-buddy
//
//  Per-run changes to which tools an `AgentTurnRunner` offers, without touching
//  the shared `AgentToolRegistry`: tools to hide from this run, and tools that
//  exist only for this run. A buddy uses it to keep a cloud-model run away from
//  the user's brain and memory, and to give each buddy tools bound to its own
//  memory (a global registry entry can't know which buddy is calling).
//

import Foundation

struct AgentRunTool: Sendable {
    let definition: BuddyToolDefinition
    /// Runs the tool. Not confirmation-gated: use it only for effects that are
    /// the run's own and recoverable.
    let run: @MainActor @Sendable (JSONValue) async -> String
}

struct AgentRunToolkit: Sendable {
    /// Registry tools this run may neither see nor call.
    var excludedToolNames: Set<String> = []
    /// When set, a registry tool must also pass this to be seen or called — an
    /// allow-list, checked by name at the moment it matters, so a tool that
    /// registers after the run starts (an MCP server finishing its connect) is
    /// held to it too. Nil allows everything not excluded.
    var permitsRegistryTool: (@Sendable (String) -> Bool)?
    /// Tools offered on every pass of this run, whatever the request says.
    var additionalTools: [AgentRunTool] = []

    static let none = AgentRunToolkit()

    /// Whether this run may see and call a registry tool.
    func permits(_ toolName: String) -> Bool {
        !excludedToolNames.contains(toolName) && (permitsRegistryTool?(toolName) ?? true)
    }

    func additionalTool(named toolName: String) -> AgentRunTool? {
        additionalTools.first { $0.definition.name == toolName }
    }
}
