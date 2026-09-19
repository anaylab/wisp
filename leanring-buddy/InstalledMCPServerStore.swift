//
//  InstalledMCPServerStore.swift
//  leanring-buddy
//
//  The source of truth for which MCP servers are installed. It reads and writes
//  ~/.wisp/mcp.json — the same file MCPManager connects from — so the
//  marketplace can install, remove, enable, and re-scope servers without the
//  user hand-editing JSON.
//
//  Two things matter here. First, the whole file is preserved on write: the raw
//  root dictionary is kept and only the touched entry is changed, so a hand-added
//  server, a comment, or a field this app doesn't understand survives a round
//  trip. Second, every mutation reloads MCPManager, so a change takes effect
//  immediately rather than at the next launch.
//
//  Installing writes an entry in the same superset format MCPManager reads:
//  a stdio "command"/"args"/"env" entry, or a remote "url"/"headers" entry, plus
//  "source"/"catalogId"/"summary" the marketplace reads back for display and
//  MCPManager ignores.
//

import Combine
import Foundation

@MainActor
final class InstalledMCPServerStore: ObservableObject {
    static let shared = InstalledMCPServerStore()

    /// One installed server, as the marketplace displays it.
    struct Record: Identifiable {
        var id: String { name }
        let name: String
        let transport: MCPTransportKind
        /// "curated", "custom", or "composio" — where it was installed from.
        let source: String
        /// The catalog entry it came from, when installed from the marketplace.
        let catalogId: String?
        var isEnabled: Bool
        let summary: String?
    }

    @Published private(set) var records: [Record] = []

    /// The whole mcp.json root, preserved verbatim so unknown keys survive.
    private var rawRoot: [String: Any] = ["mcpServers": [String: Any]()]

    private var configurationFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wisp/mcp.json")
    }

    private init() {
        reloadFromDisk()
    }

    // MARK: - Reading

    /// Re-reads mcp.json into `records`. Tolerates an absent or malformed file
    /// by treating it as "no servers", the normal first-run state.
    func reloadFromDisk() {
        if let data = try? Data(contentsOf: configurationFileURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            rawRoot = root
        } else {
            rawRoot = ["mcpServers": [String: Any]()]
        }
        rebuildRecords()
    }

    private var rawServers: [String: Any] {
        get { rawRoot["mcpServers"] as? [String: Any] ?? [:] }
        set { rawRoot["mcpServers"] = newValue }
    }

    private func rebuildRecords() {
        let servers = rawServers
        records = servers.compactMap { name, value -> Record? in
            guard let entry = value as? [String: Any] else { return nil }

            let isRemote = (entry["url"] as? String) != nil
            return Record(
                name: name,
                transport: isRemote ? .streamableHttp : .stdio,
                source: entry["source"] as? String ?? "custom",
                catalogId: entry["catalogId"] as? String,
                isEnabled: entry["enabled"] as? Bool ?? true,
                summary: entry["summary"] as? String
            )
        }
        .sorted { $0.name < $1.name }
    }

    /// The catalog ids already installed, so the marketplace can mark them.
    var installedCatalogIds: Set<String> {
        Set(records.compactMap(\.catalogId))
    }

    func isInstalled(catalogId: String) -> Bool {
        rawServers[catalogId] != nil || installedCatalogIds.contains(catalogId)
    }

    // MARK: - Mutations

    enum StoreError: LocalizedError {
        case alreadyInstalled(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .alreadyInstalled(let name): return "\"\(name)\" is already installed."
            case .writeFailed(let reason): return "couldn't save the config: \(reason)"
            }
        }
    }

    /// Installs a catalog entry, filling in the user-supplied values, then
    /// reconnects so the server's tools become available.
    func install(_ entry: MCPCatalogEntry, values: [String: String]) throws {
        guard rawServers[entry.id] == nil else {
            throw StoreError.alreadyInstalled(entry.id)
        }

        var entryDictionary: [String: Any] = [
            "source": "curated",
            "catalogId": entry.id,
            "summary": entry.summary,
            "enabled": true
        ]

        switch entry.kind {
        case .stdio:
            entryDictionary["command"] = entry.command ?? ""
            // Expand a leading ~ so the spawned server gets a real path; other
            // arguments are unaffected.
            entryDictionary["args"] = entry.resolvedArguments.map {
                ($0 as NSString).expandingTildeInPath
            }
            let environment = collectValues(entry: entry, target: .env, values: values)
            if !environment.isEmpty { entryDictionary["env"] = environment }

        case .remote:
            entryDictionary["url"] = entry.url ?? ""
            let headers = collectValues(entry: entry, target: .header, values: values)
            if !headers.isEmpty { entryDictionary["headers"] = headers }
        }

        var servers = rawServers
        servers[entry.id] = entryDictionary
        rawServers = servers

        try persistAndReload()
    }

    func uninstall(name: String) throws {
        var servers = rawServers
        servers.removeValue(forKey: name)
        rawServers = servers
        try persistAndReload()
    }

    func setEnabled(name: String, isEnabled: Bool) throws {
        try mutateEntry(name: name) { entry in
            entry["enabled"] = isEnabled
        }
    }

    /// Sets which of a server's tools are offered to the model. An empty list
    /// removes the restriction, meaning "expose all" (subject to the budget).
    func setAllowedTools(name: String, tools: [String]) throws {
        try mutateEntry(name: name) { entry in
            if tools.isEmpty {
                entry.removeValue(forKey: "allowedTools")
            } else {
                entry["allowedTools"] = tools
            }
        }
    }

    /// The current allow-list for a server, empty when unrestricted.
    func allowedTools(name: String) -> Set<String> {
        guard let entry = rawServers[name] as? [String: Any],
              let list = entry["allowedTools"] as? [String] else { return [] }
        return Set(list)
    }

    // MARK: - Helpers

    private func collectValues(
        entry: MCPCatalogEntry,
        target: ConfigField.Target,
        values: [String: String]
    ) -> [String: String] {
        var collected: [String: String] = [:]
        for field in entry.resolvedConfigFields where field.target == target {
            if let value = values[field.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                collected[field.id] = value
            }
        }
        return collected
    }

    private func mutateEntry(name: String, _ mutate: (inout [String: Any]) -> Void) throws {
        var servers = rawServers
        guard var entry = servers[name] as? [String: Any] else { return }
        mutate(&entry)
        servers[name] = entry
        rawServers = servers
        try persistAndReload()
    }

    private func persistAndReload() throws {
        do {
            try FileManager.default.createDirectory(
                at: configurationFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(
                withJSONObject: rawRoot,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: configurationFileURL, options: .atomic)
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }

        rebuildRecords()

        // Reconnect so the change is live. Background because it disconnects and
        // re-handshakes every server; the UI updates from MCPManager's own
        // published state as it goes.
        Task { await MCPManager.shared.reload() }
    }
}
