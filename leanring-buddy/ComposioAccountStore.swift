//
//  ComposioAccountStore.swift
//  leanring-buddy
//
//  The marketplace's Composio state: whether a key is set, the toolkits it can
//  offer, and the flow that installs one. Installing a toolkit provisions a
//  managed MCP server, mints a user-scoped URL, and hands it to
//  InstalledMCPServerStore as a remote server — Composio then handles the
//  toolkit's OAuth the first time the model uses it.
//
//  This is the off-machine path: a Composio server sends the transcript and
//  tool calls to Composio and on to the third-party app, so it is labelled as
//  leaving this Mac and is opt-in, never a default.
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
    @Published private(set) var toolkits: [ComposioToolkit] = []
    /// Toolkit slugs currently being installed, so their rows can show progress.
    @Published private(set) var installingToolkitSlugs: Set<String> = []
    @Published var lastErrorMessage: String?

    /// A stable per-install identifier for Composio's user-scoped URLs. Not a
    /// login — just a handle so the same connected accounts are reused.
    let userId: String

    private static let userIdDefaultsKey = "composioUserId"

    private init() {
        state = ComposioKeychainStore.hasAPIKey() ? .ready : .notConfigured

        if let existing = UserDefaults.standard.string(forKey: Self.userIdDefaultsKey) {
            userId = existing
        } else {
            let generated = "wisp-" + UUID().uuidString.lowercased()
            UserDefaults.standard.set(generated, forKey: Self.userIdDefaultsKey)
            userId = generated
        }
    }

    var hasAPIKey: Bool { ComposioKeychainStore.hasAPIKey() }

    /// Saves the key and validates it by listing toolkits (a 200 confirms it).
    func saveAPIKey(_ apiKey: String) async {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        ComposioKeychainStore.save(trimmed)
        lastErrorMessage = nil
        await refreshToolkits()
    }

    func clearAPIKey() {
        ComposioKeychainStore.delete()
        toolkits = []
        lastErrorMessage = nil
        state = .notConfigured
    }

    /// Loads the toolkit catalog; also serves as key validation.
    func refreshToolkits() async {
        guard let client = ComposioClient() else {
            state = .notConfigured
            return
        }

        state = .validating
        do {
            let fetched = try await client.listToolkits()
            toolkits = fetched.sorted { $0.name.lowercased() < $1.name.lowercased() }
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Provisions a managed server for the toolkit and installs it as a remote
    /// MCP server. Composio prompts for the toolkit's sign-in on first use.
    func installToolkit(_ toolkit: ComposioToolkit) async {
        guard let client = ComposioClient() else {
            lastErrorMessage = ComposioError.missingAPIKey.localizedDescription
            return
        }

        installingToolkitSlugs.insert(toolkit.slug)
        defer { installingToolkitSlugs.remove(toolkit.slug) }

        do {
            let provisioned = try await client.provisionManagedServer(
                name: Self.serverName(for: toolkit.slug),
                toolkits: [toolkit.slug],
                userId: userId
            )
            try InstalledMCPServerStore.shared.installRemoteServer(
                id: "composio-\(toolkit.slug)",
                url: provisioned.userScopedURL,
                source: "composio",
                summary: toolkit.description ?? "Composio · \(toolkit.name)",
                usesComposioKeychainAuth: true
            )
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func isInstalled(toolkit: ComposioToolkit) -> Bool {
        InstalledMCPServerStore.shared.isInstalled(catalogId: "composio-\(toolkit.slug)")
    }

    /// A server name Composio accepts: 4–30 chars, alphanumeric, spaces, hyphens.
    private static func serverName(for slug: String) -> String {
        let hyphenated = "wisp-" + slug.replacingOccurrences(of: "_", with: "-")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "- "))
        let cleaned = String(hyphenated.unicodeScalars.filter { allowed.contains($0) })
        return String(cleaned.prefix(30))
    }
}
