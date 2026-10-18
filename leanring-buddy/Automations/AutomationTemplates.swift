//
//  AutomationTemplates.swift
//  leanring-buddy
//
//  The eight ready-made automations in the gallery. A template is data only: picking one opens
//  the same editable draft card as "say it", so nothing is enabled without a tap.
//
//  Pure (Foundation only). `StarterBuddyKind` comes from `Buddies/StarterBuddies.swift`.
//

import Foundation

nonisolated enum AutomationTemplateID: String, Codable, CaseIterable, Identifiable, Sendable {
    case morningBrief, canvasDeadlines, dailyChecklist, weeklyReview, meetingPrep, focusBlock, studyPlan, screenWatch
    var id: String { rawValue }
}

nonisolated struct AutomationTemplate: Identifiable, Equatable, Sendable {
    let id: AutomationTemplateID
    let title: String
    /// One short line.
    let summary: String
    let symbolName: String
    let suggestedStarterBuddy: StarterBuddyKind
    let trigger: AutomationTrigger
    let source: AutomationSource
    let action: AutomationAction
    let outputs: [AutomationOutput]
    let notify: AutomationNotifyPolicy
    /// Blanks the card asks for before saving (screenWatch asks for the text to watch).
    let requiredBlanks: [String]
}

nonisolated enum AutomationTemplates {
    /// The eight, in gallery order.
    static let all: [AutomationTemplate] = [
        AutomationTemplate(
            id: .morningBrief,
            title: "Morning brief",
            summary: "Meetings and what to start with, every weekday.",
            symbolName: "sun.max",
            suggestedStarterBuddy: .briefer,
            trigger: .schedule(AutomationSchedule(recurrence: .weekdays, hour: 7, minute: 45)),
            // One source per automation; the instruction asks for the deadlines in the buddy's
            // own words, and Canvas deadlines have their own template.
            source: .todaysCalendar,
            action: .askBuddy(instruction: "Give me a short morning brief: today's meetings, anything due soon, and the one thing to start with."),
            outputs: [.notchCard, .spokenLine],
            notify: .always,
            requiredBlanks: []
        ),
        AutomationTemplate(
            id: .canvasDeadlines,
            title: "Canvas deadlines",
            summary: "Keep your calendar in step with Canvas.",
            symbolName: "graduationcap",
            suggestedStarterBuddy: .planner,
            // Display only: JobsEngine owns the real hourly timer.
            trigger: .schedule(AutomationSchedule(recurrence: .daily, hour: 7, minute: 0)),
            source: .nothing,
            action: .syncCanvas,
            outputs: [.notchCard],
            notify: .onlyWhenSomethingNew,
            requiredBlanks: []
        ),
        AutomationTemplate(
            id: .dailyChecklist,
            title: "Daily checklist",
            summary: "A tick-off list for today in Reminders.",
            symbolName: "checklist",
            suggestedStarterBuddy: .planner,
            // Display only: JobsEngine builds it once each morning.
            trigger: .schedule(AutomationSchedule(recurrence: .daily, hour: 7, minute: 30)),
            source: .nothing,
            action: .buildDailyChecklist,
            outputs: [.remindersChecklist(listTitle: AutomationOutput.defaultChecklistListTitle)],
            notify: .onlyWhenSomethingNew,
            requiredBlanks: []
        ),
        AutomationTemplate(
            id: .weeklyReview,
            title: "Weekly review",
            summary: "Sunday evening: what's coming up this week.",
            symbolName: "calendar.badge.clock",
            suggestedStarterBuddy: .briefer,
            trigger: .schedule(AutomationSchedule(recurrence: .weekly(weekday: 1), hour: 18, minute: 0)),
            source: .canvasDeadlines(withinDays: 7),
            action: .askBuddy(instruction: "Plan my week: what's due, what's heavy, and what to do first."),
            outputs: [.notchCard, .buddyThreadMessage],
            notify: .always,
            requiredBlanks: []
        ),
        AutomationTemplate(
            id: .meetingPrep,
            title: "Meeting prep",
            summary: "A short agenda 10 minutes before a meeting.",
            symbolName: "person.2",
            suggestedStarterBuddy: .briefer,
            trigger: .event(.meetingStarting(minutesBefore: 10)),
            source: .todaysCalendar,
            action: .askBuddy(instruction: "My next meeting starts soon. Give me a two-line prep: what it is and what I should have ready."),
            outputs: [.notchCard, .notification],
            notify: .always,
            requiredBlanks: []
        ),
        AutomationTemplate(
            id: .focusBlock,
            title: "Focus block",
            summary: "Find study time and ask before booking it.",
            symbolName: "timer",
            suggestedStarterBuddy: .focus,
            // Manual on purpose: writing to the calendar always asks, so nobody should be
            // expected to answer at a random hour.
            trigger: .manual,
            source: .nothing,
            action: .proposeStudyBlocks,
            outputs: [.calendarBlock, .notchCard],
            notify: .always,
            requiredBlanks: []
        ),
        AutomationTemplate(
            id: .studyPlan,
            title: "Study plan",
            summary: "Each evening, a plan for tomorrow.",
            symbolName: "book",
            suggestedStarterBuddy: .focus,
            trigger: .schedule(AutomationSchedule(recurrence: .daily, hour: 19, minute: 0)),
            source: .canvasDeadlines(withinDays: 7),
            action: .askBuddy(instruction: "Make a short study plan for tomorrow from what's due this week."),
            outputs: [.notchCard, .remindersChecklist(listTitle: AutomationOutput.defaultChecklistListTitle)],
            notify: .always,
            requiredBlanks: []
        ),
        AutomationTemplate(
            id: .screenWatch,
            title: "Screen watch",
            summary: "Tell me when some text shows up on screen.",
            symbolName: "eye",
            suggestedStarterBuddy: .briefer,
            // The text is the blank the card asks for.
            trigger: .event(.screenTextAppears(text: "")),
            source: .screenText,
            action: .askBuddy(instruction: "The text I was waiting for just appeared on my screen. Tell me in one line what it says around it."),
            outputs: [.notification, .notchCard],
            notify: .always,
            requiredBlanks: ["text to watch for"]
        ),
    ]

    static func template(withID templateID: AutomationTemplateID) -> AutomationTemplate {
        // `all` holds exactly one template per id, so this always finds one.
        all.first { $0.id == templateID } ?? all[0]
    }
}
