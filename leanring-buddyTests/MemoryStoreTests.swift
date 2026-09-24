//
//  MemoryStoreTests.swift
//  leanring-buddyTests
//
//  Proves memory.md is read as one fact per bullet, that remembering and
//  forgetting only touch bullet lines (so a user's hand-written notes survive),
//  and that the prompt index stays within its character budget while
//  preferring the most recent facts.
//

import XCTest
@testable import Wisp

@MainActor
final class MemoryStoreTests: XCTestCase {

    private let handEditedMemoryFile = """
    # Wisp memory

    Some notes I wrote myself.

    - my name is Anay
    * prefers metric units
      - works on a macOS app called Wisp
    -not a bullet without a space
    -
    """

    // MARK: - Parsing

    func testParseReadsEveryBulletStyleAndIgnoresOtherLines() {
        let facts = MemoryFileFormat.parseFacts(from: handEditedMemoryFile)

        XCTAssertEqual(facts, [
            "my name is Anay",
            "prefers metric units",
            "works on a macOS app called Wisp",
        ])
    }

    func testParseOfEmptyFileIsNoFacts() {
        XCTAssertEqual(MemoryFileFormat.parseFacts(from: ""), [])
    }

    // MARK: - Appending

    func testAppendToEmptyFileAddsHeaderThenFact() {
        let updatedMarkdown = MemoryFileFormat.appendingFact("likes green tea", to: "")

        XCTAssertTrue(updatedMarkdown.hasPrefix("# Wisp memory"))
        XCTAssertEqual(MemoryFileFormat.parseFacts(from: updatedMarkdown), ["likes green tea"])
    }

    func testAppendKeepsExistingContentAndAddsFactLast() {
        let updatedMarkdown = MemoryFileFormat.appendingFact("likes green tea", to: handEditedMemoryFile)

        XCTAssertTrue(updatedMarkdown.contains("Some notes I wrote myself."))
        XCTAssertEqual(MemoryFileFormat.parseFacts(from: updatedMarkdown).last, "likes green tea")
        XCTAssertTrue(updatedMarkdown.hasSuffix("- likes green tea\n"))
    }

    func testNormalizedFactIsOneLineWithoutItsOwnBulletAndCapped() {
        XCTAssertEqual(MemoryFileFormat.normalizedFact("  - lives in\n  Bangalore  "), "lives in Bangalore")
        XCTAssertNil(MemoryFileFormat.normalizedFact("   \n "))

        let overlongFact = String(repeating: "a", count: MemoryFileFormat.maximumFactCharacters + 50)
        XCTAssertEqual(MemoryFileFormat.normalizedFact(overlongFact)?.count, MemoryFileFormat.maximumFactCharacters)
    }

    func testContainsFactIgnoresCase() {
        XCTAssertTrue(MemoryFileFormat.containsFact("PREFERS METRIC UNITS", in: handEditedMemoryFile))
        XCTAssertFalse(MemoryFileFormat.containsFact("prefers imperial units", in: handEditedMemoryFile))
    }

    // MARK: - Removing

    func testRemoveMatchingDeletesOnlyTheMatchingBullet() {
        let removal = MemoryFileFormat.removingFacts(matching: "METRIC", from: handEditedMemoryFile)

        XCTAssertEqual(removal.removedFacts, ["prefers metric units"])
        XCTAssertEqual(MemoryFileFormat.parseFacts(from: removal.updatedMarkdown), [
            "my name is Anay",
            "works on a macOS app called Wisp",
        ])
        // Non-bullet lines, including the user's own notes, are untouched.
        XCTAssertTrue(removal.updatedMarkdown.contains("Some notes I wrote myself."))
        XCTAssertTrue(removal.updatedMarkdown.contains("-not a bullet without a space"))
    }

    func testRemoveNeverMatchesNonBulletText() {
        // "notes" appears only in a paragraph, never in a fact.
        let removal = MemoryFileFormat.removingFacts(matching: "notes", from: handEditedMemoryFile)

        XCTAssertEqual(removal.removedFacts, [])
        XCTAssertEqual(removal.updatedMarkdown, handEditedMemoryFile)
    }

    func testRemoveWithBlankQueryRemovesNothing() {
        let removal = MemoryFileFormat.removingFacts(matching: "   ", from: handEditedMemoryFile)

        XCTAssertEqual(removal.removedFacts, [])
        XCTAssertEqual(removal.updatedMarkdown, handEditedMemoryFile)
    }

    func testExactRemovalRemovesOnlyThatFact() {
        let removal = MemoryFileFormat.removingFacts(from: handEditedMemoryFile) { fact in
            fact == "my name is Anay"
        }

        XCTAssertEqual(removal.removedFacts, ["my name is Anay"])
        XCTAssertEqual(MemoryFileFormat.parseFacts(from: removal.updatedMarkdown).count, 2)
    }

    // MARK: - Prompt index

    func testPromptIndexIsEmptyWithNoFacts() {
        XCTAssertEqual(MemoryIndex.promptInstructions(for: []), "")
    }

    func testPromptIndexListsFactsInFileOrder() {
        let promptText = MemoryIndex.promptInstructions(for: ["first fact", "second fact"])

        guard let firstFactRange = promptText.range(of: "- first fact"),
              let secondFactRange = promptText.range(of: "- second fact") else {
            return XCTFail("both facts should appear in the prompt index")
        }
        XCTAssertLessThan(firstFactRange.lowerBound, secondFactRange.lowerBound)
    }

    func testPromptIndexStaysWithinBudgetAndPrefersRecentFacts() {
        // 40 facts of ~30 characters each is far more than 800 characters.
        let manyFacts = (0..<40).map { index in "fact number \(index) about the user" }

        let chosenFacts = MemoryIndex.factsFittingBudget(manyFacts, characterBudget: 800)
        let renderedCharacterCount = chosenFacts.reduce(0) { total, fact in total + "- \(fact)".count }

        XCTAssertLessThanOrEqual(renderedCharacterCount, 800)
        XCTAssertLessThan(chosenFacts.count, manyFacts.count)
        XCTAssertEqual(chosenFacts.last, "fact number 39 about the user", "the newest fact must be kept")
        XCTAssertFalse(chosenFacts.contains("fact number 0 about the user"), "the oldest facts are dropped first")
        XCTAssertEqual(chosenFacts, Array(manyFacts.suffix(chosenFacts.count)), "chosen facts stay in file order")
    }

    func testOneOverlongFactDoesNotCrowdOutShorterOlderFacts() {
        let overlongNewestFact = String(repeating: "z", count: 900)
        let facts = ["short older fact", overlongNewestFact]

        let chosenFacts = MemoryIndex.factsFittingBudget(facts, characterBudget: 800)

        XCTAssertEqual(chosenFacts, ["short older fact"])
    }

    // MARK: - Tool routing

    func testRememberRequestsRouteToTheMemoryScope() {
        XCTAssertEqual(AgentToolScope.forRequest("remember that i prefer dark roast coffee"), .memory)
        XCTAssertEqual(AgentToolScope.forRequest("please forget my old address"), .memory)
        XCTAssertTrue(AgentToolScope.memory.includes(toolNamed: "remember"))
        XCTAssertTrue(AgentToolScope.memory.includes(toolNamed: "forget"))
    }

    func testRamQuestionDoesNotRouteToTheMemoryScope() {
        XCTAssertNotEqual(AgentToolScope.forRequest("how much memory is free right now"), .memory)
    }
}
