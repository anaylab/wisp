//
//  WispSidebar.swift
//  leanring-buddy
//
//  The Wisp window's navigation, laid out as a narrow rail of
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
    @ObservedObject private var groupStore = BuddyGroupStore.shared
    @ObservedObject private var threadStore = BuddyThreadStore.shared
    @ObservedObject private var groupEngine = BuddyGroupEngine.shared
    @ObservedObject private var advancedFeatures = WispAdvancedFeaturesPreference.shared
    @ObservedObject private var jobsEngine = JobsEngine.shared
    @ObservedObject private var automationEngine = AutomationEngine.shared
    @ObservedObject private var brainIngestQueue = BrainIngestQueue.shared

    @AppStorage("WispWindowSidebarExpanded") private var isExpanded = true
    /// Comma-separated ids of the groups the user folded away. Hidden starts folded,
    /// so its id records that the user opened it (see `hiddenGroupOpenID`).
    @AppStorage("WispSidebarCollapsedGroups") private var collapsedGroupIDsRaw = ""
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
        // A permanent icon rail of destinations, then the list column, as in OpenBot:
        // the rail answers "where am I", the list answers "who am I talking to".
        HStack(spacing: 0) {
            navigationRail
            // The canvas wants the whole width, as in OpenBot's Workflows tab.
            if router.selectedPage != .workflows { listColumn }
        }
        .frame(maxHeight: .infinity)
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
            "Delete \(router.groupIDPendingDeletion.flatMap(groupStore.group(withID:))?.name ?? "this group")?",
            isPresented: isPresentedBinding($router.groupIDPendingDeletion)
        ) {
            Button("Delete Group", role: .destructive) {
                if let groupID = router.groupIDPendingDeletion {
                    BuddyGroupEngine.shared.stop(groupWithID: groupID)
                    groupStore.deleteGroup(withID: groupID)
                }
            }
        } message: {
            Text("The shared chat is removed. The buddies and their own chats stay.")
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

    // MARK: - List column

    static let navigationRailWidth: CGFloat = 54

    /// The traffic-light row (also the window's drag handle, with "+" on its
    /// right), then the list in an inset rounded panel.
    private var listColumn: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: WispWindowView.topBarHeight)
                .background(WindowDragArea())
                .overlay(alignment: .trailing) {
                    if isExpanded && pageListSection == nil {
                        newMenu.padding(.trailing, 10)
                    }
                }

            Group {
                if let pageListSection {
                    pageList(for: pageListSection).transition(.opacity)
                } else {
                    mainList.transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity)
            .background(WispColor.groupedCardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(WispColor.cardSeparator.opacity(0.5), lineWidth: 0.5))
            .padding(.trailing, 6)
            .padding(.bottom, 8)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Navigation rail

    private struct Destination: Identifiable {
        let page: WispPage
        let symbolName: String
        let title: String
        var id: WispPage { page }
    }

    /// Buddies first, then the few other places; Advanced adds the rest of the
    /// old sections (with it off they are Settings pages).
    private var navigationItems: [Destination] {
        var items = [
            Destination(page: .buddies, symbolName: "person.2", title: "Buddies"),
            Destination(page: .home, symbolName: "sun.max", title: "Today"),
            Destination(page: .chat, symbolName: "bubble.left.and.bubble.right", title: "Chat"),
            Destination(page: .automations, symbolName: "bolt", title: "Automations"),
            Destination(page: .workflows, symbolName: "point.3.connected.trianglepath.dotted", title: "Workflows"),
            Destination(page: .canvas, symbolName: "graduationcap", title: "Canvas"),
            Destination(page: .study, symbolName: "hourglass", title: "Study"),
        ]
        if advancedFeatures.isEnabled {
            items += [
                Destination(page: .brainPages, symbolName: "brain", title: "Brain"),
                Destination(page: .routines, symbolName: "bolt.circle", title: "Routines"),
                Destination(page: .timeline, symbolName: "clock.arrow.circlepath", title: "History"),
                Destination(page: .marketplace, symbolName: "powerplug", title: "Connections"),
            ]
        }
        return items
    }

    private var navigationRail: some View {
        VStack(spacing: 6) {
            // Room for the traffic lights, which sit over the rail's top.
            Color.clear.frame(height: WispWindowView.topBarHeight).background(WindowDragArea())
            ForEach(navigationItems) { item in railButton(item) }
            Spacer(minLength: 0)
            settingsRailButton
        }
        .padding(.bottom, 10)
        .frame(width: Self.navigationRailWidth)
        .frame(maxHeight: .infinity)
    }

    private func railButton(_ item: Destination) -> some View {
        let isSelected = router.selectedPage == item.page
            || (item.page == .brainPages && router.selectedSection == .brain)
            || (item.page == .marketplace && router.selectedSection == .connections)
        return railIcon(
            symbolName: item.symbolName,
            title: item.title,
            isSelected: isSelected,
            needsAttention: needsAttention(for: item.page) && !isSelected,
            action: { router.select(item.page) }
        )
    }

    private var settingsRailButton: some View {
        railIcon(
            symbolName: "gearshape",
            title: "Settings",
            isSelected: router.selectedSection == .settings,
            needsAttention: !companionManager.allPermissionsGranted,
            attentionColor: WispColor.warning,
            action: { router.select(.settings) }
        )
        .nativeTooltip("Settings  ⌥⌘4")
    }

    private func railIcon(
        symbolName: String, title: String, isSelected: Bool, needsAttention: Bool,
        attentionColor: Color = WispColor.accentText, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isSelected ? WispColor.textPrimary : WispColor.textSecondary)
                .frame(width: 38, height: 36)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 11, style: .continuous).fill(WispColor.surface3)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if needsAttention {
                        Circle().fill(attentionColor).frame(width: 7, height: 7).offset(x: -3, y: 4)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .nativeTooltip(title)
        .animation(WispMotion.quick, value: isSelected)
    }

    // MARK: - Main list

    private var mainList: some View {
        VStack(spacing: 0) {
            if !isExpanded { header }
            controls
            buddyList
            footer
        }
        // One value for "what is selected", so the highlight glides to the new row.
        .animation(reduceMotion ? nil : WispMotion.morph, value: selectionKey)
    }

    private var selectionKey: String {
        "\(router.selectedPage.rawValue)-\(router.activeBuddyID?.uuidString ?? "none")-\(router.activeGroupID?.uuidString ?? "none")"
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
            Button("New Group") { requestNewGroup() }
                .disabled(buddyStore.buddies.count < 2)
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

    // MARK: - Buddy groups

    private static let needsYouGroupID = "needs-you"
    private static let pinnedGroupID = "pinned"
    private static let buddiesGroupID = "buddies"
    private static let groupsGroupID = "groups"
    /// Recorded in the collapsed set when the user opens Hidden, which is folded by default.
    private static let hiddenGroupOpenID = "hidden:open"

    private var collapsedGroupIDs: Set<String> {
        Set(collapsedGroupIDsRaw.split(separator: ",").map(String.init))
    }

    private func toggleGroup(_ groupID: String) {
        var groupIDs = collapsedGroupIDs
        if groupIDs.contains(groupID) { groupIDs.remove(groupID) } else { groupIDs.insert(groupID) }
        collapsedGroupIDsRaw = groupIDs.sorted().joined(separator: ",")
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The list split the way OpenBot splits its agents: those that need the user
    /// first, pinned next, then everyone else, with hidden ones set apart.
    private var buddyGroups: BuddySidebarGroups<WispBuddy> {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespaces)
        let orderedBuddies = buddyStore.orderedBuddies(in: taskRegistry)
        let matchingBuddies = trimmedSearch.isEmpty
            ? orderedBuddies
            : orderedBuddies.filter { $0.name.localizedCaseInsensitiveContains(trimmedSearch) }
        return BuddySidebarGrouping.groups(
            of: matchingBuddies,
            isHidden: \.isHiddenInList,
            isWaiting: { buddyStore.mood(of: $0, in: taskRegistry) == .waiting },
            isPinned: \.isPinnedInList
        )
    }

    private var buddyList: some View {
        let groups = buddyGroups
        let hasGroupsAbove = !groups.needsYou.isEmpty || !groups.pinned.isEmpty
        return ScrollView(showsIndicators: false) {
            VStack(spacing: isExpanded ? 2 : 6) {
                buddyGroup(id: Self.needsYouGroupID, title: "Needs you", buddies: groups.needsYou, isWaitingGroup: true)
                buddyGroup(
                    id: Self.pinnedGroupID,
                    title: "Pinned",
                    buddies: groups.pinned,
                    separatedInRail: !groups.needsYou.isEmpty
                )
                buddyGroup(
                    id: Self.buddiesGroupID,
                    title: "Buddies",
                    buddies: groups.everyoneElse,
                    showsHeader: hasGroupsAbove,
                    separatedInRail: hasGroupsAbove
                )
                groupChatsGroup
                hiddenGroup(groups.hidden)
            }
            .padding(.horizontal, isExpanded ? 12 : 0)
            .padding(.vertical, 4)
            .animation(reduceMotion ? nil : WispMotion.island, value: groups.inDisplayOrder.map(\.id))
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func buddyGroup(
        id: String,
        title: String,
        buddies: [WispBuddy],
        isWaitingGroup: Bool = false,
        showsHeader: Bool = true,
        separatedInRail: Bool = false
    ) -> some View {
        if !buddies.isEmpty {
            let isFolded = isExpanded && collapsedGroupIDs.contains(id) && !isSearching
            VStack(spacing: isExpanded ? 2 : 6) {
                if isExpanded && showsHeader {
                    groupHeader(id: id, title: title, count: buddies.count, isFolded: isFolded, isOpenWhenFolded: false)
                } else if !isExpanded && separatedInRail {
                    // In the rail there is no room for a header; a hairline marks the break.
                    groupDivider
                }
                if !isFolded {
                    ForEach(buddies) { buddy in
                        buddyRow(buddy, isInWaitingGroup: isWaitingGroup)
                    }
                }
            }
        }
    }

    private var visibleGroups: [BuddyGroup] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespaces)
        let orderedGroups = groupStore.orderedGroups()
        return trimmedSearch.isEmpty
            ? orderedGroups
            : orderedGroups.filter { $0.name.localizedCaseInsensitiveContains(trimmedSearch) }
    }

    /// Group chats, listed beside the buddies the way OpenBot lists channels.
    @ViewBuilder
    private var groupChatsGroup: some View {
        let groups = visibleGroups
        if !groups.isEmpty {
            let isFolded = isExpanded && collapsedGroupIDs.contains(Self.groupsGroupID) && !isSearching
            VStack(spacing: isExpanded ? 2 : 6) {
                if isExpanded {
                    groupHeader(id: Self.groupsGroupID, title: "Groups", count: groups.count, isFolded: isFolded, isOpenWhenFolded: false)
                } else {
                    groupDivider
                }
                if !isFolded {
                    ForEach(groups) { group in
                        WispSidebarGroupRow(
                            group: group,
                            isExpanded: isExpanded,
                            isSelected: router.selectedPage == .buddies && router.activeGroupID == group.id,
                            selectionNamespace: selectionNamespace,
                            onSelect: { openGroup(group.id) }
                        )
                        .contextMenu {
                            Button("Archive", systemImage: "archivebox") {
                                groupStore.setArchived(true, groupWithID: group.id)
                            }
                            Divider()
                            Button("Delete…", systemImage: "trash", role: .destructive) {
                                router.groupIDPendingDeletion = group.id
                            }
                        }
                    }
                }
            }
        }
    }

    /// Hidden buddies, folded until the user opens the group. A search opens it,
    /// so a hidden buddy can still be found by name.
    @ViewBuilder
    private func hiddenGroup(_ buddies: [WispBuddy]) -> some View {
        if isExpanded && !buddies.isEmpty {
            let isOpen = collapsedGroupIDs.contains(Self.hiddenGroupOpenID) || isSearching
            VStack(spacing: 2) {
                groupHeader(
                    id: Self.hiddenGroupOpenID,
                    title: "Hidden",
                    count: buddies.count,
                    isFolded: !isOpen,
                    isOpenWhenFolded: true
                )
                if isOpen {
                    ForEach(buddies) { buddy in
                        buddyRow(buddy, isInWaitingGroup: false, isInHiddenGroup: true)
                    }
                }
            }
        }
    }

    private func groupHeader(id: String, title: String, count: Int, isFolded: Bool, isOpenWhenFolded: Bool) -> some View {
        Button {
            toggleGroup(id)
        } label: {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.6)
                Text("\(count)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(WispColor.textTertiary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isFolded ? -90 : 0))
            }
            .foregroundStyle(WispColor.textTertiary)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel("\(title), \(count)")
        .accessibilityValue(isFolded ? "collapsed" : "expanded")
        .animation(reduceMotion ? nil : WispMotion.quick, value: isFolded)
    }

    private var groupDivider: some View {
        Rectangle()
            .fill(WispColor.cardSeparator.opacity(0.5))
            .frame(height: 0.5)
            .padding(.horizontal, 20)
            .padding(.vertical, 2)
    }

    private func buddyRow(_ buddy: WispBuddy, isInWaitingGroup: Bool, isInHiddenGroup: Bool = false) -> some View {
        WispSidebarBuddyRow(
            buddy: buddy,
            statusText: isInHiddenGroup ? "Hidden" : buddyStatusText(buddy),
            timeText: buddyLatestTimeText(buddy),
            isExpanded: isExpanded,
            isSelected: router.selectedPage == .buddies && router.activeBuddyID == buddy.id,
            isInWaitingGroup: isInWaitingGroup,
            isHidden: isInHiddenGroup,
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

    // MARK: - Footer

    /// Wisp's own state and model, last (Settings is on the rail).
    @ViewBuilder
    private var footer: some View {
        if isExpanded {
            VStack(spacing: 0) {
                Rectangle().fill(WispColor.cardSeparator.opacity(0.5)).frame(height: 0.5)
                HStack(spacing: 10) {
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
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
            }
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
        case .workflows: return "point.3.connected.trianglepath.dotted"
        case .study: return "hourglass"
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

    private func openGroup(_ groupID: UUID) {
        router.isNewBuddyFormRequested = false
        router.groupIDToOpen = groupID
        router.select(WispPage.buddies)
    }

    private func requestNewGroup() {
        router.isNewGroupRequested = true
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
            return previewText(of: latestAnswer)
        }
        // Once History has let the run go (30 days), the thread still has the answer.
        if let latestAnsweredExchange = latestAnsweredExchange(of: buddy),
           let latestAnswer = latestAnsweredExchange.answerText {
            return previewText(of: latestAnswer)
        }
        return buddy.schedule.summary()
    }

    /// One line of an answer for the row: no machine tags, line breaks, bullets or `**`.
    private func previewText(of answer: String) -> String {
        AnswerDisplayText.cleaned(answer)
            .components(separatedBy: "\n")
            .map { line in
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                return trimmedLine.hasPrefix("- ") ? String(trimmedLine.dropFirst(2)) : trimmedLine
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: "**", with: "")
    }

    private func latestAnsweredExchange(of buddy: WispBuddy) -> BuddyThreadExchange? {
        threadStore.exchanges(ofBuddyWithID: buddy.id).last { !($0.answerText ?? "").isEmpty }
    }

    /// When the buddy last did something, in the messenger's right-hand column.
    private func buddyLatestTimeText(_ buddy: WispBuddy) -> String? {
        let latestStart = buddyStore.latestRunRecord(of: buddy, in: taskRegistry)?.startedAt
            ?? latestAnsweredExchange(of: buddy)?.startedAt
        return latestStart.map { BuddyFormatting.timeText($0) }
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
        let orderedBuddies = buddyGroups.visibleInDisplayOrder
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
    /// In "Needs you": the row's time slot says what the user does next.
    var isInWaitingGroup = false
    /// In the Hidden group: the character sleeps and the row shows no state.
    var isHidden = false
    let selectionNamespace: Namespace.ID
    var onSelect: () -> Void

    @ObservedObject private var buddyStore = BuddyStore.shared
    @ObservedObject private var taskRegistry = AgentTaskRegistry.shared
    @State private var bounceCount = 0
    @State private var isHovering = false

    var body: some View {
        let mood: BuddyMood = isHidden ? .sleepy : buddyStore.mood(of: buddy, in: taskRegistry)
        let isUnread = !isHidden && buddyStore.isUnread(buddy, in: taskRegistry)
        let state = isHidden ? nil : BuddySidebarPolicy.state(mood: mood, isUnread: isUnread)
        let roleTitle = buddy.specialty.flatMap { $0 == .general ? nil : $0.title }
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
                    .opacity(isHidden ? 0.55 : 1)

                    if let state, state != .unread {
                        WispSidebarStateBadge(state: state)
                            .offset(x: 2, y: 2)
                    }

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
                            if let roleTitle {
                                Text(roleTitle)
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(WispColor.textSecondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(Capsule(style: .continuous).fill(WispColor.surface3.opacity(0.8)))
                                    .lineLimit(1)
                                    .layoutPriority(-1)
                            }
                            Spacer(minLength: 6)
                            if isInWaitingGroup && state == .waiting {
                                WispSidebarApproveChip()
                            } else if isHidden {
                                Image(systemName: "eye.slash")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(WispColor.textTertiary)
                            } else if let timeText {
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
        .accessibilityLabel("\(buddy.name)\(roleTitle.map { ", \($0)" } ?? "")\(state.map { ", \($0.accessibilityPhrase)" } ?? "")")
        .nativeTooltip(isExpanded ? nil : (state == .waiting ? "\(buddy.name) · needs your approval" : buddy.name))
    }
}

/// The small badge on a buddy's character: what it is doing, by `BuddySidebarPolicy`'s
/// precedence. (Unread keeps its own dot, so it has no badge.)
private struct WispSidebarStateBadge: View {
    let state: BuddySidebarState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var symbolName: String {
        switch state {
        case .waiting: return "checkmark.shield"
        case .working: return "ellipsis"
        case .failed: return "xmark"
        case .responded: return "checkmark"
        case .unread: return "circle.fill"
        }
    }

    private var tint: Color {
        switch state {
        case .waiting: return WispColor.warningText
        case .failed: return DS.Colors.destructiveText
        case .responded: return WispColor.success
        case .working, .unread: return WispColor.textSecondary
        }
    }

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(tint)
            .symbolEffect(.pulse, isActive: state == .working && !reduceMotion)
            .frame(width: 16, height: 16)
            .background(Circle().fill(WispColor.surface3))
            .overlay(Circle().strokeBorder(WispColor.windowBackground, lineWidth: 1.5))
            .accessibilityHidden(true)
    }
}

/// The chip in a waiting row's time slot: what the user does next.
private struct WispSidebarApproveChip: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 9, weight: .semibold))
            Text("Approve")
                .font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(WispColor.warningText)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule(style: .continuous).fill(WispColor.warning.opacity(0.16)))
    }
}

/// One group chat in the sidebar: its members' faces overlapped, its name, the
/// start of the latest message, and a pulsing dot while a member is working.
private struct WispSidebarGroupRow: View {
    let group: BuddyGroup
    let isExpanded: Bool
    let isSelected: Bool
    let selectionNamespace: Namespace.ID
    var onSelect: () -> Void

    @ObservedObject private var groupStore = BuddyGroupStore.shared
    @ObservedObject private var groupEngine = BuddyGroupEngine.shared
    @ObservedObject private var buddyStore = BuddyStore.shared
    @State private var isHovering = false

    var body: some View {
        let members = group.memberIDs.compactMap { buddyStore.buddy(withID: $0) }
        let latestMessage = groupStore.messages(ofGroupWithID: group.id).last { $0.author != .notice }
        let isWorking = groupEngine.isWorking(inGroupWithID: group.id)
        return Button(action: onSelect) {
            HStack(spacing: 10) {
                BuddyGroupFace(members: members, size: isExpanded ? 26 : 24, maximumFaces: isExpanded ? 3 : 2)
                    .frame(width: isExpanded ? 62 : 56, height: 54)
                    .overlay(alignment: .topTrailing) {
                        if isWorking && !isExpanded {
                            Circle().fill(WispColor.accentText).frame(width: 9, height: 9)
                                .overlay(Circle().strokeBorder(WispColor.windowBackground, lineWidth: 1.5))
                        }
                    }
                if isExpanded {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(group.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(WispColor.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            if let latestMessage {
                                Text(BuddyFormatting.timeText(latestMessage.createdAt))
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(WispColor.textTertiary)
                            }
                        }
                        HStack(spacing: 6) {
                            Text(isWorking ? "Working…" : (latestMessage?.text.replacingOccurrences(of: "\n", with: " ") ?? "No messages yet"))
                                .font(.system(size: 12.5))
                                .foregroundStyle(isWorking ? WispColor.accentText : WispColor.textSecondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
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
        .animation(WispMotion.hover, value: isHovering)
        .accessibilityLabel("Group \(group.name)\(isWorking ? ", working" : "")")
        .nativeTooltip(isExpanded ? nil : group.name)
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
