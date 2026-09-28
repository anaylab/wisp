//
//  DashboardToolsTab.swift
//  leanring-buddy
//
//  What Wisp can actually reach: built-in tools and connected MCP servers.
//
//  Until now MCPManager tracked per-server state and captured each server's
//  stderr, and none of it was displayed anywhere. That is the wrong way round:
//  stdio MCP servers report everything through stderr, so a server that fails
//  to spawn — almost always a PATH problem, since a menu bar app inherits a
//  minimal PATH and cannot find npx — failed invisibly. The error existed; it
//  just had no home.
//
//  The tab also states plainly when agent mode is off. Listing tools that
//  cannot currently be invoked, with no indication of that, would be a screen
//  that lies quietly.
//

import Combine
import SwiftUI

struct ToolsTab: View {
    @ObservedObject private var mcpManager = MCPManager.shared
    @ObservedObject private var toolRegistry = AgentToolRegistry.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if CompanionManager.isAgentModeEnabled == false {
                    agentModeOffNotice
                }

                serversSection
                toolsSection
            }
            .padding(16)
        }
        .background(WispColor.windowBackground)
    }

    // MARK: - Agent mode

    private var agentModeOffNotice: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(DS.Colors.warningText)

            VStack(alignment: .leading, spacing: 3) {
                Text("Agent mode is off")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Colors.textPrimary)
                Text("Wisp answers questions but will not call any of the tools below. Set AgentModeEnabled to true in Info.plist and rebuild to turn it on.")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.warning.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(DS.Colors.warning.opacity(0.28), lineWidth: 0.5)
        )
    }

    // MARK: - Servers

    private var serversSection: some View {
        DashboardCard(title: "MCP Servers") {
            VStack(alignment: .leading, spacing: 10) {
                Text("~/.wisp/mcp.json")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                if mcpManager.serverStatuses.isEmpty {
                    Text("No servers configured. Add them to ~/.wisp/mcp.json using the same format Claude Desktop uses, then restart Wisp.")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 6) {
                        ForEach(mcpManager.serverStatuses) { status in
                            ServerRow(status: status)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Tools

    private var toolsSection: some View {
        DashboardCard(title: "Available Tools") {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(toolRegistry.definitions.count) registered")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                if toolRegistry.definitions.isEmpty {
                    Text("No tools registered.")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textTertiary)
                } else {
                    VStack(spacing: 5) {
                        ForEach(toolRegistry.definitions.sorted(by: { $0.name < $1.name }), id: \.name) { tool in
                            ToolRow(tool: tool)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Server row

private struct ServerRow: View {
    let status: MCPManager.ServerStatus

    @State private var isShowingErrorOutput = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: indicatorColor.opacity(0.6), radius: 3)

                Text(status.name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(DS.Colors.textPrimary)

                Spacer(minLength: 8)

                Text(status.state.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(indicatorColor)

                // Only offered when there is something to read. A disclosure
                // control that opens onto nothing is worse than no control.
                if status.recentErrorOutput.isEmpty == false {
                    Button {
                        isShowingErrorOutput.toggle()
                    } label: {
                        Image(systemName: isShowingErrorOutput ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(DS.Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }

            if case .failed(let reason) = status.state {
                Text(reason)
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isShowingErrorOutput {
                // Verbatim, monospaced, scrollable. A server's stderr is the
                // only real evidence of why it failed, and paraphrasing it
                // would throw away the part that identifies the cause.
                ScrollView {
                    Text(status.recentErrorOutput.joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: 120)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .fill(DS.Colors.background)
                )
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface2)
        )
    }

    private var indicatorColor: Color {
        switch status.state {
        case .connected: return DS.Colors.success
        case .connecting, .installing: return DS.Colors.warningText
        case .failed: return DS.Colors.destructiveText
        case .disabled: return DS.Colors.textTertiary
        }
    }
}

// MARK: - Tool row

private struct ToolRow: View {
    let tool: BuddyToolDefinition

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: tool.name.contains("__") ? "server.rack" : "wrench.fill")
                .font(.system(size: 10))
                .foregroundStyle(DS.Colors.textTertiary)
                .frame(width: 14)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.name)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(DS.Colors.accentText)

                    // Worth showing per tool: it is the difference between one
                    // that reads and one that acts, and that is exactly what
                    // someone scanning this list wants to know.
                    if tool.requiresConfirmation {
                        Text("asks first")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(DS.Colors.warningText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(DS.Colors.warning.opacity(0.15)))
                    }
                }

                Text(tool.description)
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
    }
}
