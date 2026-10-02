//
//  ServiceIntegrationMonitor.swift
//  leanring-buddy
//
//  Polls each connected service on its own interval and keeps the latest
//  snapshot, error and update time for the notch and Connections → Services.
//
//  New events (a payment, a finished deploy, a failed workflow, a bounce, a
//  booking) are found by comparing event ids with the previous fetch, so the
//  first fetch after launch or after connecting announces nothing — it only
//  sets the baseline. Announcements go to `latestAnnouncement`, which the
//  notch drops as a short card unless the user is on a call (quiet mode).
//
//  A service with no saved key is never contacted.
//

import Combine
import Foundation

@MainActor
final class ServiceIntegrationMonitor: ObservableObject {
    static let shared = ServiceIntegrationMonitor()

    @Published private(set) var snapshotsByKind: [ServiceIntegrationKind: ServiceIntegrationSnapshot] = [:]
    @Published private(set) var errorsByKind: [ServiceIntegrationKind: String] = [:]
    @Published private(set) var lastUpdatedDateByKind: [ServiceIntegrationKind: Date] = [:]
    @Published private(set) var configuredKinds: Set<ServiceIntegrationKind> = []
    /// The newest event worth showing; the notch watches this.
    @Published private(set) var latestAnnouncement: ServiceIntegrationEvent?

    private var pollingTasksByKind: [ServiceIntegrationKind: Task<Void, Never>] = [:]
    /// Event ids from each service's previous fetch; nil until the first fetch.
    private var previouslySeenEventIDsByKind: [ServiceIntegrationKind: Set<String>] = [:]

    private init() {}

    /// Configured services in catalogue order.
    var connectedKinds: [ServiceIntegrationKind] {
        ServiceIntegrationKind.allCases.filter { configuredKinds.contains($0) }
    }

    func start() {
        for kind in ServiceIntegrationKind.allCases {
            restartPolling(for: kind)
        }
    }

    /// Saves credentials and starts (or restarts) polling. Values are trimmed;
    /// an empty field removes that credential.
    func saveCredentials(_ valuesByFieldKey: [String: String], for kind: ServiceIntegrationKind) {
        for credentialField in kind.credentialFields {
            let fieldValue = valuesByFieldKey[credentialField.fieldKey] ?? ""
            ServiceIntegrationKeychainStore.save(fieldValue, for: kind, fieldKey: credentialField.fieldKey)
        }
        restartPolling(for: kind)
    }

    func disconnect(_ kind: ServiceIntegrationKind) {
        ServiceIntegrationKeychainStore.deleteAll(for: kind)
        restartPolling(for: kind)
    }

    func refreshNow(_ kind: ServiceIntegrationKind) {
        restartPolling(for: kind)
    }

    func dismissAnnouncement() {
        latestAnnouncement = nil
    }

    /// Everything currently known, as plain text — for the agent tool.
    func plainTextStatus() -> String {
        let connectedKinds = self.connectedKinds
        guard !connectedKinds.isEmpty else {
            return "no services are connected. the user can connect GitHub, Vercel, Stripe, n8n, Resend, Notion or Cal.com in Wisp → Connections → Services."
        }
        return connectedKinds.map { kind in
            if let snapshot = snapshotsByKind[kind] {
                return snapshot.plainTextSummary(serviceName: kind.displayName)
            }
            if let errorText = errorsByKind[kind] {
                return "\(kind.displayName): couldn't load (\(errorText))"
            }
            return "\(kind.displayName): still loading"
        }.joined(separator: "\n\n")
    }

    // MARK: - Polling

    private func restartPolling(for kind: ServiceIntegrationKind) {
        pollingTasksByKind[kind]?.cancel()
        pollingTasksByKind[kind] = nil
        previouslySeenEventIDsByKind[kind] = nil

        guard ServiceIntegrationKeychainStore.isConfigured(kind) else {
            configuredKinds.remove(kind)
            snapshotsByKind[kind] = nil
            errorsByKind[kind] = nil
            lastUpdatedDateByKind[kind] = nil
            return
        }
        configuredKinds.insert(kind)
        pollingTasksByKind[kind] = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce(kind)
                let pollIntervalNanoseconds = UInt64(kind.pollIntervalSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            }
        }
    }

    private func pollOnce(_ kind: ServiceIntegrationKind) async {
        // Read off the main actor: Keychain lookups can block briefly.
        let credentials = await Task.detached { ServiceIntegrationKeychainStore.credentials(for: kind) }.value
        guard let credentials else {
            errorsByKind[kind] = ServiceIntegrationFetchError.notConfigured.errorDescription
            return
        }
        do {
            let snapshot = try await ServiceIntegrationClient.fetchSnapshot(for: kind, credentials: credentials)
            guard !Task.isCancelled else { return }
            snapshotsByKind[kind] = snapshot
            errorsByKind[kind] = nil
            lastUpdatedDateByKind[kind] = Date()
            announceNewEvents(in: snapshot, for: kind)
        } catch {
            guard !Task.isCancelled else { return }
            errorsByKind[kind] = error.localizedDescription
        }
    }

    private func announceNewEvents(in snapshot: ServiceIntegrationSnapshot, for kind: ServiceIntegrationKind) {
        let currentEventIDs = Set(snapshot.announceableEvents.map(\.id))
        defer { previouslySeenEventIDsByKind[kind] = (previouslySeenEventIDsByKind[kind] ?? []).union(currentEventIDs) }
        guard let previouslySeenEventIDs = previouslySeenEventIDsByKind[kind] else { return }
        // Newest first in the snapshot, so the first unseen one is the newest news.
        guard let newestUnseenEvent = snapshot.announceableEvents.first(where: { !previouslySeenEventIDs.contains($0.id) }) else {
            return
        }
        latestAnnouncement = newestUnseenEvent
        switch newestUnseenEvent.tone {
        case .bad: WispSoundPlayer.shared.play(.error)
        case .good, .neutral: WispSoundPlayer.shared.play(.reply)
        }
    }
}

extension AgentToolRegistry {
    func registerServiceIntegrationTools() {
        register(
            BuddyToolDefinition(
                name: "check_connected_services",
                description: "Get the latest status of the services the user connected to Wisp — GitHub repos and stars, Vercel deployments, Stripe balance and payments, n8n workflow runs, Resend emails, Notion pages, Cal.com bookings. Use for questions like \"any new payments?\", \"did my deploy go out?\", \"what's my next booking?\".",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
                metadata: .reading(.userAccount)
            )
        ) { _ in
            ServiceIntegrationMonitor.shared.plainTextStatus()
        }
    }
}
