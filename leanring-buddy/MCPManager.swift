//
//  MCPManager.swift
//  leanring-buddy
//
//  Loads the MCP server configuration, connects to each server, and publishes
//  their tools into the assistant's tool registry.
//
//  The config file uses the same shape as Claude Desktop's, so an existing
//  mcpServers block can be pasted across unchanged. It lives at
//  ~/.wisp/mcp.json.
//
//  Tool names are namespaced as server__tool. Two servers can reasonably both
//  offer something called "search", and without a prefix the second would
//  quietly replace the first.
//
//  The exposed tool count is capped, which matters more than it appears: a
//  small local model chooses noticeably worse from a long list, and every tool
//  description occupies the same context window as a screenshot that already
//  costs seconds to encode.
//

import Combine
import Foundation

@MainActor
final class MCPManager: ObservableObject {
    static let shared = MCPManager()

    struct ServerStatus: Identifiable {
        enum State: Equatable {
            case disabled
            case connecting
            /// Still connecting a few seconds in through a package runner
            /// (npx/uvx), which is almost always a first-run download.
            case installing
            case connected(toolCount: Int)
            case failed(String)

            var displayName: String {
                switch self {
                case .disabled: return "Disabled"
                case .connecting: return "Connecting…"
                case .installing: return "Installing…"
                case .connected(let count): return "Connected · \(count) tool\(count == 1 ? "" : "s")"
                case .failed: return "Failed"
                }
            }
        }

        var id: String { name }
        let name: String
        var state: State
        var recentErrorOutput: [String] = []
        /// Every tool this server offers, before the allow-list and budget.
        /// The marketplace shows these so individual tools can be toggled.
        var offeredTools: [String] = []
        /// The tools actually registered with the model for this server.
        var exposedTools: [String] = []
    }

    @Published private(set) var serverStatuses: [ServerStatus] = []

    /// Total MCP tools registered across all servers. Every one is a candidate
    /// for the per-turn router (AgentToolRouter), which shows the model only the
    /// most relevant handful each turn. Drives the marketplace's tool summary.
    var registeredToolCount: Int {
        serverStatuses.reduce(0) { $0 + $1.exposedTools.count }
    }

    private var connections: [String: MCPServerConnection] = [:]

    /// Bumped by every disconnect. A connect that finishes after a reload has
    /// started compares against it and discards itself, so an overlapping
    /// reload (the marketplace reloads on every install) can't register a
    /// stale server's tools or overwrite the fresh statuses.
    private var connectionGeneration = 0

    /// How long a package-runner server may sit at "Connecting…" before the
    /// status says it's installing. A warm start answers well inside this.
    private static let installingStatusDelaySeconds: TimeInterval = 3

    /// Namespaced names of every tool this manager has registered, so they can
    /// be unregistered on disconnect or reload rather than lingering as stale
    /// entries the model could still call.
    private var registeredToolNames: Set<String> = []

    private var configurationFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wisp/mcp.json")
    }

    /// Connects every enabled server and registers their tools.
    ///
    /// Failures are recorded per server rather than thrown: one broken server
    /// should not prevent the others from working, and the reason belongs in
    /// the dashboard where it can be read.
    func connectConfiguredServers() async {
        let configurations = loadConfigurations()
        guard !configurations.isEmpty else {
            serverStatuses = []
            return
        }

        serverStatuses = configurations.map { configuration in
            ServerStatus(
                name: configuration.name,
                state: configuration.isEnabled ? .connecting : .disabled
            )
        }

        // Connected concurrently: one slow or failing server — a first-run
        // download, a timeout — must not leave every server after it sitting
        // at "Connecting…" until it resolves.
        let generation = connectionGeneration
        await withTaskGroup(of: Void.self) { group in
            for configuration in configurations where configuration.isEnabled {
                group.addTask {
                    await self.connectServer(configuration, generation: generation)
                }
            }
        }
    }

    /// Connects one server and registers its tools, recording the outcome in
    /// its status.
    private func connectServer(_ configuration: MCPServerConfiguration, generation: Int) async {
        let connection = MCPServerConnection(configuration: configuration)

        let installingStatusTask = showInstallingIfStillConnecting(configuration, generation: generation)
        defer { installingStatusTask?.cancel() }

        do {
            try await connection.connect()

            guard generation == connectionGeneration else {
                // A reload started while this was connecting; its own
                // connection to this server replaces this one.
                await connection.disconnect()
                return
            }

            let offeredTools = await connection.discoveredTools
            connections[configuration.name] = connection

            // Register every allowed tool (empty allow-list means all).
            // There is no registration cap: the per-turn router decides which
            // registered tools the model actually sees, so a large installed
            // library costs nothing until a request is relevant to it.
            let allowedTools = configuration.allowedToolNames.isEmpty
                ? offeredTools
                : offeredTools.filter { configuration.allowedToolNames.contains($0.name) }

            for tool in allowedTools {
                registerTool(tool, from: configuration.name, connection: connection)
            }

            updateStatus(for: configuration.name) { status in
                status.state = .connected(toolCount: allowedTools.count)
                status.offeredTools = offeredTools.map(\.name)
                status.exposedTools = allowedTools.map(\.name)
            }

            print("🔌 MCP: \(configuration.name) connected with \(allowedTools.count) tool(s)")
        } catch {
            // The subprocess is already running by the time a handshake
            // fails, and nothing else holds a reference to it — without
            // this, every failed connection leaks a node process that
            // lives until the user logs out.
            await connection.disconnect()

            guard generation == connectionGeneration else { return }

            let errorOutput = await connection.recentErrorOutput
            let failureMessage = MCPConnectionFailureMessage.compose(
                errorDescription: error.localizedDescription,
                recentErrorOutput: errorOutput
            )
            updateStatus(for: configuration.name) { status in
                status.state = .failed(failureMessage)
                status.recentErrorOutput = errorOutput
            }
            print("⚠️ MCP: \(configuration.name) failed — \(error.localizedDescription)")
            if !errorOutput.isEmpty {
                print("   server said: \(errorOutput.suffix(3).joined(separator: " | "))")
            }
        }
    }

    /// For a package-runner server, flips "Connecting…" to "Installing…" if
    /// the handshake is still going after a few seconds, so a first-run
    /// download doesn't look like a hang. Nil for other servers.
    private func showInstallingIfStillConnecting(
        _ configuration: MCPServerConfiguration,
        generation: Int
    ) -> Task<Void, Never>? {
        guard configuration.transport == .stdio,
              MCPStartupTimeoutPolicy.isPackageRunner(command: configuration.command) else { return nil }

        return Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.installingStatusDelaySeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, generation == self.connectionGeneration else { return }
            self.updateStatus(for: configuration.name) { status in
                if status.state == .connecting { status.state = .installing }
            }
        }
    }

    func disconnectAll() {
        connectionGeneration += 1

        for connection in connections.values {
            Task { await connection.disconnect() }
        }
        connections.removeAll()

        // Tools outlive the connection in the registry, so they must be removed
        // explicitly — otherwise a disabled or uninstalled server's tools stay
        // callable until the app restarts.
        for toolName in registeredToolNames {
            AgentToolRegistry.shared.unregister(toolNamed: toolName)
        }
        registeredToolNames.removeAll()

        serverStatuses.removeAll()
    }

    /// Disconnects everything and reconnects from the current `~/.wisp/mcp.json`.
    ///
    /// Called after the marketplace installs, removes, enables, or re-scopes a
    /// server so the change takes effect without an app restart.
    func reload() async {
        disconnectAll()
        await connectConfiguredServers()
    }

    /// Registers one MCP tool with the assistant's registry.
    private func registerTool(
        _ tool: MCPServerConnection.DiscoveredTool,
        from serverName: String,
        connection: MCPServerConnection
    ) {
        let sanitizedServerName = sanitize(serverName)
        let namespacedName = "\(sanitizedServerName)__\(tool.name)"
        let isCuaDriverServer = CuaDriverToolNames.isCuaDriverServerNamespace(sanitizedServerName)

        AgentToolRegistry.shared.register(
            BuddyToolDefinition(
                name: namespacedName,
                description: tool.description.isEmpty
                    ? "Tool \(tool.name) from \(serverName)."
                    : tool.description,
                inputSchema: tool.inputSchema,
                // MCP servers do not describe whether a tool changes anything,
                // so every one is treated as if it might.
                requiresConfirmation: true
            )
        ) { input in
            let toolCallContent = try await connection.callToolReturningContent(name: tool.name, arguments: input)
            // cua-driver's action calls name their target only by an element
            // token; remembering what each token was lets the confirmation
            // card for the next click say what it will press.
            if isCuaDriverServer, let structuredContent = toolCallContent.structuredContent {
                CuaDriverElementCache.shared.recordElements(fromStructuredContent: structuredContent)
            }
            return MCPToolResultRendering.modelText(
                flattenedContentText: toolCallContent.flattenedContentText,
                structuredContent: toolCallContent.structuredContent
            )
        }

        registeredToolNames.insert(namespacedName)
    }

    /// Trims a server name to what tool names allow.
    private func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    private func updateStatus(for name: String, mutate: (inout ServerStatus) -> Void) {
        guard let index = serverStatuses.firstIndex(where: { $0.name == name }) else { return }
        mutate(&serverStatuses[index])
    }

    // MARK: - Configuration file

    /// Reads ~/.wisp/mcp.json, tolerating its absence.
    ///
    /// No file simply means no MCP servers, which is the normal state for
    /// someone who hasn't set any up.
    private func loadConfigurations() -> [MCPServerConfiguration] {
        guard let data = try? Data(contentsOf: configurationFileURL) else { return [] }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else {
            print("⚠️ MCP: \(configurationFileURL.path) is not valid JSON with an \"mcpServers\" object")
            return []
        }

        return servers.compactMap { name, value -> MCPServerConfiguration? in
            guard let entry = value as? [String: Any] else { return nil }

            let isEnabled = entry["enabled"] as? Bool ?? true
            let allowedToolNames = Set(entry["allowedTools"] as? [String] ?? [])

            // A "url" entry (Streamable HTTP) is a remote server; anything with
            // a "command" is a local stdio server, exactly as before.
            if let urlString = entry["url"] as? String, let url = URL(string: urlString) {
                var headers = entry["headers"] as? [String: String] ?? [:]

                // Composio-installed servers keep no secret in the file; the key
                // is injected from the Keychain here so it never touches disk.
                // The connect product authenticates with x-consumer-api-key.
                if entry["authFromKeychain"] as? String == "composio",
                   let composioKey = ComposioKeychainStore.apiKey() {
                    headers[ComposioClient.authHeaderName] = composioKey
                }

                return MCPServerConfiguration(
                    name: name,
                    url: url,
                    headers: headers,
                    isEnabled: isEnabled,
                    allowedToolNames: allowedToolNames
                )
            }

            if let command = entry["command"] as? String {
                return MCPServerConfiguration(
                    name: name,
                    command: command,
                    arguments: entry["args"] as? [String] ?? [],
                    environment: entry["env"] as? [String: String] ?? [:],
                    isEnabled: isEnabled,
                    allowedToolNames: allowedToolNames
                )
            }

            print("⚠️ MCP: \"\(name)\" has neither a \"command\" nor a \"url\" — skipping")
            return nil
        }
        .sorted { $0.name < $1.name }
    }

    /// Writes a commented starter file if none exists, so the format is
    /// discoverable without going to find documentation.
    func createExampleConfigurationIfMissing() {

        let fileURL = configurationFileURL
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }

        let example = """
        {
          "_comment": "MCP servers for Wisp. Same format as Claude Desktop, so an existing config can be pasted in. Set enabled to true to switch one on. A server can be a local command (stdio) or a remote \\"url\\" (Streamable HTTP), with optional \\"headers\\" for auth.",
          "mcpServers": {
            "filesystem": {
              "command": "npx",
              "args": ["-y", "@modelcontextprotocol/server-filesystem", "\(FileManager.default.homeDirectoryForCurrentUser.path)/Documents"],
              "enabled": false
            },
            "example-remote": {
              "url": "https://example.com/mcp",
              "headers": { "Authorization": "Bearer YOUR_TOKEN" },
              "enabled": false
            }
          }
        }

        """

        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try example.write(to: fileURL, atomically: true, encoding: .utf8)
            print("🔌 MCP: wrote a starter config to \(fileURL.path)")
        } catch {
            print("⚠️ MCP: couldn't write \(fileURL.path) — \(error.localizedDescription)")
        }
    }
}

// MARK: - Failure message

/// The one-line reason a server failed, as the marketplace shows it.
///
/// A timeout or "not connected" says nothing about *why*; the server's own
/// last stderr line usually does ("No module named …", "npm ERR! 404 …"), and
/// the marketplace row has room only for this string, so the two are joined.
enum MCPConnectionFailureMessage {
    static let maximumServerOutputCharacters = 200

    static func compose(errorDescription: String, recentErrorOutput: [String]) -> String {
        let lastServerLine = recentErrorOutput
            .reversed()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        guard let lastServerLine, !errorDescription.contains(lastServerLine) else {
            return errorDescription
        }

        let shownServerLine = lastServerLine.count > maximumServerOutputCharacters
            ? String(lastServerLine.prefix(maximumServerOutputCharacters)) + "…"
            : lastServerLine
        return "\(errorDescription) Last server output: \(shownServerLine)"
    }
}
