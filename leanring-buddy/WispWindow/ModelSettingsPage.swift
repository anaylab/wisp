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

                UsageCard()

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
                Text("Local models stay in memory. When it runs short the system evicts them and the next reply is slow.")
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

                if selectedProviderKind == .claudeSubscription {
                    ClaudeSubscriptionStatusRow()
                }

                if selectedProviderKind == .anthropic || selectedProviderKind == .claudeSubscription {
                    ClaudeModelOptions(
                        companionManager: companionManager,
                        offersWebAccess: selectedProviderKind == .anthropic
                    )
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
            Text("Screenshots and your voice transcript go to \(selectedProviderKind.displayName) over the network. Local keeps everything on this Mac.")
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
                .buttonStyle(WispPillButtonStyle(isProminent: false))
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

/// Whether the `claude` CLI is installed and signed in — the only setup the
/// subscription provider needs. Checked by asking the CLI, never by reading
/// its credentials.
private struct ClaudeSubscriptionStatusRow: View {
    @State private var status: ClaudeSubscriptionStatus = .checking

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 10))
                .foregroundStyle(isReady ? DS.Colors.success : DS.Colors.textTertiary)
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(isReady ? DS.Colors.textSecondary : DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Check again") {
                Task { await refresh() }
            }
            .buttonStyle(WispPillButtonStyle(isProminent: false))
            .controlSize(.small)
            .pointerCursor()
        }
        .task { await refresh() }
    }

    private var isReady: Bool {
        if case .signedIn = status { return true }
        return false
    }

    private var iconName: String {
        isReady ? "checkmark.circle.fill" : "circle.dashed"
    }

    private var message: String {
        switch status {
        case .checking:
            return "Checking the Claude Code command line tool…"
        case .notInstalled:
            return "The Claude Code command line tool isn't installed. Install it, then run `claude` in Terminal once to sign in with your subscription."
        case .signedOut:
            return "Not signed in. Run `claude` in Terminal and sign in with your Claude subscription."
        case .signedIn(let email):
            return "Signed in\(email.map { " as \($0)" } ?? ""). Replies take about 4 seconds longer and count against your subscription's limits."
        }
    }

    private func refresh() async {
        status = .checking
        status = await ClaudeSubscriptionStatus.current()
    }
}

/// Claude's own choices, shown under the provider picker while Claude is
/// selected: which model, how hard it thinks, and whether it may use the web.
/// Each change rebuilds the provider so the next turn uses it.
private struct ClaudeModelOptions: View {
    @ObservedObject var companionManager: CompanionManager
    /// The web switch is an API feature (server-side tools); the subscription
    /// route runs the CLI with its tools off, so it has nothing to switch.
    let offersWebAccess: Bool

    @State private var selectedModel: AnthropicModelChoice = AnthropicModelSettings.selectedModel
    @State private var effortLevel: AnthropicEffortLevel = AnthropicModelSettings.effortLevel
    @State private var isWebAccessEnabled: Bool = AnthropicModelSettings.isWebAccessEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            SettingRow(title: "Claude model", detail: selectedModel.shortDescription) {
                Picker("Claude model", selection: $selectedModel) {
                    ForEach(AnthropicModelChoice.allCases) { modelChoice in
                        Text(modelChoice.displayName).tag(modelChoice)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .pointerCursor()
            }
            .onChange(of: selectedModel) { _, newModel in
                AnthropicModelSettings.selectedModel = newModel
                companionManager.rebuildSelectedModelProvider()
            }

            SettingRow(title: "Thinking", detail: thinkingDetail) {
                WispSegmented(
                    options: AnthropicEffortLevel.allCases,
                    title: { $0.displayName },
                    selection: $effortLevel
                )
                .disabled(!selectedModel.usesAdaptiveThinkingAndEffort)
            }
            .onChange(of: effortLevel) { _, newEffortLevel in
                AnthropicModelSettings.effortLevel = newEffortLevel
                companionManager.rebuildSelectedModelProvider()
            }

            if offersWebAccess {
            SettingRow(
                title: "Search the web",
                detail: "Lets Claude search and read web pages itself during tasks, on Anthropic's servers — without using your browser."
            ) {
                Toggle("Search the web", isOn: $isWebAccessEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .pointerCursor()
            }
            .onChange(of: isWebAccessEnabled) { _, newValue in
                AnthropicModelSettings.isWebAccessEnabled = newValue
                companionManager.rebuildSelectedModelProvider()
            }
            }
        }
    }

    private var thinkingDetail: String {
        guard selectedModel.usesAdaptiveThinkingAndEffort else {
            return "Haiku answers without extended thinking."
        }
        switch effortLevel {
        case .low: return "Quickest replies. Claude still thinks, but briefly."
        case .medium: return "More thought for multi-step tasks, a little slower."
        case .high: return "Deepest reasoning. Slowest and uses the most tokens."
        }
    }
}

// MARK: - Usage

/// What recent turns used and roughly cost at API prices, from the local
/// `UsageLogStore`. Totals for today, 7 days and 30 days, split by provider.
private struct UsageCard: View {
    @ObservedObject private var usageLogStore = UsageLogStore.shared

    var body: some View {
        let usageSummary = usageLogStore.summary
        DashboardCard(title: "Usage") {
            if usageSummary.lastThirtyDays.turnCount == 0 {
                Text("Nothing logged yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    usageRow(label: "Today", totals: usageSummary.today)
                    usageRow(label: "Last 7 days", totals: usageSummary.lastSevenDays)
                    usageRow(label: "Last 30 days", totals: usageSummary.lastThirtyDays)
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(usageSummary.providerBreakdown) { providerBreakdown in
                        HStack {
                            Text(providerBreakdown.providerKind.displayName)
                                .font(.system(size: 11))
                                .foregroundStyle(DS.Colors.textSecondary)
                            Spacer()
                            Text("\(providerBreakdown.totals.turnCount) turns · " + UsageCostEstimator.costLabel(
                                providerKind: providerBreakdown.providerKind,
                                estimatedCostUSD: providerBreakdown.totals.estimatedCostUSD))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(DS.Colors.textPrimary)
                        }
                    }
                }
            }
            HStack {
                Text("Stays on this Mac. Counts only, never your words. Cost is an estimate (prices as of \(ModelPricing.pricesSetOn)).")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Colors.textTertiary)
                Spacer()
                Button("Clear") { usageLogStore.clear() }
                    .buttonStyle(WispPillButtonStyle(isProminent: false))
                    .controlSize(.small)
                    .pointerCursor()
                    .disabled(usageSummary.lastThirtyDays.turnCount == 0)
            }
        }
    }

    private func usageRow(label: String, totals: UsageTotals) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.textSecondary)
            Spacer()
            Text("\(totals.turnCount) turns · \(UsageAggregator.formattedTokenCount(totals.totalTokens)) tokens · ≈ \(UsageCostEstimator.formattedDollars(totals.estimatedCostUSD))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DS.Colors.textPrimary)
        }
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
            .padding(16)
            // Same surface as Today's bento tiles, so every page of the window
            // reads as one system.
            .wispBentoSurface()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .wispEntrance()
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
