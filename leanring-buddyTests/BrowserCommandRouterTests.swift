//
//  BrowserCommandRouterTests.swift
//  leanring-buddyTests
//
//  Proves plain browser instructions are recognised without the model — tab
//  commands as tab commands, web tasks as web tasks — and that ordinary
//  questions and Mac-local requests are left alone for the model.
//

import XCTest
@testable import Wisp

@MainActor
final class BrowserCommandRouterTests: XCTestCase {

    func testNewTabPhrasingsAreTabCommands() {
        for phrase in ["open a new tab", "Open a new tab.", "can you open a new tab for me please",
                       "hey wisp, new tab", "open another tab"] {
            XCTAssertEqual(BrowserCommandRouter.route(phrase), .tabCommand(.newTab), phrase)
        }
    }

    func testOtherTabCommands() {
        XCTAssertEqual(BrowserCommandRouter.route("close this tab"), .tabCommand(.closeTab))
        XCTAssertEqual(BrowserCommandRouter.route("refresh the page"), .tabCommand(.reload))
        XCTAssertEqual(BrowserCommandRouter.route("go back"), .tabCommand(.back))
        XCTAssertEqual(BrowserCommandRouter.route("open a new window"), .tabCommand(.newWindow))
    }

    func testNamedSitesAndAddressesAreBrowserTasks() {
        XCTAssertEqual(BrowserCommandRouter.route("open youtube"), .browserTask(request: "open youtube"))
        XCTAssertEqual(BrowserCommandRouter.route("go to github.com"), .browserTask(request: "go to github.com"))
        XCTAssertEqual(BrowserCommandRouter.route("find a usb-c cable on amazon"),
                       .browserTask(request: "find a usb-c cable on amazon"))
    }

    func testAPlainWebSearchUsesTheDefaultEngine() {
        XCTAssertEqual(BrowserCommandRouter.route("search for nvidia stock"),
                       .browserTask(request: "search google for nvidia stock"))
    }

    func testNewTabAndThenATaskRunsTheTask() {
        XCTAssertEqual(BrowserCommandRouter.route("open a new tab and go to reddit"),
                       .browserTask(request: "go to reddit"))
    }

    func testQuestionsAndLocalRequestsAreLeftForTheModel() {
        XCTAssertNil(BrowserCommandRouter.route("what's the capital of france"))
        XCTAssertNil(BrowserCommandRouter.route("how do i go back to the previous commit in git"))
        XCTAssertNil(BrowserCommandRouter.route("search for the file called notes"))
        XCTAssertNil(BrowserCommandRouter.route("open safari"))
    }

    func testANamedSiteRoutesTheModelToBrowserTools() {
        XCTAssertEqual(AgentToolScope.forRequest("open youtube"), .browser)
        XCTAssertEqual(AgentToolScope.forRequest("go to github.com"), .browser)
    }
}
