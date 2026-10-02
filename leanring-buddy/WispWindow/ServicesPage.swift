//
//  ServicesPage.swift
//  leanring-buddy
//
//  Connections → Services: connect GitHub, Vercel, Stripe, n8n, Resend,
//  Notion and Cal.com by pasting a key, and see what Wisp last saw from each.
//  A connected service shows in the notch's hover panel and drops a short
//  notice for news (a payment, a failed deploy…); the agent can read it with
//  `check_connected_services`.
//
//  This is the one place these features reach off the Mac, so the page says
//  so: each service is contacted directly with the user's own key, on a
//  fixed interval, and only once connected.
//

import SwiftUI

struct ServicesPage: View {
    @ObservedObject private var serviceMonitor = ServiceIntegrationMonitor.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("Each service you connect is contacted directly from this Mac with your key, at the interval shown — nothing goes through a server of Wisp's. Keys are kept in your login Keychain. Services you don't connect are never contacted.", systemImage: "lock.shield")
                    .font(.callout)
                    .foregroundStyle(WispColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(ServiceIntegrationKind.allCases) { serviceKind in
                    ServiceConnectionCard(serviceKind: serviceKind)
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(WispColor.windowBackground)
    }
}

private struct ServiceConnectionCard: View {
    let serviceKind: ServiceIntegrationKind
    @ObservedObject private var serviceMonitor = ServiceIntegrationMonitor.shared

    /// Draft values while editing. Secrets are never read back into the field.
    @State private var draftValueByFieldKey: [String: String] = [:]
    @State private var isEditing = false

    private var isConnected: Bool { serviceMonitor.configuredKinds.contains(serviceKind) }

    var body: some View {
        DashboardCard(title: serviceKind.displayName) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: serviceKind.symbolName)
                        .font(.title3)
                        .foregroundStyle(WispColor.accentText)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(serviceKind.whatWispWatches)
                            .font(.callout)
                            .foregroundStyle(WispColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if isConnected {
                            statusLine
                        }
                    }
                    Spacer(minLength: 0)
                    if isConnected && !isEditing {
                        Button("Refresh") { serviceMonitor.refreshNow(serviceKind) }
                            .buttonStyle(.bordered)
                            .pointerCursor()
                        Button("Disconnect") { serviceMonitor.disconnect(serviceKind) }
                            .buttonStyle(.bordered)
                            .pointerCursor()
                    } else if !isEditing {
                        Button("Connect…") { beginEditing() }
                            .buttonStyle(.bordered)
                            .pointerCursor()
                    }
                }

                if isEditing {
                    credentialForm
                }

                if isConnected, let snapshot = serviceMonitor.snapshotsByKind[serviceKind], !snapshot.rows.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(snapshot.rows) { row in
                            snapshotRow(row)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let errorText = serviceMonitor.errorsByKind[serviceKind] {
            Label(errorText, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(WispColor.destructive)
        } else if let snapshot = serviceMonitor.snapshotsByKind[serviceKind] {
            let updatedText = serviceMonitor.lastUpdatedDateByKind[serviceKind].map {
                " · updated \(ServiceIntegrationResponseParser.relativeTimeText(for: $0))"
            } ?? ""
            Text(snapshot.headline + updatedText)
                .font(.callout.weight(.medium))
                .foregroundStyle(WispColor.textPrimary)
        } else {
            Text("Connecting…")
                .font(.callout)
                .foregroundStyle(WispColor.textSecondary)
        }
        Text("Checked every \(Int(serviceKind.pollIntervalSeconds / 60)) min while Wisp runs.")
            .font(.caption)
            .foregroundStyle(WispColor.textTertiary)
    }

    private var credentialForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(serviceKind.credentialFields) { credentialField in
                VStack(alignment: .leading, spacing: 3) {
                    Text(credentialField.label)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(WispColor.textPrimary)
                    Group {
                        if credentialField.isSecret {
                            SecureField(credentialField.placeholder, text: draftBinding(for: credentialField.fieldKey))
                        } else {
                            TextField(credentialField.placeholder, text: draftBinding(for: credentialField.fieldKey))
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    if let hint = credentialField.hint {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(WispColor.textTertiary)
                    }
                }
            }
            HStack(spacing: 8) {
                if let keyCreationURL = serviceKind.keyCreationURL {
                    Link("Create a key", destination: keyCreationURL)
                        .font(.callout)
                        .pointerCursor()
                }
                Spacer()
                Button("Cancel") { isEditing = false }
                    .pointerCursor()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDraftComplete)
                    .pointerCursor()
            }
        }
        .padding(.leading, 36)
    }

    private func snapshotRow(_ row: ServiceIntegrationRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(toneColor(row.tone))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                if let rowURL = row.url {
                    Link(row.title, destination: rowURL)
                        .font(.callout)
                        .pointerCursor()
                } else {
                    Text(row.title)
                        .font(.callout)
                        .foregroundStyle(WispColor.textPrimary)
                }
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(.caption)
                        .foregroundStyle(WispColor.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.leading, 36)
    }

    private func toneColor(_ tone: ServiceIntegrationTone) -> Color {
        switch tone {
        case .good: return WispColor.success
        case .bad: return WispColor.destructive
        case .neutral: return WispColor.textTertiary
        }
    }

    private func draftBinding(for fieldKey: String) -> Binding<String> {
        Binding(
            get: { draftValueByFieldKey[fieldKey] ?? "" },
            set: { draftValueByFieldKey[fieldKey] = $0 }
        )
    }

    private var isDraftComplete: Bool {
        serviceKind.credentialFields.allSatisfy {
            !(draftValueByFieldKey[$0.fieldKey] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func beginEditing() {
        // Non-secret fields (n8n's URL) come back for editing; keys never do.
        var initialDraftValues: [String: String] = [:]
        for credentialField in serviceKind.credentialFields where !credentialField.isSecret {
            initialDraftValues[credentialField.fieldKey] = ServiceIntegrationKeychainStore.value(for: serviceKind, fieldKey: credentialField.fieldKey) ?? ""
        }
        draftValueByFieldKey = initialDraftValues
        isEditing = true
    }

    private func save() {
        serviceMonitor.saveCredentials(draftValueByFieldKey, for: serviceKind)
        draftValueByFieldKey = [:]
        isEditing = false
    }
}
