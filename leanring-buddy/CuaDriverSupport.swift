//
//  CuaDriverSupport.swift
//  leanring-buddy
//
//  What Wisp knows about cua-driver (github.com/trycua/cua), an MCP server
//  that acts on native macOS apps over Accessibility: AX presses, typing, key
//  presses, menu picks — without moving the cursor or stealing focus. It is
//  installed like any other MCP server (an entry named `cua-driver` in
//  ~/.wisp/mcp.json, `mcp --direct`) and its tools arrive as
//  `cua-driver__click`, `cua-driver__get_window_state`, and so on.
//
//  Two things here keep it safe to hand to the model:
//
//  1. `CuaDriverToolNames.mustAlwaysAsk` — the driver's action tools act on
//     the user's real desktop with Wisp's full Accessibility grant (direct mode
//     inherits the host's TCC permissions). Their names ("click", "type_text",
//     "hotkey") match none of `ToolCallSafety`'s irreversible words, so without
//     this, session auto-approve would let a model click and type unasked. The
//     rule is scoped to this server's namespace: another server's `click` is
//     judged by the usual floor.
//
//  2. `CuaDriverElementCache` — an action call names its target only by an
//     opaque `element_token` ("s1a2b3c4d:17"). The cache remembers what each
//     token was (role, label, app) from the last few `get_window_state`
//     results Wisp passed to the model, so the confirmation card can say
//     "Click “Send” button · Mail" instead of showing the token.
//

import Foundation

enum CuaDriverToolNames {

    /// The server name Wisp expects in ~/.wisp/mcp.json.
    static let expectedServerName = "cua-driver"

    /// cua-driver tools that only observe. Everything else the server offers —
    /// the action tools, and anything a later version adds — always asks.
    /// Kept as an allow-list rather than a block-list because the driver gains
    /// tools quickly (0.28 → 0.34 added the browser set), and an unknown new
    /// tool should ask rather than slip through. `scroll` is here on purpose:
    /// it moves a view, changes nothing, and multi-step reading tasks need it.
    static let readOnlyBareToolNames: Set<String> = [
        "list_apps", "list_windows", "get_window_state", "verify_state",
        "get_desktop_state", "get_accessibility_tree", "zoom", "get_screen_size",
        "get_cursor_position", "get_agent_cursor_state", "check_permissions",
        "health_report", "get_config", "get_browser_state", "get_recording_state",
        "get_session", "list_sessions", "get_session_state", "parse_visual_regions",
        "clipboard_read", "scroll",
    ]

    /// The action tools named in the integration plan (docs/cua-spike.md).
    /// They are covered by "not read-only" above already; listing them keeps
    /// the guarantee explicit and is what the tests pin down.
    static let actionBareToolNames: Set<String> = [
        "click", "double_click", "right_click", "drag", "type_text", "press_key",
        "hotkey", "set_value", "invoke_menu", "kill_app", "clipboard_write",
        "replay_trajectory",
    ]

    /// Whether a tool's `server__` namespace is cua-driver's. Tolerates the
    /// spellings a user might give the entry ("cua-driver", "cua_driver",
    /// "Cua-Driver", "cua") — renaming the entry must not quietly turn the
    /// floor off.
    static func isCuaDriverServerNamespace(_ serverNamespace: String) -> Bool {
        let normalizedNamespace = serverNamespace.lowercased().replacingOccurrences(of: "_", with: "-")
        return normalizedNamespace == "cua" || normalizedNamespace.hasPrefix(expectedServerName)
    }

    /// Whether a namespaced tool name (`cua-driver__click`) belongs to cua-driver.
    static func isCuaDriverTool(_ toolName: String) -> Bool {
        guard let serverNamespace = ToolCallInspection.serverNamespace(of: toolName) else { return false }
        return isCuaDriverServerNamespace(serverNamespace)
    }

    /// Whether this call must be confirmed even under session auto-approve:
    /// any cua-driver tool that is not a known read-only one.
    static func mustAlwaysAsk(toolName: String) -> Bool {
        guard isCuaDriverTool(toolName) else { return false }
        return !readOnlyBareToolNames.contains(ToolCallInspection.bareToolName(toolName))
    }
}

/// What a cua-driver element token referred to when Wisp last saw it.
struct CuaDriverElementDescription: Equatable {
    /// The AX role with its `AX` prefix dropped ("Button", "TextField").
    let roleName: String?
    let label: String?
    let appName: String?
}

/// Remembers the elements of the last few cua-driver snapshots, token →
/// role/label/app, for the confirmation card.
///
/// Small on purpose. The driver itself invalidates a token once a newer read
/// of the same window supersedes it, so only recent snapshots can matter; a
/// few are kept because a model often reads two windows before acting in one.
/// Session-only (never persisted): tokens mean nothing after a relaunch.
final class CuaDriverElementCache {
    static let shared = CuaDriverElementCache()

    static let maximumRememberedSnapshots = 4

    /// Newest last. Each entry is one structured result's elements by token.
    private var rememberedSnapshots: [[String: CuaDriverElementDescription]] = []

    /// Records the elements of one cua-driver structured result. Results with
    /// no element list (a click's receipt, `list_windows`) are ignored.
    func recordElements(fromStructuredContent structuredContent: JSONValue) {
        guard case .object(let topLevelFields) = structuredContent,
              let (_, elements) = MCPToolResultRendering.elementList(in: structuredContent) else { return }

        let appName = MCPToolResultRendering.firstScalarText(forAnyOf: ["app_name", "application", "app"], in: topLevelFields)

        var elementsByToken: [String: CuaDriverElementDescription] = [:]
        for elementFields in elements {
            guard let elementToken = MCPToolResultRendering.firstScalarText(
                forAnyOf: MCPToolResultRendering.elementIdentifierKeys,
                in: elementFields
            ) else { continue }
            let roleName = MCPToolResultRendering.firstScalarText(
                forAnyOf: MCPToolResultRendering.elementRoleKeys,
                in: elementFields
            ).map(MCPToolResultRendering.readableRoleName)
            let label = MCPToolResultRendering.firstScalarText(
                forAnyOf: MCPToolResultRendering.elementLabelKeys,
                in: elementFields
            )
            elementsByToken[elementToken] = CuaDriverElementDescription(
                roleName: roleName,
                label: (label?.isEmpty ?? true) ? nil : label,
                appName: appName
            )
        }
        guard !elementsByToken.isEmpty else { return }

        rememberedSnapshots.append(elementsByToken)
        if rememberedSnapshots.count > Self.maximumRememberedSnapshots {
            rememberedSnapshots.removeFirst(rememberedSnapshots.count - Self.maximumRememberedSnapshots)
        }
    }

    /// The element a token named, newest snapshot first, or nil if Wisp never
    /// saw it (a token the model made up, or one from before a relaunch).
    func elementDescription(forToken elementToken: String) -> CuaDriverElementDescription? {
        for snapshot in rememberedSnapshots.reversed() {
            if let elementDescription = snapshot[elementToken] { return elementDescription }
        }
        return nil
    }

    func removeAll() {
        rememberedSnapshots.removeAll()
    }
}
