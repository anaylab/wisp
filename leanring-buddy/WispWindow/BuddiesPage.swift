//
//  BuddiesPage.swift
//  leanring-buddy
//
//  The Wisp window's Buddies page, as a messenger. A rail of living characters
//  down the left, the selected buddy's own chat in the middle (files, replies,
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
    /// The buddy a right-click asked to clear or delete, awaiting confirmation.
    @State private var buddyIDPendingClear: UUID?
    @State private var buddyIDPendingDeletion: UUID?

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
            BuddyRailView(
                buddies: buddyStore.orderedBuddies(in: taskRegistry),
                selectedBuddyID: selectedBuddyID,
                isCreating: showsCreation,
                onSelect: { buddyID in
                    withAnimation(WispMotion.smooth) {
                        isCreatingBuddy = false
                        selectedBuddyID = buddyID
                    }
                },
                onNewBuddy: { withAnimation(WispMotion.smooth) { isCreatingBuddy = true } },
                onDuplicated: showBuddy,
                onRequestClearConversation: { buddyIDPendingClear = $0 },
                onRequestDeletion: { buddyIDPendingDeletion = $0 }
            )

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
                            onRequestClearConversation: { buddyIDPendingClear = selectedBuddyID },
                            onRequestDeletion: { buddyIDPendingDeletion = selectedBuddyID },
                            onOpenBuddy: showBuddy
                        )
                        .id(selectedBuddyID)
                        .transition(.opacity)

                        if isInspectorOpen {
                            Divider().opacity(0.6)
                            BuddyInspectorView(
                                buddyID: selectedBuddyID,
                                onRequestClearConversation: { buddyIDPendingClear = selectedBuddyID },
                                onRequestDeletion: { buddyIDPendingDeletion = selectedBuddyID }
                            )
                            .frame(width: inspectorWidth)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(WispColor.windowBackground)
        .background(shortcutButtons)
        .onAppear {
            takeRequestFromOtherPages()
            if selectedBuddyID == nil {
                selectedBuddyID = buddyStore.orderedBuddies(in: taskRegistry).first?.id
            }
        }
        .onChange(of: router.buddyIDToOpen) { _, _ in takeRequestFromOtherPages() }
        .onChange(of: router.isNewBuddyFormRequested) { _, _ in takeRequestFromOtherPages() }
        .onChange(of: buddyStore.buddies.map(\.id)) { _, remainingBuddyIDs in
            // The open buddy was deleted: show the next one rather than nothing.
            if let selectedBuddyID, !remainingBuddyIDs.contains(selectedBuddyID) {
                self.selectedBuddyID = buddyStore.orderedBuddies(in: taskRegistry).first?.id
            }
        }
        .confirmationDialog(
            "Clear \(pendingBuddyName(buddyIDPendingClear))'s conversation?",
            isPresented: isPresentedBinding($buddyIDPendingClear)
        ) {
            Button("Clear Conversation", role: .destructive) {
                if let buddyIDPendingClear { buddyStore.clearConversation(ofBuddyWithID: buddyIDPendingClear) }
            }
        } message: {
            Text("It starts fresh. Mission, notes, files and settings stay.")
        }
        .confirmationDialog(
            "Delete \(pendingBuddyName(buddyIDPendingDeletion))?",
            isPresented: isPresentedBinding($buddyIDPendingDeletion)
        ) {
            Button("Delete", role: .destructive) {
                if let buddyIDPendingDeletion { buddyStore.deleteBuddy(withID: buddyIDPendingDeletion) }
            }
        } message: {
            Text("Its thread, notes and files are removed. Its runs stay in History.")
        }
    }

    /// ⌘1–⌘9 open the buddy at that position in the rail; ⌘N summons a new one.
    /// Invisible buttons, because SwiftUI only registers shortcuts on views.
    private var shortcutButtons: some View {
        let orderedBuddies = buddyStore.orderedBuddies(in: taskRegistry)
        return ZStack {
            ForEach(Array(orderedBuddies.prefix(9).enumerated()), id: \.element.id) { index, buddy in
                Button("") { showBuddy(buddy.id) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Button("") { withAnimation(WispMotion.smooth) { isCreatingBuddy = true } }
                .keyboardShortcut("n", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func showBuddy(_ buddyID: UUID) {
        withAnimation(WispMotion.island) {
            isCreatingBuddy = false
            selectedBuddyID = buddyID
        }
    }

    private func pendingBuddyName(_ buddyID: UUID?) -> String {
        buddyID.flatMap(buddyStore.buddy(withID:))?.name ?? "this buddy"
    }

    private func isPresentedBinding(_ pendingBuddyID: Binding<UUID?>) -> Binding<Bool> {
        Binding(
            get: { pendingBuddyID.wrappedValue != nil },
            set: { isPresented in if !isPresented { pendingBuddyID.wrappedValue = nil } }
        )
    }
}
