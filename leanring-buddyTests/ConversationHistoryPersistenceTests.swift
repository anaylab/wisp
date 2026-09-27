//
//  ConversationHistoryPersistenceTests.swift
//  leanring-buddyTests
//
//  Proves the saved conversation round-trips through conversation.json with
//  its text and tool traffic intact and its screenshots gone, and that only
//  recent turns are resumed into the model's context on launch.
//

import XCTest
@testable import Wisp

@MainActor
final class ConversationHistoryPersistenceTests: XCTestCase {

    /// Whole seconds, because the file stores ISO-8601 dates without
    /// fractional seconds.
    private let referenceDate = Date(timeIntervalSince1970: 1_750_000_000)

    private func makeTurnWithScreenshotAndToolCall(startedAt: Date) -> ConversationTranscript.Turn {
        ConversationTranscript.Turn(startedAt: startedAt, messages: [
            BuddyChatMessage(role: .user, blocks: [
                .text("what's on my clipboard?"),
                .image(data: Data([0xFF, 0xD8, 0xFF]), label: "screen 1"),
            ]),
            BuddyChatMessage(role: .assistant, blocks: [
                .text("let me check."),
                .toolUse(id: "call-1", name: "read_clipboard", input: .object(["verbose": .bool(true)])),
            ]),
            BuddyChatMessage(role: .user, blocks: [
                .toolResult(toolUseID: "call-1", toolName: "read_clipboard", content: "hello world", isError: false),
            ]),
            BuddyChatMessage(role: .assistant, text: "your clipboard says hello world."),
        ])
    }

    func testRoundTripKeepsTextAndToolBlocksAndDropsImages() throws {
        let originalTurn = makeTurnWithScreenshotAndToolCall(startedAt: referenceDate)

        let encodedData = try ConversationHistoryCodec.encode(turns: [originalTurn], savedAt: referenceDate)
        let decodedTurns = try ConversationHistoryCodec.decodeTurns(from: encodedData)

        XCTAssertEqual(decodedTurns.count, 1)
        let decodedTurn = try XCTUnwrap(decodedTurns.first)
        XCTAssertEqual(decodedTurn.id, originalTurn.id)
        XCTAssertEqual(decodedTurn.startedAt, originalTurn.startedAt)
        XCTAssertEqual(decodedTurn.messages.count, 4)
        XCTAssertEqual(decodedTurn.userText, "what's on my clipboard?")
        XCTAssertEqual(decodedTurn.assistantText, "your clipboard says hello world.")

        // The screenshot is gone; everything else is in its original order.
        for message in decodedTurn.messages {
            XCTAssertFalse(message.blocks.containsImage)
        }
        XCTAssertEqual(decodedTurn.messages[0].blocks.count, 1)

        let toolUses = decodedTurn.messages[1].toolUses
        XCTAssertEqual(toolUses.count, 1)
        XCTAssertEqual(toolUses.first?.id, "call-1")
        XCTAssertEqual(toolUses.first?.name, "read_clipboard")
        XCTAssertEqual(toolUses.first?.input, .object(["verbose": .bool(true)]))

        guard case .toolResult(let toolUseID, let toolName, let content, let isError) = decodedTurn.messages[2].blocks.first else {
            return XCTFail("expected the tool result to survive the round trip")
        }
        XCTAssertEqual(toolUseID, "call-1")
        XCTAssertEqual(toolName, "read_clipboard")
        XCTAssertEqual(content, "hello world")
        XCTAssertFalse(isError)
    }

    func testEncodedFileContainsNoImageBytes() throws {
        let encodedData = try ConversationHistoryCodec.encode(
            turns: [makeTurnWithScreenshotAndToolCall(startedAt: referenceDate)],
            savedAt: referenceDate
        )
        let encodedText = try XCTUnwrap(String(data: encodedData, encoding: .utf8))

        XCTAssertFalse(encodedText.contains("screen 1"), "the image label must not be written")
        XCTAssertFalse(encodedText.contains(Data([0xFF, 0xD8, 0xFF]).base64EncodedString()))
    }

    func testMessageThatWasOnlyAnImageIsDropped() {
        let turn = ConversationTranscript.Turn(startedAt: referenceDate, messages: [
            BuddyChatMessage(role: .user, blocks: [.image(data: Data([1, 2, 3]), label: "screen")]),
            BuddyChatMessage(role: .assistant, text: "that's a terminal."),
        ])

        let persistedTurn = ConversationHistoryCodec.persistedTurn(from: turn)

        XCTAssertEqual(persistedTurn.messages.count, 1)
        XCTAssertEqual(persistedTurn.messages.first?.role, "assistant")
    }

    func testLongToolResultIsCappedOnDisk() {
        let longContent = String(repeating: "x", count: ConversationHistoryCodec.maximumPersistedToolResultCharacters + 500)
        let turn = ConversationTranscript.Turn(startedAt: referenceDate, messages: [
            BuddyChatMessage(role: .user, blocks: [
                .toolResult(toolUseID: "call-9", toolName: "read_page", content: longContent, isError: false),
            ]),
        ])

        let persistedTurn = ConversationHistoryCodec.persistedTurn(from: turn)

        guard case .toolResult(_, _, let storedContent, _) = persistedTurn.messages.first?.blocks.first else {
            return XCTFail("expected a tool result")
        }
        XCTAssertLessThanOrEqual(storedContent.count, ConversationHistoryCodec.maximumPersistedToolResultCharacters + 1)
    }

    func testMergeKeepsOlderTurnsTheLiveWindowTrimmedAndCapsTheTotal() {
        let olderTurns = (0..<5).map { index in
            ConversationTranscript.Turn(
                startedAt: referenceDate.addingTimeInterval(TimeInterval(index)),
                messages: [BuddyChatMessage(role: .user, text: "old \(index)")]
            )
        }
        let newTurn = ConversationTranscript.Turn(
            startedAt: referenceDate.addingTimeInterval(100),
            messages: [BuddyChatMessage(role: .user, text: "new")]
        )
        // The live transcript has trimmed everything but the last old turn.
        let liveTurns = [olderTurns[4], newTurn]

        let mergedTurns = ConversationHistoryCodec.mergedTurns(
            persistedTurns: olderTurns,
            liveTurns: liveTurns,
            limit: 4
        )

        XCTAssertEqual(mergedTurns.map(\.userText), ["old 2", "old 3", "old 4", "new"])
    }

    func testOnlyRecentTurnsAreResumed() {
        let now = referenceDate
        let staleTurn = ConversationTranscript.Turn(
            startedAt: now.addingTimeInterval(-(ConversationHistoryCodec.maximumResumedTurnAge + 60)),
            messages: [BuddyChatMessage(role: .user, text: "yesterday")]
        )
        let freshTurn = ConversationTranscript.Turn(
            startedAt: now.addingTimeInterval(-600),
            messages: [BuddyChatMessage(role: .user, text: "ten minutes ago")]
        )

        let resumedTurns = ConversationHistoryCodec.turnsToResume(from: [staleTurn, freshTurn], now: now)

        XCTAssertEqual(resumedTurns.map(\.userText), ["ten minutes ago"])
    }

    func testResumedTurnsAreCappedToTheMostRecent() {
        let now = referenceDate
        let recentTurns = (0..<15).map { index in
            ConversationTranscript.Turn(
                startedAt: now.addingTimeInterval(TimeInterval(-100 + index)),
                messages: [BuddyChatMessage(role: .user, text: "turn \(index)")]
            )
        }

        let resumedTurns = ConversationHistoryCodec.turnsToResume(from: recentTurns, now: now, maximumCount: 3)

        XCTAssertEqual(resumedTurns.map(\.userText), ["turn 12", "turn 13", "turn 14"])
    }

    func testRestoringTranscriptPreservesTurnOrder() {
        let firstTurn = ConversationTranscript.Turn(startedAt: referenceDate, messages: [BuddyChatMessage(role: .user, text: "first")])
        let secondTurn = ConversationTranscript.Turn(startedAt: referenceDate, messages: [BuddyChatMessage(role: .user, text: "second")])

        let restoredTranscript = ConversationTranscript(restoringTurns: [firstTurn, secondTurn])

        XCTAssertEqual(restoredTranscript.turns.map(\.id), [firstTurn.id, secondTurn.id])
    }
}
