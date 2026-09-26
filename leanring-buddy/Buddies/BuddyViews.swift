//
//  BuddyViews.swift
//  leanring-buddy
//
//  The buddies' pages in the notch chat (`NotchWorkspaceView`): a buddy's
//  thread (its job, then each run with a status chip, time taken and
//  collapsible progress), the new-buddy form, and the schedule editor both use.
//  All drawn on the notch's dark surface.
//

import SwiftUI

// MARK: - Schedule editor

/// "Repeat: Never / Every day / Every week", then the time (and weekday).
struct BuddyScheduleEditor: View {
    @Binding var schedule: BuddySchedule

    private enum RepeatKind: String, CaseIterable, Identifiable {
        case never = "Never"
        case daily = "Every day"
        case weekly = "Every week"
        var id: String { rawValue }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("Repeat")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize()
            Picker("Repeat", selection: repeatKindBinding) {
                ForEach(RepeatKind.allCases) { repeatKind in
                    Text(repeatKind.rawValue).tag(repeatKind)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .pointerCursor()

            if case .weekly = schedule {
                Picker("Day", selection: weekdayBinding) {
                    ForEach(1...7, id: \.self) { weekday in
                        Text(Calendar.current.weekdaySymbols[weekday - 1]).tag(weekday)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .pointerCursor()
            }

            if schedule.isRepeating {
                DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .fixedSize()
            }
        }
    }

    private var repeatKindBinding: Binding<RepeatKind> {
        Binding(
            get: {
                switch schedule {
                case .once: return .never
                case .daily: return .daily
                case .weekly: return .weekly
                }
            },
            set: { newRepeatKind in
                let (hour, minute) = currentTime
                switch newRepeatKind {
                case .never: schedule = .once
                case .daily: schedule = .daily(hour: hour, minute: minute)
                case .weekly: schedule = .weekly(weekday: currentWeekday, hour: hour, minute: minute)
                }
            }
        )
    }

    private var weekdayBinding: Binding<Int> {
        Binding(
            get: { currentWeekday },
            set: { newWeekday in
                let (hour, minute) = currentTime
                schedule = .weekly(weekday: newWeekday, hour: hour, minute: minute)
            }
        )
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                let (hour, minute) = currentTime
                return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
            },
            set: { newTime in
                let timeComponents = Calendar.current.dateComponents([.hour, .minute], from: newTime)
                let hour = timeComponents.hour ?? 9
                let minute = timeComponents.minute ?? 0
                switch schedule {
                case .once: break
                case .daily: schedule = .daily(hour: hour, minute: minute)
                case .weekly(let weekday, _, _): schedule = .weekly(weekday: weekday, hour: hour, minute: minute)
                }
            }
        )
    }

    /// The schedule's time, or 9:00 when it has none yet.
    private var currentTime: (hour: Int, minute: Int) {
        switch schedule {
        case .once: return (9, 0)
        case .daily(let hour, let minute): return (hour, minute)
        case .weekly(_, let hour, let minute): return (hour, minute)
        }
    }

    /// The schedule's weekday, or Monday when it has none yet.
    private var currentWeekday: Int {
        if case .weekly(let weekday, _, _) = schedule { return weekday }
        return 2
    }
}

// MARK: - A buddy's thread

struct BuddyDetailView: View {
    let buddyID: UUID
    /// Space to leave at the top so nothing sits behind the physical notch.
    let topInset: CGFloat

    @ObservedObject private var buddyStore = BuddyStore.shared
    @ObservedObject private var taskRegistry = AgentTaskRegistry.shared

    @State private var expandedRunIDs: Set<UUID> = []
    @State private var isRenaming = false
    @State private var editedName = ""
    @State private var isConfirmingDeletion = false
    @State private var didFailToStartRun = false
    @FocusState private var isNameFieldFocused: Bool

    private let threadBottomAnchorID = "buddy-thread-bottom"

    var body: some View {
        if let buddy = buddyStore.buddy(withID: buddyID) {
            content(for: buddy)
        } else {
            Color.clear
        }
    }

    private func content(for buddy: WispBuddy) -> some View {
        let runRecords = buddyStore.runRecords(of: buddy, in: taskRegistry)
        let isRunning = buddyStore.isRunning(buddy, in: taskRegistry)
        return VStack(spacing: 0) {
            header(for: buddy, isRunning: isRunning)
                .padding(.top, topInset + 4)

            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        greetingBubble(for: buddy)
                        jobCard(for: buddy)
                        if runRecords.isEmpty {
                            Text(buddy.schedule.isRepeating
                                 ? "Hasn't run yet — its first run is \(nextRunPhrase(for: buddy))."
                                 : "Hasn't run yet.")
                                .font(.system(size: 11.5))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        ForEach(runRecords) { runRecord in
                            runView(runRecord)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(threadBottomAnchorID)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear {
                    scrollProxy.scrollTo(threadBottomAnchorID, anchor: .bottom)
                }
                .onChange(of: runRecords.last.map { "\($0.id)|\($0.status.displayName)|\($0.steps.count)" } ?? "") { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        scrollProxy.scrollTo(threadBottomAnchorID, anchor: .bottom)
                    }
                }
            }

            controlBar(for: buddy, isRunning: isRunning)
        }
        .onChange(of: buddyID) { _, _ in
            isRenaming = false
            isConfirmingDeletion = false
            didFailToStartRun = false
            expandedRunIDs = []
        }
    }

    // MARK: Header

    private func header(for buddy: WispBuddy, isRunning: Bool) -> some View {
        VStack(spacing: 5) {
            BuddyAvatar(colorIndex: buddy.colorIndex, size: 34, isWorking: isRunning)
            if isRenaming {
                TextField("Name", text: $editedName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                    .focused($isNameFieldFocused)
                    .frame(width: 180)
                    .padding(.vertical, 4)
                    .background(Capsule(style: .continuous).fill(Color.white.opacity(0.1)))
                    .onSubmit {
                        buddyStore.rename(buddyWithID: buddy.id, to: editedName)
                        isRenaming = false
                    }
                    .onAppear { isNameFieldFocused = true }
            } else {
                Button {
                    editedName = buddy.name
                    isRenaming = true
                } label: {
                    HStack(spacing: 4) {
                        Text(buddy.name)
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "pencil")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule(style: .continuous).fill(Color.white.opacity(0.08)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .nativeTooltip("Rename this buddy")
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: Thread

    private func greetingBubble(for buddy: WispBuddy) -> some View {
        Text("Hi, I'm \(buddy.name). This is my one job, and I'll keep at it for you.")
            .font(.system(size: 12.5))
            .foregroundColor(DS.Colors.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
    }

    private func jobCard(for buddy: WispBuddy) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 10, weight: .medium))
                Text("Its job")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundColor(DS.Colors.textTertiary)

            VStack(alignment: .leading, spacing: 5) {
                Text(buddy.instruction)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(scheduleLine(for: buddy))
                    .font(.system(size: 11.5))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex).opacity(0.16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex).opacity(0.35), lineWidth: 1)
            )
        }
    }

    private func scheduleLine(for buddy: WispBuddy) -> String {
        guard buddy.schedule.isRepeating else { return buddy.schedule.summary() }
        return "\(buddy.schedule.summary()) · next \(nextRunPhrase(for: buddy)) · while Wisp is running"
    }

    private func nextRunPhrase(for buddy: WispBuddy) -> String {
        guard let nextScheduledRunAt = buddy.nextScheduledRunAt else { return "when you ask" }
        let calendar = Calendar.current
        let timeText = nextScheduledRunAt.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(nextScheduledRunAt) { return "today at \(timeText)" }
        if calendar.isDateInTomorrow(nextScheduledRunAt) { return "tomorrow at \(timeText)" }
        return nextScheduledRunAt.formatted(.dateTime.weekday(.wide)) + " at \(timeText)"
    }

    private func runView(_ runRecord: AgentTaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if !runRecord.steps.isEmpty {
                progressDisclosure(for: runRecord)
            }
            runOutcome(runRecord)
            HStack(spacing: 8) {
                statusChip(for: runRecord.status)
                Text(runTimingText(runRecord))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
    }

    private func progressDisclosure(for runRecord: AgentTaskRecord) -> some View {
        let isExpanded = expandedRunIDs.contains(runRecord.id)
        return VStack(alignment: .leading, spacing: 5) {
            Button {
                withAnimation(WispMotion.smooth) {
                    if isExpanded {
                        expandedRunIDs.remove(runRecord.id)
                    } else {
                        expandedRunIDs.insert(runRecord.id)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(runRecord.steps.count == 1 ? "1 progress message" : "\(runRecord.steps.count) progress messages")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundColor(DS.Colors.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(runRecord.steps) { step in
                        HStack(alignment: .top, spacing: 6) {
                            Circle()
                                .fill(step.isError ? DS.Colors.destructive : DS.Colors.textTertiary)
                                .frame(width: 4, height: 4)
                                .padding(.top, 5)
                            Text(step.summary)
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 14)
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private func runOutcome(_ runRecord: AgentTaskRecord) -> some View {
        let answerText = AnswerDisplayText.cleaned(runRecord.finalText ?? "")
        switch runRecord.status {
        case .running, .waitingForApproval:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(runRecord.status == .waitingForApproval
                     ? "Waiting for your ok"
                     : (runRecord.steps.last?.summary ?? "Working on it…"))
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(2)
            }
        case .succeeded:
            Text(answerText.isEmpty ? "Done." : answerText)
                .font(.system(size: 12.5))
                .foregroundColor(DS.Colors.textPrimary)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                )
        case .failed(let failureReason):
            Text(answerText.isEmpty ? failureReason : answerText)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.destructiveText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .cancelled, .interrupted:
            EmptyView()
        }
    }

    /// The monospaced, outlined status tag, as HeyClicky's "INTERRUPTED BY USER".
    private func statusChip(for status: AgentTaskRecord.Status) -> some View {
        let (chipText, chipColor): (String, Color) = {
            switch status {
            case .running: return ("WORKING", WispColor.Brand.lavender)
            case .waitingForApproval: return ("NEEDS YOUR OK", DS.Colors.warning)
            case .succeeded: return ("DONE", DS.Colors.success)
            case .failed: return ("FAILED", DS.Colors.destructive)
            case .cancelled: return ("STOPPED BY YOU", DS.Colors.textTertiary)
            case .interrupted: return ("INTERRUPTED", DS.Colors.textTertiary)
            }
        }()
        return Text(chipText)
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .tracking(0.8)
            .foregroundColor(chipColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(chipColor.opacity(0.5), lineWidth: 1)
            )
    }

    /// "5m 10s · 10:39 PM" (or "Yesterday 10:39 PM").
    private func runTimingText(_ runRecord: AgentTaskRecord) -> String {
        let totalSeconds = Int(runRecord.elapsedSeconds.rounded())
        let durationText = totalSeconds >= 60
            ? "\(totalSeconds / 60)m \(totalSeconds % 60)s"
            : "\(totalSeconds)s"
        let calendar = Calendar.current
        let startedText: String
        if calendar.isDateInToday(runRecord.startedAt) {
            startedText = runRecord.startedAt.formatted(date: .omitted, time: .shortened)
        } else {
            startedText = runRecord.startedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
        return "\(durationText) · \(startedText)"
    }

    // MARK: Controls

    private func controlBar(for buddy: WispBuddy, isRunning: Bool) -> some View {
        HStack(spacing: 10) {
            if isRunning {
                Button {
                    buddyStore.stopRun(ofBuddyWithID: buddy.id)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .wispGlassButtonStyle(prominence: .subtle, cornerRadius: 999)
            } else {
                Button {
                    didFailToStartRun = !buddyStore.runNow(buddyWithID: buddy.id)
                } label: {
                    Label("Run now", systemImage: "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .wispGlassButtonStyle(prominence: .prominent, cornerRadius: 999)
                .nativeTooltip(didFailToStartRun
                    ? "Two background tasks are already running — try again when one finishes"
                    : "Do its job now")
            }

            BuddyScheduleEditor(schedule: Binding(
                get: { buddy.schedule },
                set: { newSchedule in buddyStore.updateSchedule(ofBuddyWithID: buddy.id, to: newSchedule) }
            ))

            Spacer(minLength: 0)

            if didFailToStartRun {
                Text("Busy — try again soon")
                    .font(.system(size: 10.5))
                    .foregroundColor(DS.Colors.warningText)
            }

            Button {
                if isConfirmingDeletion {
                    buddyStore.deleteBuddy(withID: buddy.id)
                } else {
                    isConfirmingDeletion = true
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                    if isConfirmingDeletion {
                        Text("Delete?")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                }
                .foregroundColor(isConfirmingDeletion ? DS.Colors.destructiveText : DS.Colors.textTertiary)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(Capsule(style: .continuous).fill(Color.white.opacity(isConfirmingDeletion ? 0.1 : 0.05)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .nativeTooltip(isConfirmingDeletion ? "Click again to delete this buddy (its runs stay in History)" : "Delete this buddy")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }
}

// MARK: - New buddy

struct NewBuddyForm: View {
    let topInset: CGFloat
    let onCreated: (UUID) -> Void
    let onCancel: () -> Void

    @ObservedObject private var buddyStore = BuddyStore.shared

    @State private var instructionText = ""
    @State private var schedule: BuddySchedule = .once
    /// Once the user picks a schedule themselves, stop guessing it from the text.
    @State private var hasChosenScheduleByHand = false
    @FocusState private var isInstructionFieldFocused: Bool

    private var trimmedInstruction: String {
        instructionText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var previewName: String {
        guard !trimmedInstruction.isEmpty else { return "New buddy" }
        return BuddyNameGenerator.name(forInstruction: trimmedInstruction, existingNames: buddyStore.buddies.map(\.name))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                BuddyAvatar(colorIndex: buddyStore.nextColorIndex(), size: 46, isWorking: false)
                VStack(alignment: .leading, spacing: 3) {
                    Text(previewName)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(DS.Colors.textPrimary)
                        .animation(.easeOut(duration: 0.15), value: previewName)
                    Text("A buddy takes one job and keeps at it — once, or on a schedule. Its runs happen in the background.")
                        .font(.system(size: 11.5))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            TextField(
                "What should it do? e.g. Every morning, summarize what's new on Hacker News",
                text: $instructionText,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundColor(DS.Colors.textPrimary)
            .lineLimit(3...6)
            .focused($isInstructionFieldFocused)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isInstructionFieldFocused ? WispColor.Brand.sage.opacity(0.7) : DS.Colors.borderSubtle, lineWidth: 1)
            )
            .onChange(of: instructionText) { _, newInstructionText in
                guard !hasChosenScheduleByHand else { return }
                schedule = BuddySchedule.inferred(fromInstruction: newInstructionText)
            }

            BuddyScheduleEditor(schedule: Binding(
                get: { schedule },
                set: { newSchedule in
                    hasChosenScheduleByHand = true
                    schedule = newSchedule
                }
            ))

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .font(.system(size: 12, weight: .medium))
                    .wispGlassButtonStyle(prominence: .subtle, cornerRadius: 999)
                Button {
                    let newBuddy = buddyStore.createBuddy(
                        instruction: trimmedInstruction,
                        schedule: schedule,
                        runImmediately: !schedule.isRepeating
                    )
                    onCreated(newBuddy.id)
                } label: {
                    Label(schedule.isRepeating ? "Create" : "Create & run", systemImage: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                }
                .wispGlassButtonStyle(prominence: .prominent, cornerRadius: 999)
                .disabled(trimmedInstruction.isEmpty)
                .opacity(trimmedInstruction.isEmpty ? 0.5 : 1)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, topInset + 16)
        .padding(.bottom, 16)
        .onAppear {
            isInstructionFieldFocused = true
        }
    }
}
