//
//  ChromeTabSessionsRow.swift
//  leanring-buddy
//
//  The Tab sessions row in Settings → Agent → Chrome Tabs (phase 04): the
//  saved sessions, newest first, each with Restore / Rename / Delete, and the
//  switch that also files saved sessions in the brain.
//
//  Delete asks first (contracts §6: deleting a snapshot gets a confirmation).
//  Restore here doesn't show the 10-tab card: the click names one exact
//  session, which is the consent the card exists to get.
//

import SwiftUI

struct ChromeTabSessionsRow: View {
    @ObservedObject private var sessionStore = ChromeTabSessionStore.shared
    @ObservedObject private var brainPreferences = BrainPreferences.shared
    @ObservedObject private var chromeExtensionBridge = ChromeExtensionBridge.shared

    @State private var sessionIDBeingRenamed: UUID?
    @State private var renameDraftText = ""
    @State private var sessionPendingDeletion: ChromeTabSession?
    @State private var restoringSessionID: UUID?
    @State private var statusText: String?

    /// Enough to see recent sessions without the card taking over the page.
    private static let maximumListHeight: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tab sessions")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Colors.textPrimary)
                Text(sessionStore.sessions.isEmpty
                     ? "Say \"save these tabs as …\" to keep a window for later."
                     : "\(sessionStore.sessions.count) saved")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textSecondary)
                Spacer(minLength: 0)
            }

            if !sessionStore.sessions.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(sessionStore.sessions) { savedSession in
                            sessionRow(savedSession)
                        }
                    }
                }
                .frame(maxHeight: Self.maximumListHeight)
            }

            if brainPreferences.isBrainEnabled {
                Toggle(isOn: $sessionStore.addsSavedSessionsToBrain) {
                    Text("Also add sessions I save to my brain, as a page of links")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .pointerCursor()
            }

            if let statusText {
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog(
            "Delete \"\(sessionPendingDeletion?.name ?? "")\"?",
            isPresented: Binding(
                get: { sessionPendingDeletion != nil },
                set: { isPresented in if !isPresented { sessionPendingDeletion = nil } }
            ),
            presenting: sessionPendingDeletion
        ) { sessionToDelete in
            Button("Delete Session", role: .destructive) {
                sessionStore.delete(sessionWithID: sessionToDelete.id)
                sessionPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { sessionPendingDeletion = nil }
        } message: { sessionToDelete in
            Text("Its \(ChromeTabSessionDescriptions.tabCountText(sessionToDelete.tabCount)) can't be restored afterwards. Your open tabs aren't touched.")
        }
    }

    private func sessionRow(_ savedSession: ChromeTabSession) -> some View {
        HStack(alignment: .center, spacing: 8) {
            if sessionIDBeingRenamed == savedSession.id {
                TextField("Session name", text: $renameDraftText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { commitRename(of: savedSession) }
                    .onExitCommand { sessionIDBeingRenamed = nil }
                Button("Save") { commitRename(of: savedSession) }
                    .buttonStyle(WispPillButtonStyle(isProminent: true))
                    .controlSize(.small)
                    .pointerCursor()
                Button("Cancel") { sessionIDBeingRenamed = nil }
                    .buttonStyle(WispPillButtonStyle(isProminent: false))
                    .controlSize(.small)
                    .pointerCursor()
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(savedSession.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(sessionDetailText(savedSession))
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(restoringSessionID == savedSession.id ? "Opening…" : "Restore") {
                    restore(savedSession)
                }
                .buttonStyle(WispPillButtonStyle(isProminent: false))
                .controlSize(.small)
                .disabled(!chromeExtensionBridge.isExtensionConnected || restoringSessionID != nil)
                .pointerCursor()
                .nativeTooltip(chromeExtensionBridge.isExtensionConnected
                               ? "Open these tabs in a new Chrome window"
                               : "Connect the Wisp Tabs extension first")
                Button("Rename") {
                    renameDraftText = savedSession.name
                    sessionIDBeingRenamed = savedSession.id
                }
                .buttonStyle(WispPillButtonStyle(isProminent: false))
                .controlSize(.small)
                .pointerCursor()
                Button {
                    sessionPendingDeletion = savedSession
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(WispPillButtonStyle(isProminent: false))
                .controlSize(.small)
                .pointerCursor()
                .nativeTooltip("Delete this session")
                .accessibilityLabel("Delete \(savedSession.name)")
            }
        }
    }

    private func sessionDetailText(_ savedSession: ChromeTabSession) -> String {
        var parts = [ChromeTabSessionDescriptions.tabCountText(savedSession.tabCount)]
        if savedSession.groupCount > 0 {
            parts.append("\(savedSession.groupCount) group\(savedSession.groupCount == 1 ? "" : "s")")
        }
        parts.append(savedSession.createdAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }

    private func commitRename(of savedSession: ChromeTabSession) {
        switch sessionStore.rename(sessionWithID: savedSession.id, to: renameDraftText) {
        case .renamed:
            sessionIDBeingRenamed = nil
            statusText = nil
        case .emptyName:
            statusText = "a session needs a name."
        case .nameTaken:
            statusText = "another session already has that name."
        case .notFound:
            sessionIDBeingRenamed = nil
        }
    }

    private func restore(_ savedSession: ChromeTabSession) {
        restoringSessionID = savedSession.id
        statusText = nil
        Task { @MainActor in
            defer { restoringSessionID = nil }
            do {
                statusText = try await ChromeTabLife.restore(savedSession, asksBeforeBigRestore: false)
                ChromeExtensionBridge.shared.bringBrowserForward()
            } catch {
                statusText = error.localizedDescription
            }
        }
    }
}
