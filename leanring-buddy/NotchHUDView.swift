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
    @ObservedObject private var bindingStore = ShortcutBindingStore.shared
    @ObservedObject private var voiceOutputPreference = VoiceOutputPreference.shared

    var body: some View {
        // The glass container lets the pill and panel render as one Liquid Glass
        // element and morph fluidly between the collapsed and expanded frames.
        GlassEffectContainer {
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
        // Liquid Glass is the notch surface. Its own tinted material replaces
        // the flat surface1 / black fills, so the pill and panel refract the
        // desktop behind them and read as one dynamic-island element. The
        // subtle stroke is kept on the expanded panel to define its edge
        // against a busy background.
        .wispNotchGlassSurface(
            in: RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
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
            return CursorAppearanceStore.shared.color
        }
    }

    // MARK: - Expanded quick-panel

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            // The latest reply as text, so silent mode has somewhere to show the
            // answer and voice mode shows it too. Capped in height and scrollable
            // so a long reply stays inside the fixed expanded bounds — the window
            // never resizes to fit it.
            replyTextRegion
            // A visual answer card, when the latest turn produced one, sits at the
            // top of the panel above the resident controls so the answer is what
            // the user sees first. It renders inside the fixed expanded bounds —
            // the window never resizes to fit it. Each card kind picks its own
            // template.
            if let resolvedCard = companionManager.resolvedGlanceCard {
                switch resolvedCard {
                case let .generic(glanceCard):
                    GlanceCardView(card: glanceCard)
                case let .weather(weatherCardState):
                    WeatherCardView(state: weatherCardState)
                case let .calendar(calendarCardState):
                    CalendarCardView(state: calendarCardState)
                case let .nowPlaying(nowPlayingCardState):
                    NowPlayingCardView(state: nowPlayingCardState)
                case let .source(sourceCardState):
                    SourceCardView(state: sourceCardState)
                }
            }
            shortcutsCheatSheet
            Divider().overlay(DS.Colors.borderSubtle)
            skillsSection
            Divider().overlay(DS.Colors.borderSubtle)
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
            voiceOutputToggle
            dockCursorToggle
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

    /// Compact cursor-dock toggle in the header. The stored flag is "cursor
    /// always visible"; docking is its inverse.
    private var dockCursorToggle: some View {
        let isDocked = !companionManager.isCursorAlwaysVisible
        return Button {
            companionManager.setCursorAlwaysVisible(isDocked)
        } label: {
            Image(systemName: isDocked ? "cursorarrow.slash" : "cursorarrow")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isDocked ? DS.Colors.textTertiary : DS.Colors.accentText)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .nativeTooltip(isDocked
            ? "Cursor docked — click to let it follow you"
            : "Dock the cursor (hide it and stop it following you)")
    }

    /// Voice / silent mode toggle in the header. When voice is off (silent
    /// mode), replies are never spoken and appear only here in the notch.
    private var voiceOutputToggle: some View {
        let isVoiceOn = voiceOutputPreference.isReplySpeechEnabled
        return Button {
            voiceOutputPreference.isReplySpeechEnabled.toggle()
        } label: {
            Image(systemName: isVoiceOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isVoiceOn ? DS.Colors.accentText : DS.Colors.textTertiary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .nativeTooltip(isVoiceOn
            ? "Voice mode — replies are spoken. Click for silent mode."
            : "Silent mode — replies show here only. Click to enable voice.")
    }

    // MARK: Reply text

    /// The current turn's reply rendered as text. Empty between turns, so it
    /// simply takes no space until an answer arrives. Height-capped and
    /// scrollable so a long answer never grows the fixed-size panel.
    @ViewBuilder
    private var replyTextRegion: some View {
        let replyText = companionManager.currentReplyText
        if !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("REPLY")
                ScrollView {
                    Text(replyText)
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }
        }
    }

    // MARK: Shortcuts cheat-sheet

    /// Rendered live from the binding store, so rebinding a chord or toggling
    /// hands-free in the Shortcuts settings is reflected here immediately. The
    /// gesture chip distinguishes Talk (hold the chord) from Text (tap it).
    private var shortcutsCheatSheet: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("SHORTCUTS")
            shortcutRow(
                name: "Talk",
                gesture: "hold",
                keys: bindingStore.primaryHoldChord.keyCapsuleLabels
            )
            shortcutRow(
                name: "Text",
                gesture: "tap",
                keys: bindingStore.primaryHoldChord.keyCapsuleLabels
            )
            shortcutRow(
                name: "Dictate",
                gesture: "hold",
                keys: bindingStore.primaryHoldChord.keyCapsuleLabels + ["shift"]
            )
            if bindingStore.handsFreeDictationEnabled {
                shortcutRow(
                    name: "Hands-free",
                    gesture: "2×",
                    keys: [bindingStore.handsFreeDictationModifier.capsuleLabel]
                )
            }
        }
    }

    private func shortcutRow(name: String, gesture: String, keys: [String]) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
            Spacer()
            HStack(spacing: 4) {
                gestureCapsule(gesture)
                ForEach(keys, id: \.self) { key in
                    keyCap(key)
                }
            }
        }
    }

    private func gestureCapsule(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(DS.Colors.accentText)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(DS.Colors.accentSubtle)
            )
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

    // MARK: Skills — one-click launchers

    /// Each skill in ~/.wisp/skills becomes a chip that runs the skill on the
    /// current screen when clicked (screenshot → model → spoken answer → on-screen
    /// pointing), rather than a link into a settings screen.
    private var skillsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("SKILLS")
            if skillManager.skills.isEmpty {
                Text("No skills yet — drop markdown files into ~/.wisp/skills")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150), spacing: 6, alignment: .leading)],
                    alignment: .leading,
                    spacing: 6
                ) {
                    ForEach(skillManager.skills) { skill in
                        skillChip(skill)
                    }
                }
            }
        }
    }

    private func skillChip(_ skill: SkillManager.SkillSummary) -> some View {
        Button {
            companionManager.runSkill(named: skill.name)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: iconName(forSkillNamed: skill.name))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.accentText)
                Text(prettifiedName(fromSkillName: skill.name))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .nativeTooltip(skill.description)
    }

    /// Turns a kebab/snake skill filename into a readable label, e.g.
    /// "summarize-screen" → "Summarize screen".
    private func prettifiedName(fromSkillName skillName: String) -> String {
        let spaced = skillName
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        guard let firstCharacter = spaced.first else { return skillName }
        return firstCharacter.uppercased() + spaced.dropFirst()
    }

    /// A best-effort icon for a skill, matched on keywords in its name. Falls
    /// back to a generic bolt so any user-authored skill still gets a glyph.
    private func iconName(forSkillNamed skillName: String) -> String {
        let lowercasedName = skillName.lowercased()
        if lowercasedName.contains("error") || lowercasedName.contains("debug") {
            return "exclamationmark.triangle"
        }
        if lowercasedName.contains("summar") {
            return "doc.text"
        }
        if lowercasedName.contains("task") || lowercasedName.contains("todo") {
            return "checklist"
        }
        if lowercasedName.contains("proof") || lowercasedName.contains("grammar") || lowercasedName.contains("write") {
            return "text.magnifyingglass"
        }
        if lowercasedName.contains("standup") || lowercasedName.contains("update") || lowercasedName.contains("meeting") {
            return "person.2"
        }
        return "bolt.fill"
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
/// cursor. Reuses the shared `Triangle` shape and the cursor colour so the brand
/// mark always matches the pointer the user chose.
private struct WispGlyph: View {
    let size: CGFloat
    @ObservedObject private var cursorAppearance = CursorAppearanceStore.shared

    var body: some View {
        Triangle()
            .fill(cursorAppearance.color)
            .frame(width: size, height: size)
            .rotationEffect(.degrees(35))
    }
}
