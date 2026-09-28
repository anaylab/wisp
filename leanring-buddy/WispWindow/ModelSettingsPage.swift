//
//  ModelSettingsPage.swift
//  leanring-buddy
//
//  Settings → Model (`PerformanceTab`): which model backs Wisp, the local
//  system readouts, and per-turn timings. Also the card and empty-state views
//  every Wisp window page shares.
//
//  The numbers are here because on a machine running the models locally the
//  honest answer to "why was that slow" is usually "a screenshot cost six
//  seconds" or "memory is full", and neither is guessable from the outside.
//

import Combine
import SwiftUI

// MARK: - Performance

struct PerformanceTab: View {
    @ObservedObject var metricsRecorder: PerfMetricsRecorder
    @ObservedObject var companionManager: CompanionManager
    @State private var memoryReadout: String = "—"
    @State private var modelResidency: String = "checking…"

    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ModelProviderCard(companionManager: companionManager)

                systemSection

                if metricsRecorder.recentTurns.isEmpty {
                    DashboardEmptyState(
                        symbolName: "speedometer",
                        title: "No timings yet",
                        message: "Timings appear after your first voice interaction."
                    )
                    .frame(height: 180)
                } else {
                    medianSection
                    recentTurnsSection
                }
            }
            .padding(20)
        }
        .background(WispColor.windowBackground)
        .onAppear {
            refreshSystemReadouts()
        }
        .onReceive(refreshTimer) { _ in
            refreshSystemReadouts()
        }
    }

    private var systemSection: some View {
        DashboardCard(title: "System") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledReadout(label: "Loaded model", value: modelResidency)
                LabeledReadout(label: "Memory", value: memoryReadout)
                Text("Local models are held in memory to stay fast. When memory runs short the system evicts them, and the next request pays to rebuild — which is what a sudden slowdown usually means.")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var medianSection: some View {
        DashboardCard(title: "Typical timings (median)") {
            VStack(alignment: .leading, spacing: 10) {
                timingRow(label: "Conversational turn", screenshotAttached: false)
                Divider().background(DS.Colors.borderSubtle)
                timingRow(label: "Screen question", screenshotAttached: true)
            }
        }
    }

    private func timingRow(label: String, screenshotAttached: Bool) -> some View {
        let phases = TurnPhase.allCases.sorted { $0.sortIndex < $1.sortIndex }
        let measured = phases.compactMap { phase -> (TurnPhase, TimeInterval)? in
            guard let seconds = metricsRecorder.medianSeconds(for: phase, screenshotAttached: screenshotAttached) else {
                return nil
            }
            return (phase, seconds)
        }

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.Colors.textPrimary)
                Spacer()
                if !measured.isEmpty {
                    Text(String(format: "%.1fs total", measured.reduce(0) { $0 + $1.1 }))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DS.Colors.textPrimary)
                }
            }

            if measured.isEmpty {
                Text("no samples yet")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Colors.textTertiary)
            } else {
                ForEach(measured, id: \.0) { phase, seconds in
                    HStack(spacing: 8) {
                        Text(phase.rawValue)
                            .font(.system(size: 10))
                            .foregroundStyle(DS.Colors.textSecondary)
                            .frame(width: 150, alignment: .leading)

                        GeometryReader { geometry in
                            let maximum = measured.map(\.1).max() ?? 1
                            RoundedRectangle(cornerRadius: 3)
                                .fill(DS.Colors.accent)
                                .frame(width: max(2, geometry.size.width * (seconds / maximum)))
                        }
                        .frame(height: 6)

                        Text(String(format: "%.2fs", seconds))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(DS.Colors.textTertiary)
                            .frame(width: 48, alignment: .trailing)
                    }
                    .frame(height: 14)
                }
            }
        }
    }

    private var recentTurnsSection: some View {
        DashboardCard(title: "Recent turns") {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(metricsRecorder.recentTurns.prefix(12)) { turn in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: turn.didAttachScreenshot ? "photo" : "text.bubble")
                            .font(.system(size: 9))
                            .foregroundStyle(DS.Colors.textTertiary)
                            .frame(width: 14)
                            .padding(.top, 2)

                        Text(turn.transcript.isEmpty ? "(no transcript)" : turn.transcript)
                            .font(.system(size: 10))
                            .foregroundStyle(DS.Colors.textSecondary)
                            .lineLimit(1)

                        Spacer(minLength: 6)

                        if let slowest = turn.slowestPhase {
                            Text(slowest.phase.rawValue)
                                .font(.system(size: 9))
                                .foregroundStyle(DS.Colors.textTertiary)
                        }

                        Text(String(format: "%.1fs", turn.totalSeconds))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(DS.Colors.textPrimary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func refreshSystemReadouts() {
        memoryReadout = SystemReadouts.memorySummary()
        Task {
            let residency = await SystemReadouts.ollamaResidencySummary()
            await MainActor.run { modelResidency = residency }
        }
    }
}

// MARK: - Model provider selection

/// Lets the user choose which model backs Wisp — the local Ollama model, or a
/// bring-your-own-key cloud provider — and enter that provider's API key.
///
/// The privacy trade is the whole point of showing it plainly: the local model
/// keeps everything on this machine, and any cloud choice sends screenshots and
/// the voice transcript off it. The warning is not fine print; it is stated as
/// prominently as the choice that triggers it.
private struct ModelProviderCard: View {
    @ObservedObject var companionManager: CompanionManager

    /// Mirrors the persisted selection. This card is the only place it changes,
    /// so a one-way initial read is enough.
    @State private var selectedProviderKind: BuddyChatProviderKind = BuddyChatProviderSelection.current
    /// The key being entered. Cleared as soon as it is saved so plaintext does
    /// not linger in view state.
    @State private var apiKeyDraft: String = ""
    /// Whether a key is already stored for the selected provider.
    @State private var hasStoredAPIKey: Bool = false

    var body: some View {
        DashboardCard(title: "Model provider") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: $selectedProviderKind) {
                    ForEach(BuddyChatProviderKind.allCases) { providerKind in
                        Text(providerKind.displayName).tag(providerKind)
                    }
                }
                .labelsHidden()
                .pointerCursor()
                .onChange(of: selectedProviderKind) { _, newProviderKind in
                    BuddyChatProviderSelection.set(newProviderKind)
                    companionManager.rebuildSelectedModelProvider()
                    // Reset the entry to whatever the newly selected provider
                    // already has stored, and never carry one provider's typed
                    // key over to another.
                    apiKeyDraft = ""
                    hasStoredAPIKey = ProviderKeychainStore.hasAPIKey(for: newProviderKind)
                }

                if selectedProviderKind.sendsScreenshotsOffThisMachine {
                    cloudPrivacyNotice
                } else {
                    localPrivacyNote
                }

                if selectedProviderKind.requiresAPIKey {
                    apiKeyField
                }
            }
        }
        .onAppear {
            hasStoredAPIKey = ProviderKeychainStore.hasAPIKey(for: selectedProviderKind)
        }
    }

    private var cloudPrivacyNotice: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.warning)
                .padding(.top, 1)
            Text("Screenshots and your voice transcript are sent to \(selectedProviderKind.displayName) over the network. Paid API tiers generally don't train on your data; free tiers often do. Local keeps everything on this machine.")
                .font(.system(size: 10))
                .foregroundStyle(DS.Colors.warningText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var localPrivacyNote: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.success)
                .padding(.top, 1)
            Text("Runs on this machine. Screenshots and your voice never leave your Mac.")
                .font(.system(size: 10))
                .foregroundStyle(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var apiKeyField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SecureField("Paste \(selectedProviderKind.displayName) API key", text: $apiKeyDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(DS.Colors.surface2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                    )

                Button("Save") {
                    saveTypedAPIKey()
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .pointerCursor()
                .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack(spacing: 8) {
                Image(systemName: hasStoredAPIKey ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.system(size: 10))
                    .foregroundStyle(hasStoredAPIKey ? DS.Colors.success : DS.Colors.textTertiary)
                Text(hasStoredAPIKey ? "Key saved" : "No key set — this provider can't run until you add one")
                    .font(.system(size: 10))
                    .foregroundStyle(hasStoredAPIKey ? DS.Colors.textSecondary : DS.Colors.textTertiary)

                Spacer()

                if hasStoredAPIKey {
                    Button("Clear key") {
                        clearStoredAPIKey()
                    }
                    .buttonStyle(DSTextButtonStyle())
                    .pointerCursor()
                }
            }
        }
    }

    private func saveTypedAPIKey() {
        let trimmedKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }
        ProviderKeychainStore.save(trimmedKey, for: selectedProviderKind)
        apiKeyDraft = ""
        hasStoredAPIKey = true
        // Rebuild so a provider that was constructed without a key picks the new
        // one up immediately.
        companionManager.rebuildSelectedModelProvider()
    }

    private func clearStoredAPIKey() {
        ProviderKeychainStore.deleteAPIKey(for: selectedProviderKind)
        apiKeyDraft = ""
        hasStoredAPIKey = false
        companionManager.rebuildSelectedModelProvider()
    }
}

// MARK: - Shared pieces

/// A titled, grouped card — the building block of every Wisp window page. Drawn
/// with the system's grouped-content colours, like a System Settings section.
struct DashboardCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(WispColor.textPrimary)
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(WispColor.groupedCardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(WispColor.cardSeparator, lineWidth: 0.5)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LabeledReadout: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DS.Colors.textPrimary)
        }
    }
}

struct DashboardEmptyState: View {
    let symbolName: String
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbolName)
        } description: {
            Text(message)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
