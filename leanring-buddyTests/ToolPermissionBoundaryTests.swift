//
//  ToolPermissionBoundaryTests.swift
//  leanring-buddyTests
//
//  Proves that nothing reaches a tool's implementation without approval.
//
//  These tests exist because the boundary they describe used to be a
//  convention. Confirmation was checked by the one caller that happened to run
//  tools, so the guarantee held only as long as every future caller — a cloud
//  runtime, a Job, a Skill — remembered to repeat the check. A guarantee that
//  depends on being remembered is not one, and the failure is silent: a model
//  executing something nobody approved, with no error to notice.
//
//  Each test asserts on whether the implementation *ran*, using a flag the
//  implementation itself sets. Asserting on the returned text would pass just
//  as happily against a version that ran the tool and then apologised.
//

import XCTest
@testable import Wisp

@MainActor
final class ToolPermissionBoundaryTests: XCTestCase {

    /// A stand-in for the user, so approval can be decided by the test rather
    /// than by a person listening to a spoken question.
    private final class StubBroker: ToolPermissionBroker {
        var decision: ToolConfirmationCoordinator.Decision
        private(set) var askedAbout: [String] = []

        init(decision: ToolConfirmationCoordinator.Decision) {
            self.decision = decision
        }

        func requestApproval(
            toolName: String,
            argumentSummary: String
        ) async -> ToolConfirmationCoordinator.Decision {
            askedAbout.append(toolName)
            return decision
        }
    }

    private let registry = AgentToolRegistry.shared

    override func tearDown() async throws {
        registry.setPermissionBroker(ToolConfirmationCoordinator.shared)
    }

    // MARK: - The invariant

    func testReadOnlyToolRunsWithoutBeingAsked() async {
        let broker = StubBroker(decision: .declined(reason: "should never be consulted"))
        registry.setPermissionBroker(broker)

        var didRun = false
        registry.register(
            BuddyToolDefinition(
                name: "test_read_only",
                description: "reads something",
                inputSchema: .object(["type": .string("object")]),
                metadata: .reading(.localMachine)
            )
        ) { _ in
            didRun = true
            return "read something"
        }

        let outcome = await registry.invoke(name: "test_read_only", input: .object([:]))

        XCTAssertTrue(didRun, "a read-only tool should run without approval")
        XCTAssertFalse(outcome.wasDeclined)
        XCTAssertFalse(outcome.isError)
        XCTAssertTrue(broker.askedAbout.isEmpty, "reading should not prompt the user")
    }

    func testDeniedToolNeverReachesItsImplementation() async {
        let broker = StubBroker(decision: .declined(reason: "the user said no"))
        registry.setPermissionBroker(broker)

        var didRun = false
        registry.register(
            BuddyToolDefinition(
                name: "test_destructive",
                description: "deletes something",
                inputSchema: .object(["type": .string("object")]),
                metadata: ToolMetadata(readOnly: false, destructive: true)
            )
        ) { _ in
            didRun = true
            return "deleted it"
        }

        let outcome = await registry.invoke(name: "test_destructive", input: .object([:]))

        XCTAssertFalse(didRun, "a denied tool must not execute — this is the whole invariant")
        XCTAssertTrue(outcome.wasDeclined)
        XCTAssertFalse(outcome.isError, "a refusal is an outcome, not a failure")
        XCTAssertEqual(broker.askedAbout, ["test_destructive"])
    }

    func testApprovedToolRunsAfterBeingAsked() async {
        let broker = StubBroker(decision: .approved)
        registry.setPermissionBroker(broker)

        var didRun = false
        registry.register(
            BuddyToolDefinition(
                name: "test_writes",
                description: "writes something",
                inputSchema: .object(["type": .string("object")]),
                metadata: .writing()
            )
        ) { _ in
            didRun = true
            return "wrote it"
        }

        let outcome = await registry.invoke(name: "test_writes", input: .object([:]))

        XCTAssertTrue(didRun)
        XCTAssertFalse(outcome.wasDeclined)
        XCTAssertEqual(broker.askedAbout, ["test_writes"])
    }

    /// The case the whole refactor exists for.
    ///
    /// A caller that knows nothing about permissions — as a cloud runtime or a
    /// Job would — still cannot get past the boundary, because there is no
    /// route to the implementation that skips it.
    func testDirectCallerCannotBypassConfirmation() async {
        let broker = StubBroker(decision: .declined(reason: "denied"))
        registry.setPermissionBroker(broker)

        var didRun = false
        registry.register(
            BuddyToolDefinition(
                name: "test_external",
                description: "sends an email",
                inputSchema: .object(["type": .string("object")]),
                metadata: .external(.userAccount)
            )
        ) { _ in
            didRun = true
            return "sent"
        }

        // Invoked directly, exactly as a future runtime would.
        let outcome = await registry.invoke(name: "test_external", input: .object([:]))

        XCTAssertFalse(didRun, "no caller may reach an implementation without approval")
        XCTAssertTrue(outcome.wasDeclined)
    }

    /// MCP tools arrive from outside and are registered like any other, so they
    /// must be gated by the same code rather than by anything MCP-specific.
    func testMCPStyleToolTakesTheSamePath() async {
        let broker = StubBroker(decision: .declined(reason: "denied"))
        registry.setPermissionBroker(broker)

        var didRun = false
        registry.register(
            BuddyToolDefinition(
                name: "filesystem__write_file",
                description: "writes a file",
                inputSchema: .object(["type": .string("object")]),
                metadata: .unknown          // what an undescribed MCP tool gets
            )
        ) { _ in
            didRun = true
            return "written"
        }

        let outcome = await registry.invoke(name: "filesystem__write_file", input: .object([:]))

        XCTAssertFalse(didRun)
        XCTAssertTrue(outcome.wasDeclined)
        XCTAssertEqual(broker.askedAbout, ["filesystem__write_file"])
    }

    func testUnknownToolIsReportedRatherThanThrown() async {
        let outcome = await registry.invoke(name: "no_such_tool", input: .object([:]))
        XCTAssertTrue(outcome.isError)
        XCTAssertFalse(outcome.wasDeclined)
        XCTAssertTrue(outcome.content.contains("no tool called"))
    }

    // MARK: - Metadata policy

    func testMetadataDerivesConfirmationConsistently() {
        XCTAssertFalse(ToolMetadata.reading().requiresConfirmation)
        XCTAssertFalse(ToolMetadata.reading(.network).requiresConfirmation)
        XCTAssertTrue(ToolMetadata.writing().requiresConfirmation)
        XCTAssertTrue(ToolMetadata.external().requiresConfirmation)
        XCTAssertTrue(ToolMetadata(readOnly: true, destructive: true).requiresConfirmation,
                      "destructive overrides read-only rather than being ignored")
        XCTAssertTrue(ToolMetadata(readOnly: true, externalSideEffect: true).requiresConfirmation,
                      "leaving the machine always warrants asking")
        XCTAssertTrue(ToolMetadata.unknown.requiresConfirmation,
                      "an undescribed tool must be treated as dangerous")
    }

    /// A prompt nobody can hear cannot be consent.
    func testNoSpeechChannelDeniesRatherThanAllows() async {
        // A fresh coordinator rather than `.shared`: the test host is the full
        // app, whose `CompanionManager.start()` installs a speech handler on the
        // shared one — so `.shared` would put up a real prompt that anyone at
        // the machine could answer.
        let coordinator = ToolConfirmationCoordinator()
        let decision = await coordinator.requestApproval(
            toolName: "test_tool", argumentSummary: "{}"
        )
        // No handler installed on this coordinator, so this must refuse.
        XCTAssertFalse(decision.isApproved,
                       "an unanswerable question must not be treated as approval")
    }

    /// The prompt runs inside the per-tool timeout now, so the tool budget has
    /// to outlast the confirmation window or every prompt dies early.
    func testToolTimeoutOutlastsTheConfirmationWindow() {
        XCTAssertGreaterThan(
            AgentTurnRunner.perToolTimeoutSecondsForTesting,
            ToolConfirmationCoordinator.confirmationTimeoutSeconds,
            "a prompt would be abandoned while its countdown was still running"
        )
    }
}
