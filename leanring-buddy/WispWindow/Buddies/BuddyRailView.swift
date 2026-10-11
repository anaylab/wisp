//
//  BuddyRailView.swift
//  leanring-buddy
//
//  The strip of buddies down the left of the Buddies page, like the server rail
//  of a chat app: each buddy is its living character with its name and what it
//  is up to. A working buddy glows, an unread one wears a dot, the open one sits
//  in a coloured pill, and the + at the bottom summons a new one.
//

import SwiftUI

struct BuddyRailView: View {
    let buddies: [WispBuddy]
    let selectedBuddyID: UUID?
    let isCreating: Bool
    var onSelect: (UUID) -> Void
    var onNewBuddy: () -> Void
    var onDuplicated: (UUID) -> Void
    var onRequestClearConversation: (UUID) -> Void
    var onRequestDeletion: (UUID) -> Void

    @ObservedObject private var buddyStore = BuddyStore.shared
    @ObservedObject private var taskRegistry = AgentTaskRegistry.shared

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 6) {
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

            Button(action: onNewBuddy) {
                VStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 40, height: 40)
                        .background(
                            Circle().fill(LinearGradient(
                                colors: [BuddyAppearance.deepColor(forColorIndex: 7), BuddyAppearance.deepColor(forColorIndex: 3)],
                                startPoint: .bottomLeading, endPoint: .topTrailing))
                        )
                        .shadow(color: BuddyAppearance.deepColor(forColorIndex: 7).opacity(isCreating ? 0.6 : 0.3), radius: isCreating ? 10 : 6, y: 3)
                        .scaleEffect(isCreating ? 1.08 : 1)
                    Text("New")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(WispColor.textSecondary)
                }
            }
            .buttonStyle(PressableScaleButtonStyle())
            .pointerCursor()
            .accessibilityLabel("New buddy")
            .nativeTooltip("Summon a new buddy")
            .padding(.vertical, 12)
            .animation(WispMotion.quick, value: isCreating)
        }
        .frame(width: 92)
        .background(WispColor.groupedCardBackground.opacity(0.7))
        .overlay(alignment: .trailing) { Divider().opacity(0.6) }
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
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    BuddyCharacter(
                        colorIndex: buddy.colorIndex,
                        size: 44,
                        mood: mood,
                        liveliness: .full,
                        bounceTrigger: bounceCount,
                        looksAtPointer: isSelected
                    )
                    .frame(width: 52, height: 52)

                    if isUnread && !isSelected {
                        Circle()
                            .fill(BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex))
                            .frame(width: 11, height: 11)
                            .overlay(Circle().strokeBorder(WispColor.windowBackground, lineWidth: 2))
                            .transition(.scale)
                    }
                    if buddy.isPinnedInList {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(WispColor.textTertiary)
                            .rotationEffect(.degrees(35))
                            .offset(x: -40, y: 2)
                    }
                }

                Text(buddy.name)
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(isSelected ? BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex) : WispColor.textPrimary)
                    .lineLimit(1)
                Text(BuddyFormatting.moodWord(mood, specialty: buddy.specialty))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(BuddyFormatting.moodColor(mood, colorIndex: buddy.colorIndex).opacity(mood == .idle ? 0.7 : 1))
                    .lineLimit(1)
            }
            .frame(width: 80)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected
                          ? AnyShapeStyle(BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex).opacity(0.16))
                          : AnyShapeStyle(isHovering ? WispColor.surface3.opacity(0.7) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex).opacity(isSelected ? 0.55 : 0), lineWidth: 1.2)
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressableScaleButtonStyle())
        .pointerCursor()
        .accessibilityLabel("\(buddy.name), \(BuddyFormatting.moodWord(mood, specialty: buddy.specialty))\(isUnread ? ", unread" : "")")
        .onHover { isHovering = $0 }
        .animation(WispMotion.quick, value: isSelected)
        .animation(WispMotion.quick, value: isHovering)
    }
}
