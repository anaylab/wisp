//
//  ToolConfirmationCardBuilderTests.swift
//  leanring-buddyTests
//
//  Proves the confirmation panel's card describes the call that will run:
//  a mail send becomes "New Email" with its recipient and subject, an event
//  shows its time and guests, a file write shows the file and flags a write
//  outside the agent folder, a Composio-wrapped call is unwrapped to its real
//  tool — and an unrecognised tool gets no card at all, so the panel falls
//  back to the plain summary exactly as before.
//

import XCTest
@testable import Wisp

@MainActor
final class ToolConfirmationCardBuilderTests: XCTestCase {

    private let agentWorkingDirectoryPath = "/Users/tester/Projects/app"

    private func card(_ toolName: String, _ toolInput: JSONValue) -> GlanceCard? {
        ToolConfirmationCardBuilder.confirmationCard(
            forToolNamed: toolName,
            toolInput: toolInput,
            agentWorkingDirectoryPath: agentWorkingDirectoryPath
        )
    }

    private func headerTitle(of card: GlanceCard?) -> String? {
        guard case .header(let title, _, _)? = card?.blocks.first else { return nil }
        return title
    }

    private func keyValuePairs(of card: GlanceCard?) -> [String: String] {
        var pairsByKey: [String: String] = [:]
        for block in card?.blocks ?? [] {
            if case .keyValue(let pairs) = block {
                for pair in pairs { pairsByKey[pair.key] = pair.value }
            }
        }
        return pairsByKey
    }

    private func listRowTexts(of card: GlanceCard?) -> [String] {
        (card?.blocks ?? []).flatMap { block -> [String] in
            if case .list(let rows) = block { return rows.map(\.text) }
            return []
        }
    }

    // MARK: - Mail

    func testSendEmailBecomesNewEmailCard() {
        let sendEmail = card("gmail__send_email", .object([
            "to": .string("ada@example.com"),
            "subject": .string("Lunch?"),
            "body": .string("Are you free\n\non Thursday?")
        ]))
        XCTAssertEqual(headerTitle(of: sendEmail), "New Email")
        XCTAssertEqual(keyValuePairs(of: sendEmail)["To"], "ada@example.com")
        XCTAssertEqual(keyValuePairs(of: sendEmail)["Subject"], "Lunch?")
        XCTAssertEqual(listRowTexts(of: sendEmail), ["Are you free on Thursday?"],
                       "the body preview collapses whitespace into one line")
    }

    func testLongBodyIsTruncated() {
        let longBody = String(repeating: "word ", count: 200)
        let sendEmail = card("gmail__send_email", .object(["to": .string("a@b.com"), "body": .string(longBody)]))
        let preview = listRowTexts(of: sendEmail).first ?? ""
        XCTAssertTrue(preview.hasSuffix("…"))
        XCTAssertLessThanOrEqual(preview.count, ToolConfirmationCardBuilder.maximumBodyPreviewCharacters + 1)
    }

    func testRecipientListIsJoined() {
        let sendEmail = card("mail__send_email", .object([
            "to": .array([.object(["email": .string("a@b.com")]), .string("c@d.com")]),
            "subject": .string("Hi")
        ]))
        XCTAssertEqual(keyValuePairs(of: sendEmail)["To"], "a@b.com, c@d.com")
    }

    // MARK: - Messages

    func testChatMessageBecomesNewMessageCard() {
        let chatMessage = card("slack__chat.postMessage", .object([
            "channel": .string("#general"),
            "text": .string("Deploy is done")
        ]))
        XCTAssertEqual(headerTitle(of: chatMessage), "New Message")
        XCTAssertEqual(keyValuePairs(of: chatMessage)["To"], "#general")
        XCTAssertEqual(listRowTexts(of: chatMessage), ["Deploy is done"])
    }

    // MARK: - Calendar

    func testCreateEventShowsTimeAndGuests() {
        let newEvent = card("calendar__create_event", .object([
            "summary": .string("Design review"),
            "start": .object(["dateTime": .string("2026-10-01T10:00:00")]),
            "end": .object(["dateTime": .string("2026-10-01T11:00:00")]),
            "attendees": .array([.object(["email": .string("ada@example.com")])])
        ]))
        XCTAssertEqual(headerTitle(of: newEvent), "New Event")
        let pairs = keyValuePairs(of: newEvent)
        XCTAssertEqual(pairs["Title"], "Design review")
        XCTAssertEqual(pairs["Starts"], "2026-10-01T10:00:00")
        XCTAssertEqual(pairs["Ends"], "2026-10-01T11:00:00")
        XCTAssertEqual(pairs["Guests"], "ada@example.com")
    }

    func testOutlookCalendarEventIsAnEventNotAnEmail() {
        let outlookEvent = card("composio__OUTLOOK_CALENDAR_CREATE_EVENT", .object([
            "subject": .string("Sync"),
            "start_datetime": .string("2026-10-01T10:00")
        ]))
        XCTAssertEqual(headerTitle(of: outlookEvent), "New Event")
    }

    // MARK: - Files

    func testWriteFileShowsFileAndFolder() {
        let fileWrite = card("filesystem__write_file", .object([
            "path": .string("/Users/tester/Projects/app/notes/todo.md"),
            "content": .string("- ship it")
        ]))
        XCTAssertEqual(headerTitle(of: fileWrite), "Write File")
        XCTAssertEqual(keyValuePairs(of: fileWrite)["File"], "todo.md")
        XCTAssertNil(keyValuePairs(of: fileWrite)["Location"], "inside the agent folder is not flagged")
        XCTAssertEqual(listRowTexts(of: fileWrite), ["- ship it"])
    }

    func testWriteOutsideAgentFolderIsFlagged() {
        let fileWrite = card("filesystem__write_file", .object([
            "path": .string("/etc/hosts"),
            "content": .string("127.0.0.1 example")
        ]))
        XCTAssertEqual(keyValuePairs(of: fileWrite)["Location"], "Outside agent folder")
    }

    func testDeleteFileGetsDeletionCardWithWarning() {
        let deletion = card("filesystem__delete_file", .object(["path": .string("/tmp/a.txt")]))
        XCTAssertEqual(headerTitle(of: deletion), "Delete file")
        XCTAssertEqual(keyValuePairs(of: deletion)["Path"], "/tmp/a.txt")
        XCTAssertTrue(listRowTexts(of: deletion).contains("This can't be taken back"))
    }

    // MARK: - Composio

    func testComposioWrappedSendIsUnwrapped() {
        let wrappedSend = card("composio-connect__COMPOSIO_MULTI_EXECUTE_TOOL", .object([
            "tools": .array([.object([
                "tool_slug": .string("GMAIL_SEND_EMAIL"),
                "arguments": .object([
                    "recipient_email": .string("ada@example.com"),
                    "subject": .string("Hello"),
                    "body": .string("Hi Ada")
                ])
            ])]),
            "sync_response_to_workbench": .bool(false)
        ]))
        XCTAssertEqual(headerTitle(of: wrappedSend), "New Email")
        XCTAssertEqual(keyValuePairs(of: wrappedSend)["To"], "ada@example.com")
        guard case .header(_, _, let trailingText)? = wrappedSend?.blocks.first else {
            return XCTFail("expected a header")
        }
        XCTAssertEqual(trailingText, "Gmail", "the toolkit prefix labels the card")
    }

    func testComposioBatchListsEveryAction() {
        let batch = card("composio-connect__COMPOSIO_MULTI_EXECUTE_TOOL", .object([
            "tools": .array([
                .object(["tool_slug": .string("GMAIL_FETCH_EMAILS"), "arguments": .object([:])]),
                .object(["tool_slug": .string("SLACK_SEND_MESSAGE"), "arguments": .object(["text": .string("hi")])])
            ])
        ]))
        XCTAssertEqual(headerTitle(of: batch), "2 Actions")
        XCTAssertEqual(listRowTexts(of: batch), ["Fetch emails", "Send message"])
    }

    // MARK: - Fallback

    func testUnknownToolHasNoCard() {
        XCTAssertNil(card("weather__forecast", .object(["city": .string("Paris")])))
        XCTAssertNil(card("github__create_issue", .object(["title": .string("Bug")])))
    }

    func testReadingToolHasNoCard() {
        XCTAssertNil(card("gmail__list_emails", .object(["query": .string("from:ada")])))
    }

    func testUnreadableComposioCallHasNoCard() {
        XCTAssertNil(card("composio-connect__COMPOSIO_MULTI_EXECUTE_TOOL", .object(["tools": .string("oops")])))
    }
}
