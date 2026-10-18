//
//  WispSidebar.swift
//  leanring-buddy
//
//  The Wisp window's navigation, laid out like HeyClicky: a narrow rail of
//  living buddy characters down the left that opens into a wider list (name and
//  what each is doing) with one tap, Wisp's mark at the top to go home, search and
//  "+" beneath it, a few quiet destinations at the bottom, and Settings last.
//  Settings, and the Brain and Connections pages when Advanced is on, swap the
//  list for a Back button and their own pages, so there is never a second strip
//  of tabs competing with the sidebar.
//
//  The rail is the only place buddies are listed: the Buddies page shows just the
//  selected buddy's chat and inspector, and the context-menu confirmations
//  (clear conversation, delete) live here so they work from any page.
//

import SwiftUI

struct WispSidebar: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var taskRegistry: AgentTaskRegistry
    @ObservedObject var router: WispWindowRouter
    @ObservedObject private var buddyStore = BuddyStore.shared
    @ObservedObject private var advancedFeatures = WispAdvancedFeaturesPreference.shared
    @ObservedObject private var jobsEngine = JobsEngine.shared
    @ObservedObject private var automationEngine = AutomationEngine.shared
    @ObservedObject private var brainIngestQueue = BrainIngestQueue.shared

    @AppStorage("WispWindowSidebarExpanded") private var isExpanded = true
    @State private var searchText = ""
    @State private var isSearchFieldFocusRequested = false
    @FocusState private var isSearchFocused: Bool
    /// Lets the one selection highlight morph from row to row as a single glass shape.
    @Namespace private var selectionNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let railWidth: CGFloat = 84
    static let expandedWidth: CGFloat = 264

    private var width: CGFloat { isExpanded ? Self.expandedWidth : Self.railWidth }

    /// Sections that replace the buddy list with their own pages and a Back button.
    private var pageListSection: WispSection? {
        let section = router.selectedSection
        return [.settings, .brain, .connections].contains(section) ? section : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Room for the traffic lights; also a drag handle for the window.
            Color.clear
                .frame(height: WispWindowView.topBarHeight)
                .background(WindowDragArea())
                .overlay(alignment: .trailing) {
                    // Expanded, "+" sits on the traffic-light line like a messenger's compose button.
                    if isExpanded && pageListSection == nil {
                        newMenu.padding(.trailing, 14)
                    }
                }

            if let pageListSection {
                pageList(for: pageListSection)
                    .transition(.opacity)
            } else {
                mainList
                    .transition(.opacity)
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(WispColor.groupedCardBackground)
        .overlay(alignment: .trailing) {
            Rectangle().fill(WispColor.cardSeparator.opacity(0.5)).frame(width: 0.5)
        }
        .background(shortcutButtons)
        .animation(reduceMotion ? nil : WispMotion.island, value: isExpanded)
        .animation(reduceMotion ? nil : WispMotion.smooth, value: pageListSection)
        .confirmationDialog(
            "Clear \(buddyName(router.buddyIDPendingClear))'s conversation?",
            isPresented: isPresentedBinding($router.buddyIDPendingClear)
        ) {
            Button("Clear Conversation", role: .destructive) {
                if let buddyID = router.buddyIDPendingClear { buddyStore.clearConversation(ofBuddyWithID: buddyID) }
            }
        } message: {
            Text("It starts fresh. Mission, notes, files and settings stay.")
        }
        .confirmationDialog(
            "Delete \(buddyName(router.buddyIDPendingDeletion))?",
            isPresented: isPresentedBinding($router.buddyIDPendingDeletion)
        ) {
            Button("Delete", role: .destructive) {
                if let buddyID = router.buddyIDPendingDeletion { buddyStore.deleteBuddy(withID: buddyID) }
            }
        } message: {
            Text("Its thread, notes and files are removed. Its runs stay in History.")
        }
    }

    // MARK: - Main list

    private var mainList: some View {
        VStack(spacing: 0) {
            if !isExpanded { header }
            controls
            buddyList
            destinations
            footer
        }
        // One value for "what is selected", so the highlight glides to the new row.
        .animation(reduceMotion ? nil : WispMotion.morph, value: selectionKey)
    }

    private var selectionKey: String {
        "\(router.selectedPage.rawValue)-\(router.activeBuddyID?.uuidString ?? "none")"
    }

    /// Wisp's mark goes home. Expanded, it names itself beside the mark.
    private var header: some View {
        HStack(spacing: 10) {
            Button {
                router.select(WispPage.home)
            } label: {
                WispMark(state: companionManager.islandState.markState, size: 22)
                    .frame(width: 44, height: 34)
                    .background { selectionBackground(isSelected: router.selectedPage == .home, cornerRadius: 10, horizontalInset: 0) }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("Today")
            .nativeTooltip("Today")

            if isExpanded {
                Text("Wisp")
                    .font(WispFont.headline)
                    .foregroundStyle(WispColor.textPrimary)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, isExpanded ? 16 : 0)
        .frame(maxWidth: .infinity, alignment: isExpanded ? .leading : .center)
        .padding(.bottom, 8)
    }

    /// Collapse toggle, search (expanded) and the new-buddy / new-automation menu.
    private var controls: some View {
        let toggle = iconButton("sidebar.left", label: isExpanded ? "Collapse sidebar" : "Expand sidebar") {
            isExpanded.toggle()
        }
        let searchIcon = iconButton("magnifyingglass", label: "Search buddies") {
            isExpanded = true
            isSearchFocused = true
        }
        return Group {
            if isExpanded {
                HStack(spacing: 8) {
                    toggle
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(WispColor.textTertiary)
                        TextField("Search", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .focused($isSearchFocused)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Capsule(style: .continuous).fill(WispColor.surface3.opacity(0.7)))
                }
                .padding(.horizontal, 12)
            } else {
                VStack(spacing: 6) {
                    toggle
                    searchIcon
                    newMenu
                }
            }
        }
        .padding(.bottom, 10)
    }

    private var newMenu: some View {
        Menu {
            Button("New Buddy") { requestNewBuddy() }
            Button("New Automation") { router.presentNewAutomation() }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(WispColor.textSecondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(WispColor.surface3.opacity(0.7)))
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .pointerCursor()
        .accessibilityLabel("New")
        .nativeTooltip("New buddy or automation (⌘N)")
    }

    private var visibleBuddies: [WispBuddy] {
        let orderedBuddies = buddyStore.orderedBuddies(in: taskRegistry)
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmedSearch.isEmpty else { return orderedBuddies }
        return orderedBuddies.filter { $0.name.localizedCaseInsensitiveContains(trimmedSearch) }
    }

    private var buddyList: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: isExpanded ? 2 : 6) {
                ForEach(visibleBuddies) { buddy in
                    WispSidebarBuddyRow(
                        buddy: buddy,
                        statusText: buddyStatusText(buddy),
                        timeText: buddyLatestTimeText(buddy),
                        isExpanded: isExpanded,
                        isSelected: router.selectedPage == .buddies && router.activeBuddyID == buddy.id,
                        selectionNamespace: selectionNamespace,
                        onSelect: { openBuddy(buddy.id) }
                    )
                    .contextMenu {
                        BuddyActionsMenuItems(
                            buddy: buddy,
                            isRunning: buddyStore.isRunning(buddy, in: taskRegistry),
                            showsReadState: true,
                            onDuplicated: openBuddy,
                            onRequestClearConversation: { router.buddyIDPendingClear = buddy.id },
                            onRequestDeletion: { router.buddyIDPendingDeletion = buddy.id }
                        )
                    }
                }
            }
            .padding(.horizontal, isExpanded ? 12 : 0)
            .padding(.vertical, 4)
            .animation(reduceMotion ? nil : WispMotion.island, value: visibleBuddies.map(\.id))
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Destinations and footer

    private struct Destination: Identifiable {
        let page: WispPage
        let symbolName: String
        let title: String
        var id: WispPage { page }
    }

    /// The few places that are not a buddy. Advanced adds the rest of the
    /// old sections; with it off they are Settings pages.
    private var destinations: some View {
        var items = [
            Destination(page: .home, symbolName: "sun.max", title: "Today"),
            Destination(page: .chat, symbolName: "bubble.left.and.bubble.right", title: "Chat"),
            Destination(page: .automations, symbolName: "bolt", title: "Automations"),
            Destination(page: .canvas, symbolName: "graduationcap", title: "Canvas"),
        ]
        if advancedFeatures.isEnabled {
            items += [
                Destination(page: .brainPages, symbolName: "brain", title: "Brain"),
                Destination(page: .routines, symbolName: "bolt.circle", title: "Routines"),
                Destination(page: .timeline, symbolName: "clock.arrow.circlepath", title: "History"),
                Destination(page: .marketplace, symbolName: "powerplug", title: "Connections"),
            ]
        }
        return VStack(spacing: 2) {
            Rectangle().fill(WispColor.cardSeparator.opacity(0.5)).frame(height: 0.5)
                .padding(.horizontal, isExpanded ? 16 : 20)
                .padding(.bottom, 6)
            ForEach(items) { item in
                destinationRow(item)
            }
        }
        .padding(.horizontal, isExpanded ? 12 : 0)
        .padding(.vertical, 8)
    }

    private func destinationRow(_ item: Destination) -> some View {
        let isSelected = router.selectedPage == item.page
            || (item.page == .brainPages && router.selectedSection == .brain)
            || (item.page == .marketplace && router.selectedSection == .connections)
        let needsAttention = needsAttention(for: item.page)
        return Button {
            router.select(item.page)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbolName)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 22)
                    .symbolEffect(.bounce, value: isSelected)
                if isExpanded {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(isSelected ? WispColor.textPrimary : WispColor.textSecondary)
            .padding(.horizontal, isExpanded ? 10 : 0)
            .frame(maxWidth: .infinity, alignment: isExpanded ? .leading : .center)
            .frame(height: 34)
            .background { selectionBackground(isSelected: isSelected, cornerRadius: 10, horizontalInset: isExpanded ? 0 : 20) }
            .overlay(alignment: .topTrailing) {
                if needsAttention && !isSelected {
                    Circle()
                        .fill(WispColor.accentText)
                        .frame(width: 7, height: 7)
                        .padding(.top, 5)
                        .padding(.trailing, isExpanded ? 10 : 26)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel(item.title)
        .nativeTooltip(isExpanded ? nil : item.title)
    }

    /// Wisp's own state and the way to Settings, last.
    private var footer: some View {
        let isSettingsAttention = !companionManager.allPermissionsGranted
        return VStack(spacing: 0) {
            Rectangle().fill(WispColor.cardSeparator.opacity(0.5)).frame(height: 0.5)
            HStack(spacing: 10) {
                if isExpanded {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(companionManager.isListeningPaused ? "Listening paused" : companionManager.islandState.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(WispColor.textPrimary)
                            .lineLimit(1)
                        Text(ActiveStackReadout.shared.chatModelName)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(WispColor.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                Button {
                    router.select(.settings)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(router.selectedSection == .settings ? WispColor.textPrimary : WispColor.textSecondary)
                        .frame(width: 34, height: 34)
                        .overlay(alignment: .topTrailing) {
                            if isSettingsAttention {
                                Circle().fill(WispColor.warning).frame(width: 7, height: 7).offset(x: -3, y: 4)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityLabel("Settings")
                .nativeTooltip("Settings  ⌥⌘4")
            }
            .padding(.horizontal, isExpanded ? 16 : 0)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
        }
    }

    // MARK: - Pages (Settings, Brain, Connections)

    private func pageList(for section: WispSection) -> some View {
        let pages = section.pages(advancedEnabled: advancedFeatures.isEnabled)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                router.select(WispPage.home)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    if isExpanded {
                        Text("Back")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .foregroundStyle(WispColor.textPrimary)
                .padding(.horizontal, isExpanded ? 12 : 0)
                .frame(width: isExpanded ? nil : 44, height: 30)
                .background(Capsule(style: .continuous).fill(WispColor.surface3.opacity(0.8)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("Back to Today")
            .padding(.horizontal, isExpanded ? 16 : 0)
            .frame(maxWidth: .infinity, alignment: isExpanded ? .leading : .center)

            if isExpanded {
                Text(section.title)
                    .font(WispFont.headline)
                    .foregroundStyle(WispColor.textPrimary)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 6)
            } else {
                Spacer().frame(height: 12)
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(pages) { page in
                        pageRow(page)
                    }
                }
                .padding(.horizontal, isExpanded ? 12 : 0)
            }

            Spacer(minLength: 0)
            footerToggle
        }
        .padding(.top, 4)
    }

    private func pageRow(_ page: WispPage) -> some View {
        let isSelected = router.selectedPage == page
        return Button {
            router.select(page)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: Self.symbolName(for: page))
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 22)
                if isExpanded {
                    Text(page.title)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(isSelected ? WispColor.textPrimary : WispColor.textSecondary)
            .padding(.horizontal, isExpanded ? 10 : 0)
            .frame(maxWidth: .infinity, alignment: isExpanded ? .leading : .center)
            .frame(height: 36)
            .background { selectionBackground(isSelected: isSelected, cornerRadius: 10, horizontalInset: isExpanded ? 0 : 20) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel(page.title)
        .nativeTooltip(isExpanded ? nil : page.title)
    }

    private var footerToggle: some View {
        HStack {
            iconButton("sidebar.left", label: isExpanded ? "Collapse sidebar" : "Expand sidebar") {
                isExpanded.toggle()
            }
        }
        .frame(maxWidth: .infinity, alignment: isExpanded ? .leading : .center)
        .padding(.horizontal, isExpanded ? 16 : 0)
        .padding(.vertical, 12)
    }

    private static func symbolName(for page: WispPage) -> String {
        switch page {
        case .home: return "sun.max"
        case .chat: return "bubble.left.and.bubble.right"
        case .buddies: return "person.2"
        case .automations: return "bolt"
        case .canvas: return "graduationcap"
        case .routines: return "bolt.circle"
        case .brainPages: return "doc.text"
        case .brainGraph: return "point.3.connected.trianglepath.dotted"
        case .brainInbox: return "tray"
        case .brainHealth: return "stethoscope"
        case .brainLog: return "list.bullet.rectangle"
        case .brainSettings: return "slider.horizontal.3"
        case .timeline: return "clock.arrow.circlepath"
        case .marketplace: return "square.grid.2x2"
        case .tools: return "wrench.and.screwdriver"
        case .sources: return "antenna.radiowaves.left.and.right"
        case .general: return "gearshape"
        case .shortcuts: return "command"
        case .dictation: return "textformat"
        case .agent: return "sparkles"
        case .model: return "cpu"
        }
    }

    // MARK: - Actions and helpers

    /// The selected row's background: one shape shared by every row, so choosing
    /// another row makes it glide across (`matchedGeometryEffect`) rather than blink out and in.
    @ViewBuilder
    private func selectionBackground(isSelected: Bool, cornerRadius: CGFloat, horizontalInset: CGFloat) -> some View {
        if isSelected {
            WispSidebarSelectionHighlight(namespace: selectionNamespace, cornerRadius: cornerRadius)
                .padding(.horizontal, horizontalInset)
        }
    }

    private func iconButton(_ symbolName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(WispColor.textSecondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel(label)
        .nativeTooltip(label)
    }

    private func openBuddy(_ buddyID: UUID) {
        router.isNewBuddyFormRequested = false
        router.buddyIDToOpen = buddyID
        router.select(WispPage.buddies)
    }

    private func requestNewBuddy() {
        router.isNewBuddyFormRequested = true
        router.select(WispPage.buddies)
    }

    /// "Working…", the start of its latest answer, or its schedule.
    private func buddyStatusText(_ buddy: WispBuddy) -> String {
        if buddyStore.isRunning(buddy, in: taskRegistry) {
            return "Working…"
        }
        if let latestRunRecord = buddyStore.latestRunRecord(of: buddy, in: taskRegistry),
           let latestAnswer = latestRunRecord.finalText,
           !latestAnswer.isEmpty {
            return AnswerDisplayText.cleaned(latestAnswer).replacingOccurrences(of: "\n", with: " ")
        }
        return buddy.schedule.summary()
    }

    /// When the buddy last did something, in the messenger's right-hand column.
    private func buddyLatestTimeText(_ buddy: WispBuddy) -> String? {
        buddyStore.latestRunRecord(of: buddy, in: taskRegistry).map { BuddyFormatting.timeText($0.startedAt) }
    }

    /// A dot beside a destination that has something waiting.
    private func needsAttention(for page: WispPage) -> Bool {
        switch page {
        case .automations:
            return automationEngine.needsYou.count > 0
        case .canvas:
            return jobsEngine.latestDiff != nil || !jobsEngine.pendingStudyBlocks.isEmpty
        case .brainPages:
            return brainIngestQueue.pendingJobCount > 0
        default:
            return false
        }
    }

    private func buddyName(_ buddyID: UUID?) -> String {
        buddyID.flatMap(buddyStore.buddy(withID:))?.name ?? "this buddy"
    }

    private func isPresentedBinding(_ pendingBuddyID: Binding<UUID?>) -> Binding<Bool> {
        Binding(
            get: { pendingBuddyID.wrappedValue != nil },
            set: { isPresented in if !isPresented { pendingBuddyID.wrappedValue = nil } }
        )
    }

    /// ⌥⌘1–4 open the sections, ⌘1–⌘9 the buddy at that position, ⌘N a new one.
    /// Invisible buttons, because SwiftUI only registers shortcuts on views.
    private var shortcutButtons: some View {
        let visibleSections = WispSection.visibleSections(advancedEnabled: advancedFeatures.isEnabled)
        let orderedBuddies = buddyStore.orderedBuddies(in: taskRegistry)
        return ZStack {
            ForEach(Array(visibleSections.enumerated()), id: \.element) { index, section in
                Button("") { router.select(section) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
            }
            ForEach(Array(orderedBuddies.prefix(9).enumerated()), id: \.element.id) { index, buddy in
                Button("") { openBuddy(buddy.id) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Button("") { requestNewBuddy() }
                .keyboardShortcut("n", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One buddy in the sidebar: its character alone in the rail, with its name and
/// what it is doing when the sidebar is open. A turning ring while it works and
/// an unread dot ride on the character as they did in the old rail.
private struct WispSidebarBuddyRow: View {
    let buddy: WispBuddy
    let statusText: String
    let timeText: String?
    let isExpanded: Bool
    let isSelected: Bool
    let selectionNamespace: Namespace.ID
    var onSelect: () -> Void

    @ObservedObject private var buddyStore = BuddyStore.shared
    @ObservedObject private var taskRegistry = AgentTaskRegistry.shared
    @State private var bounceCount = 0
    @State private var isHovering = false

    var body: some View {
        let mood = buddyStore.mood(of: buddy, in: taskRegistry)
        let isUnread = buddyStore.isUnread(buddy, in: taskRegistry)
        return Button {
            bounceCount += 1
            onSelect()
        } label: {
            HStack(spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    BuddyCharacter(
                        colorIndex: buddy.colorIndex,
                        size: isExpanded ? 44 : 46,
                        mood: mood,
                        liveliness: .full,
                        bounceTrigger: bounceCount,
                        looksAtPointer: true
                    )
                    .frame(width: isExpanded ? 54 : 56, height: isExpanded ? 54 : 56)

                    if isUnread && !isSelected && !isExpanded {
                        Circle()
                            .fill(BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex))
                            .frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(WispColor.windowBackground, lineWidth: 1.5))
                            .transition(.scale)
                    }
                }

                if isExpanded {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(buddy.name)
                                .font(.system(size: 14, weight: isUnread ? .bold : .semibold))
                                .foregroundStyle(WispColor.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            if let timeText {
                                Text(timeText)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(WispColor.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                        HStack(spacing: 6) {
                            Text(statusText)
                                .font(.system(size: 12.5))
                                .foregroundStyle(WispColor.textSecondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if isUnread && !isSelected {
                                Circle()
                                    .fill(BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex))
                                    .frame(width: 8, height: 8)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, isExpanded ? 8 : 0)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: isExpanded ? .leading : .center)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(WispColor.surface3.opacity(isHovering && !isSelected ? 0.55 : 0))
                    if isSelected {
                        WispSidebarSelectionHighlight(namespace: selectionNamespace, cornerRadius: 14)
                    }
                }
                .padding(.horizontal, isExpanded ? 0 : 12)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering = $0 }
        .onChange(of: mood) { _, newMood in
            // A finished run earns a squish, in the buddy's own measure, and only
            // while Playful is on.
            let celebrationLevel = buddy.personality?.reaction.celebrationLevel ?? 1
            if newMood == .happy, celebrationLevel > 0, WispThemeStore.shared.allowsPlayfulMotion {
                bounceCount += 1
            }
        }
        .animation(WispMotion.hover, value: isHovering)
        .accessibilityLabel("\(buddy.name)\(isUnread ? ", unread" : "")")
        .nativeTooltip(isExpanded ? nil : buddy.name)
    }
}

/// The pill behind the selected sidebar row: a soft neutral grey, like a messenger's. Every row
/// uses the same `matchedGeometryEffect` id, which is what makes the highlight glide
/// from row to row instead of blinking out and in. (A glass shape here drew over the
/// row's own icon, so this is a plain tinted fill with a lit edge.)
private struct WispSidebarSelectionHighlight: View {
    let namespace: Namespace.ID
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(WispColor.surface3)
            .matchedGeometryEffect(id: "wispSidebarSelection", in: namespace)
    }
}
