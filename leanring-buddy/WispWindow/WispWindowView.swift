//
//  WispWindowView.swift
//  leanring-buddy
//
//  The Wisp window's shell, laid out like HeyClicky: a sidebar down the left
//  (`WispSidebar` — a rail of buddy characters that opens into a list, Wisp's
//  mark to go home, a few destinations, Settings last) and the open page beside
//  it, with Wisp's own state and model in a slim strip along the top.
//
//  The window is full-size-content with a transparent title bar, so the sidebar
//  runs to the top with the traffic lights over its first row, and the top strip
//  doubles as the drag handle. Each page is an existing view (`HomeTab`,
//  `RoutinesTab`, …), so moving a page between sections never touches its code.
//

import SwiftUI

struct WispWindowView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var taskRegistry: AgentTaskRegistry
    @ObservedObject var metricsRecorder: PerfMetricsRecorder
    @ObservedObject var router: WispWindowRouter
    @ObservedObject private var advancedFeatures = WispAdvancedFeaturesPreference.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 8)),
            removal: .opacity
        )
    }

    var body: some View {
        // The themed backdrop supplies the window's base colour and the glass
        // container lets cards and pills refract it, so the shell itself paints
        // no opaque background of its own.
        WispThemedWindowSurface {
            HStack(spacing: 0) {
                WispSidebar(companionManager: companionManager, taskRegistry: taskRegistry, router: router)

                VStack(spacing: 0) {
                    contentTopBar
                    // Each page gets its own identity so switching pages crossfades
                    // with a small lift instead of swapping in place.
                    ZStack {
                        pageContent(router.selectedPage)
                            .id(router.selectedPage)
                            .transition(pageTransition)
                    }
                    .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.9), value: router.selectedPage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .tint(WispColor.accentText)
        .ignoresSafeArea(.container, edges: .top)
        // Turning Advanced off while on a Brain page moves the window
        // to Settings instead of leaving a hidden page on screen.
        .onChange(of: advancedFeatures.isEnabled) { _, _ in
            router.reconcileWithAdvancedSetting()
        }
    }

    // MARK: - Content top bar

    /// Height of the strip along the top of the window, which the sidebar's own
    /// traffic-light row matches so the lights sit level with it.
    static let topBarHeight: CGFloat = 46

    /// Only Wisp's state and model, at the end, over the page. Navigation lives
    /// in the sidebar; this strip is also the window's drag handle.
    private var contentTopBar: some View {
        HStack {
            Spacer(minLength: 8)
            WispWindowStatusPill(companionManager: companionManager)
        }
        .padding(.horizontal, 16)
        .frame(height: Self.topBarHeight)
        .background(WindowDragArea())
    }

    // MARK: - Pages

    @ViewBuilder
    private func pageContent(_ page: WispPage) -> some View {
        switch page {
        case .home:
            HomeTab(
                taskRegistry: taskRegistry,
                companionManager: companionManager,
                onSelectPage: { router.select($0) }
            )
        case .chat:
            ChatPage(companionManager: companionManager, taskRegistry: taskRegistry)
        case .buddies:
            BuddiesPage(taskRegistry: taskRegistry)
        case .automations:
            AutomationsHubView()
        case .canvas:
            // The old Jobs page, kept whole: Canvas feed link, daily checklist
            // and study blocks. Automations the Planner buddy owns run on it.
            JobsTab()
        case .routines:
            RoutinesTab(companionManager: companionManager)
        case .timeline:
            HistoryTab(
                taskRegistry: taskRegistry,
                companionManager: companionManager,
                onSelectPage: { router.select($0) }
            )
        case .brainPages:
            BrainPagesPage()
        case .brainGraph:
            BrainGraphPage()
        case .brainInbox:
            BrainInboxPage()
        case .brainHealth:
            BrainHealthPage()
        case .brainLog:
            BrainLogPage()
        case .brainSettings:
            BrainSettingsPage()
        case .marketplace:
            MarketplaceTab()
        case .tools:
            ToolsTab()
        case .sources:
            SourcesTab()
        case .general:
            GeneralSettingsPage(companionManager: companionManager)
        case .shortcuts:
            ShortcutsTab()
        case .dictation:
            DictationTab()
        case .agent:
            AgentTab(companionManager: companionManager)
        case .model:
            PerformanceTab(metricsRecorder: metricsRecorder, companionManager: companionManager)
        }
    }
}

/// Wisp itself, alive, at the end of the top bar: the mark moves with what Wisp
/// is doing (listening, thinking, acting) and the line beside it says so, then
/// which model is answering and whether it's warm. Collapses to the mark alone
/// when the window is narrow.
private struct WispWindowStatusPill: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var stackReadout = ActiveStackReadout.shared

    var body: some View {
        let islandState = companionManager.islandState
        ViewThatFits(in: .horizontal) {
            pill(islandState: islandState, showsDetail: true)
            pill(islandState: islandState, showsDetail: false)
        }
        .onAppear { stackReadout.startPolling() }
        .onDisappear { stackReadout.stopPolling() }
        .nativeTooltip(stackReadout.isEntirelyLocal ? "Running on this Mac" : "Uses a cloud service")
    }

    private func pill(islandState: WispIslandState, showsDetail: Bool) -> some View {
        HStack(spacing: 8) {
            WispMark(state: islandState.markState, size: 18)
                .frame(width: 20, height: 20)
            if showsDetail {
                Text(companionManager.isListeningPaused ? "Listening paused" : islandState.label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(WispColor.textPrimary)
                    .contentTransition(.opacity)
                    .animation(WispMotion.smooth, value: islandState.label)
                HStack(spacing: 5) {
                    Circle().fill(residencyColor).frame(width: 6, height: 6)
                    Text(stackReadout.chatModelName)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(WispColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .wispBevel(Capsule(style: .continuous), fill: WispColor.surface2)
    }

    private var residencyColor: Color {
        // Ollama's residency says nothing about a cloud model.
        guard stackReadout.isChatModelLocal else { return WispColor.success }
        switch stackReadout.residency {
        case .resident: return WispColor.success
        case .notLoaded: return WispColor.warning
        case .unreachable: return WispColor.destructive
        }
    }
}

/// A transparent strip that moves the window when dragged. The title bar is
/// transparent and the top bar sits in it, so this is what makes the bar behave
/// like one.
struct WindowDragArea: NSViewRepresentable {
    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
