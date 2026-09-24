//
//  TimerCommandParserTests.swift
//  leanring-buddyTests
//
//  Proves the "set a timer for five minutes" fast path recognises the common
//  spoken shapes — digits or number words, compound lengths, labels, polite
//  wrappers — and, just as importantly, declines anything that is more than a
//  timer command, so those still reach the model.
//

import XCTest
@testable import Wisp

@MainActor
final class TimerCommandParserTests: XCTestCase {

    private func parsed(_ normalizedText: String) -> TimerCardRequest? {
        TimerCommandParser.timerRequest(fromNormalizedText: normalizedText)
    }

    // MARK: - Recognised

    func testTimerForDurationShapes() {
        XCTAssertEqual(parsed("set a timer for 5 minutes"), TimerCardRequest(durationSeconds: 300, label: nil))
        XCTAssertEqual(parsed("timer for 30 seconds"), TimerCardRequest(durationSeconds: 30, label: nil))
        XCTAssertEqual(parsed("start a timer for an hour"), TimerCardRequest(durationSeconds: 3600, label: nil))
        XCTAssertEqual(parsed("set me a timer for five minutes"), TimerCardRequest(durationSeconds: 300, label: nil))
        XCTAssertEqual(parsed("set a timer for twenty-five minutes"), TimerCardRequest(durationSeconds: 1500, label: nil))
    }

    func testCompoundAndHalfDurations() {
        XCTAssertEqual(parsed("set a timer for 1 hour 30 minutes"), TimerCardRequest(durationSeconds: 5400, label: nil))
        XCTAssertEqual(parsed("set a timer for 2 minutes and 30 seconds"), TimerCardRequest(durationSeconds: 150, label: nil))
        XCTAssertEqual(parsed("set a timer for half an hour"), TimerCardRequest(durationSeconds: 1800, label: nil))
        XCTAssertEqual(parsed("set a timer for two and a half minutes"), TimerCardRequest(durationSeconds: 150, label: nil))
        XCTAssertEqual(parsed("set a timer for a minute and a half"), TimerCardRequest(durationSeconds: 90, label: nil))
    }

    func testDurationBeforeTimerShape() {
        XCTAssertEqual(parsed("set a 10 minute timer"), TimerCardRequest(durationSeconds: 600, label: nil))
        XCTAssertEqual(parsed("start a ten-minute timer"), TimerCardRequest(durationSeconds: 600, label: nil))
        XCTAssertEqual(parsed("5 minute timer"), TimerCardRequest(durationSeconds: 300, label: nil))
    }

    func testLabels() {
        XCTAssertEqual(parsed("set a timer for 5 minutes for tea"), TimerCardRequest(durationSeconds: 300, label: "tea"))
        XCTAssertEqual(parsed("set a timer for 12 minutes for the pasta"), TimerCardRequest(durationSeconds: 720, label: "pasta"))
        XCTAssertEqual(parsed("set a 3 minute tea timer"), TimerCardRequest(durationSeconds: 180, label: "tea"))
        XCTAssertEqual(parsed("set a 4 minute timer called eggs"), TimerCardRequest(durationSeconds: 240, label: "eggs"))
    }

    func testPoliteWrappersAreIgnored() {
        XCTAssertEqual(parsed("hey wisp can you set a timer for 5 minutes please"),
                       TimerCardRequest(durationSeconds: 300, label: nil))
        XCTAssertEqual(parsed("please set a timer for 1 minute"), TimerCardRequest(durationSeconds: 60, label: nil))
    }

    func testFastRouterNormalisesPunctuationAndCaseBeforeParsing() {
        // `handle` lowercases and strips trailing punctuation; this checks the
        // two pieces agree on that contract.
        let normalized = "Set a timer for 5 minutes."
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        XCTAssertEqual(parsed(normalized), TimerCardRequest(durationSeconds: 300, label: nil))
    }

    // MARK: - Declined (left for the model)

    func testUtterancesThatAreMoreThanATimerCommandAreDeclined() {
        XCTAssertNil(parsed("set a timer for 5 minutes and then remind me to call mum"))
        XCTAssertNil(parsed("how long is a 5 minute timer"))
        XCTAssertNil(parsed("set a timer"))
        XCTAssertNil(parsed("set an alarm for 7 am"))
        XCTAssertNil(parsed("what timer apps are there"))
        XCTAssertNil(parsed("remind me in 5 minutes"))
        XCTAssertNil(parsed("set a 5 minute timer app"))
    }

    func testOutOfRangeLengthsAreDeclined() {
        XCTAssertNil(parsed("set a timer for 0 minutes"))
        XCTAssertNil(parsed("set a timer for 25 hours"))
    }
}
