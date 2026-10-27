//
//  AppearanceSettingsCard.swift
//  leanring-buddy
//
//  Settings → General → Appearance, in one card: light / dark / system for the
//  window, the theme swatches, and the two switches that belong to the look. The
//  island stays black unless "Tint the island with my theme" is on, and "Playful"
//  (small celebrations, the drifting backdrop) always yields to Reduce Motion.
//

import SwiftUI

struct AppearanceSettingsCard: View {
    @ObservedObject private var windowAppearance = WispAppearancePreference.shared
    @ObservedObject private var themeStore = WispThemeStore.shared

    var body: some View {
        DashboardCard(title: "Appearance") {
            SettingRow(title: "Window", detail: "") {
                WispSegmented(
                    options: WispAppearancePreference.Mode.allCases,
                    title: { $0.displayName },
                    selection: $windowAppearance.mode
                )
            }
            Divider()
            WispThemePicker()
            Divider()
            SettingRow(title: "Tint the island with my theme", detail: "") {
                Toggle("Tint the island with my theme", isOn: $themeStore.tintsIsland)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .pointerCursor()
            }
            Divider()
            SettingRow(title: "Playful", detail: "") {
                Toggle("Playful", isOn: $themeStore.isPlayful)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .pointerCursor()
            }
        }
    }
}
