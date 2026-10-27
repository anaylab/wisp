//
//  NotchConversationSessionTests.swift
//  leanring-buddyTests
//
//  Proves the notch chat's sidebar splits exchanges into conversations at a
//  half-hour pause, lists them newest first, leaves out dictation and
//  background work, and searches questions and answers.
//

import XCTest
@testable import Wisp

@MainActor
final class NotchConversationSessionTests: XCTestCase {

    private let startDate = Date(timeIntervalSince1970: 1_750_000_000)

    private func exchange(
        _ title: String,
        minutesAfterStart: Double,
        answer: String? = nil,
        kind: AgentTaskRecord.Kind = .interactive,
        status: AgentTaskRecord.Status = .succeeded
    ) -> AgentTaskRecord {
        AgentTaskRecord(
            title: title,
            kind: kind,
            status: status,
            startedAt: startDate.addingTimeInterval(minutesAfterStart * 60),
            finalText: answer
        )
    }

    func testAHalfHourPauseStartsANewConversationAndNewestComesFirst() {
        let records = [
            exchange("first", minutesAfterStart: 0),
            exchange("follow-up", minutesAfterStart: 10),
            exchange("much later", minutesAfterStart: 60),
        ]
        let sessions = NotchConversationSessionGrouper.sessions(from: records)

        XCTAssertEqual(sessions.map(\.title), ["much later", "first"])
        XCTAssertEqual(sessions[1].exchanges.map(\.title), ["first", "follow-up"], "oldest first within a thread")
        XCTAssertEqual(sessions[1].id, records[0].id)
    }

    func testRegistryOrderDoesNotMatter() {
        // The registry holds records newest first.
        let records = [
            exchange("second", minutesAfterStart: 5),
            exchange("first", minutesAfterStart: 0),
        ]
        let sessions = NotchConversationSessionGrouper.sessions(from: records)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].exchanges.map(\.title), ["first", "second"])
    }

    func testDictationAndBackgroundTasksAreLeftOut() {
        let records = [
            exchange(AgentTaskRecord.dictationTitlePrefix + "Notes", minutesAfterStart: 0),
            exchange("background job", minutesAfterStart: 1, kind: .background),
            exchange("a real question", minutesAfterStart: 2),
        ]
        let sessions = NotchConversationSessionGrouper.sessions(from: records)
        XCTAssertEqual(sessions.flatMap(\.exchanges).map(\.title), ["a real question"])
    }

    func testPreviewShowsTheLatestAnswerOrItsStatus() {
        let answeredSession = NotchConversationSessionGrouper.sessions(from: [
            exchange("q", minutesAfterStart: 0, answer: "  four  "),
        ])
        XCTAssertEqual(answeredSession[0].latestAnswerPreview, "four")

        let runningSession = NotchConversationSessionGrouper.sessions(from: [
            exchange("q", minutesAfterStart: 0, status: .running),
        ])
        XCTAssertEqual(runningSession[0].latestAnswerPreview, "Working on it…")
    }

    func testSearchMatchesQuestionsAndAnswersIgnoringCase() {
        let sessions = NotchConversationSessionGrouper.sessions(from: [
            exchange("What's the weather", minutesAfterStart: 0, answer: "Sunny"),
            exchange("Summarize my inbox", minutesAfterStart: 90, answer: "Three emails from Café Ada"),
        ])
        XCTAssertEqual(NotchConversationSessionGrouper.sessions(sessions, matching: "WEATHER").map(\.title), ["What's the weather"])
        XCTAssertEqual(NotchConversationSessionGrouper.sessions(sessions, matching: "cafe").map(\.title), ["Summarize my inbox"])
        XCTAssertEqual(NotchConversationSessionGrouper.sessions(sessions, matching: "  ").count, 2)
    }
}
