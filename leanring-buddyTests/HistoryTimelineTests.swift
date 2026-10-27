//
//  HistoryTimelineTests.swift
//  leanring-buddyTests
//
//  Proves the History filters pick the right records, that routine, skill and
//  dictation entries aren't treated as the user's own question, and that a
//  question becomes a short routine name.
//

import XCTest
@testable import Wisp

@MainActor
final class HistoryTimelineTests: XCTestCase {

    private func record(
        title: String,
        status: AgentTaskRecord.Status = .succeeded,
        steps: [AgentStepRecord] = [],
        finalText: String? = nil
    ) -> AgentTaskRecord {
        AgentTaskRecord(title: title, status: status, steps: steps, finalText: finalText)
    }

    func testAnswersFilterNeedsASuccessfulNonEmptyAnswer() {
        XCTAssertTrue(HistoryTab.HistoryFilter.answers.includes(record(title: "q", finalText: "a")))
        XCTAssertFalse(HistoryTab.HistoryFilter.answers.includes(record(title: "q", finalText: "  ")))
        XCTAssertFalse(HistoryTab.HistoryFilter.answers.includes(record(title: "q", status: .failed("x"), finalText: "a")))
    }

    func testBrowserAndToolsFiltersReadTheSteps() {
        let browserRecord = record(title: "open github", steps: [
            AgentStepRecord(kind: .tool(name: "browser_task"), summary: "opened"),
        ])
        let fileToolRecord = record(title: "list files", steps: [
            AgentStepRecord(kind: .tool(name: "list_directory"), summary: "listed"),
        ])
        let modelOnlyRecord = record(title: "hi", steps: [AgentStepRecord(kind: .modelCall, summary: "answered")])

        XCTAssertTrue(HistoryTab.HistoryFilter.browser.includes(browserRecord))
        XCTAssertFalse(HistoryTab.HistoryFilter.browser.includes(fileToolRecord))
        XCTAssertTrue(HistoryTab.HistoryFilter.tools.includes(browserRecord))
        XCTAssertTrue(HistoryTab.HistoryFilter.tools.includes(fileToolRecord))
        XCTAssertFalse(HistoryTab.HistoryFilter.tools.includes(modelOnlyRecord))
    }

    func testNeedsAttentionFilter() {
        XCTAssertTrue(HistoryTab.HistoryFilter.needsAttention.includes(record(title: "q", status: .failed("x"))))
        XCTAssertTrue(HistoryTab.HistoryFilter.needsAttention.includes(record(title: "q", status: .interrupted)))
        XCTAssertTrue(HistoryTab.HistoryFilter.needsAttention.includes(record(title: "q", status: .waitingForApproval)))
        XCTAssertFalse(HistoryTab.HistoryFilter.needsAttention.includes(record(title: "q", status: .cancelled)))
        XCTAssertFalse(HistoryTab.HistoryFilter.needsAttention.includes(record(title: "q")))
    }

    func testOnlyTheUsersOwnQuestionsCountAsQuestions() {
        XCTAssertTrue(record(title: "how do I split this window?").isUsersOwnQuestion)
        XCTAssertFalse(record(title: AgentTaskRecord.routineRunTitlePrefix + "Summarize this page").isUsersOwnQuestion)
        XCTAssertFalse(record(title: AgentTaskRecord.skillRunTitlePrefix + "animate").isUsersOwnQuestion)
        XCTAssertFalse(record(title: AgentTaskRecord.dictationTitlePrefix + "Notes").isUsersOwnQuestion)
    }

    func testRoutineNameFromQuestion() {
        XCTAssertEqual(HistoryTab.routineName(fromQuestion: "what's the weather in lisbon?"),
                       "What's the weather in lisbon")
        XCTAssertEqual(HistoryTab.routineName(fromQuestion: "summarize the unread emails from my team this morning please"),
                       "Summarize the unread emails from my…")
        XCTAssertEqual(HistoryTab.routineName(fromQuestion: "   ?  "), "New routine")
    }
}
