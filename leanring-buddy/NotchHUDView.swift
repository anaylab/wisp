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
//   • Expanded — a quick-panel: header controls, the answer, live activity,
//     today's suggestions, and a Chat / Manage footer.
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
    @ObservedObject private var voiceOutputPreference = VoiceOutputPreference.shared
    @ObservedObject private var soundPreference = WispSoundPreference.shared
    @ObservedObject private var islandStylePreference = NotchIslandStylePreference.shared
    /// Observed so background work starting or finishing re-renders the
    /// island's ambient state — `islandState` reads the registry, but a computed
    /// property can't tell SwiftUI that on its own.
    @ObservedObject private var taskRegistry = AgentTaskRegistry.shared
    @ObservedObject private var upcomingEventMonitor = UpcomingEventMonitor.shared
    @ObservedObject private var morningBriefing = MorningBriefingController.shared
    @ObservedObject private var finishedWorkInbox = FinishedWorkInbox.shared
    @ObservedObject private var quietModeMonitor = QuietModeMonitor.shared

    /// The measured natural height of the answer content, so the answer region
    /// sizes to fit a short reply and the whole island shrinks when idle.
    @State private var answerContentHeight: CGFloat = 0

    /// The measured natural height of the quick panel's middle sections, so it
    /// wraps short content and scrolls only once it would overflow the window.
    @State private var quickPanelSectionsHeight: CGFloat = 0

    /// Brief confirmation shown on the reply action row after Copy / Insert, so
    /// a click that has no visible effect elsewhere still reads as having worked.
    @State private var replyActionFeedback: ReplyActionFeedback?

    /// Which reply action button the pointer is over, for its hover highlight.
    @State private var hoveredReplyAction: ReplyAction?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    // Liquid emergence: the island squeezes out of the notch
                    // like a droplet — starting narrow and short, anchored to
                    // the bezel — rather than just fading in. Reduce Motion
                    // keeps the plain fade.
                    .scaleEffect(
                        x: islandIsVisible || reduceMotion ? 1 : 0.72,
                        y: islandIsVisible || reduceMotion ? 1 : 0.35,
                        anchor: .top
                    )
                    .opacity(islandIsVisible ? 1 : 0)
            }
            // Fills the window, which is the quick panel's size normally and
            // the workspace's while chat/settings is open.
            .frame(
                width: viewModel.windowSize.width,
                height: viewModel.windowSize.height,
                alignment: .top
            )
            .animation(
                reduceMotion ? WispMotion.smooth : WispMotion.islandMorph(expanding: viewModel.isExpanded),
                value: viewModel.isExpanded
            )
            .animation(
                reduceMotion ? WispMotion.smooth : WispMotion.islandMorph(expanding: viewModel.isWorkspaceOpen),
                value: viewModel.isWorkspaceOpen
            )
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
            // small when idle (just the header and footer) and taller
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
            height: viewModel.isExpanded ? droppedFixedHeight : viewModel.collapsedSize.height,
            alignment: .top
        )
        .animation(WispMotion.island, value: collapsedPillWidth)
        .animation(WispMotion.island, value: droppedWidth)
        // Solid black by default, like Apple's Dynamic Island, so on a notched
        // Mac the surface is indistinguishable from the camera cutout; Liquid
        // Glass is the opt-in alternative (`NotchIslandStylePreference`). The
        // shape has FLUSH (square) top corners so the surface sits under the
        // bezel and reads as the physical notch itself extending downward; only
        // the bottom corners are rounded, like the real notch and the Dynamic
        // Island.
        .wispNotchIslandSurface(in: notchSurfaceShape, style: islandStylePreference.surfaceStyle)
        // Glass only: a subtle stroke defines the translucent panel's edge
        // against a busy background. Black needs none, just like the notch.
        .overlay(
            notchSurfaceShape
                .strokeBorder(
                    DS.Colors.borderSubtle.opacity(isGlassIslandExpanded ? 1 : 0),
                    lineWidth: 1
                )
        )
        .clipShape(notchSurfaceShape)
        // A soft colour wash rising from the bottom edge names the state of a
        // pending decision or a success / error moment; nothing for ordinary
        // activity, which the rim and mark already carry.
        .overlay(
            WispStateWash(color: companionManager.islandState.washColor)
                .clipShape(notchSurfaceShape)
                .opacity(viewModel.isExpanded ? 1 : 0)
        )
        // The rim carries state: lavender light travelling around it while Wisp
        // works, and the whole rim lighting up for a pending decision or a
        // success / error flash. On glass it also catches a specular highlight
        // (lit from below, since the top edge is under the bezel).
        .wispLiquidRim(
            in: notchSurfaceShape,
            light: companionManager.islandState.rimLight,
            highlightEdge: .bottom,
            showsSpecularHighlight: islandStylePreference.surfaceStyle == .liquidGlass
        )
    }

    private var isGlassIslandExpanded: Bool {
        viewModel.isExpanded && islandStylePreference.surfaceStyle == .liquidGlass
    }

    /// What drops down from the notch when expanded: the full panel on a
    /// deliberate hover, or the compact message card for an auto-presented answer.
    @ViewBuilder
    private var droppedContent: some View {
        if let workspacePage = viewModel.workspacePage {
            NotchWorkspaceView(
                viewModel: viewModel,
                companionManager: companionManager,
                page: workspacePage
            )
            .frame(
                width: NotchViewModel.workspaceSize.width,
                height: NotchViewModel.workspaceSize.height
            )
        } else if viewModel.isFullPanel {
            expandedContent
        } else {
            messageContent
        }
    }

    /// The width of the dropped surface — narrow for the compact message so a short
    /// reply stays small, full width for the panel.
    private var droppedWidth: CGFloat {
        if viewModel.isWorkspaceOpen { return NotchViewModel.workspaceSize.width }
        return viewModel.isFullPanel ? viewModel.expandedSize.width : compactMessageWidth
    }

    /// The workspace is a fixed size; the quick panel and message wrap their
    /// content (nil).
    private var droppedFixedHeight: CGFloat? {
        viewModel.isWorkspaceOpen ? NotchViewModel.workspaceSize.height : nil
    }

    /// The compact message width: a touch wider than the notch-wrap so the drop
    /// reads as the wrap growing down, capped well under the full panel.
    private var compactMessageWidth: CGFloat {
        min(viewModel.expandedSize.width, max(collapsedPillWidth, 300))
    }

    /// The compact answer surface: just the reply text and any glance card, sized
    /// to the message and inset below the notch. No header controls or footer —
    /// those belong to the full panel a hover reveals.
    private var messageContent: some View {
        compactDroppedContent
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .padding(.top, notchContentTopInset + 8)
            // A floor under the card so a one-line reply doesn't drop as a
            // sliver and then jump taller when a longer one lands.
            .frame(minHeight: notchContentTopInset + Self.compactMessageMinimumHeight, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let compactMessageMinimumHeight: CGFloat = 76

    /// An answer always wins the compact surface; the morning banner only shows
    /// on an otherwise empty notch.
    @ViewBuilder
    private var compactDroppedContent: some View {
        if !hasAnswer && morningBriefing.hasPendingBriefing {
            morningBannerContent
        } else {
            answerSurfaceWithReplyActions
        }
    }

    /// The bottom corner radius of the notch surface. Kept close to the physical
    /// notch's own curvature while collapsed so the idle pill and the grown live
    /// activity both read as the notch; a little rounder when expanded so the
    /// hanging panel feels like a panel.
    private var notchBottomCornerRadius: CGFloat {
        if viewModel.isWorkspaceOpen { return 28 }
        return viewModel.isExpanded ? 24 : 18
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
            || hasAmbientActivity
    }

    // MARK: - Live activities (executing + ambient)

    /// A browser task is carrying out the request right now.
    private var isExecutingBrowserTask: Bool {
        companionManager.islandState == .executing
    }

    /// Background tasks still running, newest first.
    private var runningBackgroundTasks: [AgentTaskRecord] {
        taskRegistry.records.filter { $0.kind == .background && !$0.status.isTerminal }
    }

    /// Something worth a glance while Wisp is otherwise idle: background work in
    /// flight, or a meeting about to start. Keeps the island showing on a notched
    /// Mac, where it would otherwise disappear into the notch at rest.
    private var hasAmbientActivity: Bool {
        !runningBackgroundTasks.isEmpty
            || upcomingEventMonitor.imminentEvent != nil
            || !finishedWorkInbox.unseenTaskIDs.isEmpty
            || morningBriefing.hasPendingBriefing
    }

    /// Whether a flank is showing a label (step count, task count, countdown)
    /// rather than a lone glyph — the wrap widens a little to fit it.
    private var isShowingFlankLabel: Bool {
        if isExecutingBrowserTask { return true }
        guard companionManager.voiceState == .idle else { return false }
        return hasAmbientActivity
    }

    /// An indeterminate progress ring: the step total of a browser task is not
    /// known in advance, so the ring spins rather than filling, and the number
    /// beside it counts steps taken. Pauses when Reduce Motion is on.
    private func activityRing(diameter: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: WispMotion.prefersReducedMotion)) { timeline in
            let rotationDegrees = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.2) / 1.2 * 360
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.15), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(WispColor.Brand.lavender, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(rotationDegrees))
            }
        }
        .frame(width: diameter, height: diameter)
    }

    /// A small ring + number for a flank, e.g. the spinning ring beside "4".
    private func flankActivityLabel(_ text: String) -> some View {
        HStack(spacing: 5) {
            activityRing(diameter: 11)
            Text(text)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundColor(WispColor.Island.textPrimary)
                .lineLimit(1)
        }
    }

    /// The calendar glyph + "12m" countdown for the right flank.
    private func flankEventCountdown(_ event: CalendarGlanceEvent) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "calendar")
                .font(.system(size: 10, weight: .semibold))
            Text(UpcomingEventMonitor.compactCountdownText(until: event.startDate))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .lineLimit(1)
        }
        .foregroundColor(WispColor.Island.textSecondary)
    }

    /// The left flank: the living mark, except while idle with background work
    /// running, when it shows that work (spinner + how many tasks). Work on the
    /// left, time on the right.
    @ViewBuilder
    private var notchLeftFlank: some View {
        if companionManager.voiceState == .idle && !isExecutingBrowserTask && !runningBackgroundTasks.isEmpty {
            flankActivityLabel("\(runningBackgroundTasks.count)")
                .nativeTooltip(runningBackgroundTasks.count == 1
                    ? "1 task running in the background"
                    : "\(runningBackgroundTasks.count) tasks running in the background")
        } else {
            WispMark(state: companionManager.islandState.markState, size: 15)
        }
    }

    /// The live section at the top of the hover panel: the running browser task's
    /// steps with a Stop button, background tasks each with their own Stop, and
    /// the imminent meeting. Empty (and absent) when none of those apply.
    @ViewBuilder
    private var liveActivitySection: some View {
        let imminentEvent = upcomingEventMonitor.imminentEvent
        if isExecutingBrowserTask || !runningBackgroundTasks.isEmpty || imminentEvent != nil {
            VStack(alignment: .leading, spacing: 10) {
                if isExecutingBrowserTask {
                    executingTaskCard
                }
                ForEach(runningBackgroundTasks) { backgroundTask in
                    backgroundTaskRow(backgroundTask)
                }
                if let imminentEvent {
                    imminentEventRow(imminentEvent)
                }
            }
        }
    }

    /// How many past steps the executing card lists above the current one.
    private let executingCardPreviousStepLimit = 3

    private var executingTaskCard: some View {
        let stepHistory = companionManager.browserTaskStepHistory
        let previousSteps = Array(stepHistory.dropLast().suffix(executingCardPreviousStepLimit))
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                sectionLabel("STEP \(max(companionManager.browserTaskStepCount, 1))")
                Spacer(minLength: 0)
                // Only a task the user is waiting on (a live turn) is stopped here.
                // A browser task running in the background has its own row below
                // with a Stop that cancels that task specifically.
                if companionManager.voiceState != .idle {
                    liveActivityStopButton(tooltip: "Stop this task") {
                        companionManager.stopCurrentTask()
                    }
                }
            }
            ForEach(Array(previousSteps.enumerated()), id: \.offset) { _, previousStep in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(WispColor.Island.textTertiary)
                        .frame(width: 12)
                    Text(previousStep)
                        .font(.system(size: 11.5))
                        .foregroundColor(WispColor.Island.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            HStack(spacing: 8) {
                activityRing(diameter: 12)
                Text(companionManager.browserActivityText)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(WispColor.Island.textPrimary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(WispColor.Island.controlFill)
        )
    }

    private func backgroundTaskRow(_ backgroundTask: AgentTaskRecord) -> some View {
        HStack(spacing: 8) {
            activityRing(diameter: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(backgroundTask.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(WispColor.Island.textPrimary)
                    .lineLimit(1)
                Text(backgroundTaskStatusLine(backgroundTask))
                    .font(.system(size: 10.5))
                    .foregroundColor(WispColor.Island.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            liveActivityStopButton(tooltip: "Stop this background task") {
                taskRegistry.cancelTask(backgroundTask.id)
            }
        }
    }

    /// "Background · 2 min · Opening github.com" — how long it has run plus its
    /// latest step when it has one.
    private func backgroundTaskStatusLine(_ backgroundTask: AgentTaskRecord) -> String {
        let elapsedMinutes = Int(backgroundTask.elapsedSeconds / 60)
        let elapsedText = elapsedMinutes < 1 ? "just started" : "\(elapsedMinutes) min"
        if backgroundTask.status == .waitingForApproval {
            return "Background · waiting for your ok"
        }
        if let latestStepSummary = backgroundTask.steps.last?.summary {
            return "Background · \(elapsedText) · \(latestStepSummary)"
        }
        return "Background · \(elapsedText)"
    }

    private func imminentEventRow(_ event: CalendarGlanceEvent) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(WispColor.Island.textSecondary)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(WispColor.Island.textPrimary)
                    .lineLimit(1)
                Text([UpcomingEventMonitor.countdownPhrase(until: event.startDate), event.location]
                    .compactMap { $0 }
                    .joined(separator: " · "))
                    .font(.system(size: 10.5))
                    .foregroundColor(WispColor.Island.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func liveActivityStopButton(tooltip: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 4) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 8, weight: .bold))
                Text("Stop")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(WispColor.Island.textPrimary)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule(style: .continuous).fill(WispColor.Island.controlFill))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableScaleButtonStyle())
        .pointerCursor()
        .nativeTooltip(tooltip)
    }

    // MARK: - Morning briefing, new results, quiet mode

    private var morningBannerTitle: String {
        let suggestionCount = morningBriefing.pendingSuggestions.count
        return suggestionCount == 1
            ? "I can do 1 thing for you today"
            : "I can do \(suggestionCount) things for you today"
    }

    /// The banner the notch drops once a day: the mark on the left, the offer
    /// and its two buttons on the right. Show me swaps the compact surface for
    /// the full panel, whose TODAY list holds the suggestions.
    private var morningBannerContent: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(WispGradient.signature)
                    .opacity(0.22)
                    .blur(radius: 8)
                WispMark(state: .thinking, size: 30)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(morningBannerTitle)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(WispColor.Island.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text("Pick what you'd like me to take on.")
                        .font(.system(size: 11))
                        .foregroundColor(WispColor.Island.textSecondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Button("Dismiss") {
                        dismissMorningBriefing()
                    }
                    .font(.system(size: 11, weight: .medium))
                    .wispIslandButtonStyle(prominence: .subtle)
                    .nativeTooltip("Skip today's suggestions")

                    Button {
                        viewModel.isFullPanel = true
                    } label: {
                        Label("Show me", systemImage: "lightbulb.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .wispIslandButtonStyle(prominence: .prominent)
                    .nativeTooltip("See what Wisp can take on today")
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func dismissMorningBriefing() {
        morningBriefing.dismiss()
        // Nothing left to show, so the notch goes back to being the notch.
        NotificationCenter.default.post(name: .wispDismissPanel, object: nil)
    }

    /// "2 new" in the right flank: background results waiting to be seen.
    private func flankUnseenResultsBadge(count: Int) -> some View {
        Text("\(count) new")
            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            .foregroundColor(WispColor.Island.textPrimary)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Capsule(style: .continuous).fill(WispColor.Brand.lavender.opacity(0.35)))
            .lineLimit(1)
            .nativeTooltip(count == 1
                ? "A background task finished — hover to see it"
                : "\(count) background tasks finished — hover to see them")
    }

    /// "✦ 5" in the right flank: the day's suggestions, tucked away after the
    /// banner was left alone.
    private func flankMorningSuggestionsCount(_ suggestionCount: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(WispColor.Brand.lavender)
            Text("\(suggestionCount)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundColor(WispColor.Island.textSecondary)
        }
        .nativeTooltip("Wisp has \(suggestionCount) suggestions for today — hover to see them")
    }

    /// A moon in the panel header while quiet mode holds announcements back.
    private func quietModeIndicator(_ quietReason: QuietModeReason) -> some View {
        Image(systemName: "moon.fill")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(WispColor.Brand.lavender)
            .frame(width: 22, height: 22)
            .nativeTooltip("\(quietReason.summary), so Wisp is keeping quiet. Finished tasks wait here instead of notifying you.")
    }

    /// NEW: background results that finished since the panel was last opened.
    /// Closing the panel marks them seen (see `NotchWindowController`).
    @ViewBuilder
    private var finishedWorkSection: some View {
        let unseenRecords = finishedWorkInbox.unseenRecords(in: taskRegistry)
        if !unseenRecords.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("NEW")
                ForEach(unseenRecords) { finishedRecord in
                    finishedWorkRow(finishedRecord)
                }
            }
        }
    }

    private func finishedWorkRow(_ finishedRecord: AgentTaskRecord) -> some View {
        let didSucceed = finishedRecord.status == .succeeded
        let resultLine = didSucceed
            ? AnswerDisplayText.cleaned(finishedRecord.finalText ?? "Done")
            : "Didn't finish — see History for details"
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: didSucceed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(didSucceed ? DS.Colors.success : DS.Colors.destructive)
                .frame(width: 12)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(finishedRecord.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(WispColor.Island.textPrimary)
                    .lineLimit(1)
                Text(resultLine)
                    .font(.system(size: 11))
                    .foregroundColor(WispColor.Island.textSecondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(WispColor.Brand.lavender.opacity(0.10))
        )
    }

    /// TODAY: the morning briefing's suggestions, one click each, with a way to
    /// dismiss the rest.
    @ViewBuilder
    private var todaySuggestionsSection: some View {
        if morningBriefing.hasPendingBriefing {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    sectionLabel("TODAY")
                    Spacer(minLength: 0)
                    Button {
                        morningBriefing.dismiss()
                    } label: {
                        Text("Dismiss")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(WispColor.Island.textTertiary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .nativeTooltip("Skip the rest of today's suggestions")
                }
                ForEach(morningBriefing.pendingSuggestions) { suggestion in
                    morningSuggestionRow(suggestion)
                }
            }
        }
    }

    private func morningSuggestionRow(_ suggestion: MorningSuggestion) -> some View {
        Button {
            morningBriefing.perform(suggestion, companionManager: companionManager)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: suggestion.symbolName)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(WispColor.Brand.lavender)
                    .frame(width: 14)
                Text(suggestion.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(WispColor.Island.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(WispColor.Island.textTertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(WispColor.Island.controlFill)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(PressableScaleButtonStyle())
        .pointerCursor()
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
            notchLeftFlank
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
                    .foregroundColor(WispColor.Island.textSecondary)
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
        if isExecutingBrowserTask {
            // Steps taken so far; the ring spins because the total isn't known.
            flankActivityLabel("\(max(companionManager.browserTaskStepCount, 1))")
                .nativeTooltip(companionManager.browserActivityText)
        } else {
            switch companionManager.voiceState {
            case .listening, .responding:
                collapsedMicroWaveform
            case .processing:
                collapsedThinkingDots
            case .idle:
                // Most time-sensitive first: a meeting about to start, then
                // results waiting to be seen, then the day's suggestions.
                if let imminentEvent = upcomingEventMonitor.imminentEvent {
                    flankEventCountdown(imminentEvent)
                        .nativeTooltip(imminentEvent.title)
                } else if !finishedWorkInbox.unseenTaskIDs.isEmpty {
                    flankUnseenResultsBadge(count: finishedWorkInbox.unseenTaskIDs.count)
                } else if morningBriefing.hasPendingBriefing {
                    flankMorningSuggestionsCount(morningBriefing.pendingSuggestions.count)
                } else {
                    stateDot
                }
            }
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
            return collapsedReplySnippet ?? ambientSummaryText
        }
    }

    /// The non-notch pill's line while idle with nothing to preview: the meeting
    /// about to start, else how much background work is running.
    private var ambientSummaryText: String? {
        if let imminentEvent = upcomingEventMonitor.imminentEvent {
            let countdownText = UpcomingEventMonitor.compactCountdownText(until: imminentEvent.startDate)
            return "\(imminentEvent.title) · \(countdownText)"
        }
        let runningCount = runningBackgroundTasks.count
        if runningCount > 0 {
            return runningCount == 1 ? "1 task running" : "\(runningCount) tasks running"
        }
        let unseenCount = finishedWorkInbox.unseenTaskIDs.count
        if unseenCount > 0 {
            return unseenCount == 1 ? "1 new result" : "\(unseenCount) new results"
        }
        if morningBriefing.hasPendingBriefing {
            return morningBannerTitle
        }
        return nil
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
    /// the cutout. A little wider when a flank carries a label ("4", "12m")
    /// rather than a lone glyph, so the text isn't crowded against the notch.
    private var notchWrapSideExtension: CGFloat {
        isShowingFlankLabel ? 58 : 44
    }

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
        return state.isActive ? state.accent : WispColor.Island.textTertiary
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
                // Everything between the header and the footer scrolls once it
                // outgrows the fixed window (an answer + live activity + the
                // day's suggestions can), so the footer — with Chat and Manage —
                // always stays reachable.
                ScrollView {
                    quickPanelScrollingSections
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(key: QuickPanelSectionsHeightKey.self, value: proxy.size.height)
                            }
                        )
                }
                .scrollIndicators(.never)
                .frame(height: min(max(quickPanelSectionsHeight, 1), quickPanelSectionsMaxHeight))
                .onPreferenceChange(QuickPanelSectionsHeightKey.self) { measuredHeight in
                    quickPanelSectionsHeight = measuredHeight
                }

                footer
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The tallest the quick panel's middle may grow: the window's height less
    /// the header band, the footer row and the padding around them.
    private var quickPanelSectionsMaxHeight: CGFloat {
        let headerHeight = viewModel.hasNotch ? notchContentTopInset : 36
        let footerRowHeight: CGFloat = 28
        let paddingAndSpacing: CGFloat = 14 * 2 + 10
        return viewModel.expandedSize.height - headerHeight - footerRowHeight - paddingAndSpacing
    }

    private var quickPanelScrollingSections: some View {
            VStack(alignment: .leading, spacing: 10) {
                // What's in flight right now, with a way to stop it.
                liveActivitySection

                // Background results that finished since the user last looked.
                finishedWorkSection

                // The day's suggestions, until run or dismissed.
                todaySuggestionsSection

                // Only present when there is an answer, so an idle panel collapses
                // down to just the header and footer.
                if hasAnswer {
                    answerSurfaceWithReplyActions
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Whether the current turn has anything to show — reply text or a glance
    /// card. Drives the panel's two layouts.
    private var hasAnswer: Bool {
        let hasReply = !companionManager.currentReplyText
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasReply || companionManager.resolvedGlanceCard != nil
    }

    // MARK: Answer surface (reply + glance card)

    /// The tallest the answer region may grow before it starts scrolling
    /// internally, keeping the whole panel inside the fixed window. A glance
    /// card gets more room: cards are laid out to be seen whole (the weather
    /// card's hourly row sat below the fold at the text-only limit), and the
    /// quick panel's middle sections scroll if other sections need space too.
    private var answerMaxHeight: CGFloat {
        companionManager.resolvedGlanceCard == nil ? 206 : 296
    }

    private var answerSurface: some View {
        let hasReply = !companionManager.currentReplyText
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if hasReply {
                    Text(companionManager.currentReplyText)
                        .font(.system(size: 12.5))
                        .foregroundColor(WispColor.Island.textPrimary)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Icon-only buttons (the tooltips name them), so the row reads as a quiet
    /// strip under the answer rather than a second block of text.
    private var replyActionRow: some View {
        HStack(spacing: 4) {
            replyActionButton(
                .copy,
                title: "",
                systemImageName: replyActionFeedback == .copied ? "checkmark" : "doc.on.doc",
                tooltip: "Copy this answer to the clipboard",
                isEnabled: true
            ) {
                copyReplyToClipboard()
            }

            let insertTargetAppName = insertTargetApplicationName
            replyActionButton(
                .insert,
                title: "",
                systemImageName: insertButtonSymbolName,
                tooltip: insertTargetAppName.map { "Type this answer at the cursor in \($0)" }
                    ?? "Click into a text field in another app first",
                isEnabled: insertTargetAppName != nil
            ) {
                insertReplyIntoFrontmostApp()
            }

            replyActionButton(
                .followUp,
                title: "",
                systemImageName: "arrowshape.turn.up.left",
                tooltip: "Ask a follow-up — Wisp keeps this conversation's context",
                isEnabled: true
            ) {
                companionManager.beginFollowUpQuestion()
            }

            replyActionButton(
                .openWindow,
                title: "",
                systemImageName: "arrow.up.left.and.arrow.down.right",
                tooltip: "Open the conversation in a window — the whole thread, follow-ups and running tasks",
                isEnabled: true
            ) {
                companionManager.openConversationWindow()
            }
        }
    }

    private var insertButtonSymbolName: String {
        switch replyActionFeedback {
        case .inserted: return "checkmark"
        case .insertFailed: return "exclamationmark.triangle"
        default: return "text.insert"
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
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
            }
            .foregroundColor(isEnabled ? WispColor.Island.textPrimary : WispColor.Island.textTertiary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(
                Capsule(style: .continuous)
                    .fill(isHovered ? WispColor.Island.controlFillHovered : WispColor.Island.controlFill)
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
                // The state rides beside the name while Wisp is doing something
                // (the mark's motion carries it too) — this replaced the big
                // waveform card that used to open the panel.
                Text(companionManager.islandState.isActive ? companionManager.islandState.label : "Wisp")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(WispColor.Island.textPrimary)
                    .lineLimit(1)
                    .animation(.easeInOut(duration: 0.2), value: companionManager.islandState.label)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 14)

            // Reserve the physical notch's width so the header only ever flanks it
            // (zero on a non-notch Mac, where the two clusters simply split the row).
            Color.clear.frame(width: viewModel.hasNotch ? viewModel.collapsedSize.width : 0)

            HStack(spacing: 3) {
                if let activeQuietReason = quietModeMonitor.activeQuietReason {
                    quietModeIndicator(activeQuietReason)
                }
                soundCuesToggle
                voiceOutputToggle
                Button {
                    WispWindowNavigator.open(.general)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(WispColor.Island.textSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .nativeTooltip("Settings")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 12)
        }
        .frame(height: viewModel.hasNotch ? notchContentTopInset : 36)
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
                .foregroundColor(areSoundsOn ? WispColor.Island.textPrimary : WispColor.Island.textTertiary)
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
                .foregroundColor(isVoiceOn ? WispColor.Island.textPrimary : WispColor.Island.textTertiary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .nativeTooltip(isVoiceOn
            ? "Voice mode — replies are spoken. Click for silent mode."
            : "Silent mode — replies show here only. Click to enable voice.")
    }

    // MARK: Footer

    /// A single quiet row: Chat (the notch workspace) and Open Wisp (the window),
    /// right-aligned. The integrations count and cursor-dock toggle that used to
    /// sit here live in the dashboard (Connections, Cursor).
    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button {
                viewModel.requestWorkspacePage?(.chat)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text("Chat")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(WispColor.Island.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(WispColor.Island.controlFill)
                )
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .nativeTooltip("Open the chat in the notch — your conversations, talk or type")
            Button {
                WispWindowNavigator.open(.home)
            } label: {
                Text("Open Wisp")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(WispColor.Island.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(WispColor.Island.controlFill)
                    )
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .nativeTooltip("Open the Wisp window — today, buddies, routines, history and settings")
        }
    }

    // MARK: Shared bits

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(WispColor.Island.textTertiary)
            .tracking(0.6)
    }
}

/// The actions on the notch reply row.
private enum ReplyAction {
    case copy
    case insert
    case followUp
    case openWindow
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

/// Carries the quick panel's middle sections' natural height up to
/// `NotchHUDView`, the same way `AnswerContentHeightKey` does for the answer.
private struct QuickPanelSectionsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
