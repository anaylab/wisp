//
//  MCPStartupTests.swift
//  leanring-buddyTests
//
//  Proves the pure pieces behind reliable MCP server startup: pipe chunks are
//  framed into whole lines however they arrive, package runners (npx/uvx) get
//  the long first-handshake budget and nothing else does, and a failure
//  message carries the server's own last stderr line.
//

import XCTest
@testable import Wisp

final class MCPStartupTests: XCTestCase {

    // MARK: - Line framing

    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testWholeLinesInOneChunkAreSplitInOrder() {
        var lineBuffer = NewlineDelimitedLineBuffer()

        let lines = lineBuffer.appendAndExtractCompleteLines(data("{\"id\":1}\n{\"id\":2}\n"))

        XCTAssertEqual(lines, ["{\"id\":1}", "{\"id\":2}"])
        XCTAssertNil(lineBuffer.flushRemainingLine())
    }

    func testALineSplitAcrossChunksIsHeldUntilItsNewlineArrives() {
        var lineBuffer = NewlineDelimitedLineBuffer()

        XCTAssertEqual(lineBuffer.appendAndExtractCompleteLines(data("{\"jsonrpc\":\"2.0\",")), [])
        XCTAssertEqual(lineBuffer.appendAndExtractCompleteLines(data("\"id\":2}\n{\"id\"")), ["{\"jsonrpc\":\"2.0\",\"id\":2}"])
        XCTAssertEqual(lineBuffer.appendAndExtractCompleteLines(data(":3}\n")), ["{\"id\":3}"])
    }

    func testCarriageReturnsAndBlankLinesAreDropped() {
        var lineBuffer = NewlineDelimitedLineBuffer()

        let lines = lineBuffer.appendAndExtractCompleteLines(data("first\r\n\n\r\nsecond\n"))

        XCTAssertEqual(lines, ["first", "second"])
    }

    func testAnUnterminatedLastLineIsReturnedAtEndOfFile() {
        var lineBuffer = NewlineDelimitedLineBuffer()

        XCTAssertEqual(lineBuffer.appendAndExtractCompleteLines(data("done\nModuleNotFoundError: x")), ["done"])
        XCTAssertEqual(lineBuffer.flushRemainingLine(), "ModuleNotFoundError: x")
        XCTAssertNil(lineBuffer.flushRemainingLine())
    }

    func testMultiByteCharactersSplitAcrossChunksDecodeIntact() {
        var lineBuffer = NewlineDelimitedLineBuffer()
        let encoded = Array("café ☕\n".utf8)
        // Split inside the three-byte ☕.
        let splitIndex = encoded.count - 3

        XCTAssertEqual(lineBuffer.appendAndExtractCompleteLines(Data(encoded[..<splitIndex])), [])
        XCTAssertEqual(lineBuffer.appendAndExtractCompleteLines(Data(encoded[splitIndex...])), ["café ☕"])
    }

    // MARK: - Startup timeouts

    func testPackageRunnersGetTheLongInitializeTimeout() {
        for command in ["npx", "uvx", "bunx", "pnpx", "pipx", "uv", "/opt/homebrew/bin/npx", "/Users/me/.local/bin/uvx"] {
            XCTAssertTrue(MCPStartupTimeoutPolicy.isPackageRunner(command: command), command)
            XCTAssertEqual(
                MCPStartupTimeoutPolicy.initializeTimeoutSeconds(forCommand: command),
                MCPStartupTimeoutPolicy.packageRunnerInitializeTimeoutSeconds,
                command
            )
        }
    }

    func testOtherCommandsAndRemoteServersKeepTheStandardTimeout() {
        // A remote server's configuration has an empty command.
        for command in ["node", "python3", "/usr/local/bin/my-server", "npx-helper", ""] {
            XCTAssertFalse(MCPStartupTimeoutPolicy.isPackageRunner(command: command), command)
            XCTAssertEqual(
                MCPStartupTimeoutPolicy.initializeTimeoutSeconds(forCommand: command),
                MCPStartupTimeoutPolicy.standardRequestTimeoutSeconds,
                command
            )
        }
    }

    // MARK: - Failure message

    func testFailureMessageAppendsTheLastNonEmptyServerLine() {
        let message = MCPConnectionFailureMessage.compose(
            errorDescription: "the server didn't answer initialize in time.",
            recentErrorOutput: ["Downloading lxml (8.2MiB)", "error: Failed to fetch: `https://pypi.org/simple/lxml/`", "   "]
        )

        XCTAssertEqual(
            message,
            "the server didn't answer initialize in time. Last server output: error: Failed to fetch: `https://pypi.org/simple/lxml/`"
        )
    }

    func testFailureMessageIsUnchangedWithoutServerOutput() {
        let message = MCPConnectionFailureMessage.compose(
            errorDescription: "not connected to the server.",
            recentErrorOutput: ["", "  "]
        )

        XCTAssertEqual(message, "not connected to the server.")
    }

    func testFailureMessageDoesNotRepeatALineTheErrorAlreadyContains() {
        let message = MCPConnectionFailureMessage.compose(
            errorDescription: "Invalid API key",
            recentErrorOutput: ["Invalid API key"]
        )

        XCTAssertEqual(message, "Invalid API key")
    }

    func testFailureMessageTruncatesAVeryLongServerLine() {
        let longLine = String(repeating: "x", count: 500)

        let message = MCPConnectionFailureMessage.compose(
            errorDescription: "failed.",
            recentErrorOutput: [longLine]
        )

        let expectedLine = String(repeating: "x", count: MCPConnectionFailureMessage.maximumServerOutputCharacters) + "…"
        XCTAssertEqual(message, "failed. Last server output: \(expectedLine)")
    }
}
