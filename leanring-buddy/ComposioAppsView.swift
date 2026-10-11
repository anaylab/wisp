//
//  ComposioAppsView.swift
//  leanring-buddy
//
//  The app list for Composio in Connections → Marketplace: real app logos,
//  Connected and Available sections, and one button per row (Connect,
//  Reconnect, Disconnect). Backed by `ComposioConnectionsStore`.
//
//  Logos come from Composio's logo service, keyed on the same slug the
//  connection uses, and are cached for the session. While one loads — or if it
//  can't — the row shows the app's initial, so a slow network never leaves a
//  hole in the list.
//

import AppKit
import SwiftUI

// MARK: - Logos

@MainActor
private enum ComposioLogoCache {
    static let images = NSCache<NSString, NSImage>()
    static var failedSlugs = Set<String>()
}

struct ComposioAppIcon: View {
    let app: ComposioApp
    var size: CGFloat = 34

    @State private var logo: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(Color.white.opacity(0.92))
            if let logo {
                Image(nsImage: logo)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.16)
            } else {
                Text(String(app.name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.55))
            }
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
        .task(id: app.slug) { await loadLogo() }
    }

    private func loadLogo() async {
        if let cached = ComposioLogoCache.images.object(forKey: app.slug as NSString) {
            logo = cached
            return
        }
        guard !ComposioLogoCache.failedSlugs.contains(app.slug),
              let url = URL(string: "https://logos.composio.dev/api/\(app.slug)") else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data) else {
                ComposioLogoCache.failedSlugs.insert(app.slug)
                return
            }
            ComposioLogoCache.images.setObject(image, forKey: app.slug as NSString)
            logo = image
        } catch {
            // Not cached as a failure: a dropped connection shouldn't blank
            // this logo for the rest of the session.
        }
    }
}

// MARK: - List

struct ComposioAppsView: View {
    @ObservedObject private var connections = ComposioConnectionsStore.shared
    @State private var searchText = ""
    @State private var customApps: [ComposioApp] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            searchField

            if let error = connections.lastRefreshError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Colors.destructiveText)
            }

            if !connectedApps.isEmpty {
                sectionHeader("Connected")
                appRows(connectedApps)
            }

            sectionHeader("Available")
            if availableApps.isEmpty {
                Text(connections.isRefreshing ? "Loading…" : "Nothing matches.")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textTertiary)
            } else {
                appRows(availableApps)
            }
        }
        .task { await connections.refresh(extraSlugs: customApps.map(\.slug)) }
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.textTertiary)
            TextField("Search apps, or type any app's name", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(DS.Colors.textPrimary)
                .onSubmit { addTypedAppIfNeeded() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface2)
        )
    }

    /// Return on a name that isn't in the list adds it as a row, so apps beyond
    /// the popular ones are one keystroke away.
    private func addTypedAppIfNeeded() {
        guard filteredApps.isEmpty, let typedApp = ComposioApp.custom(named: searchText) else { return }
        customApps.append(typedApp)
        searchText = ""
        Task { await connections.refresh(extraSlugs: customApps.map(\.slug)) }
    }

    // MARK: Derived

    private var allApps: [ComposioApp] { ComposioApp.curated + customApps }

    private var filteredApps: [ComposioApp] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return allApps }
        return allApps.filter { $0.name.lowercased().contains(query) || $0.slug.contains(query) }
    }

    private func isConnectedOrNeedsAttention(_ app: ComposioApp) -> Bool {
        switch connections.status(of: app) {
        case .connected, .needsReconnect: return true
        default: return false
        }
    }

    private var connectedApps: [ComposioApp] { filteredApps.filter(isConnectedOrNeedsAttention) }
    private var availableApps: [ComposioApp] { filteredApps.filter { !isConnectedOrNeedsAttention($0) } }

    // MARK: Rows

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(DS.Colors.textTertiary)
            .padding(.top, 4)
    }

    private func appRows(_ apps: [ComposioApp]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                ComposioAppRow(app: app, status: connections.status(of: app))
                if index < apps.count - 1 {
                    Divider().opacity(0.5)
                }
            }
        }
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface1)
        )
    }
}

private struct ComposioAppRow: View {
    let app: ComposioApp
    let status: ComposioAppStatus

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ComposioAppIcon(app: app)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Colors.textPrimary)
                    statusBadge
                }
                Text(detailText)
                    .font(.system(size: 10))
                    .foregroundStyle(detailIsError ? DS.Colors.destructiveText : DS.Colors.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            trailingButtons
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .connected:
            badge("Connected", color: DS.Colors.success)
        case .needsReconnect:
            badge("Reconnect required", color: DS.Colors.warning)
        case .connecting:
            badge("Waiting for sign-in…", color: DS.Colors.textTertiary)
        default:
            EmptyView()
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(color)
        }
    }

    private var detailText: String {
        switch status {
        case .connected(let account?): return account
        case .failed(let message): return message
        default: return app.summary
        }
    }

    private var detailIsError: Bool {
        if case .failed = status { return true }
        return false
    }

    @ViewBuilder
    private var trailingButtons: some View {
        let store = ComposioConnectionsStore.shared
        switch status {
        case .connected:
            Button("Disconnect") { Task { await store.disconnect(app) } }
                .buttonStyle(BuddyPillButtonStyle(colorIndex: 0, isProminent: false))
                .pointerCursor()
        case .needsReconnect:
            HStack(spacing: 6) {
                Button("Reconnect") { Task { await store.connect(app) } }
                    .buttonStyle(BuddyPillButtonStyle(colorIndex: 0))
                    .pointerCursor()
                Button {
                    Task { await store.disconnect(app) }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(BuddyPillButtonStyle(colorIndex: 0, isProminent: false))
                .help("Remove this connection")
                .accessibilityLabel("Remove connection")
                .pointerCursor()
            }
        case .connecting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Button("Cancel") { store.cancelConnecting(app) }
                    .buttonStyle(BuddyPillButtonStyle(colorIndex: 0, isProminent: false))
                    .pointerCursor()
            }
        default:
            Button("Connect") { Task { await store.connect(app) } }
                .buttonStyle(BuddyPillButtonStyle(colorIndex: 0))
                .pointerCursor()
        }
    }
}
