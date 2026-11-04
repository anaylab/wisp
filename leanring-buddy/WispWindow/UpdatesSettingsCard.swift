//
//  UpdatesSettingsCard.swift
//  leanring-buddy
//
//  Settings → General → Updates: which version this is, Check Now, and the two switches. The update
//  check is Wisp's one default contact with a server of its own choosing, so it is described plainly
//  here and can be turned off.
//

import SwiftUI

struct UpdatesSettingsCard: View {
    @ObservedObject private var updater = WispUpdater.shared

    var body: some View {
        DashboardCard(title: "Updates") {
            switch updater.availability {
            case .available:
                updateControls
            case .unavailable(let reason):
                SettingRow(title: updater.versionDescription, detail: reason.explanation) {
                    EmptyView()
                }
            }
        }
    }

    private var updateControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingRow(title: updater.versionDescription, detail: lastCheckedText) {
                Button(checkButtonTitle) {
                    updater.checkForUpdates()
                }
                .buttonStyle(WispPillButtonStyle(isProminent: updater.pendingUpdateVersion != nil))
                .disabled(!updater.canCheckForUpdates)
                .pointerCursor()
            }
            Divider()
            SettingRow(
                title: "Check for updates automatically",
                detail: "Once a day Wisp asks GitHub for the latest version. GitHub sees your IP address and Wisp's version, nothing else."
            ) {
                Toggle("Check for updates automatically", isOn: automaticChecksBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .pointerCursor()
            }
            Divider()
            SettingRow(
                title: "Install updates automatically",
                detail: "Downloads in the background and installs the next time Wisp quits."
            ) {
                Toggle("Install updates automatically", isOn: automaticDownloadsBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!updater.automaticallyChecksForUpdates)
                    .pointerCursor()
            }
        }
    }

    private var checkButtonTitle: String {
        updater.pendingUpdateVersion.map { "Update to \($0)…" } ?? "Check Now"
    }

    private var lastCheckedText: String {
        guard let lastUpdateCheckDate = updater.lastUpdateCheckDate else { return "Not checked yet." }
        let relativeText = lastUpdateCheckDate.formatted(.relative(presentation: .named))
        return "Last checked \(relativeText)."
    }

    private var automaticChecksBinding: Binding<Bool> {
        Binding(
            get: { updater.automaticallyChecksForUpdates },
            set: { updater.automaticallyChecksForUpdates = $0 }
        )
    }

    private var automaticDownloadsBinding: Binding<Bool> {
        Binding(
            get: { updater.automaticallyDownloadsUpdates },
            set: { updater.automaticallyDownloadsUpdates = $0 }
        )
    }
}
