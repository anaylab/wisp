//
//  CursorTab.swift
//  leanring-buddy
//
//  The dashboard's Cursor tab: whether the cursor companion is docked (hidden)
//  and what colour it and its annotations are drawn in. Visibility lives on
//  CompanionManager (shared with the notch toggle); colour lives on
//  CursorAppearanceStore and updates the overlay live.
//

import SwiftUI

struct CursorTab: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var cursorAppearance = CursorAppearanceStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                visibilityCard
                colorCard
            }
            .padding(16)
        }
        .background(WispColor.windowBackground)
    }

    // MARK: - Visibility

    private var visibilityCard: some View {
        DashboardCard(title: "Visibility") {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Dock cursor")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.Colors.textPrimary)
                    Text("Docking hides the cursor and stops it from following you. It still appears briefly when Wisp answers.")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                // The stored flag is "cursor always visible"; docked is its inverse.
                Toggle("", isOn: Binding(
                    get: { !companionManager.isCursorAlwaysVisible },
                    set: { isDocked in companionManager.setCursorAlwaysVisible(!isDocked) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .pointerCursor()
            }
        }
    }

    // MARK: - Colour

    private var colorCard: some View {
        DashboardCard(title: "Color") {
            HStack(spacing: 10) {
                ForEach(WispCursorColor.allCases) { cursorColor in
                    colorSwatch(cursorColor)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func colorSwatch(_ cursorColor: WispCursorColor) -> some View {
        let isSelected = cursorAppearance.selectedColor == cursorColor
        return Button {
            cursorAppearance.selectedColor = cursorColor
        } label: {
            Triangle()
                .fill(cursorColor.color)
                .frame(width: 22, height: 22)
                .rotationEffect(.degrees(35))
                .frame(width: 56, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.surface2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(isSelected ? cursorColor.color : DS.Colors.borderSubtle,
                                lineWidth: isSelected ? 2 : 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .nativeTooltip(cursorColor.displayName)
    }
}
