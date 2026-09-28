//
//  SourcesTab.swift
//  leanring-buddy
//
//  The dashboard's Sources tab: the one master switch for live card data
//  (weather and user-configured REST sources reaching off the machine), and a
//  read-only list of the sources the user has defined in `~/.wisp/sources.json`.
//  Editing happens in that file — the same `~/.wisp/` convention as MCP and
//  skills — and this tab reflects it, with a button to reveal the file and one
//  to re-read it after an edit.
//

import AppKit
import SwiftUI

struct SourcesTab: View {
    @ObservedObject private var cardDataPreference = GlanceCardDataPreference.shared
    @ObservedObject private var sourceStore = ConfiguredSourceStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                liveDataCard
                configuredSourcesCard
            }
            .padding(16)
        }
        .background(WispColor.windowBackground)
        .onAppear { sourceStore.reload() }
    }

    // MARK: - Live data master switch

    private var liveDataCard: some View {
        DashboardCard(title: "Live card data") {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Fetch live data over the network")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.Colors.textPrimary)
                    Text("On, cards that need the network — weather and your saved sources — fetch live. Off keeps Wisp fully local: those cards don't appear. On-device cards (calendar, now playing) are unaffected.")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: $cardDataPreference.isLiveCardDataEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .pointerCursor()
            }
        }
    }

    // MARK: - Configured sources

    private var configuredSourcesCard: some View {
        DashboardCard(title: "Your sources") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Defined in ~/.wisp/sources.json. Each source names an HTTPS endpoint and which fields to show; ask Wisp for one by name to see it in the notch.")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if sourceStore.sources.isEmpty {
                    Text("No sources configured yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(DS.Colors.textTertiary)
                } else {
                    VStack(spacing: 8) {
                        ForEach(sourceStore.sources) { source in
                            sourceRow(source)
                        }
                    }
                }

                Divider().overlay(DS.Colors.borderSubtle)

                HStack(spacing: 8) {
                    Button("Reveal config file") { revealConfigFile() }
                        .buttonStyle(DSSecondaryButtonStyle())
                        .pointerCursor()
                    Button("Reload") { sourceStore.reload() }
                        .buttonStyle(DSSecondaryButtonStyle())
                        .pointerCursor()
                    Spacer()
                }
            }
        }
    }

    private func sourceRow(_ source: ConfiguredSource) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(source.isEnabled ? DS.Colors.accentText : DS.Colors.textTertiary)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Colors.textPrimary)
                Text(hostDescription(for: source) + " · \(source.fields.count) field\(source.fields.count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !source.isEnabled {
                Text("Disabled")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DS.Colors.textTertiary)
            }
        }
    }

    private func hostDescription(for source: ConfiguredSource) -> String {
        URL(string: source.url)?.host ?? source.url
    }

    /// Shows the config file in Finder, or its parent folder if the file does
    /// not exist yet.
    private func revealConfigFile() {
        let fileURL = sourceStore.configFileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL.deletingLastPathComponent()])
        }
    }
}
