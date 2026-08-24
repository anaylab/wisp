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

    @State private var selectedTab: DashboardTab = .activity
    @State private var memory = SystemReadouts.memoryBreakdown()

    /// Two seconds: fast enough to catch a model loading, slow enough that the
    /// sidebar is not redrawing constantly behind whatever the user is reading.
    private let memoryRefreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    enum DashboardTab: String, CaseIterable, Identifiable {
        case activity = "Activity"
        case conversation = "Conversation"
        case tools = "Tools & Servers"
        case performance = "Model & Performance"

        var id: String { rawValue }

        var symbolName: String {
            switch self {
            case .activity: return "list.bullet.rectangle"
            case .conversation: return "bubble.left.and.bubble.right"
            case .tools: return "wrench.and.screwdriver"
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
                    case .activity: ActivityTab(taskRegistry: taskRegistry)
                    case .conversation: ConversationTab(taskRegistry: taskRegistry)
                    case .tools: ToolsTab()
                    case .performance: PerformanceTab(metricsRecorder: metricsRecorder)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DS.Colors.background)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            identityHeader

            VStack(spacing: 2) {
                ForEach(DashboardTab.allCases) { tab in
                    sidebarItem(for: tab)
                }
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 16)

            memoryFooter
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.Colors.surface1)
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

    private func sidebarItem(for tab: DashboardTab) -> some View {
        let isSelected = selectedTab == tab
        let runningCount = tab == .activity ? taskRegistry.runningRecords.count : 0

        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 9) {
                Image(systemName: tab.symbolName)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(tab.rawValue)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)

                Spacer(minLength: 4)

                // A running-task count belongs next to Activity, not in a
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
                    .fill(isSelected ? DS.Colors.surface3 : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
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
        HStack(spacing: 8) {
            Text(selectedTab.rawValue)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Colors.textPrimary)

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
}

// MARK: - Activity

private struct ActivityTab: View {
    @ObservedObject var taskRegistry: AgentTaskRegistry
    @State private var expandedTaskIDs: Set<UUID> = []

    var body: some View {
        if taskRegistry.records.isEmpty {
            DashboardEmptyState(
                symbolName: "list.bullet.rectangle",
                title: "No activity yet",
                message: "Hold control + option and say something. Each interaction shows up here with a timing breakdown."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(taskRegistry.records) { record in
                        TaskRow(
                            record: record,
                            isExpanded: expandedTaskIDs.contains(record.id),
                            onToggleExpanded: { toggleExpanded(record.id) },
                            onCancel: { taskRegistry.cancelTask(record.id) }
                        )
                    }
                }
                .padding(12)
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer()
                    Button("Clear finished") { taskRegistry.clearCompleted() }
                        .font(.system(size: 11))
                        .buttonStyle(.plain)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .pointerCursor()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(DS.Colors.surface1)
            }
        }
    }

    private func toggleExpanded(_ id: UUID) {
        if expandedTaskIDs.contains(id) {
            expandedTaskIDs.remove(id)
        } else {
            expandedTaskIDs.insert(id)
        }
    }
}

private struct TaskRow: View {
    let record: AgentTaskRecord
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggleExpanded) {
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                        .padding(.top, 5)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DS.Colors.textPrimary)
                            .lineLimit(isExpanded ? nil : 1)
                            .multilineTextAlignment(.leading)

                        HStack(spacing: 8) {
                            Text(record.status.displayName)
                                .foregroundStyle(statusColor)
                            Text("·")
                            Text(formattedElapsed)
                            if record.steps.count > 1 {
                                Text("·")
                                Text("\(record.steps.count) steps")
                            }
                            if record.kind == .background {
                                Text("·")
                                Text("background")
                            }
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(DS.Colors.textTertiary)
                    }

                    Spacer(minLength: 8)

                    if !record.status.isTerminal {
                        Button("Cancel", action: onCancel)
                            .font(.system(size: 10))
                            .buttonStyle(.plain)
                            .foregroundStyle(DS.Colors.textSecondary)
                            .pointerCursor()
                    }

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DS.Colors.textTertiary)
                        .padding(.top, 3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let finalText = record.finalText, !finalText.isEmpty {
                        Text(finalText)
                            .font(.system(size: 11))
                            .foregroundStyle(DS.Colors.textSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(record.steps) { step in
                        HStack(alignment: .top, spacing: 8) {
                            Text(step.kindLabel)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(step.isError ? DS.Colors.destructiveText : DS.Colors.accentText)
                                .frame(width: 74, alignment: .leading)

                            Text(step.summary)
                                .font(.system(size: 10))
                                .foregroundStyle(DS.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Spacer(minLength: 4)

                            Text(String(format: "%.2fs", step.durationSeconds))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(DS.Colors.textTertiary)
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.leading, 17)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    private var statusColor: Color {
        switch record.status {
        case .running: return DS.Colors.accentText
        case .waitingForApproval: return DS.Colors.warning
        case .succeeded: return DS.Colors.success
        case .failed: return DS.Colors.destructiveText
        case .cancelled, .interrupted: return DS.Colors.textTertiary
        }
    }

    private var formattedElapsed: String {
        let seconds = record.elapsedSeconds
        return seconds < 60
            ? String(format: "%.1fs", seconds)
            : String(format: "%dm %ds", Int(seconds) / 60, Int(seconds) % 60)
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
    @State private var memoryReadout: String = "—"
    @State private var modelResidency: String = "checking…"

    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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

private struct DashboardEmptyState: View {
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
