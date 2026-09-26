//
//  DashboardView.swift
//  leanring-buddy
//
//  The dashboard's SwiftUI content: activity history, conversation
//  transcript, connected tools, and per-turn performance.
//
//  The menu bar panel is deliberately small and momentary — it answers
//  "is Wisp working right now?". This window answers the questions the
//  panel has no room for: what did it just do, how long did each stage
//  take, what can it actually reach, and why is it slow at the moment.
//  That last question needs real numbers, because on a machine running the
//  models locally the honest answer is usually "a screenshot cost six
//  seconds" or "memory is full", and neither is guessable from the outside.
//
//  Navigation is a sidebar rather than a row of tabs. Tabs were fine for
//  three sections and stop being fine as sections accumulate, and the
//  sidebar's footer gives memory pressure a permanent home — worth doing,
//  because on 18GB the memory number is the hidden variable behind almost
//  every "why was that slow" question, and it should not be a page someone
//  has to think to visit.
//

import Combine
import SwiftUI

struct DashboardView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var taskRegistry: AgentTaskRegistry
    @ObservedObject var metricsRecorder: PerfMetricsRecorder

    @State private var selectedTab: DashboardTab = .home
    /// The page last open in each section, so returning to Settings lands on
    /// Dictation again rather than resetting to the section's first page.
    @State private var lastSelectedPageBySection: [DashboardSection: DashboardTab] = [:]
    @State private var memory = SystemReadouts.memoryBreakdown()

    /// Two seconds: fast enough to catch a model loading, slow enough that the
    /// sidebar is not redrawing constantly behind whatever the user is reading.
    private let memoryRefreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    /// The sidebar's five destinations. Each groups one or more pages
    /// (`DashboardTab`); a section with several pages shows them as sub-tabs in
    /// the content header. Grouped by what the user came to do — see what's
    /// happening, look back, automate, connect things, adjust how Wisp behaves —
    /// instead of one sidebar row per settings screen.
    enum DashboardSection: String, CaseIterable, Identifiable {
        case today = "Today"
        case history = "History"
        case routines = "Routines"
        case connections = "Connections"
        case settings = "Settings"

        var id: String { rawValue }

        var symbolName: String {
            switch self {
            case .today: return "sun.max"
            case .history: return "clock.arrow.circlepath"
            case .routines: return "bolt"
            case .connections: return "powerplug"
            case .settings: return "slider.horizontal.3"
            }
        }

        /// The section's pages, in sub-tab order. The first is the default.
        var pages: [DashboardTab] {
            switch self {
            case .today: return [.home]
            case .history: return [.activity, .conversation, .memory]
            case .routines: return [.routines]
            case .connections: return [.marketplace, .tools, .sources]
            case .settings: return [.shortcuts, .dictation, .cursor, .agent, .performance]
            }
        }
    }

    enum DashboardTab: String, CaseIterable, Identifiable {
        case home = "Home"
        case routines = "Routines"
        case activity = "Activity"
        case conversation = "Conversation"
        case memory = "Memory"
        case shortcuts = "Shortcuts"
        case dictation = "Dictation"
        case cursor = "Cursor"
        case agent = "Agent"
        case marketplace = "Marketplace"
        case tools = "Tools & Servers"
        case sources = "Sources"
        case performance = "Model & Performance"

        var id: String { rawValue }

        /// The section this page lives under in the sidebar.
        var section: DashboardSection {
            DashboardSection.allCases.first { $0.pages.contains(self) } ?? .today
        }

        /// The page's name as a sub-tab — shorter than `rawValue` where the
        /// section title already says the rest.
        var subTabTitle: String {
            switch self {
            case .activity: return "Timeline"
            case .tools: return "Servers & Tools"
            case .performance: return "Model"
            default: return rawValue
            }
        }

        var symbolName: String {
            switch self {
            case .home: return "house"
            case .routines: return "bolt"
            case .activity: return "list.bullet.rectangle"
            case .conversation: return "bubble.left.and.bubble.right"
            case .memory: return "brain.head.profile"
            case .shortcuts: return "keyboard"
            case .dictation: return "mic"
            case .cursor: return "cursorarrow"
            case .agent: return "cpu"
            case .marketplace: return "bag"
            case .tools: return "wrench.and.screwdriver"
            case .sources: return "antenna.radiowaves.left.and.right"
            case .performance: return "speedometer"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 208)

            Divider().background(DS.Colors.borderSubtle)

            VStack(spacing: 0) {
                contentHeader
                Divider().background(DS.Colors.borderSubtle)

                Group {
                    switch selectedTab {
                    case .home:
                        HomeTab(
                            taskRegistry: taskRegistry,
                            companionManager: companionManager,
                            onSelectTab: { selectPage($0) }
                        )
                    case .routines: RoutinesTab(companionManager: companionManager)
                    case .activity:
                        HistoryTab(
                            taskRegistry: taskRegistry,
                            companionManager: companionManager,
                            onSelectTab: { selectPage($0) }
                        )
                    case .conversation: ConversationTab(taskRegistry: taskRegistry)
                    case .memory: MemoryTab()
                    case .shortcuts: ShortcutsTab()
                    case .dictation: DictationTab()
                    case .cursor: CursorTab(companionManager: companionManager)
                    case .agent: AgentTab(companionManager: companionManager)
                    case .marketplace: MarketplaceTab()
                    case .tools: ToolsTab()
                    case .sources: SourcesTab()
                    case .performance: PerformanceTab(metricsRecorder: metricsRecorder, companionManager: companionManager)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // The content area keeps a solid dark fill so its dense text and
            // controls stay crisp; only the sidebar is vibrant glass.
            .background(DS.Colors.background)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            identityHeader

            VStack(spacing: 2) {
                ForEach(DashboardSection.allCases) { section in
                    sidebarItem(for: section)
                }
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 16)

            memoryFooter
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // Vibrant Liquid Glass sidebar so the window reads as the same material
        // as the notch HUD and the menu bar panel, rather than a flat fill.
        .wispGlassSurface(cornerRadius: 0)
    }

    private var identityHeader: some View {
        HStack(spacing: 9) {
            // The same triangle the menu bar and overlay cursor use, so the
            // window reads as the same app rather than a separate tool.
            Triangle()
                .fill(DS.Colors.overlayCursorBlue)
                .frame(width: 13, height: 15)
                .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 5)

            VStack(alignment: .leading, spacing: 1) {
                Text("Wisp")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.Colors.textPrimary)
                Text("Running locally")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Colors.textTertiary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }

    /// Opens a section at the page last used in it (or its first page).
    private func selectSection(_ section: DashboardSection) {
        selectPage(lastSelectedPageBySection[section] ?? section.pages[0])
    }

    private func selectPage(_ page: DashboardTab) {
        selectedTab = page
        lastSelectedPageBySection[page.section] = page
    }

    private func sidebarItem(for section: DashboardSection) -> some View {
        let isSelected = selectedTab.section == section
        let runningCount = section == .history ? taskRegistry.runningRecords.count : 0

        return Button {
            selectSection(section)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: section.symbolName)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(section.rawValue)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)

                Spacer(minLength: 4)

                // A running-task count belongs next to History, not in a
                // corner of the window: it is the reason someone would switch
                // to that section.
                if runningCount > 0 {
                    Text("\(runningCount)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(DS.Colors.textOnAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(DS.Colors.accent))
                }
            }
            .foregroundStyle(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.10) : .clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .strokeBorder(DS.Colors.borderSubtle.opacity(isSelected ? 0.7 : 0), lineWidth: 0.75)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }

    /// Memory pressure, always visible and always current.
    ///
    /// Everything about this app's behaviour on an 18GB machine — why a model
    /// was evicted, why the first screen question after idle is slow, why two
    /// models will not co-reside — traces back to this number. Burying it in a
    /// tab means it is only consulted by someone who already suspects it.
    ///
    /// The bar carries the reading before the text does. Whether the machine
    /// is near its ceiling is a glance, not a subtraction.
    private var memoryFooter: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().background(DS.Colors.borderSubtle)

            VStack(alignment: .leading, spacing: 5) {
                Text("MEMORY")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .tracking(0.6)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(DS.Colors.surface3)
                        Capsule()
                            .fill(memoryBarColor)
                            .frame(width: max(2, proxy.size.width * memory.usedFraction))
                    }
                }
                .frame(height: 4)

                // Stacked rather than joined by separators: at this width a
                // single line truncates, and the value it drops is the one
                // that matters when memory is tight.
                Text("\(memory.usedText) of \(memory.totalText)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DS.Colors.textSecondary)

                Text(memory.compressedText.map { "\(memory.freeText) free · \($0) compressed" }
                     ?? "\(memory.freeText) free")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)
        }
        .onReceive(memoryRefreshTimer) { _ in
            memory = SystemReadouts.memoryBreakdown()
        }
    }

    private var memoryBarColor: Color {
        // Thresholds chosen from what actually goes wrong: past ~85% the model
        // starts getting evicted between turns, and past ~95% synthesis and
        // inference begin failing outright.
        switch memory.usedFraction {
        case ..<0.85: return DS.Colors.success
        case ..<0.95: return DS.Colors.warning
        default: return DS.Colors.destructive
        }
    }

    // MARK: - Content header

    private var contentHeader: some View {
        HStack(spacing: 12) {
            Text(selectedTab.section.rawValue)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Colors.textPrimary)

            if selectedTab.section.pages.count > 1 {
                subTabBar(for: selectedTab.section)
            }

            Spacer()

            if taskRegistry.runningRecords.isEmpty == false {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("\(taskRegistry.runningRecords.count) running")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textSecondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(DS.Colors.surface1)
    }

    /// The pages of a multi-page section, as a row of pill tabs beside its title.
    private func subTabBar(for section: DashboardSection) -> some View {
        HStack(spacing: 2) {
            ForEach(section.pages) { page in
                subTabButton(for: page)
            }
        }
        .padding(2)
        .background(
            Capsule(style: .continuous)
                .fill(DS.Colors.surface2)
        )
    }

    private func subTabButton(for page: DashboardTab) -> some View {
        let isSelected = selectedTab == page
        return Button {
            selectPage(page)
        } label: {
            Text(page.subTabTitle)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? DS.Colors.surface4 : .clear)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - Conversation

private struct ConversationTab: View {
    @ObservedObject var taskRegistry: AgentTaskRegistry

    /// Completed interactions, oldest first, so it reads like a conversation.
    private var exchanges: [AgentTaskRecord] {
        taskRegistry.records
            .filter { $0.finalText?.isEmpty == false }
            .reversed()
    }

    var body: some View {
        if exchanges.isEmpty {
            DashboardEmptyState(
                symbolName: "bubble.left.and.bubble.right",
                title: "No conversation yet",
                message: "Your full history lives here — including turns the model itself has already forgotten, since it only sees the most recent ones."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(exchanges) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(record.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(DS.Colors.textPrimary)
                                .textSelection(.enabled)

                            Text(record.finalText ?? "")
                                .font(.system(size: 12))
                                .foregroundStyle(DS.Colors.textSecondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)

                            Text(record.startedAt.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 10))
                                .foregroundStyle(DS.Colors.textTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                .fill(DS.Colors.surface1)
                        )
                    }
                }
                .padding(12)
            }
        }
    }
}

// MARK: - Performance

private struct PerformanceTab: View {
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
            .padding(14)
        }
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

struct DashboardCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.Colors.textSecondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
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
        VStack(spacing: 8) {
            Image(systemName: symbolName)
                .font(.system(size: 26))
                .foregroundStyle(DS.Colors.textTertiary)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.Colors.textSecondary)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}
