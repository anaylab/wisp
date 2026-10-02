//
//  CodingAgentsPage.swift
//  leanring-buddy
//
//  Connections → Coding Agents: hooking Claude Code, Gemini CLI and
//  Antigravity up to the notch, the notch's switches for them, and the live
//  session list.
//
//  Installing writes to the agent's own settings file, so it always goes
//  through a preview sheet showing exactly which lines change; the file is
//  backed up beside itself before anything is written.
//

import SwiftUI

struct CodingAgentsPage: View {
    @ObservedObject private var sessionStore = CodingAgentSessionStore.shared
    @ObservedObject private var preferences = CodingAgentPreferences.shared

    @State private var installedTargets: Set<CodingAgentHookTarget> = []
    @State private var pendingPreview: CodingAgentHookChangePreview?
    @State private var errorMessageByTarget: [CodingAgentHookTarget: String] = [:]
    @State private var isPythonAvailable = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hooksCard
                notchCard
                sessionsCard
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(WispColor.windowBackground)
        .onAppear(perform: refreshInstalledState)
        .sheet(item: $pendingPreview) { preview in
            CodingAgentHookPreviewSheet(
                preview: preview,
                onConfirm: { apply(preview) },
                onCancel: { pendingPreview = nil }
            )
        }
    }

    // MARK: - Hooks

    private var hooksCard: some View {
        DashboardCard(title: "Hooks") {
            VStack(alignment: .leading, spacing: 12) {
                Text("A hook tells Wisp what an agent is doing, and lets you answer its permission prompts from the notch. Everything stays on this Mac: the agent talks to Wisp over a local socket only you can open. If Wisp isn't running, the hook does nothing and the agent carries on as usual.")
                    .font(.callout)
                    .foregroundStyle(WispColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !isPythonAvailable {
                    Label("The hook needs Python 3 from Apple's command line tools. Run `xcode-select --install` in Terminal, then come back.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(WispColor.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(CodingAgentHookTarget.allCases) { hookTarget in
                    Divider()
                    hookRow(hookTarget)
                }
            }
        }
    }

    private func hookRow(_ hookTarget: CodingAgentHookTarget) -> some View {
        let isInstalled = installedTargets.contains(hookTarget)
        return VStack(alignment: .leading, spacing: 6) {
            SettingRow(
                title: hookTarget.displayName,
                detail: "\(hookTarget.whatItEnables)\n\(hookTarget.displaySettingsPath)"
            ) {
                HStack(spacing: 8) {
                    if isInstalled {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.callout)
                            .foregroundStyle(WispColor.success)
                    }
                    Button(isInstalled ? "Remove…" : "Install…") {
                        preparePreview(for: hookTarget, installing: !isInstalled)
                    }
                    .buttonStyle(.bordered)
                    .pointerCursor()
                }
            }
            if let errorMessage = errorMessageByTarget[hookTarget] {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(WispColor.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Notch switches

    private var notchCard: some View {
        DashboardCard(title: "In the notch") {
            VStack(alignment: .leading, spacing: 12) {
                SettingRow(
                    title: "Answer permission prompts",
                    detail: "Claude Code's \"Allow this?\" questions appear in the notch with Allow and Deny. Nothing is allowed without your click; left alone for two minutes, the question goes back to the terminal."
                ) {
                    Toggle("Answer permission prompts", isOn: $preferences.areNotchApprovalsEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .pointerCursor()
                }
                Divider()
                SettingRow(
                    title: "Say when a session finishes",
                    detail: "A short card drops from the notch when an agent stops and is waiting for you — not while you're in its terminal, and not during a call."
                ) {
                    Toggle("Say when a session finishes", isOn: $preferences.isAnnouncingFinishedSessions)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .pointerCursor()
                }
            }
        }
    }

    // MARK: - Sessions

    private var sessionsCard: some View {
        DashboardCard(title: "Sessions") {
            if sessionStore.sessions.isEmpty {
                Text(installedTargets.isEmpty
                    ? "Install a hook above, then start a new agent session — it shows up here and in the notch."
                    : "No sessions right now. Start (or restart) an agent and it shows up here.")
                    .font(.callout)
                    .foregroundStyle(WispColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(sessionStore.sessions) { session in
                        sessionRow(session)
                        if session.id != sessionStore.sessions.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private func sessionRow(_ session: CodingAgentSession) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(session.projectName) · \(session.agentKind.displayName)")
                    .font(.body.weight(.medium))
                    .foregroundStyle(WispColor.textPrimary)
                Text([session.state.label, session.latestStep].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(WispColor.textSecondary)
                    .lineLimit(2)
                if !session.workingDirectoryPath.isEmpty {
                    Text(session.workingDirectoryPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(WispColor.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            Button("Jump to terminal") {
                CodingAgentTerminalJumper.jump(to: session)
            }
            .buttonStyle(.bordered)
            .pointerCursor()
        }
    }

    // MARK: - Actions

    private func refreshInstalledState() {
        installedTargets = Set(CodingAgentHookTarget.allCases.filter(CodingAgentHookInstaller.isInstalled))
        isPythonAvailable = CodingAgentHookRelay.isPythonAvailable()
    }

    private func preparePreview(for hookTarget: CodingAgentHookTarget, installing isInstalling: Bool) {
        errorMessageByTarget[hookTarget] = nil
        do {
            pendingPreview = try CodingAgentHookInstaller.preview(hookTarget, installing: isInstalling)
        } catch {
            errorMessageByTarget[hookTarget] = error.localizedDescription
        }
    }

    private func apply(_ preview: CodingAgentHookChangePreview) {
        pendingPreview = nil
        do {
            // Make sure the relay the new entries point at exists.
            try CodingAgentHookRelay.installRelayFiles()
            try CodingAgentHookInstaller.apply(preview)
        } catch {
            errorMessageByTarget[preview.target] = error.localizedDescription
        }
        refreshInstalledState()
    }
}

/// Shows exactly what will change in an agent's settings file before writing it.
struct CodingAgentHookPreviewSheet: View {
    let preview: CodingAgentHookChangePreview
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(preview.isInstalling
                ? "Add Wisp's hooks to \(preview.target.displaySettingsPath)?"
                : "Remove Wisp's hooks from \(preview.target.displaySettingsPath)?")
                .font(.headline)
                .foregroundStyle(WispColor.textPrimary)

            Text("Only Wisp's own entries change; everything else in the file stays as it is. The current file is copied to \(preview.target.settingsFileURL.lastPathComponent).bak-<date> beside it first. Restart running agent sessions to pick up the change.")
                .font(.callout)
                .foregroundStyle(WispColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(preview.removedLines.enumerated()), id: \.offset) { _, removedLine in
                        diffLine("- " + removedLine, color: WispColor.destructive)
                    }
                    ForEach(Array(preview.addedLines.enumerated()), id: \.offset) { _, addedLine in
                        diffLine("+ " + addedLine, color: WispColor.success)
                    }
                    if preview.addedLines.isEmpty && preview.removedLines.isEmpty {
                        Text("Nothing would change.")
                            .font(.callout)
                            .foregroundStyle(WispColor.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(minHeight: 220, maxHeight: 360)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(WispColor.groupedCardBackground)
            )

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .pointerCursor()
                Button(preview.isInstalling ? "Install" : "Remove", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .pointerCursor()
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    private func diffLine(_ lineText: String, color: Color) -> some View {
        Text(lineText)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(color)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
