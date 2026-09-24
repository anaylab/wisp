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
    @ObservedObject private var soundPreference = WispSoundPreference.shared

    /// The measured natural height of the answer content, so the answer region
    /// sizes to fit a short reply and the whole island shrinks when idle.
    @State private var answerContentHeight: CGFloat = 0

    /// Brief confirmation shown on the reply action row after Copy / Insert, so
    /// a click that has no visible effect elsewhere still reads as having worked.
    @State private var replyActionFeedback: ReplyActionFeedback?

    /// Which reply action button the pointer is over, for its hover highlight.
    @State private var hoveredReplyAction: ReplyAction?

    var body: some View {
        // The glass container lets the pill and panel render as one Liquid Glass
        // element and morph fluidly between the collapsed and expanded frames.
        GlassEffectContainer {
            ZStack(alignment: .top) {
                Color.clear
                // The glass surface stays flush with the screen's top edge so it
                // WRAPS the physical notch and reads as part of it. At idle nothing
                // shows — the notch is untouched. When Wisp is active a small
                // status surface hugs the notch, its content flanking the cutout on
                // the left and right (never behind the camera); larger interactions
                // let it expand downward. Visibility fades in/out with a spring.
                hudSurface
                    .opacity(islandIsVisible ? 1 : 0)
            }
            .frame(
                width: viewModel.expandedSize.width,
                height: viewModel.expandedSize.height,
                alignment: .top
            )
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: viewModel.isExpanded)
            .animation(.spring(response: 0.36, dampingFraction: 0.84), value: islandIsVisible)
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
            droppedContent
                .frame(width: droppedWidth, alignment: .top)
                .opacity(viewModel.isExpanded ? 1 : 0)

            collapsedContent
                .frame(width: collapsedPillWidth, height: viewModel.collapsedSize.height)
                .opacity(viewModel.isExpanded ? 0 : 1)
        }
        // Expanded: fix the width but let the height wrap the content (nil). The
        // content is capped/scrolled internally so it never exceeds the window.
        // Collapsed: pin to the collapsed pill size, clipping the faded-out
        // dropped content. The dropped width depends on whether this is the compact
        // message or the full panel; the collapsed width wraps the notch.
        .frame(
            width: viewModel.isExpanded ? droppedWidth : collapsedPillWidth,
            height: viewModel.isExpanded ? nil : viewModel.collapsedSize.height,
            alignment: .top
        )
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: collapsedPillWidth)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: droppedWidth)
        // Apple Liquid Glass, tinted dark (see `wispNotchGlassSurface`), so the
        // island refracts the desktop while staying legible. The subtle stroke
        // defines the expanded panel's edge against a busy background. The shape
        // has FLUSH (square) top corners so the surface sits under the bezel and
        // reads as the physical notch itself extending downward; only the bottom
        // corners are rounded, like the real notch and the Dynamic Island.
        .wispNotchGlassSurface(in: notchSurfaceShape)
        .overlay(
            notchSurfaceShape
                .strokeBorder(DS.Colors.borderSubtle.opacity(viewModel.isExpanded ? 1 : 0), lineWidth: 1)
        )
        .clipShape(notchSurfaceShape)
    }

    /// What drops down from the notch when expanded: the full panel on a
    /// deliberate hover, or the compact message card for an auto-presented answer.
    @ViewBuilder
    private var droppedContent: some View {
        if viewModel.isFullPanel {
            expandedContent
        } else {
            messageContent
        }
    }

    /// The width of the dropped surface — narrow for the compact message so a short
    /// reply stays small, full width for the panel.
    private var droppedWidth: CGFloat {
        viewModel.isFullPanel ? viewModel.expandedSize.width : compactMessageWidth
    }

    /// The compact message width: a touch wider than the notch-wrap so the drop
    /// reads as the wrap growing down, capped well under the full panel.
    private var compactMessageWidth: CGFloat {
        min(viewModel.expandedSize.width, max(collapsedPillWidth, 300))
    }

    /// The compact answer surface: just the reply text and any glance card, sized
    /// to the message and inset below the notch. No affordance, skills or footer —
    /// those belong to the full panel a hover reveals.
    private var messageContent: some View {
        answerSurfaceWithReplyActions
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .padding(.top, notchContentTopInset + 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The bottom corner radius of the notch surface. Kept close to the physical
    /// notch's own curvature while collapsed so the idle pill and the grown live
    /// activity both read as the notch; a little rounder when expanded so the
    /// hanging panel feels like a panel.
    private var notchBottomCornerRadius: CGFloat {
        viewModel.isExpanded ? 24 : 18
    }

    /// The notch-matched surface shape: square at the top (flush with the screen's
    /// top bezel, exactly like the physical notch) and rounded only at the bottom.
    /// Shared by the collapsed pill and the expanded panel so the morph between
    /// them stays one continuous surface hanging from the notch.
    private var notchSurfaceShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: notchBottomCornerRadius,
            bottomTrailingRadius: notchBottomCornerRadius,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    /// How far below the screen's top edge the island's surface begins. On a
    /// notched Mac this equals the notch height, so all content clears the camera
    /// housing and the surface hangs from the notch's bottom edge. On a non-notch
    /// Mac there is no cutout to clear, so it stays 0 (the floating-pill fallback).
    private var notchContentTopInset: CGFloat {
        viewModel.hasNotch ? viewModel.collapsedSize.height : 0
    }

    /// Whether the island should be showing at all. On a notched Mac it stays
    /// hidden at idle so the notch is just the notch, and drops in when Wisp is
    /// active (listening / thinking / responding), when an answer is lingering, or
    /// when the panel is expanded on hover. On a non-notch Mac there is no cutout
    /// to serve as the resting affordance, so the floating pill stays visible.
    private var islandIsVisible: Bool {
        !viewModel.hasNotch
            || viewModel.isExpanded
            || companionManager.voiceState != .idle
            || companionManager.islandFlash != nil
            || hasAnswer
    }

    // MARK: - Collapsed live activity

    /// The collapsed (mini) live activity. On a notched Mac it WRAPS the notch —
    /// content sits to the left and right of the cutout, never behind the camera.
    /// On a non-notch Mac there is no cutout, so it falls back to the old centred
    /// pill that grows with its text.
    @ViewBuilder
    private var collapsedContent: some View {
        if viewModel.hasNotch {
            notchWrapContent
        } else {
            floatingPillContent
        }
    }

    /// The notch-wrapping status surface: the living mark hugs the notch's left
    /// edge and the state indicator hugs its right edge, with the exact width of
    /// the physical notch reserved between them so nothing is ever occluded by the
    /// camera. Kept intentionally minimal — the mark's motion plus the indicator
    /// (waveform while listening, pulsing dots while thinking, a dot at rest) carry
    /// the state; details live in the downward expansion.
    private var notchWrapContent: some View {
        HStack(spacing: 0) {
            WispMark(state: companionManager.islandState.markState, size: 15)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 12)

            // Reserve the physical notch's width so content only ever flanks it.
            Color.clear.frame(width: viewModel.collapsedSize.width)

            collapsedIndicator
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
        }
        .frame(height: viewModel.collapsedSize.height)
    }

    /// The non-notch fallback: a centred pill that shows the mark, a one-line live
    /// activity (what Wisp is hearing / a status word / the reply preview) and the
    /// state indicator, growing with its text.
    private var floatingPillContent: some View {
        HStack(spacing: 7) {
            WispMark(state: companionManager.islandState.markState, size: 13)
            if let collapsedPrimaryText {
                Text(collapsedPrimaryText)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(collapsedTruncationMode)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
            collapsedIndicator
        }
        .padding(.horizontal, collapsedPrimaryText == nil ? 0 : 11)
    }

    /// The right-hand indicator in the collapsed pill, matched to the state so the
    /// pill reads as alive at a glance: a live micro-waveform while listening or
    /// responding, pulsing dots while thinking, and a single status dot at rest.
    @ViewBuilder
    private var collapsedIndicator: some View {
        switch companionManager.voiceState {
        case .listening, .responding:
            collapsedMicroWaveform
        case .processing:
            collapsedThinkingDots
        case .idle:
            stateDot
        }
    }

    /// Three dots that pulse in sequence while Wisp is thinking, tinted with the
    /// island's active accent — a compact "working on it" signal beside the heard
    /// prompt, distinct from the listening waveform.
    private var collapsedThinkingDots: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            let elapsedSeconds = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<3, id: \.self) { dotIndex in
                    Circle()
                        .fill(companionManager.islandState.accent)
                        .frame(width: 3.5, height: 3.5)
                        .opacity(0.3 + 0.7 * ((sin(elapsedSeconds * 4 + Double(dotIndex) * 0.9) + 1) / 2))
                }
            }
        }
        .frame(height: 12)
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

    /// The one line of text the collapsed live-activity pill shows, chosen by
    /// state: the words Wisp is hearing while listening or thinking (falling back
    /// to a status label before any words land), the reply preview while
    /// responding or lingering afterwards, and nothing at rest.
    private var collapsedPrimaryText: String? {
        switch companionManager.voiceState {
        case .listening:
            let heardSoFar = companionManager.liveTranscript
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return heardSoFar.isEmpty ? "Listening…" : heardSoFar
        case .processing:
            // A running browser task says what it is doing, which is more useful
            // mid-task than echoing the request back.
            let browserActivity = companionManager.browserActivityText
            if !browserActivity.isEmpty { return browserActivity }
            let heardSoFar = companionManager.liveTranscript
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return heardSoFar.isEmpty ? "Thinking…" : heardSoFar
        case .responding:
            return collapsedReplySnippet ?? "Responding…"
        case .idle:
            return collapsedReplySnippet
        }
    }

    /// Whether the pill is currently showing the live transcript of speech. When
    /// it is, the tail is truncated so the most recent words stay visible as the
    /// user keeps talking; otherwise the start is kept (normal reply preview).
    private var isShowingLiveTranscript: Bool {
        switch companionManager.voiceState {
        case .listening:
            return !companionManager.liveTranscript
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .processing:
            return companionManager.browserActivityText.isEmpty
                && !companionManager.liveTranscript
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .responding, .idle:
            return false
        }
    }

    private var collapsedTruncationMode: Text.TruncationMode {
        isShowingLiveTranscript ? .head : .tail
    }

    /// How far the notch-wrapping surface extends past each side of the physical
    /// notch, giving the mark and the indicator room to sit in the menu bar beside
    /// the cutout.
    private let notchWrapSideExtension: CGFloat = 44

    /// The collapsed surface's width. On a notched Mac it is the notch width plus a
    /// fixed extension on each side (so the surface wraps the notch and content
    /// flanks it) — a constant while active, so it doesn't reflow as the transcript
    /// streams. On a non-notch Mac it grows with the pill's text.
    private var collapsedPillWidth: CGFloat {
        if viewModel.hasNotch {
            return min(
                viewModel.expandedSize.width,
                viewModel.collapsedSize.width + notchWrapSideExtension * 2
            )
        }
        let bareWidth = viewModel.collapsedSize.width
        guard collapsedPrimaryText != nil else { return bareWidth }
        let liveActivityWidth: CGFloat = 320
        return min(viewModel.expandedSize.width, max(bareWidth, liveActivityWidth))
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
        VStack(alignment: .leading, spacing: 0) {
            // The header lives in the notch band itself, flanking the cutout:
            // identity on its left, controls on its right. This uses the strip that
            // would otherwise sit empty above the content and pins the logo and the
            // icons to the very top, integrated with the notch.
            notchFlankingHeader

            VStack(alignment: .leading, spacing: 10) {
                // The living centerpiece: a voice waveform that reflects the current
                // state and, while listening, the real microphone level.
                voiceAffordanceSection

                // Only present when there is an answer, so an idle panel collapses
                // down to just the affordance, skills and footer.
                if hasAnswer {
                    answerSurfaceWithReplyActions
                }

                // Skills stay one click away as a compact sideways-scrolling strip.
                skillsStrip

                footer
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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

    // MARK: Reply actions

    /// The answer plus a row of things to do with it. The row sits outside the
    /// answer's scroll view so it stays visible when a long reply scrolls.
    private var answerSurfaceWithReplyActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            answerSurface
            if hasReplyText {
                replyActionRow
            }
        }
        .onChange(of: companionManager.currentReplyText) { _, _ in
            // A new turn's answer shouldn't inherit the last one's "Copied".
            replyActionFeedback = nil
        }
    }

    private var hasReplyText: Bool {
        !companionManager.currentReplyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var replyActionRow: some View {
        HStack(spacing: 6) {
            replyActionButton(
                .copy,
                title: replyActionFeedback == .copied ? "Copied" : "Copy",
                systemImageName: replyActionFeedback == .copied ? "checkmark" : "doc.on.doc",
                tooltip: "Copy this answer to the clipboard",
                isEnabled: true
            ) {
                copyReplyToClipboard()
            }

            let insertTargetAppName = insertTargetApplicationName
            replyActionButton(
                .insert,
                title: insertButtonTitle,
                systemImageName: replyActionFeedback == .inserted ? "checkmark" : "text.insert",
                tooltip: insertTargetAppName.map { "Type this answer at the cursor in \($0)" }
                    ?? "Click into a text field in another app first",
                isEnabled: insertTargetAppName != nil
            ) {
                insertReplyIntoFrontmostApp()
            }

            replyActionButton(
                .followUp,
                title: "Follow up",
                systemImageName: "arrowshape.turn.up.left",
                tooltip: "Ask a follow-up — Wisp keeps this conversation's context",
                isEnabled: true
            ) {
                companionManager.beginFollowUpQuestion()
            }
        }
    }

    private var insertButtonTitle: String {
        switch replyActionFeedback {
        case .inserted: return "Inserted"
        case .insertFailed: return "Couldn't insert"
        default: return "Insert"
        }
    }

    /// The app an Insert would type into, or nil when that would be Wisp itself
    /// (e.g. the dashboard is frontmost), where inserting makes no sense. The
    /// notch panel is non-activating, so clicking it leaves the user's app
    /// frontmost with its text field still focused.
    private var insertTargetApplicationName: String? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return nil
        }
        return frontmostApplication.localizedName
    }

    private func copyReplyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(companionManager.currentReplyText, forType: .string)
        showReplyActionFeedback(.copied)
    }

    private func insertReplyIntoFrontmostApp() {
        let insertionMethod = DictatedTextInserter.insert(companionManager.currentReplyText)
        showReplyActionFeedback(insertionMethod == .failed ? .insertFailed : .inserted)
    }

    private func showReplyActionFeedback(_ feedback: ReplyActionFeedback) {
        replyActionFeedback = feedback
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            if replyActionFeedback == feedback {
                replyActionFeedback = nil
            }
        }
    }

    private func replyActionButton(
        _ action: ReplyAction,
        title: String,
        systemImageName: String,
        tooltip: String,
        isEnabled: Bool,
        perform: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredReplyAction == action && isEnabled
        return Button(action: perform) {
            HStack(spacing: 5) {
                Image(systemName: systemImageName)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(isEnabled ? DS.Colors.textPrimary : DS.Colors.textTertiary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.14 : 0.07))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .pointerCursor(isEnabled: isEnabled)
        .nativeTooltip(tooltip)
        .onHover { isHovering in
            if isHovering {
                hoveredReplyAction = action
            } else if hoveredReplyAction == action {
                hoveredReplyAction = nil
            }
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
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
            case let .places(placesCardState):
                PlacesCardView(state: placesCardState)
            case let .source(sourceCardState):
                SourceCardView(state: sourceCardState)
            case let .reminders(remindersCardState):
                RemindersCardView(state: remindersCardState)
            case let .timer(timerCardState):
                TimerCardView(state: timerCardState)
            }
        }
    }


    /// The panel header, laid out in the notch band so it flanks the cutout:
    /// the wisp mark + wordmark hug the notch's left edge, the controls hug its
    /// right edge, with the notch's own width reserved between them. This pins the
    /// logo and the icons to the very top, integrated with the notch, instead of a
    /// full-width row sitting below an empty band. The cursor-dock toggle moves to
    /// the footer so three controls fit comfortably in the right flank.
    private var notchFlankingHeader: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                WispMark(state: companionManager.islandState.markState, size: 16)
                Text("Wisp")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 14)

            // Reserve the physical notch's width so the header only ever flanks it
            // (zero on a non-notch Mac, where the two clusters simply split the row).
            Color.clear.frame(width: viewModel.hasNotch ? viewModel.collapsedSize.width : 0)

            HStack(spacing: 3) {
                soundCuesToggle
                voiceOutputToggle
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
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 12)
        }
        .frame(height: viewModel.hasNotch ? notchContentTopInset : 36)
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

    /// Sound-cue toggle in the header. Governs the short interaction sounds
    /// (listening / thinking / reply / error) — separate from spoken replies,
    /// which the voice/silent toggle governs.
    private var soundCuesToggle: some View {
        let areSoundsOn = soundPreference.areSoundCuesEnabled
        return Button {
            soundPreference.areSoundCuesEnabled.toggle()
        } label: {
            Image(systemName: areSoundsOn ? "bell.fill" : "bell.slash.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(areSoundsOn ? DS.Colors.accentText : DS.Colors.textTertiary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .nativeTooltip(areSoundsOn
            ? "Sound cues on — Wisp chimes as it listens, thinks and replies. Click to mute."
            : "Sound cues muted. Click to enable.")
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
            // Moved here from the header so the top-right flank stays uncrowded.
            dockCursorToggle
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

/// The actions on the notch reply row.
private enum ReplyAction {
    case copy
    case insert
    case followUp
}

/// The short-lived confirmation a reply action shows on its own button.
private enum ReplyActionFeedback: Equatable {
    case copied
    case inserted
    case insertFailed
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

