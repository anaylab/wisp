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
                budgetSection

                if !store.records.isEmpty {
                    installedSection
                }

                browseSection
                composioSection
            }
            .padding(16)
        }
        .background(DS.Colors.background)
        .task { await loadCatalog() }
        .sheet(item: $entryBeingInstalled) { entry in
            InstallSheet(entry: entry) { values in
                install(entry, values: values)
            }
        }
    }

    // MARK: - Budget

    private var budgetSection: some View {
        DashboardCard(title: "Model tool budget") {
            let used = mcpManager.exposedToolCount
            let total = MCPManager.maximumExposedTools
            let fraction = total > 0 ? min(1, Double(used) / Double(total)) : 0

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(used) of \(total) tool slots in use")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.Colors.textPrimary)
                    Spacer()
                    if used >= total {
                        Text("full")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DS.Colors.warningText)
                    }
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DS.Colors.surface2)
                        Capsule()
                            .fill(budgetColor(fraction: fraction))
                            .frame(width: max(4, proxy.size.width * fraction))
                    }
                }
                .frame(height: 6)

                Text("The local model picks better from a short list, so only \(total) MCP tools are offered at once. Toggle a server's tools below to choose which ones fill the slots.")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func budgetColor(fraction: Double) -> Color {
        switch fraction {
        case ..<0.75: return DS.Colors.success
        case ..<1.0: return DS.Colors.warning
        default: return DS.Colors.warning
        }
    }

    // MARK: - Installed

    private var installedSection: some View {
        DashboardCard(title: "Installed") {
            VStack(spacing: 8) {
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
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isSelected ? DS.Colors.background : DS.Colors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(isSelected ? DS.Colors.accent : DS.Colors.surface2)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Composio

    private var composioSection: some View {
        DashboardCard(title: "Composio · cloud toolkits") {
            VStack(alignment: .leading, spacing: 12) {
                offMachineNote

                switch composio.state {
                case .notConfigured:
                    composioKeyEntry(prompt: "Paste your Composio API key (sent as x-consumer-api-key) to connect the universal server.")
                case .validating:
                    Text("Connecting…")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textSecondary)
                case .failed(let message):
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.destructiveText)
                        .fixedSize(horizontal: false, vertical: true)
                    composioKeyEntry(prompt: "Re-enter your Composio API key.")
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

    private var offMachineNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "cloud")
                .font(.system(size: 12))
                .foregroundStyle(DS.Colors.warningText)
            Text("Composio runs in the cloud. Its servers send your transcript and tool calls off this Mac to Composio and the connected app. Local servers stay the default.")
                .font(.system(size: 10))
                .foregroundStyle(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.warning.opacity(0.08))
        )
    }

    private func composioKeyEntry(prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(prompt)
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.textSecondary)
            HStack(spacing: 8) {
                SecureField("Composio API key", text: $composioKeyDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(DS.Colors.surface2)
                    )

                Button {
                    let key = composioKeyDraft
                    composioKeyDraft = ""
                    Task { await composio.connect(apiKey: key) }
                } label: {
                    Text("Connect")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.Colors.background)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(DS.Colors.accent))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(composioKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(composioKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            }
            if composio.hasAPIKey {
                HStack(spacing: 8) {
                    Button {
                        Task { await composio.connect() }
                    } label: {
                        Text("Connect saved key")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DS.Colors.accentText)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Text("— a key is already saved; connect it without re-entering.")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.Colors.textTertiary)
                }
            }

            Text("The key is saved to your login Keychain, never to the config file.")
                .font(.system(size: 10))
                .foregroundStyle(DS.Colors.textTertiary)
        }
    }

    private var composioConnectedView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.Colors.success)
                Text(composio.isServerInstalled
                     ? "Connected — the universal server is installed."
                     : "Key saved.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Colors.textPrimary)
                Spacer()
                Button {
                    composio.disconnect()
                } label: {
                    Text("Disconnect")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DS.Colors.destructiveText)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            Text("Its tools (search, execute, manage-connections) appear under Installed above and count against the tool budget. The model finds any of Composio's 500+ apps through them; Composio prompts you to sign in to an app the first time it's used.")
                .font(.system(size: 10))
                .foregroundStyle(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
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
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.Colors.background)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(DS.Colors.accent))
                }
                .buttonStyle(.plain)
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
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
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
                .controlSize(.mini)
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

                Button(role: .destructive) {
                    uninstall()
                } label: {
                    Text("Remove")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DS.Colors.destructiveText)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            if isExpanded, let offered = status?.offeredTools {
                toolList(offered: offered, exposed: Set(status?.exposedTools ?? []))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface2)
        )
    }

    private func toolList(offered: [String], exposed: Set<String>) -> some View {
        let allowed = store.allowedTools(name: record.name)
        // Empty allow-list means "all offered are permitted".
        let permitted: Set<String> = allowed.isEmpty ? Set(offered) : allowed

        return VStack(spacing: 4) {
            ForEach(offered.sorted(), id: \.self) { toolName in
                let isPermitted = permitted.contains(toolName)
                let isLive = exposed.contains(toolName)
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

                    // A tool can be permitted yet not live when the shared budget
                    // is already full — worth saying, so the meter makes sense.
                    if isPermitted && !isLive {
                        Text("over budget")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(DS.Colors.warningText)
                    }
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
        case .connecting?: return DS.Colors.warningText
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
        .background(DS.Colors.background)
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
