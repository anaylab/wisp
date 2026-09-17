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
    @ObservedObject private var voiceOutputPreference = VoiceOutputPreference.shared

    /// The measured natural height of the answer content, so the answer region
    /// sizes to fit a short reply and the whole island shrinks when idle.
    @State private var answerContentHeight: CGFloat = 0

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
        // The dynamic island is always dark, regardless of the system's light or
        // dark appearance, so the Liquid Glass renders its dark variant and the
        // near-white text stays legible instead of flipping to a washed-out
        // light frost.
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Morphing surface

    private var hudSurface: some View {
        ZStack(alignment: .top) {
            // Both states are always present; only opacity and the surface frame
            // animate. The expanded content is given a fixed width but a NATURAL
            // height, so the glass surface wraps however much content there is —
            // small when idle (just the affordance, skills and footer) and taller
            // when an answer is showing. The window itself never resizes; the
            // unused area below simply stays transparent.
            expandedContent
                .frame(width: viewModel.expandedSize.width, alignment: .top)
                .opacity(viewModel.isExpanded ? 1 : 0)

            collapsedContent
                .frame(width: viewModel.collapsedSize.width, height: viewModel.collapsedSize.height)
                .opacity(viewModel.isExpanded ? 0 : 1)
        }
        // Expanded: fix the width but let the height wrap the content (nil). The
        // content is capped/scrolled internally so it never exceeds the window.
        // Collapsed: pin to the collapsed pill size, clipping the faded-out
        // expanded content.
        .frame(
            width: viewModel.isExpanded ? viewModel.expandedSize.width : viewModel.collapsedSize.width,
            height: viewModel.isExpanded ? nil : viewModel.collapsedSize.height,
            alignment: .top
        )
        // Apple Liquid Glass, tinted dark (see `wispNotchGlassSurface`), so the
        // island refracts the desktop while staying legible. The subtle stroke
        // defines the expanded panel's edge against a busy background.
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
            WispMark(state: companionManager.islandState.markState, size: 13)
            // A one-line preview of the latest answer, so after the panel
            // auto-collapses the reply lingers in the pill as a compact live
            // activity rather than the pill going back to dead chrome. It takes
            // the space between the glyph and the dot and truncates to fit.
            if let collapsedReplySnippet {
                Text(collapsedReplySnippet)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            collapsedIndicator
        }
        .padding(.horizontal, collapsedReplySnippet == nil ? 0 : 10)
    }

    /// The right-hand indicator in the collapsed pill: a live micro-waveform
    /// while the companion is active, or a single status dot when idle — so the
    /// pill reads as alive at a glance without expanding.
    @ViewBuilder
    private var collapsedIndicator: some View {
        if companionManager.voiceState.isActiveForAffordance {
            collapsedMicroWaveform
        } else {
            stateDot
        }
    }

    /// Three tiny bars that ripple while active, tinted with the cursor colour.
    private var collapsedMicroWaveform: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            let elapsedSeconds = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { barIndex in
                    Capsule()
                        .fill(CursorAppearanceStore.shared.color)
                        .frame(
                            width: 2,
                            height: 4 + 6 * CGFloat((sin(elapsedSeconds * 7 + Double(barIndex) * 1.4) + 1) / 2)
                        )
                }
            }
        }
        .frame(height: 12)
    }

    /// The first line of the latest reply, or nil when there is none. Drives the
    /// compact preview in the collapsed pill.
    private var collapsedReplySnippet: String? {
        let reply = companionManager.currentReplyText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return nil }
        let firstLine = reply.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? reply
        return firstLine
    }

    /// A small dot that reflects the current voice state, so the collapsed pill
    /// is a live status indicator rather than dead chrome.
    private var stateDot: some View {
        Circle()
            .fill(stateDotColor)
            .frame(width: 6, height: 6)
    }

    private var stateDotColor: Color {
        let state = companionManager.islandState
        return state.isActive ? state.accent : DS.Colors.textTertiary
    }

    // MARK: - Expanded quick-panel

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            // The living centerpiece: a voice waveform that reflects the current
            // state and, while listening, the real microphone level. This is the
            // first thing the eye lands on, VoiceOS-style.
            voiceAffordanceSection

            // Only present when there is an answer, so an idle panel collapses
            // down to just the affordance, skills and footer instead of leaving
            // a gap where an answer would go.
            if hasAnswer {
                answerSurface
            }

            // Skills stay one click away as a compact sideways-scrolling strip.
            skillsStrip

            footer
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Whether the current turn has anything to show — reply text or a glance
    /// card. Drives the panel's two layouts.
    private var hasAnswer: Bool {
        let hasReply = !companionManager.currentReplyText
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasReply || companionManager.resolvedGlanceCard != nil
    }

    // MARK: Voice affordance

    private var voiceAffordanceSection: some View {
        VStack(spacing: 6) {
            WispVoiceAffordance(
                voiceState: companionManager.voiceState,
                audioPowerLevel: companionManager.currentAudioPowerLevel,
                accentColor: CursorAppearanceStore.shared.color
            )
            Text(companionManager.islandState.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .tracking(0.4)
                .animation(.easeInOut(duration: 0.2), value: companionManager.islandState.label)
        }
    }

    // MARK: Answer surface (reply + glance card)

    /// The tallest the answer region may grow before it starts scrolling
    /// internally, keeping the whole panel inside the fixed window.
    private let answerMaxHeight: CGFloat = 206

    private var answerSurface: some View {
        let hasReply = !companionManager.currentReplyText
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if hasReply {
                    VStack(alignment: .leading, spacing: 6) {
                        sectionLabel("REPLY")
                        Text(companionManager.currentReplyText)
                            .font(.system(size: 12.5))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                glanceCardView
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Measure the natural content height so the scroll view is sized to
            // exactly fit a short answer and only starts scrolling once the
            // content exceeds `answerMaxHeight`.
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: AnswerContentHeightKey.self, value: proxy.size.height)
                }
            )
        }
        .frame(height: min(max(answerContentHeight, 1), answerMaxHeight))
        .onPreferenceChange(AnswerContentHeightKey.self) { measuredHeight in
            answerContentHeight = measuredHeight
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: answerContentHeight)
    }

    @ViewBuilder
    private var glanceCardView: some View {
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
    }


    private var header: some View {
        HStack(spacing: 8) {
            WispMark(state: companionManager.islandState.markState, size: 16)
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

    // MARK: Skills — one-click launcher strip

    /// Each skill in ~/.wisp/skills becomes a chip that runs the skill on the
    /// current screen when clicked (screenshot → model → spoken answer → on-screen
    /// pointing). Demoted to a compact horizontal strip so the voice affordance
    /// and answer own the panel, but every skill stays one click away.
    @ViewBuilder
    private var skillsStrip: some View {
        if !skillManager.skills.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("SKILLS")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(skillManager.skills) { skill in
                            skillChip(skill)
                        }
                    }
                    .padding(.vertical, 1)
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
                    .foregroundColor(WispColor.Brand.sage)
                Text(prettifiedName(fromSkillName: skill.name))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(DS.Colors.borderSubtle.opacity(0.7), lineWidth: 0.75)
            )
            .contentShape(Capsule(style: .continuous))
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

    // MARK: Footer — integrations at a glance

    /// A single quiet row: the count of connected integrations on the left and a
    /// "manage" affordance on the right that opens the dashboard. Folded down
    /// from the old full-height integrations section so it never competes with
    /// the answer surface.
    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
            Text(integrationsSummary)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                NotificationCenter.default.post(name: .wispOpenDashboard, object: nil)
            } label: {
                Text("Manage")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .nativeTooltip("Manage integrations & settings")
        }
    }

    /// A compact summary like "3 integrations" / "1 integration" / "No integrations".
    private var integrationsSummary: String {
        let count = connectedServerNames.count
        switch count {
        case 0: return "No integrations connected"
        case 1: return "1 integration · \(connectedServerNames[0])"
        default: return "\(count) integrations connected"
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

    // MARK: Shared bits

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(DS.Colors.textTertiary)
            .tracking(0.6)
    }
}

/// Carries the answer content's measured natural height up to `NotchHUDView`, so
/// the answer region can size itself to the content (and the island shrink when
/// idle) rather than occupy a fixed block.
private struct AnswerContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

