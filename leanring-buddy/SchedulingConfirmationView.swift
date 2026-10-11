//
//  SchedulingConfirmationView.swift
//  leanring-buddy
//
//  The confirmation panel for adding a calendar event or a reminder, drawn the
//  way Siri shows one: the event as Calendar would (a date tile, the title
//  large, the day and time, the place) or the reminder as Reminders would (a
//  ring, the title, when it's due, the list), then Cancel / Add. It replaces
//  the generic tool panel for `create_calendar_event` and `create_reminder`,
//  whose "needs your ok" header, key/value table and raw call told the user
//  about a tool call, when all they need to check is what lands where.
//
//  Same consent flow underneath, like `MessageSendConfirmationView`: the
//  coordinator's timeout, the spoken "yes" and deny-by-default are unchanged.
//  The title (and an event's place) can still be edited in place; the edits
//  go to the coordinator, so a spoken "yes" adds the edited version.
//

import Combine
import SwiftUI

/// What a pending calendar/reminder confirmation will add, read from the tool
/// input (the fast path's prepared input, or the model's own arguments).
enum SchedulingConfirmationPreview: Equatable {
    case event(title: String, startDate: Date, endDate: Date, isAllDay: Bool, location: String?, calendarName: String?)
    case reminder(title: String, dueDate: Date?, dueDateIncludesTimeOfDay: Bool, listName: String?)

    /// Nil unless this is one of the two tools with a title and readable dates
    /// — anything else keeps the generic panel, which shows the raw call.
    init?(toolName: String, toolInput: JSONValue) {
        let bareToolName = ToolCallInspection.bareToolName(toolName)
        guard let title = ToolCallInspection.stringValue(forAnyOf: ["title"], in: toolInput)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }

        if bareToolName == AgentToolRegistry.createCalendarEventToolName {
            guard let startText = ToolCallInspection.stringValue(forAnyOf: ["start"], in: toolInput),
                  let parsedStart = ReminderDueDateParser.parse(startText) else { return nil }
            let isAllDay = !parsedStart.includesTimeOfDay
            var endDate = isAllDay ? parsedStart.date : parsedStart.date.addingTimeInterval(60 * 60)
            if let endText = ToolCallInspection.stringValue(forAnyOf: ["end"], in: toolInput) {
                guard let parsedEnd = ReminderDueDateParser.parse(endText) else { return nil }
                endDate = parsedEnd.date
            }
            self = .event(
                title: title,
                startDate: parsedStart.date,
                endDate: endDate,
                isAllDay: isAllDay,
                location: ToolCallInspection.stringValue(forAnyOf: ["location"], in: toolInput),
                calendarName: ToolCallInspection.stringValue(forAnyOf: ["calendar"], in: toolInput)
            )
            return
        }

        if bareToolName == EditableConfirmationFields.createReminderToolName {
            var parsedDue: ReminderDueDateParser.ParsedDueDate?
            if let dueText = ToolCallInspection.stringValue(forAnyOf: ["due"], in: toolInput) {
                guard let readableDue = ReminderDueDateParser.parse(dueText) else { return nil }
                parsedDue = readableDue
            }
            self = .reminder(
                title: title,
                dueDate: parsedDue?.date,
                dueDateIncludesTimeOfDay: parsedDue?.includesTimeOfDay ?? false,
                listName: ToolCallInspection.stringValue(forAnyOf: ["list"], in: toolInput)
            )
            return
        }
        return nil
    }
}

struct SchedulingConfirmationView: View {
    let preview: SchedulingConfirmationPreview
    let editableFields: [EditableConfirmationField]
    /// The edits so far, by argument key.
    let editedTextsByArgumentKey: [String: String]
    let expiryDate: Date?
    let onTextChange: (_ argumentKey: String, _ editedText: String) -> Void
    let onEditingActivity: () -> Void
    let onAdd: () -> Void
    let onCancel: () -> Void

    @State private var secondsRemaining = Int(ToolConfirmationCoordinator.confirmationTimeoutSeconds)
    private let countdownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let panelShape = RoundedRectangle(cornerRadius: WispRadius.panel, style: .continuous)
        // A solid island surface rather than `WispGlassPanel`'s see-through
        // glass: over a light window the glass took on the window's colour and
        // the panel read as a washed-out grey with faint text. Black matches
        // the notch it hangs from; the glowing rim still says "waiting on you".
        VStack(alignment: .leading, spacing: WispSpacing.md) {
            appHeader
            switch preview {
            case let .event(title, startDate, endDate, isAllDay, location, calendarName):
                eventBody(title: title, startDate: startDate, endDate: endDate, isAllDay: isAllDay, location: location, calendarName: calendarName)
            case let .reminder(title, dueDate, dueDateIncludesTimeOfDay, listName):
                reminderBody(title: title, dueDate: dueDate, dueDateIncludesTimeOfDay: dueDateIncludesTimeOfDay, listName: listName)
            }
            actions
            Text("or just say yes")
                .font(WispFont.caption)
                .foregroundColor(WispColor.OnGlass.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(WispSpacing.lg)
        .background(panelShape.fill(WispColor.Island.surface))
        .overlay(panelShape.strokeBorder(WispColor.Island.separator, lineWidth: 1))
        // An addition is waiting on the user, like any confirmation card.
        .wispLiquidRim(in: panelShape, light: .glowing(WispColor.warning))
        .wispShadow(.island)
        .frame(width: 312)
        // Only this card takes clicks; the overlay behind it stays click-through.
        .allowsHitTesting(true)
        .onReceive(countdownTimer) { _ in refreshSecondsRemaining() }
        .onChange(of: expiryDate) { _, _ in refreshSecondsRemaining() }
    }

    private func refreshSecondsRemaining() {
        guard let expiryDate else { return }
        secondsRemaining = max(0, Int(expiryDate.timeIntervalSinceNow.rounded(.up)))
    }

    // MARK: - Header

    private var isEvent: Bool {
        if case .event = preview { return true }
        return false
    }

    /// Which app it lands in, the way Siri labels a snippet, and the countdown.
    private var appHeader: some View {
        HStack(spacing: WispSpacing.xs + 2) {
            Image(systemName: isEvent ? "calendar" : "checklist")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isEvent ? Color(nsColor: .systemRed) : Color(nsColor: .systemBlue))
            Text(isEvent ? "CALENDAR" : "REMINDERS")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(WispColor.OnGlass.textTertiary)
            Spacer(minLength: WispSpacing.sm)
            Text("\(secondsRemaining)s")
                .font(WispFont.mono)
                .foregroundColor(secondsRemaining <= 10 ? WispColor.destructiveText : WispColor.OnGlass.textTertiary)
        }
    }

    // MARK: - Event

    private func eventBody(title: String, startDate: Date, endDate: Date, isAllDay: Bool, location: String?, calendarName: String?) -> some View {
        HStack(alignment: .top, spacing: WispSpacing.md) {
            CalendarDateTile(date: startDate)
            VStack(alignment: .leading, spacing: 4) {
                editableTitle(originalTitle: title)
                Text(SchedulingPhrasing.fullDayText(for: startDate))
                    .font(WispFont.callout)
                    .foregroundColor(WispColor.OnGlass.textSecondary)
                Text(SchedulingPhrasing.timeRangeText(start: startDate, end: endDate, isAllDay: isAllDay))
                    .font(WispFont.callout)
                    .foregroundColor(WispColor.OnGlass.textSecondary)
                if let locationField = editableField(forArgumentKey: "location") {
                    locationRow(editableField: locationField)
                } else if let location {
                    detailRow(symbolName: "mappin.and.ellipse", text: location)
                }
                if let calendarName {
                    detailRow(symbolName: "circle.fill", text: calendarName)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Reminder

    private func reminderBody(title: String, dueDate: Date?, dueDateIncludesTimeOfDay: Bool, listName: String?) -> some View {
        HStack(alignment: .top, spacing: WispSpacing.md) {
            ReminderCheckRing(color: Color(nsColor: .systemBlue))
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
                editableTitle(originalTitle: title)
                if let dueDate {
                    detailRow(
                        symbolName: dueDateIncludesTimeOfDay ? "bell.fill" : "calendar",
                        text: SchedulingPhrasing.whenPhrase(for: dueDate, includesTimeOfDay: dueDateIncludesTimeOfDay).capitalizedFirstLetter
                    )
                }
                detailRow(symbolName: "list.bullet", text: listName ?? "Default list")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func editableTitle(originalTitle: String) -> some View {
        if let titleField = editableField(forArgumentKey: "title") {
            let currentTitle = editedTextsByArgumentKey[titleField.argumentKey] ?? titleField.originalText
            InlineEditableTitle(
                text: currentTitle,
                isEdited: currentTitle != titleField.originalText,
                onTextChange: { editedTitle in onTextChange(titleField.argumentKey, editedTitle) },
                onEditingActivity: onEditingActivity
            )
        } else {
            InlineEditableTitle(text: originalTitle, isEdited: false, onTextChange: nil, onEditingActivity: onEditingActivity)
        }
    }

    private func locationRow(editableField: EditableConfirmationField) -> some View {
        let currentLocation = editedTextsByArgumentKey[editableField.argumentKey] ?? editableField.originalText
        return HStack(spacing: 5) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(WispColor.OnGlass.textTertiary)
            TextField("Add location", text: Binding(
                get: { currentLocation },
                set: { editedLocation in onTextChange(editableField.argumentKey, editedLocation) }
            ))
            .textFieldStyle(.plain)
            .font(WispFont.callout)
            .foregroundColor(WispColor.OnGlass.textSecondary)
            .accessibilityLabel("Location, editable")
            if currentLocation != editableField.originalText {
                EditedConfirmationFieldMark()
            }
        }
    }

    private func detailRow(symbolName: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbolName)
                .font(.system(size: symbolName == "circle.fill" ? 6 : 10, weight: .medium))
                .foregroundColor(WispColor.OnGlass.textTertiary)
                .frame(width: 12)
            Text(text)
                .font(WispFont.callout)
                .foregroundColor(WispColor.OnGlass.textSecondary)
                .lineLimit(1)
        }
    }

    private func editableField(forArgumentKey argumentKey: String) -> EditableConfirmationField? {
        editableFields.first { $0.argumentKey == argumentKey }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: WispSpacing.sm) {
            Button("Cancel", action: onCancel)
                .wispGlassButtonStyle(prominence: .subtle)

            Button(action: onAdd) {
                Text(isEvent ? "Add to Calendar" : "Add Reminder")
                    .frame(maxWidth: .infinity)
            }
            .wispGlassButtonStyle(prominence: .prominent)
            // Cmd-Return adds from inside a field; plain Return never does.
            .keyboardShortcut(.return, modifiers: .command)
        }
    }
}

private extension String {
    var capitalizedFirstLetter: String {
        guard let firstCharacter = first else { return self }
        return firstCharacter.uppercased() + dropFirst()
    }
}
