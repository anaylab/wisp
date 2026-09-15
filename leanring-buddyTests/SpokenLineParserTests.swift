//
//  SpokenLineParserTests.swift
//  leanring-buddyTests
//
//  Proves the optional [SAY:...] tag is captured as the spoken line and
//  stripped from the displayed text, and that a reply without the tag simply
//  has no spoken line (visual-first, the model chose not to speak).
//

import XCTest
@testable import Wisp

final class SpokenLineParserTests: XCTestCase {

    func testSpokenLineIsCapturedAndTagStripped() {
        let reply = "The build passed. [SAY: All green — you're good to ship.]"

        let result = SpokenLineParser.parse(reply)

        XCTAssertEqual(result.spokenLine, "All green — you're good to ship.")
        XCTAssertEqual(result.displayText, "The build passed.")
    }

    func testNoTagMeansNoSpokenLineAndTextUnchanged() {
        let reply = "Here are the three failing tests and why."

        let result = SpokenLineParser.parse(reply)

        XCTAssertNil(result.spokenLine)
        XCTAssertEqual(result.displayText, "Here are the three failing tests and why.")
    }

    func testEmptyTagYieldsNoSpokenLineButIsStillStripped() {
        // A tag with nothing worth speaking should not leave the bracket behind
        // in the displayed text, and should not produce an empty utterance.
        let reply = "Pointing at it now. [SAY: ]"

        let result = SpokenLineParser.parse(reply)

        XCTAssertNil(result.spokenLine)
        XCTAssertEqual(result.displayText, "Pointing at it now.")
    }

    func testOnlyFirstTagIsSpokenAndAllTagsAreStripped() {
        let reply = "[SAY: First line.] middle [SAY: second line.]"

        let result = SpokenLineParser.parse(reply)

        XCTAssertEqual(result.spokenLine, "First line.")
        XCTAssertEqual(result.displayText, "middle")
    }

    func testTagIsMatchedCaseInsensitively() {
        let reply = "done [say: lowercased tag works]"

        let result = SpokenLineParser.parse(reply)

        XCTAssertEqual(result.spokenLine, "lowercased tag works")
        XCTAssertEqual(result.displayText, "done")
    }
}
