//
//  MarketplaceTab.swift
//  leanring-buddy
//
//  The MCP marketplace: browse a curated catalog of servers, install one in a
//  click (supplying any keys it needs), and manage what's installed — enable or
//  remove a server, and pick which of its tools the model may use.
//
//  The core tension this screen makes visible is the tool budget. The local
//  model chooses noticeably worse from a long list, so only a handful of tools
//  can be offered at once. Installing a server is therefore separate from
//  exposing its tools: the budget meter shows how many of the limited slots are
//  in use, and each server's tools can be toggled to stay within it.
//

import Combine
import SwiftUI

struct MarketplaceTab: View {
    @ObservedObject private var store = InstalledMCPServerStore.shared
    @ObservedObject private var mcpManager = MCPManager.shared
    @ObservedObject private var composio = ComposioAccountStore.shared

    @State private var catalogEntries: [MCPCatalogEntry] = []
    @State private var catalogError: String?
    @State private var searchText = ""
    @State private var selectedCategory: String?
    @State private var entryBeingInstalled: MCPCatalogEntry?
    @State private var composioKeyDraft = ""

    private let catalogProvider: MCPCatalogProvider = CuratedRegistryCatalogProvider()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                composioSection

                if !store.records.isEmpty {
                    installedSection
                }

                browseSection
            }
            .padding(16)
        }
        .background(WispColor.windowBackground)
        .task { await loadCatalog() }
        .sheet(item: $entryBeingInstalled) { entry in
            InstallSheet(entry: entry) { values in
                install(entry, values: values)
            }
        }
    }

    // MARK: - Installed

    private var installedSection: some View {
        DashboardCard(title: "Servers") {
            VStack(alignment: .leading, spacing: 10) {
                // The one fact worth knowing about the budget: how many tools there
                // are, and that the model is only ever shown a few per turn.
                Text("\(mcpManager.registeredToolCount) tools · the model sees the \(AgentToolScope.maximumExposedTools) most relevant each turn")
                    .font(.system(size: 11.5))
                    .foregroundStyle(WispColor.textSecondary)
                ForEach(store.records) { record in
                    InstalledServerRow(
                        record: record,
                        status: mcpManager.serverStatuses.first { $0.name == record.name }
                    )
                }
            }
        }
    }

    // MARK: - Browse

    private var browseSection: some View {
        DashboardCard(title: "Browse") {
            VStack(alignment: .leading, spacing: 12) {
                searchField

                if !allCategories.isEmpty {
                    categoryChips
                }

                if let catalogError {
                    Text(catalogError)
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.destructiveText)
                } else if filteredEntries.isEmpty {
                    Text("No servers match.")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textTertiary)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 8) {
                        ForEach(filteredEntries) { entry in
                            CatalogEntryRow(
                                entry: entry,
                                isInstalled: store.isInstalled(catalogId: entry.id),
                                onInstall: { beginInstall(entry) }
                            )
                        }
                    }
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.textTertiary)
            TextField("Search servers", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(DS.Colors.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface2)
        )
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                categoryChip(title: "All", value: nil)
                ForEach(allCategories, id: \.self) { category in
                    categoryChip(title: category, value: category)
                }
            }
        }
    }

    private func categoryChip(title: String, value: String?) -> some View {
        let isSelected = selectedCategory == value
        return Button {
            selectedCategory = value
        } label: {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? WispColor.textPrimary : WispColor.textSecondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background {
                    if isSelected {
                        Color.clear.wispBevel(Capsule(style: .continuous), fill: WispColor.surface3)
                    }
                }
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Composio

    private var composioSection: some View {
        DashboardCard(title: "Apps") {
            VStack(alignment: .leading, spacing: 12) {
                offMachineNote

                switch composio.state {
                case .notConfigured:
                    composioKeyEntry(prompt: "Paste your Composio key to connect apps like Gmail, Calendar and Notion.")
                case .validating:
                    Text("Connecting…")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textSecondary)
                case .failed(let message):
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.destructiveText)
                        .fixedSize(horizontal: false, vertical: true)
                    composioKeyEntry(prompt: "Enter your Composio key again.")
                case .ready:
                    composioConnectedView
                }

                if let error = composio.lastErrorMessage {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(DS.Colors.destructiveText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// One line: the thing worth knowing before connecting an app.
    private var offMachineNote: some View {
        Label("Apps run through Composio's cloud", systemImage: "cloud")
            .font(.system(size: 11.5))
            .foregroundStyle(WispColor.textSecondary)
    }

    private func composioKeyEntry(prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(prompt)
                .font(.system(size: 12.5))
                .foregroundStyle(WispColor.textSecondary)
            HStack(spacing: 8) {
                SecureField("Composio key", text: $composioKeyDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WispColor.surface2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(WispColor.cardSeparator.opacity(0.7), lineWidth: 0.5)
                    )

                Button("Connect") {
                    let key = composioKeyDraft
                    composioKeyDraft = ""
                    Task { await composio.connect(apiKey: key) }
                }
                .buttonStyle(WispPillButtonStyle())
                .disabled(composioKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                .pointerCursor()
            }
            if composio.hasAPIKey {
                Button("Use the saved key") { Task { await composio.connect() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WispColor.accentText)
                    .pointerCursor()
            }
        }
    }

    private var composioConnectedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            ComposioAppsView()

            Button("Remove key") {
                composio.disconnect()
                ComposioConnectionsStore.shared.reset()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(WispColor.textTertiary)
            .pointerCursor()
        }
    }

    // MARK: - Derived

    private var allCategories: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for entry in catalogEntries {
            for category in entry.resolvedCategories where !seen.contains(category) {
                seen.insert(category)
                ordered.append(category)
            }
        }
        return ordered.sorted()
    }

    private var filteredEntries: [MCPCatalogEntry] {
        catalogEntries.filter { entry in
            let matchesCategory = selectedCategory == nil
                || entry.resolvedCategories.contains(selectedCategory!)
            let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
            let matchesSearch = query.isEmpty
                || entry.name.lowercased().contains(query)
                || entry.summary.lowercased().contains(query)
                || entry.publisher.lowercased().contains(query)
            return matchesCategory && matchesSearch
        }
        .sorted { $0.name < $1.name }
    }

    // MARK: - Actions

    private func loadCatalog() async {
        do {
            catalogEntries = try await catalogProvider.entries()
            catalogError = nil
        } catch {
            catalogError = error.localizedDescription
        }
    }

    private func beginInstall(_ entry: MCPCatalogEntry) {
        if entry.resolvedConfigFields.isEmpty {
            install(entry, values: [:])
        } else {
            entryBeingInstalled = entry
        }
    }

    private func install(_ entry: MCPCatalogEntry, values: [String: String]) {
        do {
            try store.install(entry, values: values)
        } catch {
            catalogError = error.localizedDescription
        }
        entryBeingInstalled = nil
    }
}

// MARK: - Catalog entry row

private struct CatalogEntryRow: View {
    let entry: MCPCatalogEntry
    let isInstalled: Bool
    let onInstall: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.iconSymbol)
                .font(.system(size: 15))
                .foregroundStyle(DS.Colors.accentText)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .fill(DS.Colors.accent.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Colors.textPrimary)
                    if entry.kind == .remote {
                        Text("remote")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(DS.Colors.textTertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(DS.Colors.surface2))
                    }
                }
                Text(entry.summary)
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(entry.publisher)
                    .font(.system(size: 9))
                    .foregroundStyle(DS.Colors.textTertiary)
            }

            Spacer(minLength: 8)

            if isInstalled {
                Label("Installed", systemImage: "checkmark")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DS.Colors.success)
            } else {
                Button(action: onInstall) {
                    Text("Install")
                }
                .buttonStyle(WispPillButtonStyle())
                .controlSize(.small)
                .pointerCursor()
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface2)
        )
    }
}

// MARK: - Installed server row

private struct InstalledServerRow: View {
    let record: InstalledMCPServerStore.Record
    let status: MCPManager.ServerStatus?

    @ObservedObject private var store = InstalledMCPServerStore.shared
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 7, height: 7)

                Text(record.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.Colors.textPrimary)

                if record.source == "composio" {
                    Text("cloud · Composio")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(DS.Colors.warningText)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(DS.Colors.warning.opacity(0.15)))
                } else if record.transport == .streamableHttp {
                    Text("remote")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(DS.Colors.textTertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(DS.Colors.background))
                }

                Spacer(minLength: 8)

                Text(statusText)
                    .font(.system(size: 10))
                    .foregroundStyle(indicatorColor)

                Toggle("", isOn: Binding(
                    get: { record.isEnabled },
                    set: { setEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(WispColor.accentText)
                .pointerCursor()
            }

            if case .failed(let reason)? = status?.state {
                Text(reason)
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                if let offered = status?.offeredTools, !offered.isEmpty {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                            Text("\(offered.count) tools")
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(DS.Colors.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }

                Spacer(minLength: 0)

                Button {
                    uninstall()
                } label: {
                    Text("Remove")
                }
                .buttonStyle(WispPillButtonStyle(isProminent: false))
                .controlSize(.small)
                .pointerCursor()
            }

            if isExpanded, let offered = status?.offeredTools {
                toolList(offered: offered)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface2)
        )
    }

    private func toolList(offered: [String]) -> some View {
        let allowed = store.allowedTools(name: record.name)
        // Empty allow-list means "all offered are permitted".
        let permitted: Set<String> = allowed.isEmpty ? Set(offered) : allowed

        return VStack(spacing: 4) {
            ForEach(offered.sorted(), id: \.self) { toolName in
                let isPermitted = permitted.contains(toolName)
                HStack(spacing: 8) {
                    Button {
                        toggleTool(toolName, offered: offered, currentlyPermitted: permitted)
                    } label: {
                        Image(systemName: isPermitted ? "checkmark.square.fill" : "square")
                            .font(.system(size: 12))
                            .foregroundStyle(isPermitted ? DS.Colors.accentText : DS.Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Text(toolName)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(DS.Colors.textSecondary)

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                .fill(DS.Colors.background)
        )
    }

    private var indicatorColor: Color {
        switch status?.state {
        case .connected?: return DS.Colors.success
        case .connecting?, .installing?: return DS.Colors.warningText
        case .failed?: return DS.Colors.destructiveText
        case .disabled?, .none: return DS.Colors.textTertiary
        }
    }

    private var statusText: String {
        status?.state.displayName ?? (record.isEnabled ? "…" : "Disabled")
    }

    // MARK: Actions

    private func setEnabled(_ isEnabled: Bool) {
        try? store.setEnabled(name: record.name, isEnabled: isEnabled)
    }

    private func uninstall() {
        try? store.uninstall(name: record.name)
    }

    private func toggleTool(_ toolName: String, offered: [String], currentlyPermitted: Set<String>) {
        var next = currentlyPermitted
        if next.contains(toolName) {
            next.remove(toolName)
        } else {
            next.insert(toolName)
        }
        // If everything offered is permitted, store an empty list (= "all"),
        // which keeps future-added tools available too.
        let tools = next == Set(offered) ? [] : Array(next)
        try? store.setAllowedTools(name: record.name, tools: tools)
    }
}

// MARK: - Install sheet

private struct InstallSheet: View {
    let entry: MCPCatalogEntry
    let onInstall: ([String: String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: entry.iconSymbol)
                    .font(.system(size: 18))
                    .foregroundStyle(DS.Colors.accentText)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Install \(entry.name)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.Colors.textPrimary)
                    Text(entry.publisher)
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textTertiary)
                }
            }

            Text(entry.summary)
                .font(.system(size: 12))
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(entry.resolvedConfigFields) { field in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(field.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DS.Colors.textPrimary)
                        fieldEditor(for: field)
                    }
                }
            }

            if entry.resolvedConfigFields.contains(where: \.secret) {
                Text("Secrets are saved to ~/.wisp/mcp.json on this Mac, the same place Claude Desktop keeps them.")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .pointerCursor()

                Button {
                    onInstall(values)
                } label: {
                    Text("Install")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Colors.background)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(DS.Colors.accent))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(!requiredFieldsFilled)
                .opacity(requiredFieldsFilled ? 1 : 0.5)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(WispColor.windowBackground)
    }

    @ViewBuilder
    private func fieldEditor(for field: ConfigField) -> some View {
        let binding = Binding(
            get: { values[field.id] ?? "" },
            set: { values[field.id] = $0 }
        )
        Group {
            if field.secret {
                SecureField(field.resolvedPlaceholder, text: binding)
            } else {
                TextField(field.resolvedPlaceholder, text: binding)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(DS.Colors.textPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface2)
        )
    }

    private var requiredFieldsFilled: Bool {
        entry.resolvedConfigFields.allSatisfy { field in
            !(values[field.id]?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        }
    }
}
