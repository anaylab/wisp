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
            case connected(toolCount: Int)
            case failed(String)

            var displayName: String {
                switch self {
                case .disabled: return "Disabled"
                case .connecting: return "Connecting…"
                case .connected(let count): return "Connected · \(count) tool\(count == 1 ? "" : "s")"
                case .failed: return "Failed"
                }
            }
        }

        var id: String { name }
        let name: String
        var state: State
        var recentErrorOutput: [String] = []
    }

    /// Ceiling on tools offered to the model at once.
    private static let maximumExposedTools = 8

    @Published private(set) var serverStatuses: [ServerStatus] = []

    private var connections: [String: MCPServerConnection] = [:]

    private var configurationFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wisp/mcp.json")
    }

    /// Where the config lived before the app was renamed.
    private var legacyConfigurationFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clicky/mcp.json")
    }

    /// Moves a pre-rename config to the new location, once.
    ///
    /// Someone who already configured servers should not have to discover that
    /// the rename quietly orphaned their file. The old copy is left in place
    /// rather than deleted — this is the user's config, not ours to remove, and
    /// a stray file costs nothing next to losing hand-written settings.
    private func migrateLegacyConfigurationIfNeeded() {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: configurationFileURL.path),
              manager.fileExists(atPath: legacyConfigurationFileURL.path) else { return }

        do {
            try manager.createDirectory(
                at: configurationFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try manager.copyItem(at: legacyConfigurationFileURL, to: configurationFileURL)
            print("📦 MCP: migrated config from ~/.clicky/mcp.json to ~/.wisp/mcp.json")
        } catch {
            print("⚠️ MCP: could not migrate old config: \(error.localizedDescription)")
        }
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

        var remainingToolBudget = Self.maximumExposedTools

        for configuration in configurations where configuration.isEnabled {
            let connection = MCPServerConnection(configuration: configuration)

            do {
                try await connection.connect()
                let tools = await connection.discoveredTools
                connections[configuration.name] = connection

                let toolsToExpose = Array(tools.prefix(max(0, remainingToolBudget)))
                remainingToolBudget -= toolsToExpose.count

                for tool in toolsToExpose {
                    registerTool(tool, from: configuration.name, connection: connection)
                }

                updateStatus(for: configuration.name) { status in
                    status.state = .connected(toolCount: toolsToExpose.count)
                }

                if toolsToExpose.count < tools.count {
                    print("🔌 MCP: \(configuration.name) offers \(tools.count) tools; exposing \(toolsToExpose.count) to stay within the model's limit")
                } else {
                    print("🔌 MCP: \(configuration.name) connected with \(toolsToExpose.count) tool(s)")
                }
            } catch {
                let errorOutput = await connection.recentErrorOutput
                updateStatus(for: configuration.name) { status in
                    status.state = .failed(error.localizedDescription)
                    status.recentErrorOutput = errorOutput
                }
                print("⚠️ MCP: \(configuration.name) failed — \(error.localizedDescription)")
                if !errorOutput.isEmpty {
                    print("   server said: \(errorOutput.suffix(3).joined(separator: " | "))")
                }
            }
        }
    }

    func disconnectAll() {
        for connection in connections.values {
            Task { await connection.disconnect() }
        }
        connections.removeAll()
        serverStatuses.removeAll()
    }

    /// Registers one MCP tool with the assistant's registry.
    private func registerTool(
        _ tool: MCPServerConnection.DiscoveredTool,
        from serverName: String,
        connection: MCPServerConnection
    ) {
        let namespacedName = "\(sanitize(serverName))__\(tool.name)"

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
            try await connection.callTool(name: tool.name, arguments: input)
        }
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
        migrateLegacyConfigurationIfNeeded()
        guard let data = try? Data(contentsOf: configurationFileURL) else { return [] }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else {
            print("⚠️ MCP: \(configurationFileURL.path) is not valid JSON with an \"mcpServers\" object")
            return []
        }

        return servers.compactMap { name, value -> MCPServerConfiguration? in
            guard let entry = value as? [String: Any],
                  let command = entry["command"] as? String else { return nil }

            return MCPServerConfiguration(
                name: name,
                command: command,
                arguments: entry["args"] as? [String] ?? [],
                environment: entry["env"] as? [String: String] ?? [:],
                isEnabled: entry["enabled"] as? Bool ?? true,
                allowedToolNames: Set(entry["allowedTools"] as? [String] ?? [])
            )
        }
        .sorted { $0.name < $1.name }
    }

    /// Writes a commented starter file if none exists, so the format is
    /// discoverable without going to find documentation.
    func createExampleConfigurationIfMissing() {
        // Migrate first. This runs before connectConfiguredServers(), so
        // without this the starter file below would be written into the empty
        // new location and the migration — which only acts when the target is
        // absent — would then find a file already there and skip, silently
        // shadowing a config the user wrote by hand.
        migrateLegacyConfigurationIfNeeded()

        let fileURL = configurationFileURL
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }

        let example = """
        {
          "_comment": "MCP servers for Wisp. Same format as Claude Desktop, so an existing config can be pasted in. Set enabled to true to switch one on.",
          "mcpServers": {
            "filesystem": {
              "command": "npx",
              "args": ["-y", "@modelcontextprotocol/server-filesystem", "\(FileManager.default.homeDirectoryForCurrentUser.path)/Documents"],
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
