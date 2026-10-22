//
//  AgentTab.swift
//  leanring-buddy
//
//  Settings → Agent: where the agent works (its folder), how much it asks
//  before acting (session auto-approve), announcements, Apple Shortcuts and
//  the Chrome Tabs extension. macOS permissions live in Settings → General.
//

import AppKit
import SwiftUI

struct AgentTab: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var agentSettings = AgentSettingsStore.shared
    @ObservedObject private var confirmationCoordinator = ToolConfirmationCoordinator.shared
    @ObservedObject private var shortcutsBridge = ShortcutsBridge.shared
    @ObservedObject private var announcementPreferences = AnnouncementPreferences.shared
    @ObservedObject private var quietModeMonitor = QuietModeMonitor.shared
    @ObservedObject private var chromeExtensionBridge = ChromeExtensionBridge.shared
    /// Why the last "Choose what Wisp can do in Chrome…" click didn't open the
    /// page, shown under the button until the next try.
    @State private var chromePermissionsPageErrorText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if CompanionManager.isAgentModeEnabled == false {
                    agentModeOffNotice
                }
                agentFolderCard
                approvalsCard
                announcementsCard
                appleShortcutsCard
                chromeTabsCard
            }
            .padding(16)
        }
        .background(WispColor.windowBackground)
        .task {
            // Reads the cached list if it is fresh; otherwise lists once so the
            // count shown is current when the tab opens.
            await shortcutsBridge.refreshIfStale()
        }
    }

    private var agentModeOffNotice: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(DS.Colors.warningText)
            VStack(alignment: .leading, spacing: 3) {
                Text("Agent mode is off")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Colors.textPrimary)
                Text("These apply once agent mode is on (AgentModeEnabled in Info.plist).")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.warning.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(DS.Colors.warning.opacity(0.28), lineWidth: 0.5)
        )
    }

    // MARK: - Agent folder

    private var agentFolderCard: some View {
        DashboardCard(title: "Agent Folder") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Where the agent's file tasks run.")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textSecondary)

                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundStyle(DS.Colors.textSecondary)
                    Text(agentSettings.resolvedWorkingDirectoryDisplayPath)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(DS.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if agentSettings.isUsingDefaultWorkingDirectory {
                        Text("default")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(DS.Colors.textTertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                    .fill(DS.Colors.surface2)
                            )
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.surface2)
                )

                HStack(spacing: 8) {
                    Button(action: chooseWorkingDirectory) {
                        Text("Choose…")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DS.Colors.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                    .fill(DS.Colors.surface3)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    if !agentSettings.isUsingDefaultWorkingDirectory {
                        Button { agentSettings.resetWorkingDirectoryToDefault() } label: {
                            Text("Reset to default")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(DS.Colors.textSecondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                        .fill(DS.Colors.surface2)
                                )
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func chooseWorkingDirectory() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Choose"
        openPanel.message = "Choose the folder the agent should work in"
        if openPanel.runModal() == .OK, let chosenURL = openPanel.url {
            agentSettings.setWorkingDirectory(chosenURL)
        }
    }

    // MARK: - Approvals

    private var approvalsCard: some View {
        DashboardCard(title: "Approvals") {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Auto-approve this session")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.Colors.textPrimary)
                    Text("Run tools without asking until Wisp restarts. Sending, posting, deleting, paying, inviting, running commands and writing outside the agent folder still ask.")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: $confirmationCoordinator.autoApproveThisSession)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .pointerCursor()
            }
        }
    }

    // MARK: - Announcements

    /// What Wisp brings up without being asked: the morning suggestions banner,
    /// and whether it holds back while the user is on a call.
    private var announcementsCard: some View {
        DashboardCard(title: "Announcements") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Morning suggestions")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DS.Colors.textPrimary)
                        Text("The first time you're at your Mac each day, the notch offers today's meetings, what's due and your routines. Built on this Mac, no model call.")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button {
                        // Get Wisp's own surfaces out of the way first (the dashboard,
                        // as the Today page does, or the notch's settings when this
                        // page is shown there) so the banner drops onto the user's screen.
                        if let keyWindow = NSApp.keyWindow, !(keyWindow is NotchPanel) {
                            keyWindow.performClose(nil)
                        }
                        NotificationCenter.default.post(name: .wispCloseNotchWorkspace, object: nil)
                        MorningBriefingController.shared.presentNow()
                    } label: {
                        Text("Show now")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DS.Colors.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                    .fill(DS.Colors.surface3)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!announcementPreferences.areMorningSuggestionsEnabled)
                    .pointerCursor(isEnabled: announcementPreferences.areMorningSuggestionsEnabled)
                    .nativeTooltip("Show today's suggestions in the notch")
                    Toggle("", isOn: $announcementPreferences.areMorningSuggestionsEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .pointerCursor()
                }

                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Stay quiet on calls")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DS.Colors.textPrimary)
                        Text(quietDuringCallsDetail)
                            .font(.system(size: 11))
                            .foregroundStyle(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Toggle("", isOn: $announcementPreferences.isQuietDuringCallsEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .pointerCursor()
                }
            }
        }
    }

    private var quietDuringCallsDetail: String {
        let explanation = "While another app uses your microphone or camera, Wisp holds its announcements: finished tasks wait in the notch instead of notifying you. Anything you ask for still works."
        guard let activeQuietReason = quietModeMonitor.activeQuietReason else { return explanation }
        return "\(activeQuietReason.summary) — Wisp is keeping quiet right now. " + explanation
    }

    // MARK: - Apple Shortcuts

    /// Whether the agent can run the user's Apple Shortcuts, how many it
    /// found, and a manual refresh for after the user edits Shortcuts.
    private var appleShortcutsCard: some View {
        DashboardCard(title: "Apple Shortcuts") {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(appleShortcutsStatusTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.Colors.textPrimary)
                    Text(appleShortcutsStatusDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    Task { await shortcutsBridge.refresh() }
                } label: {
                    HStack(spacing: 5) {
                        if shortcutsBridge.isRefreshing {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        Text("Refresh")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(DS.Colors.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(DS.Colors.surface3)
                    )
                }
                .buttonStyle(.plain)
                .disabled(shortcutsBridge.isRefreshing)
                .pointerCursor(isEnabled: !shortcutsBridge.isRefreshing)
                .nativeTooltip("List your shortcuts again")
            }
        }
    }

    private var appleShortcutsStatusTitle: String {
        switch shortcutsBridge.availability {
        case .notChecked:
            return "Checking Shortcuts…"
        case .available:
            let shortcutCount = shortcutsBridge.shortcuts.count
            return shortcutCount == 1 ? "1 shortcut available" : "\(shortcutCount) shortcuts available"
        case .unavailable:
            return "Shortcuts unavailable"
        }
    }

    private var appleShortcutsStatusDetail: String {
        switch shortcutsBridge.availability {
        case .notChecked, .available:
            return "Ask Wisp to run one by name. Every run asks first, even with auto-approve on."
        case .unavailable(let reason):
            return reason
        }
    }

    // MARK: - Chrome tabs

    /// Whether the Wisp Tabs Chrome extension is connected, how to install
    /// it when it isn't, and what the user has let it do.
    private var chromeTabsCard: some View {
        DashboardCard(title: "Chrome Tabs") {
            VStack(alignment: .leading, spacing: 12) {
                chromeTabsConnectionRow
                if chromeExtensionBridge.isExtensionConnected {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(ChromeExtensionCapability.allCases, id: \.self) { capability in
                            chromeCapabilityRow(capability)
                        }
                    }
                }
                chromePermissionsButton
                ChromeTabSessionsRow()
            }
        }
    }

    private var chromeTabsConnectionRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(chromeExtensionBridge.isExtensionConnected ? DS.Colors.success : DS.Colors.warning)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(chromeTabsStatusTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Colors.textPrimary)
                Text(chromeTabsStatusDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if !chromeExtensionBridge.isExtensionConnected {
                Button {
                    openChromeExtensionsPage()
                } label: {
                    Text("Open Extensions")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DS.Colors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(DS.Colors.surface3)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .nativeTooltip("Open chrome://extensions to load the Wisp Tabs extension")
            }
        }
    }

    /// One capability: granted or not, and what it lets Wisp do.
    private func chromeCapabilityRow(_ capability: ChromeExtensionCapability) -> some View {
        let isGranted = chromeExtensionBridge.hasCapability(capability)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11))
                .foregroundStyle(isGranted ? DS.Colors.success : DS.Colors.textTertiary)
            Text(capability.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.Colors.textPrimary)
            Text(capability.whatItAllows)
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(isGranted ? "Allowed" : "Off")
                .font(.system(size: 11))
                .foregroundStyle(isGranted ? DS.Colors.success : DS.Colors.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    /// Chrome only shows a permission prompt after a click inside an
    /// extension page, so Wisp can't grant anything: this asks the extension
    /// to open its options page, where the Allow buttons are.
    private var chromePermissionsButton: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                openChromePermissionsPage()
            } label: {
                Text("Choose what Wisp can do in Chrome…")
            }
            .buttonStyle(WispPillButtonStyle(isProminent: false))
            .controlSize(.small)
            .disabled(!chromeExtensionBridge.isExtensionConnected)
            .pointerCursor()
            .nativeTooltip("Opens the extension's permissions page in Chrome")
            if let chromePermissionsPageErrorText {
                Text(chromePermissionsPageErrorText)
                    .font(.system(size: 11))
                    foregroundStyle(DS.Colors.warningText)
            }
        }
    }

    private func openChromePermissionsPage() {
        chromePermissionsPageErrorText = nil
        Task { @MainActor in
            do {
                _ = try await chromeExtensionBridge.sendRequest(
                    method: "openPermissionsPage",
                    parameters: [String: String](),
                    resultType: OpenPermissionsPageResult.self
                )
                // The page opens as a Chrome tab; bring Chrome forward so the
                // user sees it rather than Wisp's window.
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first?.activate()
            } catch {
                chromePermissionsPageErrorText = error.localizedDescription
            }
        }
    }

    private struct OpenPermissionsPageResult: Decodable {
        let opened: Bool?
    }

    private var chromeTabsStatusTitle: String {
        switch chromeExtensionBridge.connectionState {
        case .notStarted, .waitingForExtension:
            return "Extension not connected"
        case .connected(_, let browserName):
            return "Connected to \(browserName)"
        case .failed:
            return "Couldn't start the tab bridge"
        }
    }

    private var chromeTabsStatusDetail: String {
        switch chromeExtensionBridge.connectionState {
        case .notStarted, .waitingForExtension:
            return "In Chrome, turn on Developer mode in chrome://extensions, choose Load unpacked, and pick the chrome-extension folder in Wisp's source. It connects to Wisp on this Mac only (127.0.0.1)."
        case .connected:
            return "Say \"organize my tabs\" or \"close duplicate tabs\". Pinned tabs and your own groups stay put."
        case .failed(let reason):
            return reason
        }
    }

    /// chrome:// pages have no URL handler of their own, so the address is
    /// handed to Chrome directly.
    private func openChromeExtensionsPage() {
        guard let chromeApplicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"),
              let extensionsPageURL = URL(string: "chrome://extensions") else { return }
        NSWorkspace.shared.open(
            [extensionsPageURL],
            withApplicationAt: chromeApplicationURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}
