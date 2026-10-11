//
//  BuddyToolsView.swift
//  leanring-buddy
//
//  What a buddy may use, and the way to connect more. Two modes: Everything (the
//  default — every tool, every connected app) or Choose, which shows one row per
//  thing with a switch. Apps come first, with their real logos, because they are
//  what people reach for; Wisp's own abilities (browser, screen, messages …)
//  follow. "Add app" opens a sheet that connects an app without leaving the
//  buddy: it asks for the Composio key if there isn't one, then lists apps with
//  Connect buttons.
//
//  An app the buddy isn't given is refused at call time, not just hidden
//  (`BuddyToolAccessPolicy.appRefusalReason`), so the switches mean what they say.
//

import SwiftUI

struct BuddyToolsView: View {
    @Binding var toolAccess: BuddyToolAccess?
    /// Whether the buddy's model runs off this Mac, which takes the brain and
    /// the user's memory off the table.
    let modelSendsDataOffThisMachine: Bool
    let colorIndex: Int

    @ObservedObject private var toolRegistry = AgentToolRegistry.shared
    @ObservedObject private var buddyStore = BuddyStore.shared
    @ObservedObject private var connections = ComposioConnectionsStore.shared
    @ObservedObject private var composio = ComposioAccountStore.shared
    @State private var isShowingConnectSheet = false

    private var accent: Color { BuddyAppearance.deepColor(forColorIndex: colorIndex) }
    private var composioGroupID: String { BuddyToolAccessPolicy.groupID(forServerNamed: ComposioAccountStore.serverId) }

    /// Apps that are connected right now, in the list's own order.
    private var connectedApps: [ComposioApp] {
        let customConnected = connections.statusBySlug.compactMap { slug, status -> ComposioApp? in
            guard case .connected = status, !ComposioApp.curated.contains(where: { $0.slug == slug }) else { return nil }
            return ComposioApp.custom(named: slug)
        }
        let curatedConnected = ComposioApp.curated.filter {
            if case .connected = connections.status(of: $0) { return true }
            return false
        }
        return curatedConnected + customConnected.sorted { $0.slug < $1.slug }
    }

    private var availableGroups: [BuddyToolGroup] {
        let registeredToolNames = toolRegistry.toolNames
        return BuddyToolGroup.allCases.filter { group in
            if group == .delegation { return buddyStore.buddies.count > 1 }
            return registeredToolNames.contains { BuddyToolGroup.group(forToolNamed: $0) == group }
        }
    }

    /// Connected MCP servers other than Composio (which the app rows stand in for).
    private var otherServerNames: [String] {
        BuddyToolAccessPolicy.serverNames(inToolNames: toolRegistry.toolNames)
            .filter { $0 != ComposioAccountStore.serverId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            modePicker

            if let limitedAccess = toolAccess {
                appsSection(limitedAccess)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                wispSection(limitedAccess)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                everythingSummary
                    .transition(.opacity)
            }
        }
        .animation(WispMotion.smooth, value: toolAccess == nil)
        .task { await refreshConnectionsIfPossible() }
        .sheet(isPresented: $isShowingConnectSheet, onDismiss: { Task { await refreshConnectionsIfPossible() } }) {
            BuddyConnectAppsSheet(onDone: { isShowingConnectSheet = false })
        }
    }

    private func refreshConnectionsIfPossible() async {
        guard composio.hasAPIKey, composio.isServerInstalled else { return }
        await connections.refresh()
    }

    // MARK: - Mode

    private var modePicker: some View {
        HStack(spacing: 2) {
            modeButton("Everything", isSelected: toolAccess == nil) { toolAccess = nil }
            modeButton("Choose", isSelected: toolAccess != nil) {
                if toolAccess == nil { toolAccess = BuddyToolAccess.everythingAsChoices(connectedAppSlugs: Set(connectedApps.map(\.slug)), availableGroupIDs: availableGroups.map(\.rawValue), serverIDs: otherServerNames.map(BuddyToolAccessPolicy.groupID(forServerNamed:)), composioGroupID: composioGroupID) }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(WispColor.surface3.opacity(0.6)))
        .animation(WispMotion.quick, value: toolAccess == nil)
    }

    private func modeButton(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(WispMotion.smooth, action)
        } label: {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? WispColor.textPrimary : WispColor.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background {
                    if isSelected {
                        Color.clear.buddyBevel(RoundedRectangle(cornerRadius: 8, style: .continuous), fill: WispColor.surface1)
                            .transition(.opacity)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Everything

    private var everythingSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            if connectedApps.isEmpty {
                Text("Every tool Wisp has.")
                    .font(.system(size: 13)).foregroundStyle(WispColor.textSecondary)
            } else {
                HStack(spacing: -6) {
                    ForEach(connectedApps.prefix(7)) { app in
                        ComposioAppIcon(app: app, size: 28)
                            .overlay(Circle().stroke(WispColor.windowBackground, lineWidth: 0))
                    }
                    if connectedApps.count > 7 {
                        Text("+\(connectedApps.count - 7)")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(WispColor.textSecondary)
                            .padding(.leading, 12)
                    }
                }
                Text("Every tool Wisp has, and your \(connectedApps.count) connected \(connectedApps.count == 1 ? "app" : "apps").")
                    .font(.system(size: 13)).foregroundStyle(WispColor.textSecondary)
            }
            addAppButton
        }
    }

    // MARK: - Apps

    private func appsSection(_ access: BuddyToolAccess) -> some View {
        let connectedSlugs = Set(connectedApps.map(\.slug))
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionHeader("Apps")
                Spacer()
                if !connectedApps.isEmpty { addAppButton }
            }

            if connectedApps.isEmpty {
                Button { isShowingConnectSheet = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(accent)
                            .frame(width: 32, height: 32)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(accent.opacity(0.12)))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Connect an app").font(.system(size: 13, weight: .semibold)).foregroundStyle(WispColor.textPrimary)
                            Text("Gmail, Calendar, Notion, Slack and more").font(.system(size: 11.5)).foregroundStyle(WispColor.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(WispColor.textTertiary)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(WispColor.surface2.opacity(0.7)))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PressableScaleButtonStyle())
                .pointerCursor()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(connectedApps.enumerated()), id: \.element.id) { index, app in
                        toggleRow(
                            icon: AnyView(ComposioAppIcon(app: app, size: 30)),
                            title: app.name,
                            subtitle: nil,
                            isOn: access.allowsApp(app.slug),
                            isUnavailable: false
                        ) { newValue in
                            toolAccess = access.settingApp(app.slug, isAllowed: newValue, connectedAppSlugs: connectedSlugs)
                        }
                        if index < connectedApps.count - 1 { rowDivider }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(WispColor.surface2.opacity(0.7)))
            }
        }
    }

    private var addAppButton: some View {
        Button { isShowingConnectSheet = true } label: {
            Label("Add app", systemImage: "plus")
        }
        .buttonStyle(BuddyPillButtonStyle(colorIndex: colorIndex, isProminent: false))
        .pointerCursor()
    }

    // MARK: - Wisp's own abilities

    private func wispSection(_ access: BuddyToolAccess) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Wisp")
            VStack(spacing: 0) {
                ForEach(Array(availableGroups.enumerated()), id: \.element.id) { index, group in
                    let isUnavailable = group.isPrivateKnowledge && modelSendsDataOffThisMachine
                    toggleRow(
                        icon: AnyView(symbolTile(group.symbolName)),
                        title: group.title,
                        subtitle: isUnavailable ? "Local models only" : group.summary,
                        isOn: access.allows(group) && !isUnavailable,
                        isUnavailable: isUnavailable
                    ) { newValue in
                        toolAccess = access.setting(groupID: group.rawValue, isAllowed: newValue)
                    }
                    if index < availableGroups.count - 1 || !otherServerNames.isEmpty { rowDivider }
                }
                ForEach(Array(otherServerNames.enumerated()), id: \.element) { index, serverName in
                    toggleRow(
                        icon: AnyView(symbolTile("puzzlepiece.extension")),
                        title: serverName,
                        subtitle: "Connected server",
                        isOn: access.allowsServer(named: serverName),
                        isUnavailable: false
                    ) { newValue in
                        toolAccess = access.setting(groupID: BuddyToolAccessPolicy.groupID(forServerNamed: serverName), isAllowed: newValue)
                    }
                    if index < otherServerNames.count - 1 { rowDivider }
                }
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(WispColor.surface2.opacity(0.7)))

            Button {
                WispWindowNavigator.open(.marketplace)
            } label: {
                Label("Browse more in Connections", systemImage: "arrow.up.forward")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(WispColor.textSecondary)
            }
            .buttonStyle(.plain).pointerCursor().padding(.top, 4)
        }
    }

    // MARK: - Pieces

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(WispColor.textSecondary)
    }

    private var rowDivider: some View {
        Rectangle().fill(WispColor.cardSeparator.opacity(0.4)).frame(height: 0.5).padding(.leading, 54)
    }

    private func symbolTile(_ symbolName: String) -> some View {
        Image(systemName: symbolName)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(accent)
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(accent.opacity(0.12)))
    }

    private func toggleRow(
        icon: AnyView, title: String, subtitle: String?,
        isOn: Bool, isUnavailable: Bool, set: @escaping (Bool) -> Void
    ) -> some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(WispColor.textPrimary)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(WispColor.textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Toggle("", isOn: Binding(get: { isOn }, set: { newValue in withAnimation(WispMotion.quick) { set(newValue) } }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(accent)
                .disabled(isUnavailable)
                .pointerCursor()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .opacity(isUnavailable ? 0.5 : 1)
    }
}

// MARK: - Connect sheet

/// Connecting an app from inside a buddy: the Composio key if there isn't one
/// yet, then the app list with Connect buttons.
struct BuddyConnectAppsSheet: View {
    var onDone: () -> Void

    @ObservedObject private var composio = ComposioAccountStore.shared
    @State private var keyDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Add apps").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction).pointerCursor()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch composio.state {
                    case .ready:
                        ComposioAppsView()
                    case .validating:
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Connecting to Composio…").font(.system(size: 13)).foregroundStyle(WispColor.textSecondary) }
                    case .notConfigured, .failed:
                        keyEntry
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .padding(22)
        .frame(width: 520, height: 560)
    }

    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apps connect through Composio. Paste your Composio key to begin; it stays in your Keychain.")
                .font(.system(size: 13)).foregroundStyle(WispColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                SecureField("Composio key", text: $keyDraft).textFieldStyle(.roundedBorder)
                Button("Connect") {
                    let key = keyDraft
                    keyDraft = ""
                    Task { await composio.connect(apiKey: key) }
                }
                .buttonStyle(BuddyPillButtonStyle(colorIndex: 0))
                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                .pointerCursor()
            }
            if composio.hasAPIKey {
                Button("Use the saved key") { Task { await composio.connect() } }.buttonStyle(.link).pointerCursor()
            }
            if case .failed(let message) = composio.state {
                Text(message).font(.system(size: 12)).foregroundStyle(DS.Colors.destructiveText)
            }
            Text("Composio runs in the cloud: what a connected app does passes through its servers.")
                .font(.system(size: 11.5)).foregroundStyle(WispColor.textTertiary)
        }
    }
}
