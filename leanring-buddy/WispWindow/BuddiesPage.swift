//
//  BuddiesPage.swift
//  leanring-buddy
//
//  The Wisp window's Buddies page, as a messenger. The sidebar lists the living
//  characters; this page shows the selected buddy's own chat (files, replies,
//  handoffs), and an inspector on the right for its automation, files, memory,
//  tools and settings — or, in place of the chat, the summon-a-buddy flow with
//  its specialty cards. Notch chat still uses the compact thread and form
//  (`BuddyDetailView`, `NewBuddyForm`); this page is where buddies are lived with
//  and managed.
//

import SwiftUI

struct BuddiesPage: View {
    @ObservedObject var taskRegistry: AgentTaskRegistry
    @ObservedObject private var buddyStore = BuddyStore.shared
    @ObservedObject private var router = WispWindowRouter.shared

    @ObservedObject private var groupStore = BuddyGroupStore.shared
    @State private var selectedBuddyID: UUID?
    @State private var selectedGroupID: UUID?
    @State private var isCreatingBuddy = false
    /// The group editor is open: for a new group, or (with `editingGroupID`) an existing one.
    @State private var isEditingGroup = false
    @State private var editingGroupID: UUID?
    @AppStorage("BuddyInspectorOpen") private var isInspectorOpen = true

    private let inspectorWidth: CGFloat = 330

    /// Other pages can ask for a particular buddy, or the summon flow; take the
    /// request once and clear it.
    private func takeRequestFromOtherPages() {
        if router.isNewBuddyFormRequested {
            router.isNewBuddyFormRequested = false
            isCreatingBuddy = true
            isEditingGroup = false
        } else if router.isNewGroupRequested {
            router.isNewGroupRequested = false
            editingGroupID = nil
            isEditingGroup = true
        } else if let requestedGroupID = router.groupIDToOpen {
            router.groupIDToOpen = nil
            isCreatingBuddy = false
            isEditingGroup = false
            selectedGroupID = requestedGroupID
        } else if let requestedBuddyID = router.buddyIDToOpen {
            router.buddyIDToOpen = nil
            isCreatingBuddy = false
            isEditingGroup = false
            selectedGroupID = nil
            selectedBuddyID = requestedBuddyID
        }
    }

    private var showsCreation: Bool { isCreatingBuddy || buddyStore.buddies.isEmpty }
    private var showsGroupEditor: Bool { isEditingGroup && !buddyStore.buddies.isEmpty }
    private var shownGroupID: UUID? {
        guard !showsCreation, let selectedGroupID, groupStore.group(withID: selectedGroupID) != nil else { return nil }
        return selectedGroupID
    }

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if showsCreation {
                    BuddyCreationView(
                        isFirstBuddy: buddyStore.buddies.isEmpty,
                        onCreated: showBuddy,
                        onCancel: { withAnimation(WispMotion.smooth) { isCreatingBuddy = false } }
                    )
                    .transition(.opacity)
                } else if let shownGroupID {
                    BuddyGroupChatView(
                        groupID: shownGroupID,
                        onEdit: {
                            editingGroupID = shownGroupID
                            withAnimation(WispMotion.smooth) { isEditingGroup = true }
                        },
                        onOpenBuddy: showBuddy
                    )
                    .id(shownGroupID)
                    .transition(.opacity)
                } else if let selectedBuddyID {
                    HStack(spacing: 0) {
                        BuddyChatView(
                            buddyID: selectedBuddyID,
                            isInspectorOpen: $isInspectorOpen,
                            onRequestClearConversation: { router.buddyIDPendingClear = selectedBuddyID },
                            onRequestDeletion: { router.buddyIDPendingDeletion = selectedBuddyID },
                            onOpenBuddy: showBuddy
                        )
                        .id(selectedBuddyID)
                        .transition(.opacity)

                        if isInspectorOpen {
                            Divider().opacity(0.6)
                            BuddyInspectorView(
                                buddyID: selectedBuddyID,
                                onRequestClearConversation: { router.buddyIDPendingClear = selectedBuddyID },
                                onRequestDeletion: { router.buddyIDPendingDeletion = selectedBuddyID }
                            )
                            .frame(width: inspectorWidth)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: Binding(get: { showsGroupEditor }, set: { if !$0 { isEditingGroup = false } })) {
            BuddyGroupEditorView(
                groupID: editingGroupID,
                onSaved: { savedGroupID in
                    withAnimation(WispMotion.island) {
                        isEditingGroup = false
                        selectedGroupID = savedGroupID
                    }
                },
                onCancel: { isEditingGroup = false }
            )
        }
        .onAppear {
            takeRequestFromOtherPages()
            if selectedBuddyID == nil {
                selectedBuddyID = buddyStore.orderedBuddies(in: taskRegistry).first?.id
            }
            publishActiveBuddy()
        }
        // The sidebar marks the open buddy, so it needs to know which that is.
        .onChange(of: selectedBuddyID) { _, _ in publishActiveBuddy() }
        .onChange(of: isCreatingBuddy) { _, _ in publishActiveBuddy() }
        .onChange(of: selectedGroupID) { _, _ in publishActiveBuddy() }
        .onChange(of: isEditingGroup) { _, _ in publishActiveBuddy() }
        .onChange(of: router.groupIDToOpen) { _, _ in takeRequestFromOtherPages() }
        .onChange(of: router.isNewGroupRequested) { _, _ in takeRequestFromOtherPages() }
        .onChange(of: groupStore.groups.map(\.id)) { _, remainingGroupIDs in
            // The open group was deleted: fall back to a buddy.
            if let selectedGroupID, !remainingGroupIDs.contains(selectedGroupID) { self.selectedGroupID = nil }
        }
        .onChange(of: router.buddyIDToOpen) { _, _ in takeRequestFromOtherPages() }
        .onChange(of: router.isNewBuddyFormRequested) { _, _ in takeRequestFromOtherPages() }
        .onChange(of: buddyStore.buddies.map(\.id)) { _, remainingBuddyIDs in
            // The open buddy was deleted: show the next one rather than nothing.
            if let selectedBuddyID, !remainingBuddyIDs.contains(selectedBuddyID) {
                self.selectedBuddyID = buddyStore.orderedBuddies(in: taskRegistry).first?.id
            }
        }
    }

    private func publishActiveBuddy() {
        router.activeGroupID = shownGroupID
        router.activeBuddyID = (showsCreation || shownGroupID != nil) ? nil : selectedBuddyID
    }

    private func showBuddy(_ buddyID: UUID) {
        withAnimation(WispMotion.island) {
            isCreatingBuddy = false
            isEditingGroup = false
            selectedGroupID = nil
            selectedBuddyID = buddyID
        }
    }
}
