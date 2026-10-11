//
//  WispWindowView.swift
//  leanring-buddy
//
//  The Wisp window's shell: a native sidebar split view. The sidebar lists the
//  sections (see `WispNavigation.swift`); a section with several pages switches
//  between them with a segmented control in the window toolbar, the way System
//  Settings-era Mac apps do, instead of the custom pill tabs the old dashboard
//  drew in its own header.
//
//  The look is deliberately stock macOS — system sidebar, unified toolbar,
//  semantic colours that follow light/dark — with Wisp's colours used only as
//  the accent. Each page is an existing view (`HomeTab`, `RoutinesTab`, …), so
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

    private var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 8)),
            removal: .opacity
        )
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
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
                .navigationTitle(router.selectedSection.title)
                .toolbar {
                    if router.selectedSection.pages.count > 1 {
                        ToolbarItem(placement: .principal) {
                            pagePicker
                        }
                    }
                }
        }
        .tint(WispColor.accentText)
    }

    // MARK: - Sidebar

    private var sidebarSelection: Binding<WispSection?> {
        Binding(
            get: { router.selectedSection },
            set: { newSection in
                if let newSection { router.select(newSection) }
            }
        )
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section {
                ForEach(WispSection.useSections) { section in
                    sidebarRow(section)
                }
            }
            Section("Manage") {
                ForEach(WispSection.manageSections) { section in
                    sidebarRow(section)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            WispWindowStatusFooter(companionManager: companionManager)
        }
    }

    @ViewBuilder
    private func sidebarRow(_ section: WispSection) -> some View {
        let badgeCount = sidebarBadgeCount(for: section)
        Label(section.title, systemImage: section.symbolName)
            .badge(badgeCount)
            .tag(section)
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

    // MARK: - Toolbar

    private var pagePickerSelection: Binding<WispPage> {
        Binding(
            get: { router.selectedPage },
            set: { router.select($0) }
        )
    }

    private var pagePicker: some View {
        Picker("Page", selection: pagePickerSelection) {
            ForEach(router.selectedSection.pages) { page in
                Text(page.title).tag(page)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
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
        case .yourData:
            PersonalContextPage()
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

/// The sidebar's footer: Wisp itself, alive — the mark moves with what Wisp
/// is doing (listening, thinking, acting) and the line under it says so —
/// plus which model is answering and whether it's warm. It replaced the old
/// dashboard's memory gauge, which sat at 95%+ red on any Mac with a local
/// model loaded and read as an alarm; the full memory readout lives in
/// Settings → Model.
private struct WispWindowStatusFooter: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var stackReadout = ActiveStackReadout.shared

    var body: some View {
        let islandState = companionManager.islandState
        HStack(spacing: 10) {
            WispMark(state: islandState.markState, size: 26)
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(islandState.isActive ? WispColor.intelligence.opacity(0.18) : WispColor.accentSubtle)
                )
                .animation(WispMotion.smooth, value: islandState.isActive)
            VStack(alignment: .leading, spacing: 1) {
                Text(companionManager.isListeningPaused ? "Listening paused" : islandState.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.opacity)
                    .animation(WispMotion.smooth, value: islandState.label)
                HStack(spacing: 5) {
                    Circle()
                        .fill(residencyColor)
                        .frame(width: 6, height: 6)
                    Text(stackReadout.chatModelName)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .nativeTooltip(stackReadout.isEntirelyLocal ? "Running on this Mac" : "Uses a cloud service")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .onAppear { stackReadout.startPolling() }
        .onDisappear { stackReadout.stopPolling() }
    }

    private var residencyColor: Color {
        switch stackReadout.residency {
        case .resident: return WispColor.success
        case .notLoaded: return WispColor.warning
        case .unreachable: return WispColor.destructive
        }
    }
}
