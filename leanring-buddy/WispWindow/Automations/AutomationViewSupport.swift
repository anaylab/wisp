//
//  AutomationViewSupport.swift
//  leanring-buddy
//
//  Small pieces the automations views share: the editor "kinds" (what the pickers choose
//  between), the chip that opens an editor popover, a wrapping layout for chips, the status
//  look of a run, and the one place an edited automation is written to the store.
//

import SwiftUI

// MARK: - Editor kinds

nonisolated enum AutomationTriggerKind: CaseIterable, Hashable {
    case schedule, event, manual

    var title: String {
        switch self {
        case .schedule: return "Schedule"
        case .event: return "Event"
        case .manual: return "Manual"
        }
    }

    init(trigger: AutomationTrigger) {
        switch trigger {
        case .schedule: self = .schedule
        case .event: self = .event
        case .manual: self = .manual
        }
    }

    var symbolName: String {
        switch self {
        case .schedule: return "clock"
        case .event: return "bolt"
        case .manual: return "hand.tap"
        }
    }
}

nonisolated enum AutomationRecurrenceKind: CaseIterable, Hashable {
    case once, daily, weekdays, weekly, monthly

    var title: String {
        switch self {
        case .once: return "Once"
        case .daily: return "Every day"
        case .weekdays: return "Every weekday"
        case .weekly: return "Every week"
        case .monthly: return "Every month"
        }
    }

    init(recurrence: AutomationSchedule.Recurrence) {
        switch recurrence {
        case .once: self = .once
        case .daily: self = .daily
        case .weekdays: self = .weekdays
        case .weekly: self = .weekly
        case .monthly: self = .monthly
        }
    }

    /// A sensible starting recurrence when the user switches to this kind.
    func defaultRecurrence(now: Date, calendar: Calendar) -> AutomationSchedule.Recurrence {
        switch self {
        case .once:
            // The next whole hour, so a fresh "once" is never already in the past.
            let nextWholeHour = calendar.nextDate(
                after: now,
                matching: DateComponents(minute: 0, second: 0),
                matchingPolicy: .nextTime
            ) ?? now.addingTimeInterval(3600)
            return .once(nextWholeHour)
        case .daily: return .daily
        case .weekdays: return .weekdays
        case .weekly: return .weekly(weekday: 2)
        case .monthly: return .monthly(dayOfMonth: 1)
        }
    }
}

nonisolated enum AutomationEventKind: CaseIterable, Hashable {
    case newCanvasItem, meetingStarting, screenTextAppears, fileDropped

    var title: String {
        switch self {
        case .newCanvasItem: return "A new Canvas item"
        case .meetingStarting: return "A meeting is about to start"
        case .screenTextAppears: return "Some text shows on screen"
        case .fileDropped: return "A file lands in a folder"
        }
    }

    init(event: AutomationEvent) {
        switch event {
        case .newCanvasItem: self = .newCanvasItem
        case .meetingStarting: self = .meetingStarting
        case .screenTextAppears: self = .screenTextAppears
        case .fileDropped: self = .fileDropped
        }
    }

    var defaultEvent: AutomationEvent {
        switch self {
        case .newCanvasItem: return .newCanvasItem
        case .meetingStarting: return .meetingStarting(minutesBefore: 10)
        case .screenTextAppears: return .screenTextAppears(text: "")
        case .fileDropped: return .fileDropped(folderPath: "")
        }
    }
}

nonisolated enum AutomationSourceKind: CaseIterable, Hashable {
    case nothing, todaysCalendar, canvasDeadlines, reminders, clipboard, screenText, folderFiles

    var title: String {
        switch self {
        case .nothing: return "Nothing extra"
        case .todaysCalendar: return "Today's calendar"
        case .canvasDeadlines: return "Canvas deadlines"
        case .reminders: return "Reminders"
        case .clipboard: return "Clipboard"
        case .screenText: return "Text on screen"
        case .folderFiles: return "Files in a folder"
        }
    }

    init(source: AutomationSource) {
        switch source {
        case .nothing: self = .nothing
        case .todaysCalendar: self = .todaysCalendar
        case .canvasDeadlines: self = .canvasDeadlines
        case .reminders: self = .reminders
        case .clipboard: self = .clipboard
        case .screenText: self = .screenText
        case .folderFiles: self = .folderFiles
        }
    }

    var defaultSource: AutomationSource {
        switch self {
        case .nothing: return .nothing
        case .todaysCalendar: return .todaysCalendar
        case .canvasDeadlines: return .canvasDeadlines(withinDays: 7)
        case .reminders: return .reminders(listName: nil)
        case .clipboard: return .clipboard
        case .screenText: return .screenText
        case .folderFiles: return .folderFiles(path: "")
        }
    }
}

/// The places a result can go. `remindersChecklist` carries a list title, so output kinds are
/// matched by case rather than by equality.
nonisolated enum AutomationOutputKind: CaseIterable, Hashable {
    case notchCard, remindersChecklist, calendarBlock, notification, buddyThreadMessage, spokenLine

    var title: String {
        switch self {
        case .notchCard: return "Notch card"
        case .remindersChecklist: return "Reminders checklist"
        case .calendarBlock: return "Calendar block"
        case .notification: return "Notification"
        case .buddyThreadMessage: return "Buddy's thread"
        case .spokenLine: return "Spoken line"
        }
    }

    var detail: String {
        switch self {
        case .notchCard: return "The reply, in the notch."
        case .remindersChecklist: return "Tick-off items in a Wisp list."
        case .calendarBlock: return "Always asks before booking."
        case .notification: return "A macOS notification."
        case .buddyThreadMessage: return "Filed in the buddy's chat."
        case .spokenLine: return "Read aloud, in voice mode."
        }
    }

    init(output: AutomationOutput) {
        switch output {
        case .notchCard: self = .notchCard
        case .remindersChecklist: self = .remindersChecklist
        case .calendarBlock: self = .calendarBlock
        case .notification: self = .notification
        case .buddyThreadMessage: self = .buddyThreadMessage
        case .spokenLine: self = .spokenLine
        }
    }

    var defaultOutput: AutomationOutput {
        switch self {
        case .notchCard: return .notchCard
        case .remindersChecklist: return .remindersChecklist(listTitle: AutomationOutput.defaultChecklistListTitle)
        case .calendarBlock: return .calendarBlock
        case .notification: return .notification
        case .buddyThreadMessage: return .buddyThreadMessage
        case .spokenLine: return .spokenLine
        }
    }
}

// MARK: - Saving and templates

/// The one place an edited automation reaches the store, so every card writes the same way.
@MainActor
enum AutomationDraftSaving {
    /// Updates when the automation already exists, adds it otherwise.
    @discardableResult
    static func save(_ automation: Automation) -> Automation {
        let store = AutomationStore.shared
        if store.automation(withID: automation.id) != nil {
            store.update(automation)
            return store.automation(withID: automation.id) ?? automation
        }
        return store.add(automation)
    }

    /// An empty draft for "New". The trigger starts highlighted because it is the part the
    /// user always has to choose.
    static func blankDraft(buddyID: UUID? = nil) -> AutomationDraft {
        AutomationDraft(
            originalText: "",
            name: "",
            buddyID: buddyID,
            trigger: .schedule(AutomationSchedule(recurrence: .daily, hour: 9, minute: 0)),
            action: .askBuddy(instruction: ""),
            outputs: [.notchCard],
            notify: .always,
            uncertainFields: [.trigger],
            notes: [.trigger: "Pick when this should run."]
        )
    }

    /// A template's suggested starter buddy, but only if that buddy exists (the user may have
    /// deleted it), so the draft never names a buddy that is gone.
    static func suggestedBuddyID(for template: AutomationTemplate) -> UUID? {
        let starterBuddyID = StarterBuddyDefinition.definition(for: template.suggestedStarterBuddy).id
        return BuddyStore.shared.buddy(withID: starterBuddyID) != nil ? starterBuddyID : nil
    }

    static func draft(for template: AutomationTemplate) -> AutomationDraft {
        AutomationDraft(template: template, buddyID: suggestedBuddyID(for: template))
    }
}

// MARK: - Status look

/// How a run's outcome looks: one symbol and one colour, used by the history and the list.
struct AutomationOutcomeStyle {
    let symbolName: String
    let color: Color

    static func style(for outcome: AutomationRunOutcome?) -> AutomationOutcomeStyle {
        guard let outcome else {
            return AutomationOutcomeStyle(symbolName: "circle.dotted", color: WispColor.intelligence)
        }
        switch outcome {
        case .succeeded:
            return AutomationOutcomeStyle(symbolName: "checkmark.circle.fill", color: WispColor.success)
        case .succeededNothingNew:
            return AutomationOutcomeStyle(symbolName: "checkmark.circle", color: WispColor.textTertiary)
        case .failed:
            return AutomationOutcomeStyle(symbolName: "exclamationmark.triangle.fill", color: WispColor.warningText)
        case .needsApproval:
            return AutomationOutcomeStyle(symbolName: "hand.raised.fill", color: WispColor.warningText)
        case .skippedBusy, .skippedPaused:
            return AutomationOutcomeStyle(symbolName: "forward.circle", color: WispColor.textTertiary)
        }
    }
}

// MARK: - Chip

/// One tappable part of an automation (when, from, to, who, tell me). Opens its editor in a
/// popover. A guessed or missing part is drawn in the warning tint so the user's eye goes to it.
struct AutomationChipButton<EditorContent: View>: View {
    let fieldTitle: String
    let valueText: String
    let symbolName: String
    var isUncertain = false
    @Binding var isEditorOpen: Bool
    @ViewBuilder var editorContent: EditorContent

    @State private var isHovered = false

    var body: some View {
        Button {
            isEditorOpen.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isUncertain ? WispColor.warningText : WispColor.accentText)
                    .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(fieldTitle.uppercased())
                        .font(WispFont.overline)
                        .tracking(0.6)
                        .foregroundStyle(WispColor.textTertiary)
                    Text(valueText)
                        .font(WispFont.callout)
                        .foregroundStyle(WispColor.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: 220, alignment: .leading)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(WispColor.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isUncertain
                          ? WispColor.warning.opacity(0.14)
                          : WispColor.surface3.opacity(isHovered ? 0.95 : 0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        isUncertain ? WispColor.warning.opacity(0.65) : WispColor.cardSeparator.opacity(0.6),
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            withAnimation(WispMotion.quick) { isHovered = hovering }
        }
        .popover(isPresented: $isEditorOpen, arrowEdge: .bottom) {
            editorContent
                .padding(14)
                .frame(width: 310, alignment: .leading)
        }
        .accessibilityLabel("\(fieldTitle): \(valueText)")
        .accessibilityHint(isUncertain ? "Needs a look. Opens the editor." : "Opens the editor.")
    }
}

// MARK: - Flow layout

/// Lays chips out left to right and wraps to a new line when the row is full, so the card
/// works at any window width without a fixed grid.
struct AutomationChipFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let arrangement = arrange(availableWidth: proposal.width ?? .infinity, subviews: subviews)
        return arrangement.totalSize
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(availableWidth: bounds.width, subviews: subviews)
        for (subviewIndex, subview) in subviews.enumerated() {
            let position = arrangement.positions[subviewIndex]
            subview.place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrange(availableWidth: CGFloat, subviews: Subviews) -> (positions: [CGPoint], totalSize: CGSize) {
        var positions: [CGPoint] = []
        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        var widestRowWidth: CGFloat = 0

        for subview in subviews {
            let subviewSize = subview.sizeThatFits(.unspecified)
            let wouldOverflowRow = cursorX > 0 && cursorX + subviewSize.width > availableWidth
            if wouldOverflowRow {
                cursorX = 0
                cursorY += currentRowHeight + verticalSpacing
                currentRowHeight = 0
            }
            positions.append(CGPoint(x: cursorX, y: cursorY))
            cursorX += subviewSize.width + horizontalSpacing
            currentRowHeight = max(currentRowHeight, subviewSize.height)
            widestRowWidth = max(widestRowWidth, cursorX - horizontalSpacing)
        }
        return (positions, CGSize(width: widestRowWidth, height: cursorY + currentRowHeight))
    }
}

// MARK: - Section title

/// The small heading above a block on the automations page.
struct AutomationSectionTitle: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(WispFont.headline)
                .foregroundStyle(WispColor.textPrimary)
            if let detail {
                Text(detail)
                    .font(WispFont.caption)
                    .foregroundStyle(WispColor.textTertiary)
            }
        }
        .padding(.leading, 2)
    }
}
