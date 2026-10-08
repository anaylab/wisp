//
//  GlanceCardActionButton.swift
//  leanring-buddy
//
//  The small capsule button on the result cards ("Open in Calendar", "Undo"),
//  drawn on the notch's dark palette like the timer card's Cancel: pointer
//  cursor and a hover fill so it reads as clickable in the notch, and dimmed
//  while disabled (an Undo already running).
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
                .foregroundColor(showsHoverFill ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(showsHoverFill ? DS.Colors.surface4 : DS.Colors.surface3)
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
