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

// MARK: - Model editor

/// "Model: Same as Wisp / Local / Claude …". A cloud choice says plainly what
/// leaves this Mac, and what doesn't.
struct BuddyModelEditor: View {
    @Binding var modelChoice: BuddyModelChoice?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Model")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize()
                Picker("Model", selection: $modelChoice) {
                    Text("Same as Wisp").tag(BuddyModelChoice?.none)
                    Divider()
                    ForEach(BuddyModelChoice.allChoices) { choice in
                        Text(menuLabel(for: choice)).tag(BuddyModelChoice?.some(choice))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .pointerCursor()
            }
            if let modelChoice, modelChoice.sendsDataOffThisMachine {
                Text(ProviderKeychainStore.hasAPIKey(for: modelChoice.providerKind)
                     ? "Its job, thread and notes go to \(modelChoice.providerKind.displayName). Your brain and memory stay here."
                     : "Add a \(modelChoice.providerKind.displayName) key in Settings → Model, or this buddy can't run.")
                    .font(.system(size: 10.5))
                    .foregroundColor(ProviderKeychainStore.hasAPIKey(for: modelChoice.providerKind)
                                     ? DS.Colors.textTertiary : DS.Colors.warningText)
                    // A minimum width, or the window's minimum-size pass wraps this
                    // one word per line and the page grows taller than the window.
                    .frame(minWidth: 280, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func menuLabel(for choice: BuddyModelChoice) -> String {
        choice.sendsDataOffThisMachine ? "\(choice.displayName) · cloud" : choice.displayName
    }
}

// MARK: - Tool access editor

/// "Tools · All tools ▸": what this buddy may use, as switches per group.
/// Collapsed it is one line; a buddy with no limit shows "All tools".
struct BuddyToolAccessEditor: View {
    @Binding var toolAccess: BuddyToolAccess?
    /// Whether the buddy's model runs off this Mac, which takes the brain and
    /// the user's memory off the table.
    let modelSendsDataOffThisMachine: Bool

    @ObservedObject private var toolRegistry = AgentToolRegistry.shared
    @ObservedObject private var buddyStore = BuddyStore.shared
    @State private var isExpanded: Bool

    init(toolAccess: Binding<BuddyToolAccess?>, modelSendsDataOffThisMachine: Bool, startsExpanded: Bool = false) {
        _toolAccess = toolAccess
        self.modelSendsDataOffThisMachine = modelSendsDataOffThisMachine
        _isExpanded = State(initialValue: startsExpanded)
    }

    /// Only groups that have a tool right now, so no switch does nothing.
    private var availableGroups: [BuddyToolGroup] {
        let registeredToolNames = toolRegistry.toolNames
        return BuddyToolGroup.allCases.filter { group in
            // Asking other buddies is a run-only tool, not in the registry: it
            // exists whenever there is more than this one buddy.
            if group == .delegation { return buddyStore.buddies.count > 1 }
            return registeredToolNames.contains { BuddyToolGroup.group(forToolNamed: $0) == group }
        }
    }

    private var availableServerNames: [String] {
        BuddyToolAccessPolicy.serverNames(inToolNames: toolRegistry.toolNames)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(WispMotion.smooth) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text("Tools · \(BuddyToolAccessPolicy.summary(of: toolAccess))")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundColor(DS.Colors.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .nativeTooltip("Choose what this buddy is allowed to use")

            if isExpanded {
                VStack(alignment: .leading, spacing: 7) {
                    Toggle(isOn: Binding(
                        get: { toolAccess == nil },
                        set: { allowsEveryTool in toolAccess = allowsEveryTool ? nil : BuddyToolAccess.nothing }
                    )) {
                        Text("Every tool")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)

                    if let limitedToolAccess = toolAccess {
                        ForEach(availableGroups) { group in
                            groupRow(
                                title: group.title,
                                summary: group.summary,
                                symbolName: group.symbolName,
                                isAllowed: limitedToolAccess.allows(group),
                                isUnavailable: group.isPrivateKnowledge && modelSendsDataOffThisMachine,
                                groupID: group.rawValue
                            )
                        }
                        ForEach(availableServerNames, id: \.self) { serverName in
                            groupRow(
                                title: serverName,
                                summary: "Connected app",
                                symbolName: "puzzlepiece.extension",
                                isAllowed: limitedToolAccess.allowsServer(named: serverName),
                                isUnavailable: false,
                                groupID: BuddyToolAccessPolicy.groupID(forServerNamed: serverName)
                            )
                        }
                    }
                }
                .padding(.leading, 14)
                .transition(.opacity)
            }
        }
    }

    private func groupRow(
        title: String, summary: String, symbolName: String,
        isAllowed: Bool, isUnavailable: Bool, groupID: String
    ) -> some View {
        Toggle(isOn: Binding(
            get: { isAllowed && !isUnavailable },
            set: { newValue in toolAccess = toolAccess?.setting(groupID: groupID, isAllowed: newValue) }
        )) {
            HStack(spacing: 6) {
                Image(systemName: symbolName)
                    .font(.system(size: 10.5))
                    .frame(width: 14)
                    .foregroundColor(DS.Colors.textTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(isUnavailable ? "Not available to cloud models" : summary)
                        .font(.system(size: 10.5))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .disabled(isUnavailable)
        .opacity(isUnavailable ? 0.55 : 1)
    }
}

extension BuddyModelChoice {
    /// Whether a buddy with this choice (nil = follows Wisp) runs off this Mac.
    static func sendsDataOffThisMachine(_ choice: BuddyModelChoice?) -> Bool {
        choice?.sendsDataOffThisMachine ?? BuddyChatProviderSelection.current.sendsScreenshotsOffThisMachine
    }
}

// MARK: - A buddy's thread

struct BuddyDetailView: View {
    let buddyID: UUID
    /// Space to leave at the top so nothing sits behind the physical notch.
    let topInset: CGFloat

    @ObservedObject private var buddyStore = BuddyStore.shared
    @ObservedObject private var taskRegistry = AgentTaskRegistry.shared
    @ObservedObject private var threadStore = BuddyThreadStore.shared
    @ObservedObject private var memoryStore = BuddyMemoryStore.shared

    @State private var expandedRunIDs: Set<UUID> = []
    @State private var draftMessageText = ""
    @State private var isMemoryExpanded = false
    @FocusState private var isMessageFieldFocused: Bool
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
                        memorySection(for: buddy)
                        BuddyToolAccessEditor(
                            toolAccess: Binding(
                                get: { buddy.toolAccess },
                                set: { newToolAccess in buddyStore.updateToolAccess(ofBuddyWithID: buddy.id, to: newToolAccess) }
                            ),
                            modelSendsDataOffThisMachine: BuddyModelChoice.sendsDataOffThisMachine(buddy.modelChoice)
                        )
                        if runRecords.isEmpty {
                            Text(buddy.schedule.isRepeating
                                 ? "Hasn't run yet — its first run is \(nextRunPhrase(for: buddy))."
                                 : "Hasn't run yet.")
                                .font(.system(size: 11.5))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        ForEach(runRecords) { runRecord in
                            runView(runRecord, buddyID: buddy.id)
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

            messageField(for: buddy, isRunning: isRunning)
            controlBar(for: buddy, isRunning: isRunning)
        }
        .onChange(of: buddyID) { _, _ in
            isRenaming = false
            isConfirmingDeletion = false
            didFailToStartRun = false
            expandedRunIDs = []
            draftMessageText = ""
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
                    .background(Capsule(style: .continuous).fill(WispColor.surface2))
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
                    .background(Capsule(style: .continuous).fill(WispColor.surface2))
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
                    .fill(WispColor.surface2)
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

    /// What the buddy has chosen to remember. Hidden until it has saved
    /// something; each note can be forgotten.
    @ViewBuilder
    private func memorySection(for buddy: WispBuddy) -> some View {
        let savedNotes = memoryStore.facts(ofBuddyWithID: buddy.id)
        if !savedNotes.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Button {
                    withAnimation(WispMotion.smooth) { isMemoryExpanded.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(isMemoryExpanded ? 90 : 0))
                        Text(savedNotes.count == 1 ? "Remembers 1 thing" : "Remembers \(savedNotes.count) things")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()

                if isMemoryExpanded {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(savedNotes, id: \.self) { savedNote in
                            HStack(alignment: .top, spacing: 6) {
                                Text(savedNote)
                                    .font(.system(size: 11.5))
                                    .foregroundColor(DS.Colors.textSecondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 4)
                                Button {
                                    memoryStore.forgetExactFact(savedNote, forBuddyWithID: buddy.id)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundColor(DS.Colors.textTertiary)
                                }
                                .buttonStyle(.plain)
                                .pointerCursor()
                                .nativeTooltip("Forget this")
                            }
                        }
                    }
                    .padding(.leading, 14)
                    .transition(.opacity)
                }
            }
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

    private func runView(_ runRecord: AgentTaskRecord, buddyID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            // A run of the buddy's own job needs no bubble (the job card says it);
            // one the user started with a message shows what they said.
            if let messageExchange = threadStore.exchange(forTaskID: runRecord.id, ofBuddyWithID: buddyID),
               messageExchange.origin != .job {
                userMessageBubble(
                    messageExchange.userText,
                    senderName: messageExchange.origin == .delegated ? messageExchange.requesterName : nil
                )
            }
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

    /// What was asked: the user's message, or — with `senderName` — another
    /// buddy's request, labelled so it isn't mistaken for the user's.
    private func userMessageBubble(_ messageText: String, senderName: String? = nil) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            if let senderName {
                Text("From \(senderName)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Text(messageText)
                .font(.system(size: 12.5))
                .foregroundColor(DS.Colors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(senderName == nil ? WispColor.Brand.sage.opacity(0.22) : WispColor.surface3)
                )
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
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
                        .fill(WispColor.surface2)
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

    /// Reply to the buddy. It answers in the same thread, remembering the
    /// earlier exchanges; disabled while it is mid-run.
    private func messageField(for buddy: WispBuddy, isRunning: Bool) -> some View {
        let trimmedDraft = draftMessageText.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(spacing: 8) {
            TextField("Message \(buddy.name)", text: $draftMessageText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundColor(DS.Colors.textPrimary)
                .focused($isMessageFieldFocused)
                .disabled(isRunning)
                .onSubmit { sendDraftMessage(to: buddy) }
            Button {
                sendDraftMessage(to: buddy)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(trimmedDraft.isEmpty || isRunning ? DS.Colors.textTertiary : WispColor.Brand.sage)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(trimmedDraft.isEmpty || isRunning)
            .nativeTooltip("Send")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule(style: .continuous).fill(WispColor.surface2))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(isMessageFieldFocused ? WispColor.Brand.sage.opacity(0.7) : DS.Colors.borderSubtle, lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private func sendDraftMessage(to buddy: WispBuddy) {
        let didStart = buddyStore.sendMessage(draftMessageText, toBuddyWithID: buddy.id)
        didFailToStartRun = !didStart && !draftMessageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if didStart { draftMessageText = "" }
    }

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
                    ? "This buddy's model is busy with other runs — try again when one finishes"
                    : "Do its job now")
            }

            VStack(alignment: .leading, spacing: 6) {
                BuddyScheduleEditor(schedule: Binding(
                    get: { buddy.schedule },
                    set: { newSchedule in buddyStore.updateSchedule(ofBuddyWithID: buddy.id, to: newSchedule) }
                ))
                BuddyModelEditor(modelChoice: Binding(
                    get: { buddy.modelChoice },
                    set: { newModelChoice in buddyStore.updateModelChoice(ofBuddyWithID: buddy.id, to: newModelChoice) }
                ))
            }

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
                .background(Capsule(style: .continuous).fill(isConfirmingDeletion ? WispColor.surface3 : WispColor.surface2))
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
    @State private var modelChoice: BuddyModelChoice?
    @State private var toolAccess: BuddyToolAccess?
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
                        // Same reason as the model note: without a minimum width the
                        // window's minimum-size pass makes this text enormously tall.
                        .frame(minWidth: 280, alignment: .leading)
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
                    .fill(WispColor.surface2)
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

            BuddyModelEditor(modelChoice: $modelChoice)
            BuddyToolAccessEditor(
                toolAccess: $toolAccess,
                modelSendsDataOffThisMachine: BuddyModelChoice.sendsDataOffThisMachine(modelChoice)
            )

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
                        modelChoice: modelChoice,
                        toolAccess: toolAccess,
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
