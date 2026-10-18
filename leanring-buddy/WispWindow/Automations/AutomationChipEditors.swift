//
//  AutomationChipEditors.swift
//  leanring-buddy
//
//  The popover editors behind the draft card's chips: when it runs, what it reads, where the
//  result goes, which buddy owns it and when to tell the user. Each edits a binding and
//  nothing else; the card decides what counts as "resolved".
//

import AppKit
import SwiftUI

// MARK: - Trigger

struct AutomationTriggerEditor: View {
    @Binding var trigger: AutomationTrigger
    /// Canvas sync and the daily checklist keep their own timers in JobsEngine, so editing a
    /// time here would change nothing. Say so instead of offering a control that lies.
    let isTimingManagedElsewhere: Bool

    var body: some View {
        if isTimingManagedElsewhere {
            Text("This one keeps its own timing. Change it on the Canvas page.")
                .font(WispFont.callout)
                .foregroundStyle(WispColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                WispSegmented(
                    options: AutomationTriggerKind.allCases,
                    title: { $0.title },
                    selection: triggerKindBinding
                )
                switch trigger {
                case .schedule:
                    AutomationScheduleEditor(schedule: scheduleBinding)
                case .event:
                    AutomationEventEditor(event: eventBinding)
                case .manual:
                    Text("Runs only when you press Run now.")
                        .font(WispFont.callout)
                        .foregroundStyle(WispColor.textSecondary)
                }
            }
        }
    }

    private var triggerKindBinding: Binding<AutomationTriggerKind> {
        Binding(
            get: { AutomationTriggerKind(trigger: trigger) },
            set: { newKind in
                guard newKind != AutomationTriggerKind(trigger: trigger) else { return }
                switch newKind {
                case .schedule:
                    trigger = .schedule(AutomationSchedule(recurrence: .daily, hour: 9, minute: 0))
                case .event:
                    trigger = .event(.meetingStarting(minutesBefore: 10))
                case .manual:
                    trigger = .manual
                }
            }
        )
    }

    private var scheduleBinding: Binding<AutomationSchedule> {
        Binding(
            get: {
                if case .schedule(let schedule) = trigger { return schedule }
                return AutomationSchedule(recurrence: .daily, hour: 9, minute: 0)
            },
            set: { trigger = .schedule($0) }
        )
    }

    private var eventBinding: Binding<AutomationEvent> {
        Binding(
            get: {
                if case .event(let event) = trigger { return event }
                return .newCanvasItem
            },
            set: { trigger = .event($0) }
        )
    }
}

private struct AutomationScheduleEditor: View {
    @Binding var schedule: AutomationSchedule

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Repeats", selection: recurrenceKindBinding) {
                ForEach(AutomationRecurrenceKind.allCases, id: \.self) { recurrenceKind in
                    Text(recurrenceKind.title).tag(recurrenceKind)
                }
            }
            .pickerStyle(.menu)
            .pointerCursor()

            switch schedule.recurrence {
            case .once(let runDate):
                DatePicker(
                    "When",
                    selection: onceDateBinding(currentDate: runDate),
                    displayedComponents: [.date, .hourAndMinute]
                )
            case .weekly(let weekday):
                Picker("On", selection: weekdayBinding(currentWeekday: weekday)) {
                    ForEach(1...7, id: \.self) { weekdayNumber in
                        Text(AutomationTimeText.weekdayName(weekdayNumber)).tag(weekdayNumber)
                    }
                }
                .pickerStyle(.menu)
                .pointerCursor()
                timePicker
            case .monthly(let dayOfMonth):
                Stepper(
                    "On the \(AutomationTimeText.ordinal(dayOfMonth))",
                    value: dayOfMonthBinding(currentDay: dayOfMonth),
                    in: 1...31
                )
                timePicker
            case .daily, .weekdays:
                timePicker
            }

            Text(schedule.summary(calendar: .current))
                .font(WispFont.caption)
                .foregroundStyle(WispColor.textTertiary)
        }
    }

    private var timePicker: some View {
        DatePicker("At", selection: timeOfDayBinding, displayedComponents: .hourAndMinute)
    }

    private var recurrenceKindBinding: Binding<AutomationRecurrenceKind> {
        Binding(
            get: { AutomationRecurrenceKind(recurrence: schedule.recurrence) },
            set: { newKind in
                guard newKind != AutomationRecurrenceKind(recurrence: schedule.recurrence) else { return }
                let newRecurrence = newKind.defaultRecurrence(now: Date(), calendar: .current)
                schedule.recurrence = newRecurrence
                if case .once(let runDate) = newRecurrence {
                    let components = Calendar.current.dateComponents([.hour, .minute], from: runDate)
                    schedule.hour = components.hour ?? schedule.hour
                    schedule.minute = components.minute ?? schedule.minute
                }
            }
        )
    }

    /// The schedule stores hour and minute as numbers; a date picker wants a Date, so today
    /// at that time stands in for it.
    private var timeOfDayBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: Date()) ?? Date()
            },
            set: { newDate in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                schedule.hour = components.hour ?? schedule.hour
                schedule.minute = components.minute ?? schedule.minute
            }
        )
    }

    private func onceDateBinding(currentDate: Date) -> Binding<Date> {
        Binding(
            get: { currentDate },
            set: { newDate in
                schedule.recurrence = .once(newDate)
                let components = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                schedule.hour = components.hour ?? schedule.hour
                schedule.minute = components.minute ?? schedule.minute
            }
        )
    }

    private func weekdayBinding(currentWeekday: Int) -> Binding<Int> {
        Binding(get: { currentWeekday }, set: { schedule.recurrence = .weekly(weekday: $0) })
    }

    private func dayOfMonthBinding(currentDay: Int) -> Binding<Int> {
        Binding(get: { currentDay }, set: { schedule.recurrence = .monthly(dayOfMonth: $0) })
    }
}

private struct AutomationEventEditor: View {
    @Binding var event: AutomationEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("When", selection: eventKindBinding) {
                ForEach(AutomationEventKind.allCases, id: \.self) { eventKind in
                    Text(eventKind.title).tag(eventKind)
                }
            }
            .pickerStyle(.menu)
            .pointerCursor()

            switch event {
            case .newCanvasItem:
                Text("Runs after a Canvas sync finds something new.")
                    .font(WispFont.callout)
                    .foregroundStyle(WispColor.textSecondary)
            case .meetingStarting(let minutesBefore):
                Stepper(
                    minutesBefore == 1 ? "1 minute before" : "\(minutesBefore) minutes before",
                    value: minutesBinding(currentMinutes: minutesBefore),
                    in: AutomationEvent.meetingMinutesRange
                )
            case .screenTextAppears(let watchedText):
                TextField("Text to wait for", text: watchedTextBinding(currentText: watchedText))
                    .textFieldStyle(.roundedBorder)
                Text("Wisp reads your screen on this Mac to look for it.")
                    .font(WispFont.caption)
                    .foregroundStyle(WispColor.textTertiary)
            case .fileDropped(let folderPath):
                AutomationFolderPathField(folderPath: folderPathBinding(currentPath: folderPath))
            }
        }
    }

    private var eventKindBinding: Binding<AutomationEventKind> {
        Binding(
            get: { AutomationEventKind(event: event) },
            set: { newKind in
                guard newKind != AutomationEventKind(event: event) else { return }
                event = newKind.defaultEvent
            }
        )
    }

    private func minutesBinding(currentMinutes: Int) -> Binding<Int> {
        Binding(get: { currentMinutes }, set: { event = .meetingStarting(minutesBefore: $0) })
    }

    private func watchedTextBinding(currentText: String) -> Binding<String> {
        Binding(get: { currentText }, set: { event = .screenTextAppears(text: $0) })
    }

    private func folderPathBinding(currentPath: String) -> Binding<String> {
        Binding(get: { currentPath }, set: { event = .fileDropped(folderPath: $0) })
    }
}

/// A folder path the user types or picks. Picking is the normal way; the field is there so a
/// path can be pasted.
struct AutomationFolderPathField: View {
    @Binding var folderPath: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Folder", text: $folderPath)
                .textFieldStyle(.roundedBorder)
            Button("Choose folder…") {
                chooseFolder()
            }
            .buttonStyle(WispPillButtonStyle(isProminent: false))
            .controlSize(.small)
            .pointerCursor()
        }
    }

    private func chooseFolder() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Choose"
        if openPanel.runModal() == .OK, let chosenURL = openPanel.url {
            folderPath = chosenURL.path
        }
    }
}

// MARK: - Source

struct AutomationSourceEditor: View {
    @Binding var source: AutomationSource

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Read first, then handed over as data:")
                .font(WispFont.caption)
                .foregroundStyle(WispColor.textTertiary)
            ForEach(AutomationSourceKind.allCases, id: \.self) { sourceKind in
                AutomationChoiceRow(
                    title: sourceKind.title,
                    detail: nil,
                    isSelected: AutomationSourceKind(source: source) == sourceKind
                ) {
                    if AutomationSourceKind(source: source) != sourceKind {
                        source = sourceKind.defaultSource
                    }
                }
            }
            sourceDetailControl
        }
    }

    @ViewBuilder
    private var sourceDetailControl: some View {
        switch source {
        case .canvasDeadlines(let withinDays):
            Stepper(
                withinDays == 1 ? "Next day" : "Next \(withinDays) days",
                value: Binding(get: { withinDays }, set: { source = .canvasDeadlines(withinDays: $0) }),
                in: 1...60
            )
            .padding(.top, 6)
        case .reminders(let listName):
            TextField(
                "List name (blank = all lists)",
                text: Binding(
                    get: { listName ?? "" },
                    set: { source = .reminders(listName: $0.isEmpty ? nil : $0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .padding(.top, 6)
        case .folderFiles(let path):
            AutomationFolderPathField(
                folderPath: Binding(get: { path }, set: { source = .folderFiles(path: $0) })
            )
            .padding(.top, 6)
        case .nothing, .todaysCalendar, .clipboard, .screenText:
            EmptyView()
        }
    }
}

// MARK: - Outputs

struct AutomationOutputEditor: View {
    @Binding var outputs: [AutomationOutput]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(AutomationOutputKind.allCases, id: \.self) { outputKind in
                Toggle(isOn: toggleBinding(for: outputKind)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(outputKind.title)
                            .font(WispFont.bodyMedium)
                            .foregroundStyle(WispColor.textPrimary)
                        Text(outputKind.detail)
                            .font(WispFont.caption)
                            .foregroundStyle(WispColor.textTertiary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .pointerCursor()
            }
            if let listTitle = remindersListTitle {
                TextField(
                    "Reminders list",
                    text: Binding(
                        get: { listTitle },
                        set: { newTitle in replaceRemindersListTitle(with: newTitle) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .padding(.top, 2)
            }
        }
    }

    private var remindersListTitle: String? {
        for output in outputs {
            if case .remindersChecklist(let listTitle) = output { return listTitle }
        }
        return nil
    }

    private func replaceRemindersListTitle(with newTitle: String) {
        outputs = outputs.map { output in
            if case .remindersChecklist = output { return .remindersChecklist(listTitle: newTitle) }
            return output
        }
    }

    private func toggleBinding(for outputKind: AutomationOutputKind) -> Binding<Bool> {
        Binding(
            get: { outputs.contains { AutomationOutputKind(output: $0) == outputKind } },
            set: { isOn in
                if isOn {
                    if !outputs.contains(where: { AutomationOutputKind(output: $0) == outputKind }) {
                        outputs.append(outputKind.defaultOutput)
                    }
                } else {
                    outputs.removeAll { AutomationOutputKind(output: $0) == outputKind }
                }
            }
        )
    }
}

// MARK: - Buddy

struct AutomationBuddyEditor: View {
    @Binding var buddyID: UUID?
    @ObservedObject private var buddyStore = BuddyStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AutomationChoiceRow(
                title: "Choose for me",
                detail: "Wisp picks a buddy when you save.",
                isSelected: buddyID == nil
            ) {
                buddyID = nil
            }
            ForEach(buddyStore.buddies) { buddy in
                Button {
                    buddyID = buddy.id
                } label: {
                    HStack(spacing: 10) {
                        BuddyAvatar(colorIndex: buddy.colorIndex, size: 26)
                        Text(buddy.name)
                            .font(WispFont.bodyMedium)
                            .foregroundStyle(WispColor.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if buddyID == buddy.id {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(WispColor.accentText)
                        }
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }
}

// MARK: - Notify

struct AutomationNotifyEditor: View {
    @Binding var notifyPolicy: AutomationNotifyPolicy

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tell me")
                .font(WispFont.caption)
                .foregroundStyle(WispColor.textTertiary)
            ForEach(AutomationNotifyPolicy.allCases, id: \.self) { policy in
                AutomationChoiceRow(
                    title: AutomationDisplayText.notifyTitle(policy),
                    detail: AutomationDisplayText.notifyDetail(policy),
                    isSelected: notifyPolicy == policy
                ) {
                    notifyPolicy = policy
                }
            }
        }
    }
}

// MARK: - Shared row

/// One choice in a single-choice popover: a title, an optional line under it, a check.
struct AutomationChoiceRow: View {
    let title: String
    let detail: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(WispFont.bodyMedium)
                        .foregroundStyle(WispColor.textPrimary)
                    if let detail {
                        Text(detail)
                            .font(WispFont.caption)
                            .foregroundStyle(WispColor.textTertiary)
                    }
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(WispColor.accentText)
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
