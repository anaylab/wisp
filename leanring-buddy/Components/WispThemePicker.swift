//
//  WispThemePicker.swift
//  leanring-buddy
//
//  Six swatch cards, one per theme. Each card previews the theme as it will look in
//  the current appearance (its backdrop colours, an accent pill, the AI-activity
//  dot), and choosing one applies it at once, so the window behind the picker is
//  the live preview too. Used in Settings → General → Appearance and in first-run
//  setup.
//

import SwiftUI

struct WispThemePicker: View {
    @ObservedObject private var themeStore = WispThemeStore.shared

    init() {}

    private let swatchColumns = [GridItem(.adaptive(minimum: 132, maximum: 190), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: swatchColumns, alignment: .leading, spacing: 12) {
            ForEach(WispTheme.all) { theme in
                WispThemeSwatch(
                    theme: theme,
                    isSelected: theme.id == themeStore.currentThemeID,
                    choose: {
                        withAnimation(WispMotion.smooth) { themeStore.currentThemeID = theme.id }
                    }
                )
            }
        }
    }
}

private struct WispThemeSwatch: View {
    let theme: WispTheme
    let isSelected: Bool
    let choose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    private func hex(_ pair: WispThemeColorPair) -> Color {
        Color(hex: colorScheme == .dark ? pair.darkHex : pair.lightHex)
    }

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 8) {
                preview
                HStack(spacing: 6) {
                    Text(theme.name)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(WispColor.textPrimary)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(WispColor.accentText)
                    }
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(WispColor.surface2.opacity(isHovered ? 0.9 : 0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? WispColor.accentText : WispColor.cardSeparator,
                                  lineWidth: isSelected ? 2 : 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(theme.name) theme")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// A miniature of the theme: its backdrop, a glass-ish card, an accent pill with
    /// its label colour, and the AI-activity dot.
    private var preview: some View {
        let previewShape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: theme.backdropStops.map { hex($0) },
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            HStack(spacing: 6) {
                Text("Aa")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(hex: theme.textOnAccentHex))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(hex(theme.accent)))
                Circle()
                    .fill(hex(theme.aiActivityAccent))
                    .frame(width: 8, height: 8)
                Circle()
                    .fill(hex(theme.secondaryAccent))
                    .frame(width: 8, height: 8)
            }
            .padding(7)
            .background(
                Capsule().fill(.ultraThinMaterial)
            )
            .padding(7)
        }
        .frame(height: 58)
        .clipShape(previewShape)
        .overlay(previewShape.strokeBorder(WispColor.cardSeparator, lineWidth: 0.5))
    }
}
