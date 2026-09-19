//
//  ComposioAccountStore.swift
//  leanring-buddy
//
//  The marketplace's Composio state for the connect universal server: whether a
//  key is set, and the connect/disconnect flow. Connecting validates the key,
//  then installs one remote MCP server pointing at Composio's connect endpoint;
//  its meta-tools (search, execute, manage-connections) then appear in the
//  installed list, subject to the tool budget like any other server.
//
//  This is the off-machine path: the connect server sends the transcript and
//  tool calls to Composio and on to the connected app, so it is labelled as
//  leaving this Mac and is opt-in, never a default. The key lives only in the
//  Keychain (ComposioKeychainStore) and is injected into the transport by
//  MCPManager at connect time — never written to mcp.json.
//

import Combine
import Foundation

@MainActor
final class ComposioAccountStore: ObservableObject {
    static let shared = ComposioAccountStore()

    enum State: Equatable {
        case notConfigured
        case validating
        case ready
        case failed(String)
    }

    @Published private(set) var state: State
    @Published var lastErrorMessage: String?

    /// The installed-server id for the connect universal server.
    static let serverId = "composio-connect"

    private init() {
        // Ready only when the key is present AND the server is actually
        // installed. A saved key with no installed server still needs a
        // connect, so it stays .notConfigured (which offers the connect action).
        state = (ComposioKeychainStore.hasAPIKey()
                 && InstalledMCPServerStore.shared.isInstalled(catalogId: Self.serverId))
            ? .ready : .notConfigured
    }

    var hasAPIKey: Bool { ComposioKeychainStore.hasAPIKey() }

    var isServerInstalled: Bool {
        InstalledMCPServerStore.shared.isInstalled(catalogId: Self.serverId)
    }

    /// Saves the key (when a new one is provided), validates it against the
    /// connect server, and installs the universal server on success. Passing no
    /// key reuses the one already in the Keychain — so a saved-but-not-installed
    /// key can be connected without retyping.
    func connect(apiKey: String? = nil) async {
        if let apiKey {
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            ComposioKeychainStore.save(trimmed)
        }

        state = .validating
        lastErrorMessage = nil

        guard let client = ComposioClient() else {
            state = .notConfigured
            return
        }

        do {
            try await client.validate()
            try installServer()
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        try? InstalledMCPServerStore.shared.uninstall(name: Self.serverId)
        ComposioKeychainStore.delete()
        lastErrorMessage = nil
        state = .notConfigured
    }

    /// Installs (or reinstalls) the connect server. Reinstalling makes
    /// reconnecting with a new key idempotent.
    private func installServer() throws {
        if InstalledMCPServerStore.shared.isInstalled(catalogId: Self.serverId) {
            try? InstalledMCPServerStore.shared.uninstall(name: Self.serverId)
        }
        try InstalledMCPServerStore.shared.installRemoteServer(
            id: Self.serverId,
            url: ComposioClient.mcpEndpoint,
            source: "composio",
            summary: "Composio universal server — 500+ apps via search + execute tools.",
            usesComposioKeychainAuth: true
        )
    }
}
