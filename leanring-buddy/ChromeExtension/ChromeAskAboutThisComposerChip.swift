//
//  ChromeAskAboutThisComposerChip.swift
//  leanring-buddy
//
//  The text composer's "About: selected text ✕" chip for a part of a Chrome
//  page (phase 06), beside the screen region's "About: selected part" chip
//  and drawn the same way. It watches `ChromeAskAboutThisRouter`, so it
//  appears when a right-click opens the composer and goes when the ✕ (or a
//  fresh question) clears the part. Nothing shows when no part is chosen.
//

import SwiftUI

struct ChromeAskAboutThisComposerChip: View {
    @ObservedObject private var askAboutThisRouter = ChromeAskAboutThisRouter.shared
    @State private var isHovered = false

    var body: some View {
        if let focusedPagePart = askAboutThisRouter.focusedPagePart {
            Button {
                askAboutThisRouter.clearFocusedPagePart()
            } label: {
                HStack(spacing: 5) {
                    Text(focusedPagePart.chipLabel)
                        .font(.system(size: 10, weight: .medium))
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundColor(isHovered ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule(style: .continuous).fill(DS.Colors.surface2))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .onHover { isHovering in isHovered = isHovering }
            .help("Ask about the whole screen instead")
            .accessibilityLabel(focusedPagePart.chipAccessibilityLabel)
        }
    }
}
