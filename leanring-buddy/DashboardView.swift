//
//  DashboardView.swift
//  leanring-buddy
//
//  The dashboard's SwiftUI content: activity history, conversation
//  transcript, and per-turn performance.
//
//  The menu bar panel is deliberately small and momentary — it answers
//  "is Clicky working right now?". This window answers the questions the
//  panel has no room for: what did it just do, how long did each stage
//  take, and why is it slow at the moment. That last question needs real
//  numbers, because on a machine running the models locally the honest
//  answer is usually "a screenshot cost six seconds" or "memory is full",
//  and neither is guessable from the outside.
//

import Combine
import SwiftUI

struct DashboardView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var taskRegistry: AgentTaskRegistry
    @ObservedObject var metricsRecorder: PerfMetricsRecorder

    @State private var selectedTab: DashboardTab = .activity

    enum DashboardTab: String, CaseIterable, Identifiable {
        case activity = "Activity"
        case conversation = "Conversation"
        case performance = "Model & Performance"

        var id: String { rawValue }

        var symbolName: String {
            switch self {
            case .activity: return "list.bullet.rectangle"
            case .conversation: return "bubble.left.and.bubble.right"
            case .performance: return "speedometer"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().background(DS.Colors.borderSubtle)

            Group {
                switch selectedTab {
                case .activity: ActivityTab(taskRegistry: taskRegistry)
                case .conversation: ConversationTab(taskRegistry: taskRegistry)
                case .performance: PerformanceTab(metricsRecorder: metricsRecorder)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DS.Colors.background)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(DashboardTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.symbolName)
                        Text(tab.rawValue)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selectedTab == tab ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(selectedTab == tab ? DS.Colors.surface3 : .clear)
                    )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            Spacer()

            if taskRegistry.runningRecords.isEmpty == false {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("\(taskRegistry.runningRecords.count) running")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                .padding(.trailing, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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

private struct DashboardCard<Content: View>: View {
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
