//
//  BrowserAgentLoopTests.swift
//  leanring-buddyTests
//
//  Proves the browser agent reads a model reply into the right actions — a
//  thought, a batch of form fills, an ending action that closes the list — and
//  that the irreversible-action classifier asks about committing buttons
//  without nagging about ordinary navigation.
//

import XCTest
@testable import Wisp

@MainActor
final class BrowserAgentLoopTests: XCTestCase {

    // MARK: - Parsing

    func testThoughtAndBatchOfFormActionsParseInOrder() {
        let reply = """
        thinking: fill the shipping form then continue
        fill e3 = Ada Lovelace
        fill e4 = "12 Analytical Way"
        select e5 = California
        click e9
        """

        let parsed = BrowserAgentLoop.parseReply(reply)

        XCTAssertEqual(parsed.thought, "fill the shipping form then continue")
        XCTAssertEqual(parsed.actions, [
            .type(elementID: "e3", text: "Ada Lovelace", submit: false),
            .type(elementID: "e4", text: "12 Analytical Way", submit: false),
            .select(elementID: "e5", optionLabel: "California"),
            .click(elementID: "e9"),
        ])
    }

    func testTypeSubmitsAndFillDoesNot() {
        XCTAssertEqual(BrowserAgentLoop.parseAction("type e2 = running shoes"),
                       .type(elementID: "e2", text: "running shoes", submit: true))
        XCTAssertEqual(BrowserAgentLoop.parseAction("fill e2 = running shoes"),
                       .type(elementID: "e2", text: "running shoes", submit: false))
    }

    func testEndingActionClosesTheList() {
        let parsed = BrowserAgentLoop.parseReply("done The cheapest is $42 at Acme.\nclick e1")

        XCTAssertEqual(parsed.actions, [.done(answer: "The cheapest is $42 at Acme.")])
    }

    func testListMarkersAndPunctuationAreTolerated() {
        let parsed = BrowserAgentLoop.parseReply("- click e12.\n* key escape")

        XCTAssertEqual(parsed.actions, [.click(elementID: "e12"), .key(name: "escape")])
    }

    func testOpenNormalisesABareHostAndRejectsNonsense() {
        XCTAssertEqual(BrowserAgentLoop.parseAction("open example.com/search?q=x"),
                       .open(url: URL(string: "https://example.com/search?q=x")!))
        XCTAssertNil(BrowserAgentLoop.parseAction("open"))
    }

    func testProseWithoutAnActionYieldsNothing() {
        let parsed = BrowserAgentLoop.parseReply("I think the page is still loading, let me see.")

        XCTAssertTrue(parsed.actions.isEmpty)
    }

    func testPageChangingActionsStopABatch() {
        XCTAssertTrue(BrowserAgentAction.click(elementID: "e1").mayChangePage)
        XCTAssertTrue(BrowserAgentAction.type(elementID: "e1", text: "x", submit: true).mayChangePage)
        XCTAssertFalse(BrowserAgentAction.type(elementID: "e1", text: "x", submit: false).mayChangePage)
        XCTAssertFalse(BrowserAgentAction.select(elementID: "e1", optionLabel: "x").mayChangePage)
    }

    // MARK: - Safety

    func testCommittingButtonsAreIrreversible() {
        XCTAssertTrue(BrowserActionSafety.isIrreversible(elementLabel: "Place your order", role: "button"))
        XCTAssertTrue(BrowserActionSafety.isIrreversible(elementLabel: "Send", role: "button"))
        XCTAssertTrue(BrowserActionSafety.isIrreversible(elementLabel: "Delete repository", role: "button"))
        XCTAssertTrue(BrowserActionSafety.isIrreversible(elementLabel: "Buy now", role: "button"))
    }

    func testOrdinaryControlsAreNotIrreversible() {
        XCTAssertFalse(BrowserActionSafety.isIrreversible(elementLabel: "Add to cart", role: "button"))
        XCTAssertFalse(BrowserActionSafety.isIrreversible(elementLabel: "Search", role: "button"))
        XCTAssertFalse(BrowserActionSafety.isIrreversible(elementLabel: "Books", role: "link"))
        XCTAssertFalse(BrowserActionSafety.isIrreversible(elementLabel: "PayPal help", role: "link"))
        // Not an acting control at all, whatever it says.
        XCTAssertFalse(BrowserActionSafety.isIrreversible(elementLabel: "Send", role: "textbox"))
    }

    func testLinksOnlyCountWhenTheCommittingWordLeads() {
        XCTAssertTrue(BrowserActionSafety.isIrreversible(elementLabel: "Sign up", role: "link"))
        XCTAssertFalse(BrowserActionSafety.isIrreversible(elementLabel: "Why you should sign up", role: "link"))
    }

    func testSubmittingAMessageFieldSendsButASearchDoesNot() {
        XCTAssertTrue(BrowserActionSafety.submittingSendsMessage(fieldLabel: "Write a message…"))
        XCTAssertFalse(BrowserActionSafety.submittingSendsMessage(fieldLabel: "Search messages"))
        XCTAssertFalse(BrowserActionSafety.submittingSendsMessage(fieldLabel: "Where to?"))
    }
}
