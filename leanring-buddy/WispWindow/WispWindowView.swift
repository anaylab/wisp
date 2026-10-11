//
//  WispWindowView.swift
//  leanring-buddy
//
//  The Wisp window's shell. There is no sidebar: a slim bar along the top holds
//  the eight sections as icons — the open one expands to show its name and
//  slides to the next as you move — with Wisp's own state and model at the far
//  end, and a section with several pages gets a quiet segmented strip beneath
//  it. That gives every page the full width, which the Buddies messenger and
//  the Brain graph both want.
//
//  The window is full-size-content with a transparent title bar, so the bar sits
//  where the title bar would, beside the traffic lights, and doubles as the drag
//  handle. Each page is an existing view (`HomeTab`, `RoutinesTab`, …), so
//  moving a page between sections never touches its code.
//

import SwiftUI

struct WispWindowView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var taskRegistry: AgentTaskRegistry
    @ObservedObject var metricsRecorder: PerfMetricsRecorder
    @ObservedObject var router: WispWindowRouter
    @ObservedObject private var buddyStore = BuddyStore.shared
    @ObservedObject private var brainIngestQueue = BrainIngestQueue.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var sectionTabNamespace
    @Namespace private var pageTabNamespace

    private var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 8)),
            removal: .opacity
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if router.selectedSection.pages.count > 1 {
                pageStrip
                    .transition(.opacity)
            }
            // Each page gets its own identity so switching pages crossfades
            // with a small lift instead of swapping in place.
            ZStack {
                pageContent(router.selectedPage)
                    .id(router.selectedPage)
                    .transition(pageTransition)
            }
            .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.9), value: router.selectedPage)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WispColor.windowBackground)
        }
        .background(WispColor.windowBackground)
        .animation(reduceMotion ? nil : WispMotion.smooth, value: router.selectedSection)
        .tint(WispColor.accentText)
        .ignoresSafeArea(.container, edges: .top)
    }

    // MARK: - Top bar

    /// Room for the traffic lights, which sit over the bar's leading edge.
    private let trafficLightsInset: CGFloat = 78
    static let topBarHeight: CGFloat = 46

    private var topBar: some View {
        HStack(spacing: 12) {
            Spacer().frame(width: trafficLightsInset)

            HStack(spacing: 2) {
                ForEach(WispSection.allCases) { section in
                    sectionTab(section)
                }
            }

            Spacer(minLength: 8)

            WispWindowStatusPill(companionManager: companionManager)
        }
        .padding(.trailing, 16)
        .frame(height: Self.topBarHeight)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) {
            if router.selectedSection.pages.count <= 1 {
                Rectangle().fill(WispColor.cardSeparator.opacity(0.5)).frame(height: 0.5)
            }
        }
    }

    private func sectionTab(_ section: WispSection) -> some View {
        let isSelected = router.selectedSection == section
        let badge = sidebarBadgeCount(for: section)
        return Button {
            router.select(section)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: section.symbolName)
                    .font(.system(size: 13, weight: .medium))
                if isSelected {
                    Text(section.title)
                        .font(.system(size: 12, weight: .semibold))
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                }
            }
            .foregroundStyle(isSelected ? WispColor.textPrimary : WispColor.textSecondary)
            .padding(.horizontal, isSelected ? 12 : 10)
            .frame(height: 30)
            .background {
                if isSelected {
                    Color.clear
                        .wispBevel(Capsule(style: .continuous), fill: WispColor.surface3)
                        .matchedGeometryEffect(id: "sectionTab", in: sectionTabNamespace)
                }
            }
            .overlay(alignment: .topTrailing) {
                if badge > 0 && !isSelected {
                    Circle()
                        .fill(section == .settings ? WispColor.warning : WispColor.accentText)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(WispColor.windowBackground, lineWidth: 1.5))
                        .offset(x: -2, y: 3)
                        .transition(.scale)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel(section.title)
        .nativeTooltip(isSelected ? nil : section.title)
    }

    /// Running work shows where the user would go to see it.
    private func sidebarBadgeCount(for section: WispSection) -> Int {
        switch section {
        case .history:
            return taskRegistry.runningRecords.count
        case .buddies:
            // Working, or finished with something the user hasn't read.
            return buddyStore.buddiesNeedingAttentionCount(in: taskRegistry)
        case .brain:
            // Things still being read into the brain.
            return brainIngestQueue.pendingJobCount
        case .settings:
            return companionManager.allPermissionsGranted ? 0 : 1
        default:
            return 0
        }
    }

    // MARK: - Page strip

    private var pageStrip: some View {
        HStack(spacing: 2) {
            ForEach(router.selectedSection.pages) { page in
                let isSelected = router.selectedPage == page
                Button {
                    router.select(page)
                } label: {
                    Text(page.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? WispColor.textPrimary : WispColor.textSecondary)
                        .padding(.horizontal, 11)
                        .frame(height: 26)
                        .background {
                            if isSelected {
                                Color.clear
                                    .wispBevel(RoundedRectangle(cornerRadius: 8, style: .continuous), fill: WispColor.surface3)
                                    .matchedGeometryEffect(id: "pageTab", in: pageTabNamespace)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(WispColor.cardSeparator.opacity(0.5)).frame(height: 0.5)
        }
        .animation(reduceMotion ? nil : WispMotion.smooth, value: router.selectedPage)
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
private struct WindowDragArea: NSViewRepresentable {
    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
