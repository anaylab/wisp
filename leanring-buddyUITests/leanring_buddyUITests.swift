import XCTest

/// Smoke test: Wisp is a menu bar app with no main window, so the only thing a
/// UI test can promise is that it launches and stays running.
final class WispLaunchSmokeTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAppLaunchesAndStaysRunning() throws {
        let wispApplication = XCUIApplication()
        wispApplication.launch()

        XCTAssertTrue(wispApplication.wait(for: .runningBackground, timeout: 10)
                      || wispApplication.state == .runningForeground)
    }
}
