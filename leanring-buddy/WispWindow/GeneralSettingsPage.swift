//
//  GeneralSettingsPage.swift
//  leanring-buddy
//
//  Settings → General: the first page of settings, and where setup happens.
//
//  It gathers what used to be split between the menu bar panel and the notch's
//  own settings pages — the four macOS permissions with their Grant buttons,
//  what's running (model, speech, voice) and whether it's all local, and the
//  switches for how the island looks and how Wisp sounds. The permission
//  checklist is also shown at the top of Today until everything is granted.
//

import AVFoundation
import SwiftUI

struct GeneralSettingsPage: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var islandStylePreference = NotchIslandStylePreference.shared
    @ObservedObject private var voiceOutputPreference = VoiceOutputPreference.shared
    @ObservedObject private var soundPreference = WispSoundPreference.shared
    @ObservedObject private var companionPreference = WispCompanionPreference.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DashboardCard(title: "Permissions") {
                    PermissionsChecklist(companionManager: companionManager)
                }
                ActiveStackCard()
                islandCard
                voiceCard
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(WispColor.windowBackground)
    }

    private var islandCard: some View {
        DashboardCard(title: "Notch") {
            SettingRow(
                title: "Island surface",
                detail: "Black blends into the notch, like the iPhone's Dynamic Island. Liquid Glass lets the desktop show through."
            ) {
                Picker("Island surface", selection: $islandStylePreference.surfaceStyle) {
                    ForEach(NotchIslandSurfaceStyle.allCases) { surfaceStyle in
                        Text(surfaceStyle.displayName).tag(surfaceStyle)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .pointerCursor()
            }
            Divider()
            SettingRow(
                title: "Companion",
                detail: "A little cloud lives in the notch: it follows your cursor with its eyes, hops when an agent finishes or something needs you, dozes off when it's quiet, and minds being poked. Off shows the Wisp mark."
            ) {
                Toggle("Companion", isOn: $companionPreference.isCompanionEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .pointerCursor()
            }
        }
    }

    private var voiceCard: some View {
        DashboardCard(title: "Voice & sound") {
            VStack(alignment: .leading, spacing: 12) {
                SettingRow(
                    title: "Speak replies",
                    detail: "On, Wisp says a short line out loud when it helps. Off is silent mode: answers appear only in the notch."
                ) {
                    Toggle("Speak replies", isOn: $voiceOutputPreference.isReplySpeechEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .pointerCursor()
                }
                Divider()
                SettingRow(
                    title: "Sound cues",
                    detail: "Soft chimes as Wisp starts listening, thinks and replies."
                ) {
                    Toggle("Sound cues", isOn: $soundPreference.areSoundCuesEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .pointerCursor()
                }
                if !AppleSpeechSynthesisClient.hasHighQualityVoiceInstalled {
                    Divider()
                    VoiceUpgradeHint()
                }
            }
        }
    }
}

// MARK: - Shared rows

/// A setting's title and explanation on the left, its control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(WispColor.textPrimary)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(WispColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            control
        }
    }
}

// MARK: - Permissions

/// The four macOS permissions Wisp needs, each with its status and a Grant
/// button that raises the system prompt (or opens System Settings once the
/// prompt has already been answered).
struct PermissionsChecklist: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            permissionRow(
                title: "Microphone",
                detail: "Hear you while you hold the talk shortcut.",
                symbolName: "mic",
                isGranted: companionManager.hasMicrophonePermission,
                grant: requestMicrophone
            )
            Divider().padding(.vertical, 8)
            permissionRow(
                title: "Accessibility",
                detail: "Notice the talk shortcut in any app and type dictated text.",
                symbolName: "hand.raised",
                isGranted: companionManager.hasAccessibilityPermission,
                grant: { WindowPositionManager.requestAccessibilityPermission() },
                secondaryActionTitle: "Find App",
                secondaryAction: {
                    // Unsigned development builds often don't appear in the list
                    // on their own; revealing the app lets the user drag it in.
                    WindowPositionManager.revealAppInFinder()
                    WindowPositionManager.openAccessibilitySettings()
                }
            )
            Divider().padding(.vertical, 8)
            permissionRow(
                title: "Screen Recording",
                detail: companionManager.hasScreenRecordingPermission
                    ? "Only takes a screenshot when you ask something."
                    : "See the screen to answer and point. Quit and reopen Wisp after granting.",
                symbolName: "rectangle.dashed.badge.record",
                isGranted: companionManager.hasScreenRecordingPermission,
                grant: { WindowPositionManager.requestScreenRecordingPermission() }
            )
            if companionManager.hasScreenRecordingPermission {
                Divider().padding(.vertical, 8)
                permissionRow(
                    title: "Screen Content",
                    detail: "Read the window contents behind a question.",
                    symbolName: "eye",
                    isGranted: companionManager.hasScreenContentPermission,
                    grant: { companionManager.requestScreenContentPermission() }
                )
            }
        }
    }

    private func requestMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        } else if let microphoneSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(microphoneSettingsURL)
        }
    }

    private func permissionRow(
        title: String,
        detail: String,
        symbolName: String,
        isGranted: Bool,
        grant: @escaping () -> Void,
        secondaryActionTitle: String? = nil,
        secondaryAction: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbolName)
                .font(.body.weight(.medium))
                .foregroundStyle(isGranted ? WispColor.textSecondary : WispColor.warning)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(WispColor.textPrimary)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(WispColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if isGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(WispColor.success)
            } else {
                if let secondaryActionTitle, let secondaryAction {
                    Button(secondaryActionTitle, action: secondaryAction)
                        .buttonStyle(.bordered)
                        .pointerCursor()
                }
                Button("Grant", action: grant)
                    .buttonStyle(.borderedProminent)
                    .pointerCursor()
            }
        }
    }
}

// MARK: - What's running

/// The model, speech and voice Wisp is using right now, whether the model is
/// warm, and whether everything stays on this Mac.
struct ActiveStackCard: View {
    @ObservedObject private var stackReadout = ActiveStackReadout.shared
    @ObservedObject private var toolRegistry = AgentToolRegistry.shared

    var body: some View {
        DashboardCard(title: "What's running") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(residencyColor)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stackReadout.chatModelName)
                            .font(.body.weight(.medium).monospaced())
                            .foregroundStyle(WispColor.textPrimary)
                        Text(residencyDescription)
                            .font(.callout)
                            .foregroundStyle(WispColor.textSecondary)
                    }
                    Spacer(minLength: 0)
                    if CompanionManager.isAgentModeEnabled {
                        Label("Agent mode · \(toolRegistry.definitions.count) tools", systemImage: "bolt.fill")
                            .font(.callout)
                            .foregroundStyle(WispColor.accentText)
                    }
                }
                Divider()
                stackRow(label: "Speech", value: stackReadout.speechProviderName)
                stackRow(label: "Voice", value: stackReadout.voiceProviderName)
                Divider()
                Label(
                    stackReadout.isEntirelyLocal
                        ? "Runs entirely on this Mac. Nothing you say or show Wisp is sent anywhere."
                        : "One or more stages use a cloud service, so some of what you say or show Wisp leaves this Mac.",
                    systemImage: stackReadout.isEntirelyLocal ? "lock.laptopcomputer" : "icloud"
                )
                .font(.callout)
                .foregroundStyle(stackReadout.isEntirelyLocal ? WispColor.success : WispColor.warningText)
            }
        }
        .onAppear { stackReadout.startPolling() }
        .onDisappear { stackReadout.stopPolling() }
    }

    private func stackRow(label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundStyle(WispColor.textSecondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.callout)
                .foregroundStyle(WispColor.textPrimary)
            Spacer(minLength: 0)
        }
    }

    private var residencyColor: Color {
        switch stackReadout.residency {
        case .resident: return WispColor.success
        case .notLoaded: return WispColor.warning
        case .unreachable: return WispColor.destructive
        }
    }

    private var residencyDescription: String {
        switch stackReadout.residency {
        case .resident(_, let sizeText):
            return "\(stackReadout.chatProviderName) · \(sizeText) loaded"
        case .notLoaded:
            // Named as a delay rather than a state: "not loaded" invites the
            // reading that something is broken, when it only means the next
            // question pays the load cost once.
            return "\(stackReadout.chatProviderName) · cold, the first reply is slower"
        case .unreachable:
            return "Ollama isn't running — start it with `ollama serve`"
        }
    }
}

/// Shown only while the installed voices are the robotic ones. macOS ships
/// compact voices and says nothing about the better ones being a free download,
/// and the setting is four levels deep, so this opens the right pane directly.
struct VoiceUpgradeHint: View {
    var body: some View {
        SettingRow(
            title: "Get a natural voice",
            detail: "Only the basic macOS voices are installed, so spoken replies sound robotic. Enhanced voices are a free download."
        ) {
            Button("Open Spoken Content") {
                if let spokenContentURL = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent") {
                    NSWorkspace.shared.open(spokenContentURL)
                }
            }
            .buttonStyle(.bordered)
            .pointerCursor()
        }
    }
}
