//
//  BuddyPersonalityPicker.swift
//  leanring-buddy
//
//  Five chips, one per work style, with the chosen style's one-line tagline
//  underneath. Used when summoning a buddy, on its About tab and in first-run
//  setup. It makes no promise about the voice: the tagline describes tone only.
//

import SwiftUI

struct BuddyPersonalityPicker: View {
    @Binding var selection: BuddyPersonality

    @State private var hoveredPersonality: BuddyPersonality?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(BuddyPersonality.allCases) { personality in
                    personalityChip(personality)
                }
            }
            Text(selection.tagline)
                .font(.system(size: 11.5))
                .foregroundStyle(WispColor.textSecondary)
        }
    }

    private func personalityChip(_ personality: BuddyPersonality) -> some View {
        let isSelected = personality == selection
        return Button {
            selection = personality
        } label: {
            HStack(spacing: 5) {
                Image(systemName: personality.symbolName)
                    .font(.system(size: 11, weight: .medium))
                Text(personality.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? WispColor.accentText : WispColor.textSecondary)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background {
                if isSelected || hoveredPersonality == personality {
                    Color.clear.wispBevel(
                        Capsule(),
                        fill: isSelected ? WispColor.accentSubtle : WispColor.surface3
                    )
                    .transition(.opacity)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering in hoveredPersonality = isHovering ? personality : nil }
        .animation(WispMotion.quick, value: isSelected)
        .accessibilityLabel("\(personality.title), \(personality.tagline)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
