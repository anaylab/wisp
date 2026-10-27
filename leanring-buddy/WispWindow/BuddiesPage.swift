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

    @State private var selectedBuddyID: UUID?
    @State private var isCreatingBuddy = false
    @AppStorage("BuddyInspectorOpen") private var isInspectorOpen = true

    private let inspectorWidth: CGFloat = 330

    /// Other pages can ask for a particular buddy, or the summon flow; take the
    /// request once and clear it.
    private func takeRequestFromOtherPages() {
        if router.isNewBuddyFormRequested {
            router.isNewBuddyFormRequested = false
            isCreatingBuddy = true
        } else if let requestedBuddyID = router.buddyIDToOpen {
            router.buddyIDToOpen = nil
            isCreatingBuddy = false
            selectedBuddyID = requestedBuddyID
        }
    }

    private var showsCreation: Bool { isCreatingBuddy || buddyStore.buddies.isEmpty }

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
        router.activeBuddyID = showsCreation ? nil : selectedBuddyID
    }

    private func showBuddy(_ buddyID: UUID) {
        withAnimation(WispMotion.island) {
            isCreatingBuddy = false
            selectedBuddyID = buddyID
        }
    }
}
