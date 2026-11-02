//
//  WispDemoSampleData.swift
//  leanring-buddy
//
//  The sample day demo mode shows (`WispDemoMode`): a student's checklist, a few
//  calendar events, and what the starter buddies said about them. Everything is
//  made up and dated relative to "now", so a screenshot taken any day looks like
//  that day. Pure, so it is tested with plain swiftc (`Tests/DemoMode`).
//

import Foundation

nonisolated enum WispDemoSampleData {

    // MARK: Today's checklist and calendar

    static func checklist(now: Date, calendar: Calendar = .current) -> [ChecklistItem] {
        let dayKey = dayKeyText(for: now, calendar: calendar)
        let startOfDay = calendar.startOfDay(for: now)
        func at(_ hour: Int, _ minute: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: startOfDay) ?? now
        }
        return [
            ChecklistItem(id: "canvasDue:demo-lab-report:\(dayKey)", title: "Bio lab report",
                          subtitle: "BIO 201 · due 11:59 PM", dueDate: at(23, 59), origin: .canvasDue,
                          rolloverCount: 0, isCompleted: false, completionDate: nil),
            ChecklistItem(id: "calendarEvent:demo-spanish-quiz:\(dayKey)", title: "Spanish quiz",
                          subtitle: "SPAN 102 · 10:00 AM", dueDate: at(10, 0), origin: .calendarEvent,
                          rolloverCount: 0, isCompleted: true, completionDate: at(10, 40)),
            ChecklistItem(id: "studyBlock:demo-results:\(dayKey)", title: "Study block: lab report results",
                          subtitle: "2:00 – 3:00 PM", dueDate: at(14, 0), origin: .studyBlock,
                          rolloverCount: 0, isCompleted: false, completionDate: nil),
            ChecklistItem(id: "rolledOver:demo-history-reading:\(dayKey)", title: "Read chapter 7",
                          subtitle: "HIST 110 · from yesterday", dueDate: nil, origin: .rolledOver,
                          rolloverCount: 1, isCompleted: false, completionDate: nil),
            ChecklistItem(id: "calendarEvent:demo-soccer:\(dayKey)", title: "Soccer practice",
                          subtitle: "5:00 PM · North field", dueDate: at(17, 0), origin: .calendarEvent,
                          rolloverCount: 0, isCompleted: false, completionDate: nil),
        ]
    }

    /// The next few events, always ahead of `now` so "Up next" is never empty.
    static func calendarSnapshot(now: Date, calendar: Calendar = .current) -> CalendarSnapshot {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let dayAfter = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now)) ?? now
        let tomorrowMorning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        let events = [
            CalendarGlanceEvent(id: "demo-study-block", title: "Study block: lab report",
                                startDate: now.addingTimeInterval(45 * 60), endDate: now.addingTimeInterval(105 * 60),
                                isAllDay: false, location: nil, calendarColorHex: "#34C759"),
            CalendarGlanceEvent(id: "demo-soccer", title: "Soccer practice",
                                startDate: now.addingTimeInterval(4 * 3600), endDate: now.addingTimeInterval(5.5 * 3600),
                                isAllDay: false, location: "North field", calendarColorHex: "#FF9500"),
            CalendarGlanceEvent(id: "demo-group-project", title: "Group project check-in",
                                startDate: tomorrowMorning, endDate: tomorrowMorning.addingTimeInterval(30 * 60),
                                isAllDay: false, location: "Library, room 2", calendarColorHex: "#007AFF"),
            CalendarGlanceEvent(id: "demo-field-trip", title: "Field trip forms due",
                                startDate: dayAfter, endDate: dayAfter.addingTimeInterval(24 * 3600),
                                isAllDay: true, location: nil, calendarColorHex: "#AF52DE"),
        ]
        return CalendarSnapshot(events: events, generatedAt: now)
    }

    // MARK: What the buddies said

    static let morningBrief = """
    Three things today. The **Bio lab report** is due at 11:59 PM, so start the results section in your 2:00 study block. \
    The **Spanish quiz** is at 10, and soccer is at 5. History chapter 7 rolled over from yesterday; it can wait until tonight.
    """

    static let writerPlan = """
    Here's a plan to get the lab report done before soccer:
    - **Results (2:00–2:30):** the table and graph first, with units and the averages.
    - **Analysis (2:30–3:00):** percent error against the expected value, and one line on what it means.
    - **Discussion (tonight):** two sources of error and how each one moved your result.
    - **Intro and conclusion (last):** five sentences each, once you know what you found.

    Paste your draft here when you have one and I'll tighten it.
    """

    static let plannerJob = "Build today's checklist from Canvas and my calendar."
    static let plannerAnswer = "Today's checklist is ready: five items, the lab report first. I blocked 2:00–3:00 for its results section."

    static let inboxQuestion = "What needs a reply today?"
    static let inboxAnswer = """
    Two things:
    - **Ms. Rivera** needs the field trip form signed by Friday.
    - **Sam** asked to move Thursday's study session to 4:00.

    Want me to draft both replies? Nothing sends until you press Send.
    """

    static let researcherQuestion = "Find three solid sources on how sleep affects memory"
    static let researcherAnswer = """
    Three good ones:
    1. Rasch & Born, *About Sleep's Role in Memory*, Physiological Reviews (2013). The best overview to start with.
    2. Stickgold, *Sleep-dependent memory consolidation*, Nature (2005). Short and widely cited.
    3. Walker, *Why We Sleep* (2017). Easy to quote, but check its claims against the first two.

    Want me to pull one quote from each for your essay?
    """

    /// Questions asked from the notch, for Today's recent answers and History.
    static let recentAnswers: [(question: String, answer: String)] = [
        ("Organize my tabs", "Grouped 14 tabs into School, Research, Soccer and Shopping, and closed 3 duplicates."),
        ("Put Safari on the left and Notes on the right", "Done: Safari left, Notes right."),
        ("Draft an email to Sam about moving Thursday's study session", "Opened a draft to Sam about moving Thursday's study session to 4:00."),
    ]

    private static func dayKeyText(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
