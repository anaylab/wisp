//
//  GlanceCardActionButton.swift
//  leanring-buddy
//
//  The small capsule button on the result cards ("Open in Calendar", "Undo"),
//  in the island's control language (`WispColor.Island`: a flat white-alpha
//  fill on the black, white text): pointer cursor and a brighter fill on hover
//  so it reads as clickable in the notch, and dimmed while disabled (an Undo
//  already running).
//

import SwiftUI

struct GlanceCardActionButton: View {
    let title: String
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let showsHoverFill = isHovered && isEnabled
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(WispColor.Island.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(showsHoverFill ? WispColor.Island.controlFillHovered : WispColor.Island.controlFill)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.6)
        .pointerCursor(isEnabled: isEnabled)
        .onHover { isHovering in
            isHovered = isHovering
        }
        .animation(.easeOut(duration: 0.12), value: showsHoverFill)
    }
}
