//
//  ToolCallSafetyTests.swift
//  leanring-buddyTests
//
//  Proves the destructive-action floor under session auto-approve: calls that
//  send, post, delete, pay or write outside the agent folder keep asking,
//  while reads and ordinary writes inside the agent folder stay auto-approved.
//  Also covers Composio's gateway, whose wrapper name says nothing — only the
//  unwrapped tool slugs decide.
//

import XCTest
@testable import Wisp

@MainActor
final class ToolCallSafetyTests: XCTestCase {

    private let agentWorkingDirectoryPath = "/Users/tester/Projects/app"

    private func mustAsk(_ toolName: String, _ toolInput: JSONValue = .object([:])) -> Bool {
        ToolCallSafety.mustAskEvenWithSessionAutoApprove(
            toolName: toolName,
            toolInput: toolInput,
            agentWorkingDirectoryPath: agentWorkingDirectoryPath
        )
    }

    private func composioExecute(_ toolItems: [(slug: String, arguments: [String: JSONValue])]) -> JSONValue {
        .object([
            "tools": .array(toolItems.map { toolItem in
                .object(["tool_slug": .string(toolItem.slug), "arguments": .object(toolItem.arguments)])
            }),
            "sync_response_to_workbench": .bool(false)
        ])
    }

    // MARK: - Irreversible by name

    func testSendingPostingDeletingAndPayingAlwaysAsk() {
        XCTAssertTrue(mustAsk("gmail__send_email"))
        XCTAssertTrue(mustAsk("slack__chat.postMessage"))
        XCTAssertTrue(mustAsk("github__delete_repository"))
        XCTAssertTrue(mustAsk("stripe__create_payment"))
        XCTAssertTrue(mustAsk("drive__share_file"))
        XCTAssertTrue(mustAsk("calendar__invite_attendee"))
        XCTAssertTrue(mustAsk("github__merge_pull_request"))
        XCTAssertTrue(mustAsk("reddit__create_post"))
    }

    func testReadingToolsStayAutoApproved() {
        XCTAssertFalse(mustAsk("gmail__list_emails"))
        XCTAssertFalse(mustAsk("reddit__get_post"), "a post that is only read is not a post that is made")
        XCTAssertFalse(mustAsk("shop__get_order"))
        XCTAssertFalse(mustAsk("read_page"))
        XCTAssertFalse(mustAsk("github__create_issue"), "an ordinary create stays auto-approved")
    }

    func testArbitraryCommandExecutionAsks() {
        XCTAssertTrue(mustAsk("terminal__run_command", .object(["command": .string("ls")])))
        XCTAssertTrue(mustAsk("shell__exec"))
    }

    // MARK: - Calendar

    func testEventWithGuestsAsksBecauseItSendsInvitations() {
        let eventWithGuests: JSONValue = .object([
            "summary": .string("Sync"),
            "attendees": .array([.string("ada@example.com")])
        ])
        XCTAssertTrue(mustAsk("calendar__create_event", eventWithGuests))
    }

    func testPrivateEventStaysAutoApproved() {
        XCTAssertFalse(mustAsk("calendar__create_event", .object(["summary": .string("Focus time")])))
    }

    // MARK: - Files

    func testWriteInsideAgentFolderStaysAutoApproved() {
        let insideWrite: JSONValue = .object([
            "path": .string("/Users/tester/Projects/app/notes.md"),
            "content": .string("hello")
        ])
        XCTAssertFalse(mustAsk("filesystem__write_file", insideWrite))
        XCTAssertFalse(mustAsk("filesystem__write_file", .object(["path": .string("docs/readme.md")])),
                       "a relative path resolves against the agent folder")
    }

    func testWriteOutsideAgentFolderAsks() {
        XCTAssertTrue(mustAsk("filesystem__write_file", .object(["path": .string("/Users/tester/.zshrc")])))
        XCTAssertTrue(mustAsk("filesystem__write_file", .object(["path": .string("../other/secret.txt")])),
                      "climbing out of the agent folder with .. is still outside")
        XCTAssertTrue(mustAsk("filesystem__write_file", .object(["path": .string("/Users/tester/Projects/app-other/x")])),
                      "a sibling folder sharing the prefix is not inside")
        XCTAssertTrue(mustAsk("filesystem__move_file", .object([
            "source": .string("/Users/tester/Projects/app/a.txt"),
            "destination": .string("/Users/tester/Desktop/a.txt")
        ])))
    }

    func testDeletingAFileAsksEvenInsideAgentFolder() {
        XCTAssertTrue(mustAsk("filesystem__delete_file", .object(["path": .string("/Users/tester/Projects/app/a.txt")])))
    }

    func testPathContainmentHelper() {
        XCTAssertTrue(ToolCallInspection.isPath("/a/b/c", insideDirectory: "/a/b"))
        XCTAssertTrue(ToolCallInspection.isPath("/a/b", insideDirectory: "/a/b/"))
        XCTAssertFalse(ToolCallInspection.isPath("/a/bc", insideDirectory: "/a/b"))
        XCTAssertFalse(ToolCallInspection.isPath("/a/b/../c", insideDirectory: "/a/b"))
    }

    // MARK: - Composio

    func testComposioExecuteOfSendAsks() {
        let sendEmail = composioExecute([(slug: "GMAIL_SEND_EMAIL", arguments: ["to": .string("ada@example.com")])])
        XCTAssertTrue(mustAsk("composio-connect__COMPOSIO_MULTI_EXECUTE_TOOL", sendEmail))
    }

    func testComposioExecuteOfReadsStaysAutoApproved() {
        let reads = composioExecute([
            (slug: "GMAIL_FETCH_EMAILS", arguments: ["max_results": .number(5)]),
            (slug: "GOOGLECALENDAR_LIST_EVENTS", arguments: [:])
        ])
        XCTAssertFalse(mustAsk("composio-connect__COMPOSIO_MULTI_EXECUTE_TOOL", reads))
    }

    func testComposioBatchAsksWhenAnyItemIsIrreversible() {
        let mixed = composioExecute([
            (slug: "GMAIL_FETCH_EMAILS", arguments: [:]),
            (slug: "SLACK_SEND_MESSAGE", arguments: ["channel": .string("#general"), "text": .string("hi")])
        ])
        XCTAssertTrue(mustAsk("composio-connect__COMPOSIO_MULTI_EXECUTE_TOOL", mixed))
    }

    func testUnreadableComposioExecuteAsks() {
        XCTAssertTrue(mustAsk("composio-connect__COMPOSIO_MULTI_EXECUTE_TOOL", .object(["tools": .string("oops")])))
    }

    func testComposioInnerArgumentsMayArriveAsAJSONString() {
        let stringArguments: JSONValue = .object([
            "tools": .array([.object([
                "tool_slug": .string("GMAIL_SEND_EMAIL"),
                "arguments": .string("{\"to\":\"ada@example.com\",\"subject\":\"Hi\"}")
            ])])
        ])
        let actions = ToolCallInspection.composioExecutedActions(in: stringArguments)
        XCTAssertEqual(actions?.first?.bareActionName, "GMAIL_SEND_EMAIL")
        XCTAssertEqual(ToolCallInspection.stringValue(forAnyOf: ["subject"], in: actions?.first?.arguments ?? .null), "Hi")
    }

    func testComposioLookupMetaToolsStayAutoApprovedButRemoteCodeAsks() {
        XCTAssertFalse(mustAsk("composio-connect__COMPOSIO_SEARCH_TOOLS"))
        XCTAssertFalse(mustAsk("composio-connect__COMPOSIO_GET_TOOL_SCHEMAS"))
        XCTAssertFalse(mustAsk("composio-connect__COMPOSIO_MANAGE_CONNECTIONS"))
        XCTAssertTrue(mustAsk("composio-connect__COMPOSIO_REMOTE_BASH_TOOL"))
        XCTAssertTrue(mustAsk("composio-connect__COMPOSIO_REMOTE_WORKBENCH"))
    }

    // MARK: - Name splitting

    func testIdentifierWordSplitting() {
        XCTAssertEqual(ToolCallInspection.words(inIdentifier: "chat.postMessage"), ["chat", "post", "message"])
        XCTAssertEqual(ToolCallInspection.words(inIdentifier: "GMAIL_SEND_EMAIL"), ["gmail", "send", "email"])
        XCTAssertEqual(ToolCallInspection.bareToolName("composio-connect__COMPOSIO_SEARCH_TOOLS"), "COMPOSIO_SEARCH_TOOLS")
        XCTAssertEqual(ToolCallInspection.serverNamespace(of: "filesystem__write_file"), "filesystem")
        XCTAssertNil(ToolCallInspection.serverNamespace(of: "read_page"))
    }
}
