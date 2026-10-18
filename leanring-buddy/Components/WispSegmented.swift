//
//  WispSegmented.swift
//  leanring-buddy
//
//  The window's segmented control: a quiet track with a raised, lit-edge thumb
//  that slides to the chosen option. Replaces the system segmented picker in the
//  settings pages, whose selection colour clashes with the rest of the window.
//

import SwiftUI

struct WispSegmented<Value: Hashable>: View {
    let options: [Value]
    let title: (Value) -> String
    @Binding var selection: Value

    @Namespace private var thumbNamespace
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    withAnimation(WispMotion.smooth) { selection = option }
                } label: {
                    Text(title(option))
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? WispColor.accentText : WispColor.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background {
                            if isSelected {
                                Color.clear
                                    .wispBevel(RoundedRectangle(cornerRadius: 7, style: .continuous), fill: WispColor.surface1)
                                    .matchedGeometryEffect(id: "thumb", in: thumbNamespace)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(WispColor.surface3.opacity(0.6)))
        .opacity(isEnabled ? 1 : 0.5)
        .fixedSize()
    }
}
