//
//  AgentTaskHistoryStoreTests.swift
//  leanring-buddyTests
//
//  Proves saved task history round-trips with its statuses and steps intact,
//  that a task still running at quit comes back as interrupted, and that
//  records past the retention period are dropped on load.
//

import XCTest
@testable import Wisp

final class AgentTaskHistoryStoreTests: XCTestCase {

    /// Whole seconds, because the file stores ISO-8601 dates without
    /// fractional seconds.
    private let referenceDate = Date(timeIntervalSince1970: 1_750_000_000)

    private func encodedHistory(_ records: [AgentTaskRecord]) throws -> Data {
        try XCTUnwrap(AgentTaskHistoryStore.encode(records))
    }

    func testRoundTripKeepsStatusesAndSteps() throws {
        let failedRecord = AgentTaskRecord(
            title: "compare flights",
            kind: .background,
            status: .failed("sign-in required"),
            steps: [
                AgentStepRecord(kind: .tool(name: "browser_task"), summary: "opened kayak.com",
                                startedAt: referenceDate, durationSeconds: 2.5, isError: false),
                AgentStepRecord(kind: .modelCall, summary: "planned", startedAt: referenceDate),
            ],
            startedAt: referenceDate,
            finishedAt: referenceDate.addingTimeInterval(30),
            finalText: nil
        )
        let succeededRecord = AgentTaskRecord(
            title: "how do I split this window?",
            status: .succeeded,
            startedAt: referenceDate,
            finishedAt: referenceDate.addingTimeInterval(3),
            finalText: "Hover the green button."
        )

        let loadedRecords = try XCTUnwrap(AgentTaskHistoryStore.decodeRecords(
            from: try encodedHistory([succeededRecord, failedRecord]),
            now: referenceDate.addingTimeInterval(60)
        ))

        XCTAssertEqual(loadedRecords.map(\.id), [succeededRecord.id, failedRecord.id], "order is kept")
        XCTAssertEqual(loadedRecords[0].status, .succeeded)
        XCTAssertEqual(loadedRecords[0].finalText, "Hover the green button.")
        XCTAssertEqual(loadedRecords[1].status, .failed("sign-in required"))
        XCTAssertEqual(loadedRecords[1].kind, .background)
        XCTAssertEqual(loadedRecords[1].steps.count, 2)
        XCTAssertEqual(loadedRecords[1].steps[0].kindLabel, "browser_task")
        XCTAssertEqual(loadedRecords[1].steps[0].durationSeconds, 2.5)
        XCTAssertEqual(loadedRecords[1].steps[1].kindLabel, "model")
    }

    func testTaskRunningAtQuitComesBackInterrupted() throws {
        let runningRecord = AgentTaskRecord(title: "still going", status: .running, startedAt: referenceDate)
        let waitingRecord = AgentTaskRecord(title: "needs ok", status: .waitingForApproval, startedAt: referenceDate)

        let loadedRecords = try XCTUnwrap(AgentTaskHistoryStore.decodeRecords(
            from: try encodedHistory([runningRecord, waitingRecord]),
            now: referenceDate.addingTimeInterval(60)
        ))

        XCTAssertEqual(loadedRecords.map(\.status), [.interrupted, .interrupted])
        XCTAssertTrue(loadedRecords.allSatisfy { $0.status.isTerminal })
        XCTAssertEqual(loadedRecords[0].finishedAt, referenceDate, "an interrupted task gets an end date")
    }

    func testRecordsPastRetentionAreDropped() throws {
        let retention = AgentTaskHistoryStore.retentionPeriodSeconds
        let now = referenceDate.addingTimeInterval(retention + 3600)
        let expiredRecord = AgentTaskRecord(
            title: "old", status: .succeeded,
            startedAt: referenceDate, finishedAt: referenceDate
        )
        let recentRecord = AgentTaskRecord(
            title: "recent", status: .succeeded,
            startedAt: now.addingTimeInterval(-60), finishedAt: now.addingTimeInterval(-50)
        )

        let loadedRecords = try XCTUnwrap(AgentTaskHistoryStore.decodeRecords(
            from: try encodedHistory([recentRecord, expiredRecord]),
            now: now
        ))

        XCTAssertEqual(loadedRecords.map(\.title), ["recent"])
    }

    func testUnreadableDataYieldsNil() {
        XCTAssertNil(AgentTaskHistoryStore.decodeRecords(from: Data("not json".utf8), now: referenceDate))
        XCTAssertNil(AgentTaskHistoryStore.decodeRecords(
            from: Data(#"{"formatVersion": 99, "records": []}"#.utf8),
            now: referenceDate
        ), "an unknown format version is not guessed at")
    }
}
