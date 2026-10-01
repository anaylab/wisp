//
//  BuddiesPage.swift
//  leanring-buddy
//
//  The Wisp window's Buddies page: every buddy in a list on the left, and the
//  selected buddy's thread (or the new-buddy form) on the right. Buddies used to
//  be reachable only from the notch chat's sidebar; they're scheduled jobs the
//  user manages, so they now have a page of their own. The thread and form are
//  the same views the notch used (`BuddyDetailView`, `NewBuddyForm`).
//

import SwiftUI

struct BuddiesPage: View {
    @ObservedObject var taskRegistry: AgentTaskRegistry
    @ObservedObject private var buddyStore = BuddyStore.shared

    @State private var selectedBuddyID: UUID?
    @State private var isCreatingBuddy = false
    /// The buddy a right-click asked to clear or delete, awaiting confirmation.
    @State private var buddyIDPendingClear: UUID?
    @State private var buddyIDPendingDeletion: UUID?

    var body: some View {
        Group {
            if buddyStore.buddies.isEmpty && !isCreatingBuddy {
                // Nothing to list yet: one invitation, not an empty list beside
                // an empty detail pane.
                summonInvitation
            } else {
                HStack(spacing: 0) {
                    buddyList
                        .frame(width: 250)
                    Divider()
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear {
            if selectedBuddyID == nil {
                selectedBuddyID = buddyStore.orderedBuddies(in: taskRegistry).first?.id
            }
        }
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
            Text("It starts fresh. Its job, notes and settings stay, and its runs stay in History.")
        }
        .confirmationDialog(
            "Delete \(pendingBuddyName(buddyIDPendingDeletion))?",
            isPresented: isPresentedBinding($buddyIDPendingDeletion)
        ) {
            Button("Delete", role: .destructive) {
                if let buddyIDPendingDeletion { buddyStore.deleteBuddy(withID: buddyIDPendingDeletion) }
            }
        } message: {
            Text("Its thread and notes are removed. Its runs stay in History.")
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

    // MARK: - List

    private var listSelection: Binding<UUID?> {
        Binding(
            get: { isCreatingBuddy ? nil : selectedBuddyID },
            set: { newBuddyID in
                isCreatingBuddy = false
                selectedBuddyID = newBuddyID
            }
        )
    }

    private var buddyList: some View {
        VStack(spacing: 0) {
            List(selection: listSelection) {
                ForEach(buddyStore.orderedBuddies(in: taskRegistry)) { buddy in
                    buddyRow(buddy)
                        .tag(buddy.id)
                        .contextMenu {
                            BuddyActionsMenuItems(
                                buddy: buddy,
                                isRunning: buddyStore.isRunning(buddy, in: taskRegistry),
                                showsReadState: true,
                                onDuplicated: showBuddy,
                                onRequestClearConversation: { buddyIDPendingClear = buddy.id },
                                onRequestDeletion: { buddyIDPendingDeletion = buddy.id }
                            )
                        }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)

            Divider()

            Button {
                selectedBuddyID = nil
                isCreatingBuddy = true
            } label: {
                Label("New Buddy", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .pointerCursor()
            .padding(12)
        }
        .background(WispColor.groupedCardBackground.opacity(0.6))
    }

    private func showBuddy(_ buddyID: UUID) {
        isCreatingBuddy = false
        selectedBuddyID = buddyID
    }

    private func buddyRow(_ buddy: WispBuddy) -> some View {
        let isRunning = buddyStore.isRunning(buddy, in: taskRegistry)
        // The open buddy is being read, so it never shows the dot.
        let isUnread = buddyStore.isUnread(buddy, in: taskRegistry) && !(buddy.id == selectedBuddyID && !isCreatingBuddy)
        return HStack(spacing: 10) {
            BuddyAvatar(colorIndex: buddy.colorIndex, size: 30, isWorking: isRunning)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(buddy.name)
                        .font(.body.weight(isUnread ? .bold : .semibold))
                        .lineLimit(1)
                    if buddy.isPinnedInList {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Pinned")
                    }
                }
                Text(BuddyStatusText.line(
                    for: buddy,
                    isRunning: isRunning,
                    latestRunRecord: buddyStore.latestRunRecord(of: buddy, in: taskRegistry)
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isUnread {
                Circle()
                    .fill(WispColor.accentText)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("New")
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if isCreatingBuddy {
            NewBuddyForm(
                topInset: 0,
                onCreated: { newBuddyID in
                    isCreatingBuddy = false
                    selectedBuddyID = newBuddyID
                },
                onCancel: { isCreatingBuddy = false }
            )
        } else if let selectedBuddyID, buddyStore.buddy(withID: selectedBuddyID) != nil {
            BuddyDetailView(buddyID: selectedBuddyID, topInset: 0, onDuplicated: showBuddy)
                .id(selectedBuddyID)
        } else {
            summonInvitation
        }
    }

    private var summonInvitation: some View {
        ContentUnavailableView {
            Label("Summon a buddy", systemImage: "person.2")
        } description: {
            Text("A buddy owns one job — a morning digest, a weekly check — and runs it on a schedule in the background while Wisp is running.")
        } actions: {
            Button("New Buddy") { isCreatingBuddy = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .pointerCursor()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
