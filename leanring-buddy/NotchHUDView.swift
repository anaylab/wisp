//
//  NotchHUDView.swift
//  leanring-buddy
//
//  The SwiftUI content of the notch HUD. It fills a fixed-size window (the
//  controller never resizes it) and morphs a top-anchored surface between two
//  states with a single spring:
//
//   • Collapsed — a black rounded pill that merges with the physical notch (or
//     floats just under the menu bar on a non-notch Mac), showing the wisp
//     glyph and a small live state dot.
//   • Expanded — a quick-panel with the resident controls: a shortcuts
//     cheat-sheet, skills, active integrations, and the dock-cursor toggle.
//
//  The expanded content is laid out at its full size regardless of the surface
//  frame and merely clipped/faded while collapsed, so nothing reflows during the
//  animation — that, plus the window staying put, is what keeps the morph smooth.
//  Expand/collapse itself is decided by the controller from the global mouse
//  position; this view only reflects `viewModel.isExpanded`.
//

import SwiftUI

struct NotchHUDView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var skillManager = SkillManager.shared
    @ObservedObject private var mcpManager = MCPManager.shared

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            hudSurface
        }
        .frame(
            width: viewModel.expandedSize.width,
            height: viewModel.expandedSize.height,
            alignment: .top
        )
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: viewModel.isExpanded)
    }

    // MARK: - Morphing surface

    private var hudSurface: some View {
        ZStack(alignment: .top) {
            // Both states are always present and laid out at their own fixed
            // size; only opacity and the surface frame animate, so nothing
            // reflows mid-animation.
            expandedContent
                .frame(width: viewModel.expandedSize.width, height: viewModel.expandedSize.height, alignment: .top)
                .opacity(viewModel.isExpanded ? 1 : 0)

            collapsedContent
                .frame(width: viewModel.collapsedSize.width, height: viewModel.collapsedSize.height)
                .opacity(viewModel.isExpanded ? 0 : 1)
        }
        .frame(
            width: viewModel.isExpanded ? viewModel.expandedSize.width : viewModel.collapsedSize.width,
            height: viewModel.isExpanded ? viewModel.expandedSize.height : viewModel.collapsedSize.height,
            alignment: .top
        )
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .fill(viewModel.isExpanded ? DS.Colors.surface1 : Color.black)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .strokeBorder(DS.Colors.borderSubtle.opacity(viewModel.isExpanded ? 1 : 0), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous))
    }

    // MARK: - Collapsed pill

    private var collapsedContent: some View {
        HStack(spacing: 6) {
            WispGlyph(size: 11)
            stateDot
        }
    }

    /// A small dot that reflects the current voice state, so the collapsed pill
    /// is a live status indicator rather than dead chrome.
    private var stateDot: some View {
        Circle()
            .fill(stateDotColor)
            .frame(width: 6, height: 6)
    }

    private var stateDotColor: Color {
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.textTertiary
        default:
            return DS.Colors.overlayCursorBlue
        }
    }

    // MARK: - Expanded quick-panel

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            shortcutsCheatSheet
            Divider().overlay(DS.Colors.borderSubtle)
            skillsAndCursorRow
            activeIntegrations
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            WispGlyph(size: 13)
            Text("Wisp")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Spacer()
            Button {
                NotificationCenter.default.post(name: .wispOpenDashboard, object: nil)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .nativeTooltip("Open dashboard")
        }
    }

    // MARK: Shortcuts cheat-sheet

    /// Only the shortcuts that actually exist today are shown. Text mode and
    /// hands-free dictation arrive in later phases and will be added here then,
    /// rather than advertising bindings the engine does not yet honor.
    private var shortcutsCheatSheet: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("SHORTCUTS")
            shortcutRow(
                name: "Talk",
                keys: BuddyPushToTalkShortcut.ShortcutOption.controlOption.keyCapsuleLabels
            )
            shortcutRow(
                name: "Dictate",
                keys: ["ctrl", "option", "shift"]
            )
        }
    }

    private func shortcutRow(name: String, keys: [String]) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
            Spacer()
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    keyCap(key)
                }
            }
        }
    }

    private func keyCap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(DS.Colors.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
    }

    // MARK: Skills + dock cursor

    private var skillsAndCursorRow: some View {
        HStack(spacing: 8) {
            Button {
                NotificationCenter.default.post(name: .wispOpenDashboard, object: nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                    Text(skillsButtonTitle)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.surface2)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .nativeTooltip("Manage skills")

            Spacer()

            dockCursorButton
        }
    }

    private var skillsButtonTitle: String {
        let count = skillManager.skills.count
        return count == 0 ? "Skills" : "Skills · \(count)"
    }

    private var dockCursorButton: some View {
        // The stored flag is "cursor always visible"; docking is its inverse.
        let isDocked = !companionManager.isCursorAlwaysVisible
        return Button {
            companionManager.setCursorAlwaysVisible(isDocked) // toggle
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isDocked ? "cursorarrow.slash" : "cursorarrow")
                    .font(.system(size: 11, weight: .medium))
                Text(isDocked ? "Cursor docked" : "Dock cursor")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(isDocked ? DS.Colors.textSecondary : DS.Colors.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(isDocked ? DS.Colors.surface1 : DS.Colors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .nativeTooltip(isDocked
            ? "Cursor is docked and won't follow you"
            : "Hide the cursor and stop it following you")
    }

    // MARK: Active integrations

    private var activeIntegrations: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("ACTIVE INTEGRATIONS")
            HStack(spacing: 6) {
                if connectedServerNames.isEmpty {
                    Text("None connected")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                } else {
                    ForEach(connectedServerNames, id: \.self) { serverName in
                        integrationChip(serverName)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    NotificationCenter.default.post(name: .wispOpenDashboard, object: nil)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                .fill(DS.Colors.surface2)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .nativeTooltip("Manage integrations")
            }
        }
    }

    private var connectedServerNames: [String] {
        mcpManager.serverStatuses.compactMap { serverStatus in
            if case .connected = serverStatus.state {
                return serverStatus.name
            }
            return nil
        }
    }

    private func integrationChip(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(DS.Colors.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
    }

    // MARK: Shared bits

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(DS.Colors.textTertiary)
            .tracking(0.6)
    }
}

/// The wisp triangle, matching the rotation of the menu bar icon and the in-app
/// cursor. Reuses the shared `Triangle` shape so all three stay in sync.
private struct WispGlyph: View {
    let size: CGFloat

    var body: some View {
        Triangle()
            .fill(DS.Colors.overlayCursorBlue)
            .frame(width: size, height: size)
            .rotationEffect(.degrees(35))
    }
}
