//
//  HistoryTab.swift
//  leanring-buddy
//
//  The dashboard's History timeline: everything Wisp has done, searchable, with
//  a detail pane for the selected entry — the answer, the steps Wisp took (what
//  ran, how long, which failed), and what to do next: copy the answer, ask the
//  question again, or save it as a routine.
//
//  Reads `AgentTaskRegistry`, whose records are saved to disk
//  (`AgentTaskHistoryStore`), so the timeline survives relaunches. Replaces the
//  old flat Activity list; Conversation and Memory remain their own pages.
//

import AppKit
import SwiftUI

struct HistoryTab: View {
    @ObservedObject var taskRegistry: AgentTaskRegistry
    let companionManager: CompanionManager
    /// Navigates the dashboard (Save as routine opens the Routines page).
    let onSelectTab: (DashboardView.DashboardTab) -> Void

    @State private var searchText = ""
    @State private var selectedFilter: HistoryFilter = .all
    @State private var selectedRecordID: UUID?
    @State private var isAnswerJustCopied = false

    var body: some View {
        HStack(spacing: 0) {
            timelineColumn
                .frame(width: 300)
            Divider().background(DS.Colors.borderSubtle)
            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DS.Colors.background)
    }

    // MARK: - Filtering

    enum HistoryFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case answers = "Answers"
        case browser = "Browser"
        case tools = "Tools"
        case needsAttention = "Needs attention"

        var id: String { rawValue }

        func includes(_ record: AgentTaskRecord) -> Bool {
            switch self {
            case .all:
                return true
            case .answers:
                return record.status == .succeeded
                    && !(record.finalText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .browser:
                return record.steps.contains { $0.kindLabel.localizedCaseInsensitiveContains("browser") }
            case .tools:
                return record.steps.contains { step in
                    if case .tool = step.kind { return true }
                    return false
                }
            case .needsAttention:
                switch record.status {
                case .failed, .interrupted, .waitingForApproval: return true
                default: return false
                }
            }
        }
    }

    /// Records passing the filter and the search (title, answer and step text).
    private var visibleRecords: [AgentTaskRecord] {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return taskRegistry.records.filter { record in
            guard selectedFilter.includes(record) else { return false }
            guard !trimmedSearchText.isEmpty else { return true }
            if record.title.localizedCaseInsensitiveContains(trimmedSearchText) { return true }
            if (record.finalText ?? "").localizedCaseInsensitiveContains(trimmedSearchText) { return true }
            return record.steps.contains { $0.summary.localizedCaseInsensitiveContains(trimmedSearchText) }
        }
    }

    /// The visible records split by day ("Today", "Yesterday", "Monday 21 Sept"),
    /// newest day first; records within a day keep the registry's newest-first order.
    private var visibleRecordsByDay: [(dayTitle: String, records: [AgentTaskRecord])] {
        var dayGroups: [(dayTitle: String, records: [AgentTaskRecord])] = []
        for record in visibleRecords {
            let dayTitle = Self.dayTitle(for: record.startedAt)
            if dayGroups.last?.dayTitle == dayTitle {
                dayGroups[dayGroups.count - 1].records.append(record)
            } else {
                dayGroups.append((dayTitle: dayTitle, records: [record]))
            }
        }
        return dayGroups
    }

    private static func dayTitle(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    /// The selected record, or the newest visible one when nothing is selected
    /// (or the selection was filtered out), so the detail pane is never blank
    /// while there is something to show.
    private var selectedRecord: AgentTaskRecord? {
        if let selectedRecordID,
           let matchingRecord = visibleRecords.first(where: { $0.id == selectedRecordID }) {
            return matchingRecord
        }
        return visibleRecords.first
    }

    // MARK: - Timeline column

    private var timelineColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchField
            filterChips

            if visibleRecords.isEmpty {
                Spacer()
                Text(taskRegistry.records.isEmpty
                     ? "Nothing yet. Hold your talk shortcut and ask something — it shows up here."
                     : "Nothing matches.")
                    .font(WispFont.callout)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(visibleRecordsByDay, id: \.dayTitle) { dayGroup in
                            Text(dayGroup.dayTitle.uppercased())
                                .font(WispFont.overline)
                                .tracking(0.6)
                                .foregroundStyle(DS.Colors.textTertiary)
                                .padding(.horizontal, 8)
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                            ForEach(dayGroup.records) { record in
                                timelineRow(record)
                            }
                        }
                    }
                }
            }

            retentionFooter
        }
        .padding(12)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.Colors.textTertiary)
            TextField("Search questions, answers, steps", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .nativeTooltip("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    private var filterChips: some View {
        // Wraps onto a second line at this column width rather than scrolling
        // sideways, so every filter stays visible.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 5)], alignment: .leading, spacing: 5) {
            ForEach(HistoryFilter.allCases) { filter in
                let isSelected = selectedFilter == filter
                Button {
                    selectedFilter = filter
                } label: {
                    Text(filter.rawValue)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? DS.Colors.textOnAccent : DS.Colors.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(
                            Capsule(style: .continuous)
                                .fill(isSelected ? DS.Colors.accent : DS.Colors.surface2)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    private func timelineRow(_ record: AgentTaskRecord) -> some View {
        let isSelected = record.id == selectedRecord?.id
        return Button {
            selectedRecordID = record.id
            isAnswerJustCopied = false
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: Self.symbolName(for: record))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Self.statusColor(for: record.status))
                    .frame(width: 16)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Colors.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(timelineRowSubtitle(record))
                        .font(.system(size: 10.5))
                        .foregroundStyle(record.status.isTerminal && record.status != .succeeded
                                         ? Self.statusColor(for: record.status)
                                         : DS.Colors.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(isSelected ? DS.Colors.surface3 : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    /// "9:41 · 3 steps", "Running · background", "Failed · 9:20".
    private func timelineRowSubtitle(_ record: AgentTaskRecord) -> String {
        var subtitleParts: [String] = []
        if record.status != .succeeded {
            subtitleParts.append(record.status.displayName)
        }
        subtitleParts.append(record.startedAt.formatted(date: .omitted, time: .shortened))
        if record.kind == .background {
            subtitleParts.append("background")
        }
        let toolStepCount = record.steps.filter { step in
            if case .tool = step.kind { return true }
            return false
        }.count
        if toolStepCount > 0 {
            subtitleParts.append(toolStepCount == 1 ? "1 tool step" : "\(toolStepCount) tool steps")
        }
        return subtitleParts.joined(separator: " · ")
    }

    private var retentionFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock")
                .font(.system(size: 10))
            Text("Saved on this Mac for 30 days")
                .font(.system(size: 10.5))
            Spacer(minLength: 4)
            Button("Clear finished") {
                taskRegistry.clearCompleted()
                selectedRecordID = nil
            }
            .font(.system(size: 10.5, weight: .medium))
            .buttonStyle(.plain)
            .foregroundStyle(DS.Colors.accentText)
            .pointerCursor()
            .nativeTooltip("Remove every finished entry from History")
        }
        .foregroundStyle(DS.Colors.textTertiary)
        .padding(.horizontal, 4)
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let selectedRecord {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    detailHeader(selectedRecord)
                    detailActions(selectedRecord)
                    if let answerText = selectedRecord.finalText,
                       !answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        DashboardCard(title: answerCardTitle(for: selectedRecord)) {
                            Text(answerText)
                                .font(.system(size: 13))
                                .foregroundStyle(DS.Colors.textPrimary)
                                .lineSpacing(2)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if case .failed(let failureReason) = selectedRecord.status {
                        DashboardCard(title: "What went wrong") {
                            Text(failureReason)
                                .font(.system(size: 12))
                                .foregroundStyle(DS.Colors.destructiveText)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !selectedRecord.steps.isEmpty {
                        stepsCard(selectedRecord)
                    }
                }
                .padding(16)
            }
        } else {
            DashboardEmptyState(
                symbolName: "clock.arrow.circlepath",
                title: "No history yet",
                message: "Everything Wisp answers or does shows up here, saved on this Mac."
            )
        }
    }

    private func answerCardTitle(for record: AgentTaskRecord) -> String {
        record.title.hasPrefix(AgentTaskRecord.dictationTitlePrefix) ? "Typed" : "Answer"
    }

    private func detailHeader(_ record: AgentTaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(DS.Colors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Circle()
                    .fill(Self.statusColor(for: record.status))
                    .frame(width: 7, height: 7)
                Text(record.status.displayName)
                    .foregroundStyle(Self.statusColor(for: record.status))
                Text("·")
                Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(Self.formattedDuration(record.elapsedSeconds))
                if record.kind == .background {
                    Text("·")
                    Text("Background")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(DS.Colors.textSecondary)
        }
    }

    @ViewBuilder
    private func detailActions(_ record: AgentTaskRecord) -> some View {
        let answerText = (record.finalText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        HStack(spacing: 8) {
            if !record.status.isTerminal {
                Button {
                    if record.kind == .interactive {
                        companionManager.stopCurrentTask()
                    } else {
                        taskRegistry.cancelTask(record.id)
                    }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(WispGlassButtonStyle())
                .pointerCursor()
            }
            if !answerText.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(answerText, forType: .string)
                    isAnswerJustCopied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.6))
                        isAnswerJustCopied = false
                    }
                } label: {
                    Label(isAnswerJustCopied ? "Copied" : "Copy answer",
                          systemImage: isAnswerJustCopied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(WispGlassButtonStyle())
                .pointerCursor()
            }
            // Asking again and saving as a routine only make sense for the
            // user's own question — a routine or skill run's title is a label.
            if record.isUsersOwnQuestion && record.status.isTerminal {
                Button {
                    askAgainOnUsersWork(record.title)
                } label: {
                    Label("Ask again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(WispGlassButtonStyle())
                .pointerCursor()
                .nativeTooltip("Close the dashboard and ask this again about what's on screen now")

                Button {
                    saveAsRoutine(record)
                } label: {
                    Label("Save as routine", systemImage: "bolt")
                }
                .buttonStyle(WispGlassButtonStyle(prominence: .prominent))
                .pointerCursor()
                .nativeTooltip("Turn this question into a routine you can run in one click")
            }
        }
        .font(WispFont.caption)
    }

    private func stepsCard(_ record: AgentTaskRecord) -> some View {
        DashboardCard(title: "What Wisp did") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(record.steps) { step in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: step.isError ? "xmark" : "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(step.isError ? DS.Colors.destructiveText : DS.Colors.accentText)
                            .frame(width: 18, height: 18)
                            .background(
                                Circle().fill(step.isError
                                              ? DS.Colors.destructive.opacity(0.12)
                                              : DS.Colors.accentSubtle)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.summary)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(DS.Colors.textPrimary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if let stepDetail = step.detail, !stepDetail.isEmpty {
                                Text(stepDetail)
                                    .font(.system(size: 11))
                                    .foregroundStyle(DS.Colors.textSecondary)
                                    .lineLimit(4)
                                    .textSelection(.enabled)
                            }
                            Text("\(step.kindLabel) · \(Self.formattedDuration(step.durationSeconds))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(DS.Colors.textTertiary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    /// Closes the dashboard so the screenshot sees the user's work, then asks.
    private func askAgainOnUsersWork(_ question: String) {
        NSApp.keyWindow?.performClose(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            companionManager.askTypedQuestion(question)
        }
    }

    /// Creates a routine from the question and opens it in the Routines editor,
    /// where the user names it and picks a shortcut or apps.
    private func saveAsRoutine(_ record: AgentTaskRecord) {
        let savedRoutine = RoutineStore.shared.addRoutine(WispRoutine(
            name: Self.routineName(fromQuestion: record.title),
            instruction: record.title
        ))
        RoutineStore.shared.routineIDToOpenInEditor = savedRoutine.id
        onSelectTab(.routines)
    }

    /// A short routine name from a question: its first few words, capitalised,
    /// without a trailing question mark.
    static func routineName(fromQuestion question: String) -> String {
        let trimmedQuestion = question
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "?.!"))
        let maximumNameWordCount = 6
        let questionWords = trimmedQuestion.split(separator: " ")
        var shortenedName = questionWords.prefix(maximumNameWordCount).joined(separator: " ")
        if questionWords.count > maximumNameWordCount {
            shortenedName += "…"
        }
        guard let firstCharacter = shortenedName.first else { return "New routine" }
        return firstCharacter.uppercased() + shortenedName.dropFirst()
    }

    // MARK: - Formatting

    private static func symbolName(for record: AgentTaskRecord) -> String {
        if record.title.hasPrefix(AgentTaskRecord.routineRunTitlePrefix) { return "bolt" }
        if record.title.hasPrefix(AgentTaskRecord.skillRunTitlePrefix) { return "sparkles" }
        if record.title.hasPrefix(AgentTaskRecord.dictationTitlePrefix) { return "text.cursor" }
        if record.title.hasPrefix(AgentTaskRecord.buddyRunTitlePrefix) { return "cloud" }
        if record.steps.contains(where: { $0.kindLabel.localizedCaseInsensitiveContains("browser") }) { return "globe" }
        if record.kind == .background { return "clock.arrow.2.circlepath" }
        return "bubble.left"
    }

    private static func statusColor(for status: AgentTaskRecord.Status) -> Color {
        switch status {
        case .running: return DS.Colors.accentText
        case .waitingForApproval: return DS.Colors.warning
        case .succeeded: return DS.Colors.accentText
        case .failed: return DS.Colors.destructiveText
        case .cancelled, .interrupted: return DS.Colors.textTertiary
        }
    }

    private static func formattedDuration(_ seconds: TimeInterval) -> String {
        seconds < 60
            ? String(format: "%.1fs", seconds)
            : String(format: "%dm %ds", Int(seconds) / 60, Int(seconds) % 60)
    }
}
