//
//  BuddyTests.swift
//  leanring-buddyTests
//
//  Proves buddies are named sensibly from their job, pick up a schedule from
//  its wording, compute their next run, run on time (once per due slot, and
//  retry when they can't start), and that stored answers are shown without
//  Wisp's machine tags.
//

import XCTest
@testable import Wisp

@MainActor
final class BuddyTests: XCTestCase {

    private var gregorianCalendarInUTC: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func makeTemporaryStore() -> BuddyStore {
        let temporaryFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddies-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: temporaryFileURL) }
        return BuddyStore(buddiesFileURL: temporaryFileURL)
    }

    // MARK: - Names

    func testNameUsesAProperNounAndARoleFromTheVerb() {
        XCTAssertEqual(
            BuddyNameGenerator.name(forInstruction: "Every morning, summarize what's new on Hacker News", existingNames: []),
            "Hacker News Digest"
        )
        XCTAssertEqual(
            BuddyNameGenerator.name(forInstruction: "check my Gmail for anything from the bank", existingNames: []),
            "Gmail Watch"
        )
    }

    func testNameFallsBackToAMeaningfulWordAndStaysUnique() {
        XCTAssertEqual(
            BuddyNameGenerator.name(forInstruction: "find cheap flights to lisbon", existingNames: []),
            "Cheap Scout"
        )
        XCTAssertEqual(
            BuddyNameGenerator.name(forInstruction: "check my Gmail", existingNames: ["Gmail Watch"]),
            "Gmail Watch 2"
        )
    }

    // MARK: - Schedules

    func testScheduleIsInferredFromTheWording() {
        XCTAssertEqual(BuddySchedule.inferred(fromInstruction: "Every morning, recap my inbox"), .daily(hour: 9, minute: 0))
        XCTAssertEqual(BuddySchedule.inferred(fromInstruction: "each night list tomorrow's meetings"), .daily(hour: 18, minute: 0))
        XCTAssertEqual(BuddySchedule.inferred(fromInstruction: "Every Friday, summarize the week"), .weekly(weekday: 6, hour: 9, minute: 0))
        XCTAssertEqual(BuddySchedule.inferred(fromInstruction: "weekly: check for app updates"), .weekly(weekday: 2, hour: 9, minute: 0))
        XCTAssertEqual(BuddySchedule.inferred(fromInstruction: "find me a good pasta recipe"), .once)
    }

    func testNextRunDates() {
        let calendar = gregorianCalendarInUTC
        // Friday 25 September 2026, 20:30 UTC.
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 20, minute: 30))!

        XCTAssertNil(BuddySchedule.once.nextRunDate(after: now, calendar: calendar))
        XCTAssertEqual(
            BuddySchedule.daily(hour: 9, minute: 0).nextRunDate(after: now, calendar: calendar),
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 9))
        )
        XCTAssertEqual(
            BuddySchedule.daily(hour: 21, minute: 0).nextRunDate(after: now, calendar: calendar),
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 21)),
            "later today"
        )
        XCTAssertEqual(
            BuddySchedule.weekly(weekday: 2, hour: 9, minute: 0).nextRunDate(after: now, calendar: calendar),
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 9)),
            "next Monday"
        )
    }

    // MARK: - Store

    func testOneOffBuddyRunsRightAwayAndRepeatingOneWaits() {
        let store = makeTemporaryStore()
        var startedInstructions: [String] = []
        store.start { buddy in
            startedInstructions.append(buddy.instruction)
            return UUID()
        }

        let oneOffBuddy = store.createBuddy(instruction: "find a pasta recipe", schedule: .once, runImmediately: false)
        let repeatingBuddy = store.createBuddy(instruction: "summarize my inbox", schedule: .daily(hour: 9, minute: 0), runImmediately: false)

        XCTAssertEqual(startedInstructions, ["find a pasta recipe"])
        XCTAssertEqual(store.buddy(withID: oneOffBuddy.id)?.runTaskIDs.count, 1)
        XCTAssertNotNil(store.buddy(withID: repeatingBuddy.id)?.nextScheduledRunAt)
        XCTAssertNotEqual(oneOffBuddy.colorIndex, repeatingBuddy.colorIndex, "each new buddy gets a fresh colour")
    }

    func testDueBuddyRunsOnceAndAdvancesAndRetriesWhenItCannotStart() {
        let store = makeTemporaryStore()
        var canStartRuns = false
        var startCount = 0
        store.start { _ in
            guard canStartRuns else { return nil }
            startCount += 1
            return UUID()
        }
        let buddy = store.createBuddy(instruction: "recap my inbox", schedule: .daily(hour: 9, minute: 0), runImmediately: false)
        let dueDate = store.buddy(withID: buddy.id)!.nextScheduledRunAt!
        let afterDueDate = dueDate.addingTimeInterval(60)

        // Busy: nothing starts, and it stays due.
        store.runDueBuddies(now: afterDueDate)
        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(store.buddy(withID: buddy.id)?.nextScheduledRunAt, dueDate)

        // Free: it runs once and moves to the next day.
        canStartRuns = true
        store.runDueBuddies(now: afterDueDate)
        XCTAssertEqual(startCount, 1)
        XCTAssertGreaterThan(store.buddy(withID: buddy.id)!.nextScheduledRunAt!, afterDueDate)

        store.runDueBuddies(now: afterDueDate)
        XCTAssertEqual(startCount, 1, "not twice for the same slot")
    }

    func testBuddiesPersistAcrossStores() {
        let temporaryFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddies-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporaryFileURL) }

        let firstStore = BuddyStore(buddiesFileURL: temporaryFileURL)
        let createdBuddy = firstStore.createBuddy(instruction: "summarize my inbox", schedule: .weekly(weekday: 2, hour: 8, minute: 30), runImmediately: false)
        firstStore.rename(buddyWithID: createdBuddy.id, to: "Inbox Pal")

        let reloadedStore = BuddyStore(buddiesFileURL: temporaryFileURL)
        XCTAssertEqual(reloadedStore.buddies.first?.name, "Inbox Pal")
        XCTAssertEqual(reloadedStore.buddies.first?.schedule, .weekly(weekday: 2, hour: 8, minute: 30))
    }

    // MARK: - Answer display

    func testMachineTagsAreRemovedButOtherBracketsStay() {
        XCTAssertEqual(
            AnswerDisplayText.cleaned("Click the clicky button. [POINT:a83:clicky]"),
            "Click the clicky button."
        )
        XCTAssertEqual(
            AnswerDisplayText.cleaned("It's sunny [SAY: it's sunny] today. [CARD:{\"kind\":\"weather\",\"list\":[1,2]}]"),
            "It's sunny today."
        )
        XCTAssertEqual(AnswerDisplayText.cleaned("See step [2] below"), "See step [2] below")
    }
}
