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
                selectedBuddyID = buddyStore.buddies.first?.id
            }
        }
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
                ForEach(buddyStore.buddies) { buddy in
                    buddyRow(buddy)
                        .tag(buddy.id)
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

    private func buddyRow(_ buddy: WispBuddy) -> some View {
        let isRunning = buddyStore.isRunning(buddy, in: taskRegistry)
        return HStack(spacing: 10) {
            BuddyAvatar(colorIndex: buddy.colorIndex, size: 30, isWorking: isRunning)
            VStack(alignment: .leading, spacing: 2) {
                Text(buddy.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(isRunning ? "Working…" : buddy.schedule.summary())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
            BuddyDetailView(buddyID: selectedBuddyID, topInset: 0)
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
