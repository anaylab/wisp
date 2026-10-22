//
//  ChromeFocusSettingsRow.swift
//  leanring-buddy
//
//  Focus mode's row in Settings → Agent → Chrome Tabs (phase 09): which sites count
//  as distracting, which always stay in view, and whether distracting tabs move to a
//  minimised "Later" window. Plus Stop while a session runs.
//

import SwiftUI

struct ChromeFocusSettingsRow: View {
    @ObservedObject private var settings = ChromeFocusSettings.shared
    @ObservedObject private var focusSession = ChromeFocusSession.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "scope")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textSecondary)
                Text("Focus mode")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Colors.textPrimary)
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if focusSession.isFocusing {
                    Button("Stop") {
                        Task { await focusSession.stopFocus() }
                    }
                    .buttonStyle(WispPillButtonStyle(isProminent: false))
                    .controlSize(.small)
                    .pointerCursor()
                }
            }
            sitesField(title: "Distracting", text: $settings.distractingSitesText, placeholder: "youtube.com, reddit.com")
            sitesField(title: "Always keep", text: $settings.allowListedSitesText, placeholder: "docs.google.com")
            Toggle("Move distracting tabs to a minimised Later window", isOn: $settings.movesDistractingTabsToLaterWindow)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 11))
                .pointerCursor()
        }
    }

    private var statusText: String {
        guard let activeSession = focusSession.activeSession else {
            return "Say \"focus on my essay for 45 minutes\"."
        }
        let endText = activeSession.endDate.formatted(date: .omitted, time: .shortened)
        return activeSession.topic.isEmpty ? "On until \(endText)" : "On \(activeSession.topic) until \(endText)"
    }

    private func sitesField(title: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.textSecondary)
                .frame(width: 72, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
        }
    }
}
