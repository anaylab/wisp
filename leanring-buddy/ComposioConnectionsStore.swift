//
//  ComposioConnectionsStore.swift
//  leanring-buddy
//
//  Per-app connection state for Composio, so Settings can show a list of apps
//  with a Connect / Reconnect / Disconnect button each, like any other
//  integrations screen, instead of leaving sign-in to happen mid-conversation.
//
//  It uses the connect server the user already installed, with the same key and
//  transport, and calls its own `COMPOSIO_MANAGE_CONNECTIONS` tool directly:
//  `list` for status, `add` for a sign-in link, `remove` to disconnect. No new
//  key, no second endpoint. Connect opens the sign-in link in the user's
//  browser, then polls `list` until the account turns active, and the list also
//  refreshes whenever Wisp comes back to the front (the usual way back from the
//  browser), so the row flips to Connected without a manual refresh.
//
//  Off-machine like the rest of Composio. Nothing here runs until the user has
//  saved a Composio key.
//

import AppKit
import Combine
import Foundation

/// One app Settings offers to connect. `slug` is Composio's toolkit id, which is
/// also what its logo service is keyed on.
struct ComposioApp: Identifiable, Hashable, Sendable {
    let slug: String
    let name: String
    let summary: String
    var id: String { slug }

    /// Popular apps first. Anything else Composio supports can be connected by
    /// typing its name in the search box.
    static let curated: [ComposioApp] = [
        ComposioApp(slug: "gmail", name: "Gmail", summary: "Search and read Gmail, manage labels and drafts, then reply, forward, or send email with approval."),
        ComposioApp(slug: "googlecalendar", name: "Google Calendar", summary: "See your schedule, find free time, and create or change events."),
        ComposioApp(slug: "googledrive", name: "Google Drive", summary: "Find, read and organize files and folders in Drive."),
        ComposioApp(slug: "googlesheets", name: "Google Sheets", summary: "Read and update spreadsheets, rows and ranges."),
        ComposioApp(slug: "googledocs", name: "Google Docs", summary: "Read, create and edit documents."),
        ComposioApp(slug: "outlook", name: "Outlook", summary: "Read and send Outlook mail and manage your calendar."),
        ComposioApp(slug: "slack", name: "Slack", summary: "Search channels and messages, and post or reply with approval."),
        ComposioApp(slug: "notion", name: "Notion", summary: "Search pages and databases, then create, update or comment on them."),
        ComposioApp(slug: "linear", name: "Linear", summary: "Search issues, teams and projects, then create or update issues."),
        ComposioApp(slug: "github", name: "GitHub", summary: "Search repositories, inspect issues, PRs and Actions, then create or update repo work with approval."),
        ComposioApp(slug: "youtube", name: "YouTube", summary: "Manage videos, playlists and channels, and read and reply to comments."),
        ComposioApp(slug: "asana", name: "Asana", summary: "Find and update tasks and projects."),
        ComposioApp(slug: "trello", name: "Trello", summary: "Browse boards and cards, and create or move cards."),
        ComposioApp(slug: "todoist", name: "Todoist", summary: "Read, add and complete tasks."),
        ComposioApp(slug: "discord", name: "Discord", summary: "Read and post messages in your servers."),
        ComposioApp(slug: "spotify", name: "Spotify", summary: "Search music, and manage playlists and playback."),
        ComposioApp(slug: "twitter", name: "X (Twitter)", summary: "Read your timeline and post with approval."),
        ComposioApp(slug: "linkedin", name: "LinkedIn", summary: "Read your profile and post with approval."),
        ComposioApp(slug: "hubspot", name: "HubSpot", summary: "Look up and update contacts, companies and deals."),
        ComposioApp(slug: "dropbox", name: "Dropbox", summary: "Find, read and share files."),
    ]

    /// An app typed into the search box that isn't in the curated list.
    static func custom(named typedName: String) -> ComposioApp? {
        let slug = typedName.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
        guard slug.count >= 2 else { return nil }
        return ComposioApp(slug: slug, name: typedName.trimmingCharacters(in: .whitespaces),
                           summary: "Connect \(typedName.trimmingCharacters(in: .whitespaces)) through Composio.")
    }
}

enum ComposioAppStatus: Equatable, Sendable {
    case unknown
    case notConnected
    /// Sign-in link opened; waiting for the user to finish in the browser.
    case connecting
    case connected(account: String?)
    /// An account exists but is no longer active (expired or revoked).
    case needsReconnect
    case failed(String)
}

@MainActor
final class ComposioConnectionsStore: ObservableObject {
    static let shared = ComposioConnectionsStore()

    @Published private(set) var statusBySlug: [String: ComposioAppStatus] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshError: String?

    private var connection: MCPServerConnection?
    private var pollingTasks: [String: Task<Void, Never>] = [:]
    private var knownAccountIDsBySlug: [String: [(id: String, isActive: Bool)]] = [:]
    private var didBecomeActiveObserver: NSObjectProtocol?

    /// How long to wait for the user to finish signing in before giving up.
    private static let signInWaitSeconds: TimeInterval = 180

    private init() {
        // Back from the browser → look again, so the row flips on its own.
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, ComposioAccountStore.shared.isServerInstalled,
                      self.statusBySlug.isEmpty == false else { return }
                await self.refresh()
            }
        }
    }

    func status(of app: ComposioApp) -> ComposioAppStatus {
        statusBySlug[app.slug] ?? .unknown
    }

    // MARK: - Refresh

    /// Reads every listed app's status in one call. `extraSlugs` lets a custom
    /// app that was connected earlier keep showing up.
    func refresh(extraSlugs: [String] = []) async {
        guard ComposioKeychainStore.hasAPIKey() else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let slugs = ComposioApp.curated.map(\.slug) + extraSlugs.filter { slug in
            !ComposioApp.curated.contains { $0.slug == slug }
        }
        do {
            let results = try await manageConnections(
                slugs.map { ["name": $0, "action": "list"] }
            )
            apply(results: results, forSlugs: slugs)
            lastRefreshError = nil
        } catch {
            lastRefreshError = error.localizedDescription
        }
    }

    private func apply(results: [String: Any], forSlugs slugs: [String]) {
        for slug in slugs {
            guard let entry = results[slug] as? [String: Any] else { continue }
            let accounts = (entry["accounts"] as? [[String: Any]]) ?? []
            let parsedAccounts = accounts.compactMap { account -> (id: String, isActive: Bool)? in
                guard let id = account["id"] as? String else { return nil }
                return (id, (account["status"] as? String)?.lowercased() == "active")
            }
            knownAccountIDsBySlug[slug] = parsedAccounts

            // Don't clobber a sign-in in progress with a stale "not connected".
            if pollingTasks[slug] != nil, !parsedAccounts.contains(where: \.isActive) { continue }

            let toolkitStatus = (entry["status"] as? String)?.lowercased() ?? ""
            if let activeAccount = accounts.first(where: { ($0["status"] as? String)?.lowercased() == "active" }) {
                let userInfo = activeAccount["user_info"] as? [String: Any]
                let label = (userInfo?["email"] as? String) ?? (userInfo?["name"] as? String)
                statusBySlug[slug] = .connected(account: label)
            } else if !accounts.isEmpty || ["expired", "failed", "inactive"].contains(toolkitStatus) {
                statusBySlug[slug] = .needsReconnect
            } else {
                statusBySlug[slug] = .notConnected
            }
        }
    }

    // MARK: - Connect / disconnect

    /// Opens the sign-in page in the browser and waits for the account to go
    /// active. Also the Reconnect path: it simply makes a fresh link.
    func connect(_ app: ComposioApp) async {
        pollingTasks[app.slug]?.cancel()
        statusBySlug[app.slug] = .connecting

        do {
            let results = try await manageConnections([["name": app.slug, "action": "add"]])
            guard let signInURL = Self.firstWebURL(in: results[app.slug] ?? results) else {
                statusBySlug[app.slug] = .failed("Composio didn't return a sign-in link for \(app.name).")
                return
            }
            NSWorkspace.shared.open(signInURL)
        } catch {
            statusBySlug[app.slug] = .failed(error.localizedDescription)
            return
        }

        pollingTasks[app.slug] = Task { [weak self] in
            await self?.waitForSignIn(of: app)
        }
    }

    private func waitForSignIn(of app: ComposioApp) async {
        let deadline = Date().addingTimeInterval(Self.signInWaitSeconds)
        while Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
            guard let results = try? await manageConnections([["name": app.slug, "action": "list"]]),
                  let entry = results[app.slug] as? [String: Any] else { continue }
            let accounts = (entry["accounts"] as? [[String: Any]]) ?? []
            if accounts.contains(where: { ($0["status"] as? String)?.lowercased() == "active" }) {
                pollingTasks[app.slug] = nil
                apply(results: results, forSlugs: [app.slug])
                await removeStaleAccounts(of: app)
                return
            }
        }
        guard !Task.isCancelled else { return }
        pollingTasks[app.slug] = nil
        statusBySlug[app.slug] = .failed("Sign-in wasn't finished. Try Connect again.")
    }

    /// After a successful reconnect the expired account is just clutter.
    private func removeStaleAccounts(of app: ComposioApp) async {
        let staleAccountIDs = (knownAccountIDsBySlug[app.slug] ?? []).filter { !$0.isActive }.map(\.id)
        guard !staleAccountIDs.isEmpty else { return }
        _ = try? await manageConnections(staleAccountIDs.map {
            ["name": app.slug, "action": "remove", "account_id": $0]
        })
    }

    func cancelConnecting(_ app: ComposioApp) {
        pollingTasks[app.slug]?.cancel()
        pollingTasks[app.slug] = nil
        statusBySlug[app.slug] = .notConnected
    }

    func disconnect(_ app: ComposioApp) async {
        let accountIDs = (knownAccountIDsBySlug[app.slug] ?? []).map(\.id)
        do {
            if !accountIDs.isEmpty {
                _ = try await manageConnections(accountIDs.map {
                    ["name": app.slug, "action": "remove", "account_id": $0]
                })
            }
            knownAccountIDsBySlug[app.slug] = []
            statusBySlug[app.slug] = .notConnected
        } catch {
            statusBySlug[app.slug] = .failed(error.localizedDescription)
        }
    }

    /// Forget everything, for when the Composio key is removed.
    func reset() {
        pollingTasks.values.forEach { $0.cancel() }
        pollingTasks = [:]
        statusBySlug = [:]
        knownAccountIDsBySlug = [:]
        lastRefreshError = nil
        let staleConnection = connection
        connection = nil
        Task { await staleConnection?.disconnect() }
    }

    // MARK: - Calling the connect server

    /// One `COMPOSIO_MANAGE_CONNECTIONS` call. Returns the per-toolkit `results`
    /// object. Retries once on a fresh session, since a long-idle one can go
    /// stale.
    private func manageConnections(_ toolkitOperations: [[String: String]]) async throws -> [String: Any] {
        do {
            return try await callManageConnections(toolkitOperations)
        } catch {
            let staleConnection = connection
            connection = nil
            await staleConnection?.disconnect()
            return try await callManageConnections(toolkitOperations)
        }
    }

    private func callManageConnections(_ toolkitOperations: [[String: String]]) async throws -> [String: Any] {
        let connection = try await liveConnection()
        let argumentsData = try JSONSerialization.data(withJSONObject: ["toolkits": toolkitOperations])
        let arguments = try JSONDecoder().decode(JSONValue.self, from: argumentsData)
        let text = try await connection.callTool(name: "COMPOSIO_MANAGE_CONNECTIONS", arguments: arguments)

        guard let data = text.data(using: .utf8),
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ComposioError.malformedResponse("Composio's reply wasn't JSON")
        }
        if envelope["successful"] as? Bool == false {
            throw ComposioError.malformedResponse((envelope["error"] as? String) ?? "the request was rejected")
        }
        let payload = (envelope["data"] as? [String: Any]) ?? envelope
        return (payload["results"] as? [String: Any]) ?? payload
    }

    private func liveConnection() async throws -> MCPServerConnection {
        if let connection { return connection }
        guard let key = ComposioKeychainStore.apiKey(), !key.isEmpty else { throw ComposioError.missingAPIKey }
        let newConnection = MCPServerConnection(configuration: MCPServerConfiguration(
            name: "composio-connections",
            url: ComposioClient.mcpEndpoint,
            headers: [ComposioClient.authHeaderName: key]
        ))
        try await newConnection.connect()
        connection = newConnection
        return newConnection
    }

    /// The first http(s) link anywhere in a reply — the field name has varied
    /// (`redirect_url`, `redirectUrl`, …) so this doesn't depend on it.
    nonisolated static func firstWebURL(in value: Any) -> URL? {
        if let text = value as? String, text.hasPrefix("http"), let url = URL(string: text) { return url }
        if let dictionary = value as? [String: Any] {
            for preferredKey in ["redirect_url", "redirectUrl", "auth_url", "url"] {
                if let found = dictionary[preferredKey].flatMap({ firstWebURL(in: $0) }) { return found }
            }
            for nested in dictionary.values {
                if let found = firstWebURL(in: nested) { return found }
            }
        }
        if let array = value as? [Any] {
            for nested in array { if let found = firstWebURL(in: nested) { return found } }
        }
        return nil
    }
}
