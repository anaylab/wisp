//
//  RemindersAndTimerCardTests.swift
//  leanring-buddyTests
//
//  Proves the two on-device card kinds added after calendar behave:
//  `[CARD:{"kind":"reminders",…}]` and `[CARD:{"kind":"timer",…}]` parse into
//  typed requests (forgiving the near-misses a small model writes, dropping the
//  nonsense), the timer's clock and spoken lengths read naturally, the
//  reminders card keeps and orders the right reminders for each filter, and a
//  `create_reminder` due date is read from the ISO 8601 variants models emit.
//

import XCTest
@testable import Wisp

@MainActor
final class RemindersAndTimerCardTests: XCTestCase {

    // MARK: - Reminders payload parsing

    func testRemindersIntentParsesListAndFilterAndStripsTag() {
        let reply = #"Here's what's due. [CARD:{"kind":"reminders","list":"Groceries","filter":"today"}]"#

        let result = GlanceCardParser.parse(reply)

        XCTAssertEqual(result.spokenText, "Here's what's due.")
        XCTAssertEqual(
            result.request,
            .reminders(RemindersCardRequest(listName: "Groceries", filter: .today))
        )
    }

    func testRemindersIntentWithNoFieldsMeansAllListsAndAllReminders() {
        let result = GlanceCardParser.parse(#"[CARD:{"kind":"reminders"}]"#)

        XCTAssertEqual(result.request, .reminders(RemindersCardRequest(listName: nil, filter: .all)))
    }

    func testRemindersFilterIsReadForgivingly() {
        // Case and whitespace are ignored; an unknown filter means "all".
        let overdueResult = GlanceCardParser.parse(#"[CARD:{"kind":"reminders","filter":" Overdue "}]"#)
        XCTAssertEqual(overdueResult.request, .reminders(RemindersCardRequest(listName: nil, filter: .overdue)))

        let unknownFilterResult = GlanceCardParser.parse(#"[CARD:{"kind":"reminders","filter":"someday"}]"#)
        XCTAssertEqual(unknownFilterResult.request, .reminders(RemindersCardRequest(listName: nil, filter: .all)))
    }

    func testSingularReminderKindAndBlankListAreAccepted() {
        let result = GlanceCardParser.parse(#"[CARD:{"kind":"reminder","list":"   "}]"#)

        XCTAssertEqual(result.request, .reminders(RemindersCardRequest(listName: nil, filter: .all)))
    }

    // MARK: - Timer payload parsing

    func testTimerIntentParsesSecondsAndLabelAndStripsTag() {
        let reply = #"Tea timer started. [CARD:{"kind":"timer","seconds":300,"label":"tea"}]"#

        let result = GlanceCardParser.parse(reply)

        XCTAssertEqual(result.spokenText, "Tea timer started.")
        XCTAssertEqual(result.request, .timer(TimerCardRequest(durationSeconds: 300, label: "tea")))
    }

    func testTimerSecondsWrittenAsAStringStillParse() {
        // A synthesized Double? would fail the whole card on this near-miss.
        let result = GlanceCardParser.parse(#"[CARD:{"kind":"timer","seconds":"90"}]"#)

        XCTAssertEqual(result.request, .timer(TimerCardRequest(durationSeconds: 90, label: nil)))
    }

    func testTimerMinutesAreAcceptedWhenSecondsAreMissing() {
        let result = GlanceCardParser.parse(#"[CARD:{"kind":"timer","minutes":2.5}]"#)

        XCTAssertEqual(result.request, .timer(TimerCardRequest(durationSeconds: 150, label: nil)))
    }

    func testTimerWithoutALengthIsDropped() {
        let result = GlanceCardParser.parse(#"Okay. [CARD:{"kind":"timer","label":"tea"}]"#)

        XCTAssertNil(result.request)
        XCTAssertEqual(result.spokenText, "Okay.")
    }

    func testTimerWithZeroNegativeOrOverADayLengthIsDropped() {
        XCTAssertNil(GlanceCardParser.parse(#"[CARD:{"kind":"timer","seconds":0}]"#).request)
        XCTAssertNil(GlanceCardParser.parse(#"[CARD:{"kind":"timer","seconds":-30}]"#).request)
        XCTAssertNil(GlanceCardParser.parse(#"[CARD:{"kind":"timer","seconds":90000}]"#).request)
        XCTAssertNil(GlanceCardParser.parse(#"[CARD:{"kind":"timer","seconds":"soon"}]"#).request)
    }

    func testTimerBlankLabelBecomesNoLabelAndLongLabelIsCapped() {
        let blankLabelResult = GlanceCardParser.parse(#"[CARD:{"kind":"timer","seconds":60,"label":"  "}]"#)
        XCTAssertEqual(blankLabelResult.request, .timer(TimerCardRequest(durationSeconds: 60, label: nil)))

        let longLabel = String(repeating: "x", count: 80)
        let longLabelResult = GlanceCardParser.parse(#"[CARD:{"kind":"timer","seconds":60,"label":"\#(longLabel)"}]"#)
        guard case let .timer(timerRequest)? = longLabelResult.request else {
            return XCTFail("expected a timer request")
        }
        XCTAssertEqual(timerRequest.label?.count, 40)
    }

    // MARK: - Duration formatting

    func testCountdownTextRoundsUpAndFormatsMinutesAndHours() {
        XCTAssertEqual(WispTimerDurationFormatter.countdownText(remainingSeconds: 300), "5:00")
        // Part-way through the first second it still shows the full length.
        XCTAssertEqual(WispTimerDurationFormatter.countdownText(remainingSeconds: 299.4), "5:00")
        XCTAssertEqual(WispTimerDurationFormatter.countdownText(remainingSeconds: 299), "4:59")
        XCTAssertEqual(WispTimerDurationFormatter.countdownText(remainingSeconds: 9), "0:09")
        XCTAssertEqual(WispTimerDurationFormatter.countdownText(remainingSeconds: 3723), "1:02:03")
        XCTAssertEqual(WispTimerDurationFormatter.countdownText(remainingSeconds: 0), "0:00")
        XCTAssertEqual(WispTimerDurationFormatter.countdownText(remainingSeconds: -5), "0:00")
    }

    func testSpokenDurationTextIsNaturalAndPluralisedCorrectly() {
        XCTAssertEqual(WispTimerDurationFormatter.spokenDurationText(totalSeconds: 45), "45 seconds")
        XCTAssertEqual(WispTimerDurationFormatter.spokenDurationText(totalSeconds: 1), "1 second")
        XCTAssertEqual(WispTimerDurationFormatter.spokenDurationText(totalSeconds: 60), "1 minute")
        XCTAssertEqual(WispTimerDurationFormatter.spokenDurationText(totalSeconds: 300), "5 minutes")
        XCTAssertEqual(WispTimerDurationFormatter.spokenDurationText(totalSeconds: 150), "2 minutes 30 seconds")
        XCTAssertEqual(WispTimerDurationFormatter.spokenDurationText(totalSeconds: 5400), "1 hour 30 minutes")
        XCTAssertEqual(WispTimerDurationFormatter.spokenDurationText(totalSeconds: 7200), "2 hours")
        XCTAssertEqual(WispTimerDurationFormatter.spokenDurationText(totalSeconds: 0), "0 seconds")
    }

    func testTimerRemainingAndFractionAreClamped() {
        let startDate = Date(timeIntervalSince1970: 1_000_000)
        let timer = WispTimer(id: UUID(), label: nil, durationSeconds: 100, startDate: startDate, status: .running)

        XCTAssertEqual(timer.remainingSeconds(at: startDate.addingTimeInterval(25)), 75)
        XCTAssertEqual(timer.fractionRemaining(at: startDate.addingTimeInterval(25)), 0.75, accuracy: 0.0001)
        XCTAssertEqual(timer.remainingSeconds(at: startDate.addingTimeInterval(500)), 0)
        XCTAssertEqual(timer.fractionRemaining(at: startDate.addingTimeInterval(-10)), 1)
    }

    // MARK: - Reminder filtering

    /// A fixed Gregorian calendar in UTC so the day boundaries in these tests do
    /// not depend on where the tests run.
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2026-09-24 14:00 UTC.
    private let referenceNow = Date(timeIntervalSince1970: 1_790_258_400)

    private func reminder(
        _ title: String,
        dueInHours hoursFromNow: Double?,
        isAllDay: Bool = false
    ) -> RemindersGlanceReminder {
        var dueDate = hoursFromNow.map { referenceNow.addingTimeInterval($0 * 3600) }
        if isAllDay, let timedDueDate = dueDate {
            dueDate = utcCalendar.startOfDay(for: timedDueDate)
        }
        return RemindersGlanceReminder(
            id: title,
            title: title,
            dueDate: dueDate,
            isDueDateAllDay: isAllDay,
            listName: "Inbox",
            listColorHex: nil
        )
    }

    private var sampleReminders: [RemindersGlanceReminder] {
        [
            reminder("undated", dueInHours: nil),
            reminder("next week", dueInHours: 24 * 7),
            reminder("later today", dueInHours: 3),
            reminder("yesterday", dueInHours: -24),
            reminder("an hour ago", dueInHours: -1),
            // Due today as a whole day: not overdue until today has passed.
            reminder("today all day", dueInHours: 0, isAllDay: true),
            reminder("tomorrow", dueInHours: 24),
        ]
    }

    private func selectedTitles(_ filter: RemindersFilter, maximumCount: Int = 10) -> [String] {
        RemindersSelection.selectReminders(
            from: sampleReminders,
            filter: filter,
            now: referenceNow,
            maximumCount: maximumCount,
            calendar: utcCalendar
        ).map(\.title)
    }

    func testOverdueFilterKeepsOnlyPastDueAndTreatsAllDayAsDueUntilTheDayEnds() {
        XCTAssertEqual(selectedTitles(.overdue), ["yesterday", "an hour ago"])
    }

    func testTodayFilterKeepsOverdueAndDueTodayInDueOrder() {
        XCTAssertEqual(
            selectedTitles(.today),
            ["yesterday", "today all day", "an hour ago", "later today"]
        )
    }

    func testAllFilterOrdersDatedFirstThenUndatedAndRespectsTheCap() {
        XCTAssertEqual(
            selectedTitles(.all),
            ["yesterday", "today all day", "an hour ago", "later today", "tomorrow", "next week", "undated"]
        )
        XCTAssertEqual(selectedTitles(.all, maximumCount: 2), ["yesterday", "today all day"])
    }

    func testListNameMatchingIgnoresCaseDiacriticsAndWhitespace() {
        XCTAssertTrue(RemindersSelection.listName("Groceries", matchesRequestedName: " groceries "))
        XCTAssertTrue(RemindersSelection.listName("Café", matchesRequestedName: "cafe"))
        XCTAssertFalse(RemindersSelection.listName("Groceries", matchesRequestedName: "grocery"))
        XCTAssertFalse(RemindersSelection.listName("Groceries", matchesRequestedName: "   "))
    }

    // MARK: - create_reminder due dates

    func testDueDateParserReadsZonedLocalAndDateOnlyForms() throws {
        let utc = TimeZone(identifier: "UTC")!

        let zoned = try XCTUnwrap(ReminderDueDateParser.parse("2026-09-25T15:00:00Z", timeZone: utc))
        XCTAssertTrue(zoned.includesTimeOfDay)
        XCTAssertEqual(zoned.date, Date(timeIntervalSince1970: 1_790_348_400))

        let localWithoutSeconds = try XCTUnwrap(ReminderDueDateParser.parse("2026-09-25T15:00", timeZone: utc))
        XCTAssertTrue(localWithoutSeconds.includesTimeOfDay)
        XCTAssertEqual(localWithoutSeconds.date, zoned.date)

        let dateOnly = try XCTUnwrap(ReminderDueDateParser.parse("2026-09-25", timeZone: utc))
        XCTAssertFalse(dateOnly.includesTimeOfDay)
        XCTAssertEqual(dateOnly.date, Date(timeIntervalSince1970: 1_790_294_400))
    }

    func testDueDateParserRejectsUnreadableText() {
        XCTAssertNil(ReminderDueDateParser.parse("tomorrow at 3"))
        XCTAssertNil(ReminderDueDateParser.parse(""))
    }
}
