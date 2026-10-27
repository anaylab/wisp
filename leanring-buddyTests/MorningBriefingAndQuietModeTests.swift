//
//  MorningBriefingAndQuietModeTests.swift
//  leanring-buddyTests
//
//  Proves the morning banner offers the right things in the right order,
//  appears at most once a day while the user is at the Mac, and that quiet
//  mode ignores Wisp itself and the always-listening system services.
//

import XCTest
@testable import Wisp

@MainActor
final class MorningBriefingAndQuietModeTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private var gregorianCalendarInUTC: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: - Suggestions

    func testMeetingsAndRemindersLeadThenPinnedThenRecentRoutines() {
        let pinnedRoutine = WispRoutine(name: "Pinned", instruction: "p", isPinnedInNotch: true)
        let recentlyUsedRoutine = WispRoutine(
            name: "Recent",
            instruction: "r",
            lastRunAt: now.addingTimeInterval(-60 * 60)
        )
        let suggestions = MorningSuggestionBuilder.buildSuggestions(
            routines: [recentlyUsedRoutine, pinnedRoutine],
            remainingMeetingCountToday: 3,
            hasRemindersAccess: true,
            now: now
        )

        XCTAssertEqual(suggestions.map(\.title), [
            "Go over today's 3 meetings",
            "Check what's due today",
            "Pinned",
            "Recent",
        ])
        XCTAssertEqual(suggestions[0].action, .askQuestion("What's on my calendar today?"))
        XCTAssertEqual(suggestions[2].action, .runRoutine(routineID: pinnedRoutine.id))
    }

    func testSingleMeetingIsPhrasedInTheSingular() {
        let suggestions = MorningSuggestionBuilder.buildSuggestions(
            routines: [],
            remainingMeetingCountToday: 1,
            hasRemindersAccess: false,
            now: now
        )
        XCTAssertEqual(suggestions.map(\.title), ["Go over today's meeting"])
    }

    func testNoCalendarAccessOrClearDayOffersNoMeetingSuggestion() {
        for remainingMeetingCountToday in [nil, 0] as [Int?] {
            let suggestions = MorningSuggestionBuilder.buildSuggestions(
                routines: [],
                remainingMeetingCountToday: remainingMeetingCountToday,
                hasRemindersAccess: false,
                now: now
            )
            XCTAssertTrue(suggestions.isEmpty)
        }
    }

    func testForgottenUnpinnedRoutinesAreLeftOut() {
        let neverRunRoutine = WispRoutine(name: "Never", instruction: "n")
        let longAgoRoutine = WispRoutine(
            name: "Old",
            instruction: "o",
            lastRunAt: now.addingTimeInterval(-30 * 24 * 60 * 60)
        )
        let suggestions = MorningSuggestionBuilder.buildSuggestions(
            routines: [neverRunRoutine, longAgoRoutine],
            remainingMeetingCountToday: nil,
            hasRemindersAccess: false,
            now: now
        )
        XCTAssertTrue(suggestions.isEmpty)
    }

    func testSuggestionsAreCapped() {
        let pinnedRoutines = (0..<12).map { routineIndex in
            WispRoutine(name: "Routine \(routineIndex)", instruction: "i", isPinnedInNotch: true)
        }
        let suggestions = MorningSuggestionBuilder.buildSuggestions(
            routines: pinnedRoutines,
            remainingMeetingCountToday: 2,
            hasRemindersAccess: true,
            now: now
        )
        XCTAssertEqual(suggestions.count, MorningSuggestionBuilder.maximumSuggestions)
    }

    // MARK: - Schedule

    private func date(hour: Int, day: Int = 25) -> Date {
        gregorianCalendarInUTC.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: 30))!
    }

    func testPresentsOnceADayWhileTheUserIsActiveDuringTheDay() {
        let calendar = gregorianCalendarInUTC
        XCTAssertTrue(MorningBriefingSchedule.shouldPresent(
            now: date(hour: 9), calendar: calendar, lastPresentedDayKey: "2026-09-24", secondsSinceLastUserInput: 5
        ))
        XCTAssertFalse(MorningBriefingSchedule.shouldPresent(
            now: date(hour: 9), calendar: calendar, lastPresentedDayKey: "2026-09-25", secondsSinceLastUserInput: 5
        ), "already shown today")
        XCTAssertTrue(MorningBriefingSchedule.shouldPresent(
            now: date(hour: 9), calendar: calendar, lastPresentedDayKey: nil, secondsSinceLastUserInput: 5
        ), "never shown before")
    }

    func testWaitsForTheUserAndStaysOutOfTheNightAndEvening() {
        let calendar = gregorianCalendarInUTC
        XCTAssertFalse(MorningBriefingSchedule.shouldPresent(
            now: date(hour: 9), calendar: calendar, lastPresentedDayKey: nil, secondsSinceLastUserInput: 600
        ), "nobody at the Mac")
        XCTAssertFalse(MorningBriefingSchedule.shouldPresent(
            now: date(hour: 3), calendar: calendar, lastPresentedDayKey: nil, secondsSinceLastUserInput: 5
        ))
        XCTAssertFalse(MorningBriefingSchedule.shouldPresent(
            now: date(hour: 19), calendar: calendar, lastPresentedDayKey: nil, secondsSinceLastUserInput: 5
        ))
    }

    func testDayKeyIsZeroPadded() {
        let calendar = gregorianCalendarInUTC
        let earlyMonthDate = calendar.date(from: DateComponents(year: 2026, month: 3, day: 4, hour: 10))!
        XCTAssertEqual(MorningBriefingSchedule.dayKey(for: earlyMonthDate, calendar: calendar), "2026-03-04")
    }

    // MARK: - Quiet mode

    func testWispsOwnDictationAndSiriDoNotCountAsACall() {
        let ownProcessIdentifier: pid_t = 4242
        let capturingProcesses = [
            QuietModeDetection.AudioInputCapturingProcess(processIdentifier: ownProcessIdentifier, bundleIdentifier: "com.example.wisp"),
            QuietModeDetection.AudioInputCapturingProcess(processIdentifier: 654, bundleIdentifier: "com.apple.CoreSpeech"),
        ]
        XCTAssertFalse(QuietModeDetection.isCallLikeMicrophoneCapture(
            among: capturingProcesses,
            excludingProcessIdentifier: ownProcessIdentifier
        ))
    }

    func testAnotherAppCapturingTheMicrophoneCountsAsACall() {
        let capturingProcesses = [
            QuietModeDetection.AudioInputCapturingProcess(processIdentifier: 777, bundleIdentifier: "us.zoom.xos"),
        ]
        XCTAssertTrue(QuietModeDetection.isCallLikeMicrophoneCapture(
            among: capturingProcesses,
            excludingProcessIdentifier: 4242
        ))
        // A command-line recorder has no bundle id but is still another process.
        let unbundledProcess = [QuietModeDetection.AudioInputCapturingProcess(processIdentifier: 778, bundleIdentifier: "")]
        XCTAssertTrue(QuietModeDetection.isCallLikeMicrophoneCapture(
            among: unbundledProcess,
            excludingProcessIdentifier: 4242
        ))
    }

    // MARK: - Finished work inbox

    func testInboxKeepsNewestFirstWithoutDuplicatesAndCaps() {
        let inbox = FinishedWorkInbox.shared
        inbox.markAllSeen()
        defer { inbox.markAllSeen() }

        let taskIDs = (0..<(FinishedWorkInbox.maximumUnseenResults + 2)).map { _ in UUID() }
        for taskID in taskIDs {
            inbox.recordFinishedTask(taskID)
        }
        inbox.recordFinishedTask(taskIDs[taskIDs.count - 2])

        XCTAssertEqual(inbox.unseenTaskIDs.count, FinishedWorkInbox.maximumUnseenResults)
        XCTAssertEqual(inbox.unseenTaskIDs.first, taskIDs[taskIDs.count - 2])
        XCTAssertEqual(Set(inbox.unseenTaskIDs).count, inbox.unseenTaskIDs.count)

        inbox.markAllSeen()
        XCTAssertTrue(inbox.unseenTaskIDs.isEmpty)
    }
}
