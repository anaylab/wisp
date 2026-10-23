//
//  BrowserSettingsCard.swift
//  leanring-buddy
//
//  Settings → Agent → Browser: everything about the Wisp extension in one
//  card (phase 13). Each connected browser with what it lets Wisp do and an
//  Allow… button for what it doesn't yet, the switches phases 04/07/09/10
//  added, and a "What Wisp can do in your browser" list of things to say.
//
//  Wisp can't grant a browser permission itself: Chrome only shows the prompt
//  after a click inside an extension page, so Allow… asks that browser's
//  extension to open its options page and brings the browser forward.
//

import AppKit
import SwiftUI

struct BrowserSettingsCard: View {
    @ObservedObject private var chromeExtensionBridge = ChromeExtensionBridge.shared
    /// Why the last Allow… click didn't open the page, shown until the next try.
    @State private var permissionsPageErrorText: String?
    @State private var isShowingWhatWispCanDo = false

    var body: some View {
        DashboardCard(title: "Browser") {
            VStack(alignment: .leading, spacing: 14) {
                if chromeExtensionBridge.connectedBrowsers.isEmpty {
                    notConnectedRow
                } else {
                    ForEach(chromeExtensionBridge.connectedBrowsers) { connectedBrowser in
                        connectedBrowserSection(connectedBrowser)
                    }
                }
                if let permissionsPageErrorText {
                    Text(permissionsPageErrorText)
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.warningText)
                }
                Divider()
                ChromeTabSessionsRow()
                DownloadConciergeSettingsRow()
                CanvasAddToTodaySettingsRow()
                ChromeFocusSettingsRow()
                Divider()
                whatWispCanDoDisclosure
            }
        }
    }

    // MARK: - Connections

    private var notConnectedRow: some View {
        HStack(alignment: .top, spacing: 10) {
            statusDot(isConnected: false)
            VStack(alignment: .leading, spacing: 3) {
                Text(notConnectedTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Colors.textPrimary)
                Text(notConnectedDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Open Extensions") {
                openChromeExtensionsPage()
            }
            .buttonStyle(WispPillButtonStyle(isProminent: false))
            .controlSize(.small)
            .pointerCursor()
            .nativeTooltip("Open chrome://extensions in Chrome to load the Wisp extension")
        }
    }

    private var notConnectedTitle: String {
        if case .failed = chromeExtensionBridge.connectionState { return "Couldn't start the browser bridge" }
        return "Extension not connected"
    }

    private var notConnectedDetail: String {
        if case .failed(let reason) = chromeExtensionBridge.connectionState { return reason }
        return "In chrome://extensions, turn on Developer mode, choose Load unpacked and pick the chrome-extension folder in Wisp's source. Arc, Brave, Edge and Vivaldi work too. It talks only to Wisp on this Mac."
    }

    private func connectedBrowserSection(_ connectedBrowser: ChromeExtensionBridge.ConnectedBrowser) -> some View {
        let isActiveBrowser = connectedBrowser.id == chromeExtensionBridge.activeBrowserID
        let showsInUseTag = isActiveBrowser && chromeExtensionBridge.connectedBrowsers.count > 1
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                statusDot(isConnected: true)
                Text(connectedBrowser.browserName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Colors.textPrimary)
                Text("v\(connectedBrowser.extensionVersion)")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textTertiary)
                if showsInUseTag {
                    Text("In use")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(DS.Colors.surface3))
                        .nativeTooltip("Wisp works in the browser you're using, and stays in one while its work there is going.")
                }
                Spacer(minLength: 0)
            }
            ForEach(ChromeExtensionCapability.allCases, id: \.self) { capability in
                capabilityRow(capability, in: connectedBrowser)
            }
            .padding(.leading, 15)
        }
    }

    private func capabilityRow(_ capability: ChromeExtensionCapability, in connectedBrowser: ChromeExtensionBridge.ConnectedBrowser) -> some View {
        let isGranted = connectedBrowser.capabilities.contains(capability)
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
            if isGranted {
                Text("Allowed")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.success)
            } else {
                Button("Allow…") {
                    openPermissionsPage(in: connectedBrowser)
                }
                .buttonStyle(WispPillButtonStyle(isProminent: false))
                .controlSize(.small)
                .pointerCursor()
                .nativeTooltip("Opens the extension's permissions page in \(connectedBrowser.browserName)")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func statusDot(isConnected: Bool) -> some View {
        Circle()
            .fill(isConnected ? DS.Colors.success : DS.Colors.warning)
            .frame(width: 7, height: 7)
    }

    private func openPermissionsPage(in connectedBrowser: ChromeExtensionBridge.ConnectedBrowser) {
        permissionsPageErrorText = nil
        Task { @MainActor in
            do {
                _ = try await chromeExtensionBridge.sendRequest(
                    method: "openPermissionsPage",
                    parameters: [String: String](),
                    resultType: OpenPermissionsPageResult.self,
                    toBrowserWithID: connectedBrowser.id
                )
                // The page opens as a tab; bring that browser forward so the
                // user sees it rather than Wisp's window.
                chromeExtensionBridge.bringBrowserForward(browserID: connectedBrowser.id)
            } catch {
                permissionsPageErrorText = error.localizedDescription
            }
        }
    }

    private struct OpenPermissionsPageResult: Decodable {
        let opened: Bool?
    }

    /// chrome:// pages have no URL handler of their own, so the address is
    /// handed to Chrome directly.
    private func openChromeExtensionsPage() {
        guard let chromeApplicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ChromiumBrowserCatalog.googleChromeBundleIdentifier),
              let extensionsPageURL = URL(string: "chrome://extensions") else { return }
        NSWorkspace.shared.open(
            [extensionsPageURL],
            withApplicationAt: chromeApplicationURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    // MARK: - What Wisp can do

    private var whatWispCanDoDisclosure: some View {
        DisclosureGroup(isExpanded: $isShowingWhatWispCanDo) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(BrowserCommandExamples.groups, id: \.title) { commandGroup in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(commandGroup.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DS.Colors.textSecondary)
                        ForEach(commandGroup.examples, id: \.self) { example in
                            Text(example)
                                .font(.system(size: 11))
                                .foregroundStyle(DS.Colors.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Text("What Wisp can do in your browser")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.Colors.textPrimary)
        }
        .pointerCursor()
    }
}

/// The things to say (or click) for each capability, shown in the card's
/// disclosure. Kept to one example per feature.
enum BrowserCommandExamples {
    struct Group {
        let title: String
        let examples: [String]
    }

    static let groups: [Group] = [
        Group(title: "Tabs (always)", examples: [
            "\u{201C}organize my tabs\u{201D} · \u{201C}close duplicate tabs\u{201D} · \u{201C}mute my tabs\u{201D}",
            "\u{201C}save these tabs as thesis research\u{201D} · \u{201C}restore thesis research\u{201D}",
            "\u{201C}clean up old tabs\u{201D} · \u{201C}triage my tabs\u{201D}",
            "\u{201C}focus on my essay for 45 minutes\u{201D} · \u{201C}stop focus\u{201D}",
        ]),
        Group(title: "With Read pages", examples: [
            "\u{201C}summarize this tab\u{201D} · \u{201C}add this page to my brain\u{201D}",
            "\u{201C}where's the sign-in button?\u{201D} marks it in the page",
            "Right-click → Ask Wisp…, \u{201C}w your question\u{201D} in the address bar, or ⌘⇧Y",
            "\u{201C}tell me when this tab says Deployed\u{201D} · \u{201C}tell me when the price drops below $80\u{201D}",
            "On a Canvas assignment: \u{201C}is this on my checklist?\u{201D} · \u{201C}add this to today\u{201D} · \u{201C}plan this\u{201D}",
            "In a Meet or Zoom call with captions on: \u{201C}what did I miss?\u{201D}",
            "\u{201C}research the best budget mechanical keyboards\u{201D}",
            "\u{201C}fill this form\u{201D} (never passwords or card numbers, and Wisp doesn't submit)",
        ]),
        Group(title: "With Downloads", examples: [
            "A finished download gets File, Just brain or Ignore in the notch",
        ]),
    ]
}
