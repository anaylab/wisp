//
//  UpcomingEventCountdownTests.swift
//  leanring-buddyTests
//
//  Proves the notch's meeting countdown rounds up to whole minutes and says
//  "now" / "Started" once the event is about to begin or has begun.
//

import XCTest
@testable import Wisp

@MainActor
final class UpcomingEventCountdownTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    func testCompactCountdownRoundsUpToWholeMinutes() {
        XCTAssertEqual(UpcomingEventMonitor.compactCountdownText(until: now.addingTimeInterval(12 * 60), now: now), "12m")
        XCTAssertEqual(UpcomingEventMonitor.compactCountdownText(until: now.addingTimeInterval(11 * 60 + 1), now: now), "12m")
        XCTAssertEqual(UpcomingEventMonitor.compactCountdownText(until: now.addingTimeInterval(45), now: now), "1m")
    }

    func testCompactCountdownSaysNowAtAndAfterTheStart() {
        XCTAssertEqual(UpcomingEventMonitor.compactCountdownText(until: now.addingTimeInterval(20), now: now), "now")
        XCTAssertEqual(UpcomingEventMonitor.compactCountdownText(until: now.addingTimeInterval(-120), now: now), "now")
    }

    func testCountdownPhrase() {
        XCTAssertEqual(UpcomingEventMonitor.countdownPhrase(until: now.addingTimeInterval(5 * 60), now: now), "In 5 min")
        XCTAssertEqual(UpcomingEventMonitor.countdownPhrase(until: now.addingTimeInterval(-60), now: now), "Started")
    }
}
