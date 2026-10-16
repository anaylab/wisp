//
//  BuddyRailView.swift
//  leanring-buddy
//
//  The strip of buddies down the left of the Buddies page. Each is its
//  character and its name; what it is doing is in its face (a turning ring
//  while it works, an amber badge when it needs you), and an unread buddy wears
//  a dot. ⌘1–9 jump to a buddy by position.
//

import SwiftUI

struct BuddyRailView: View {
    let buddies: [WispBuddy]
    let selectedBuddyID: UUID?
    let isCreating: Bool
    var onSelect: (UUID) -> Void
    var onNewBuddy: () -> Void
    var isShowingPipelines = false
    var onShowPipelines: () -> Void = {}
    var onDuplicated: (UUID) -> Void
    var onRequestClearConversation: (UUID) -> Void
    var onRequestDeletion: (UUID) -> Void

    @ObservedObject private var buddyStore = BuddyStore.shared
    @ObservedObject private var taskRegistry = AgentTaskRegistry.shared
    @State private var isNewHovering = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(buddies) { buddy in
                        BuddyRailItem(
                            buddy: buddy,
                            mood: buddyStore.mood(of: buddy, in: taskRegistry),
                            isSelected: buddy.id == selectedBuddyID && !isCreating,
                            isUnread: buddyStore.isUnread(buddy, in: taskRegistry),
                            onSelect: { onSelect(buddy.id) }
                        )
                        .contextMenu {
                            BuddyActionsMenuItems(
                                buddy: buddy,
                                isRunning: buddyStore.isRunning(buddy, in: taskRegistry),
                                showsReadState: true,
                                onDuplicated: onDuplicated,
                                onRequestClearConversation: { onRequestClearConversation(buddy.id) },
                                onRequestDeletion: { onRequestDeletion(buddy.id) }
                            )
                        }
                    }
                }
                .padding(.vertical, 12)
                .animation(WispMotion.island, value: buddies.map(\.id))
            }

            if buddies.contains(where: { $0.schedule.isRepeating }) {
                Button { buddyStore.setAllAutomationsPaused(!buddyStore.areAllAutomationsPaused) } label: {
                    Image(systemName: buddyStore.areAllAutomationsPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(buddyStore.areAllAutomationsPaused ? DS.Colors.warningText : WispColor.textTertiary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(WispColor.surface3.opacity(buddyStore.areAllAutomationsPaused ? 1 : 0.5)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityLabel(buddyStore.areAllAutomationsPaused ? "Resume all buddy automation" : "Pause all buddy automation")
                .nativeTooltip(buddyStore.areAllAutomationsPaused
                               ? "Buddy automation is paused — click to resume"
                               : "Pause all scheduled buddy runs")
                .padding(.top, 10)
            }

            Button(action: onShowPipelines) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isShowingPipelines ? WispColor.textPrimary : WispColor.textTertiary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(WispColor.surface3.opacity(isShowingPipelines ? 1 : 0.5)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("Pipelines")
            .nativeTooltip("Pipelines — chain buddies")
            .padding(.top, 10)

            Button(action: onNewBuddy) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isCreating ? WispColor.textPrimary : WispColor.textSecondary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(WispColor.surface3.opacity(isCreating || isNewHovering ? 1 : 0.6)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .onHover { isNewHovering = $0 }
            .accessibilityLabel("New buddy")
            .nativeTooltip("New buddy (⌘N)")
            .padding(.vertical, 14)
            .animation(WispMotion.quick, value: isNewHovering)
        }
        .frame(width: 78)
        .background(WispColor.groupedCardBackground.opacity(0.6))
        .overlay(alignment: .trailing) { Rectangle().fill(WispColor.cardSeparator.opacity(0.5)).frame(width: 0.5) }
    }
}

private struct BuddyRailItem: View {
    let buddy: WispBuddy
    let mood: BuddyMood
    let isSelected: Bool
    let isUnread: Bool
    var onSelect: () -> Void

    @State private var bounceCount = 0
    @State private var isHovering = false

    var body: some View {
        Button {
            bounceCount += 1
            onSelect()
        } label: {
            VStack(spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    BuddyCharacter(
                        colorIndex: buddy.colorIndex,
                        size: 38,
                        mood: mood,
                        liveliness: .full,
                        bounceTrigger: bounceCount,
                        looksAtPointer: isSelected
                    )
                    .frame(width: 46, height: 46)

                    if isUnread && !isSelected {
                        Circle()
                            .fill(BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex))
                            .frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(WispColor.windowBackground, lineWidth: 1.5))
                            .transition(.scale)
                    }
                }

                Text(buddy.name)
                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? WispColor.textPrimary : WispColor.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: 66)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(WispColor.surface3.opacity(isSelected ? 1 : (isHovering ? 0.55 : 0)))
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering = $0 }
        .animation(WispMotion.quick, value: isSelected)
        .animation(WispMotion.quick, value: isHovering)
        .accessibilityLabel("\(buddy.name)\(isUnread ? ", unread" : "")")
    }
}
