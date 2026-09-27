//
//  ShortcutsAgentToolsTests.swift
//  leanring-buddyTests
//
//  Proves the Apple Shortcuts tools: `shortcuts list` output is parsed into
//  names and identifiers, a request like "run my morning routine" finds the
//  "Morning Routine" shortcut (and ordinary questions don't), the run command
//  keeps a hostile name a single argument, `run_shortcut` always asks — even
//  under session auto-approve — and its confirmation card shows the shortcut
//  and its input. Pure logic only: nothing here spawns the shortcuts tool or
//  touches the shared bridge's state.
//

import XCTest
@testable import Wisp

@MainActor
final class ShortcutsAgentToolsTests: XCTestCase {

    // MARK: - Parsing `shortcuts list`

    func testParsesNamesWithIdentifiers() {
        let listOutput = """
        AI Recipe to Notes (EC0741DD-C9AB-4A5B-9233-2D291A270504)
        Morning Routine (B6AD5C95-F54D-4B2C-B43D-83599491830B)

        Backup (daily) (FA79DAE6-7536-419E-A646-12BC9380AEC1)
        """
        let parsedEntries = ShortcutsListParser.parseShortcutsListOutput(listOutput)
        XCTAssertEqual(parsedEntries, [
            AppleShortcutEntry(name: "AI Recipe to Notes", identifier: "EC0741DD-C9AB-4A5B-9233-2D291A270504"),
            AppleShortcutEntry(name: "Morning Routine", identifier: "B6AD5C95-F54D-4B2C-B43D-83599491830B"),
            AppleShortcutEntry(name: "Backup (daily)", identifier: "FA79DAE6-7536-419E-A646-12BC9380AEC1"),
        ])
    }

    func testParsesPlainNamesWithoutIdentifiers() {
        let parsedEntries = ShortcutsListParser.parseShortcutsListOutput("Find my Ti84 Calculator\nBackup (daily)\n")
        XCTAssertEqual(parsedEntries, [
            AppleShortcutEntry(name: "Find my Ti84 Calculator", identifier: nil),
            AppleShortcutEntry(name: "Backup (daily)", identifier: nil),
        ], "a parenthesis that is not a UUID stays part of the name")
    }

    func testEmptyListOutputParsesToNothing() {
        XCTAssertTrue(ShortcutsListParser.parseShortcutsListOutput("\n\n").isEmpty)
    }

    // MARK: - Command lines

    func testRunArgumentsPutTheNameLastAfterTerminator() {
        let hostileName = "-rf \"quoted\" name; rm -rf ~"
        let runArguments = ShortcutsCommandLine.runArguments(
            shortcutNameOrIdentifier: hostileName,
            inputFilePath: "/tmp/in.txt",
            outputFilePath: "/tmp/out"
        )
        XCTAssertEqual(runArguments, [
            "run", "--input-path", "/tmp/in.txt", "--output-path", "/tmp/out", "--", hostileName,
        ])
    }

    func testRunArgumentsWithoutInput() {
        let runArguments = ShortcutsCommandLine.runArguments(
            shortcutNameOrIdentifier: "Morning Routine",
            inputFilePath: nil,
            outputFilePath: "/tmp/out"
        )
        XCTAssertEqual(runArguments, ["run", "--output-path", "/tmp/out", "--", "Morning Routine"])
        XCTAssertEqual(ShortcutsCommandLine.listArguments, ["list", "--show-identifiers"])
    }

    // MARK: - Resolving a name the model gave

    private var exampleEntries: [AppleShortcutEntry] {
        [
            AppleShortcutEntry(name: "Morning Routine", identifier: "B6AD5C95-F54D-4B2C-B43D-83599491830B"),
            AppleShortcutEntry(name: "Mom's Birthday!", identifier: nil),
            AppleShortcutEntry(name: "Log Water", identifier: nil),
        ]
    }

    func testResolvesExactCaseInsensitiveAndIdentifierNames() {
        XCTAssertEqual(ShortcutNameMatcher.resolveShortcut(named: "Morning Routine", among: exampleEntries)?.name, "Morning Routine")
        XCTAssertEqual(ShortcutNameMatcher.resolveShortcut(named: "morning routine", among: exampleEntries)?.name, "Morning Routine")
        XCTAssertEqual(ShortcutNameMatcher.resolveShortcut(named: "moms birthday", among: exampleEntries)?.name, "Mom's Birthday!")
        XCTAssertEqual(
            ShortcutNameMatcher.resolveShortcut(named: "b6ad5c95-f54d-4b2c-b43d-83599491830b", among: exampleEntries)?.name,
            "Morning Routine"
        )
    }

    func testDoesNotResolveAFuzzyName() {
        XCTAssertNil(ShortcutNameMatcher.resolveShortcut(named: "Morning", among: exampleEntries),
                     "the user approved a specific name; a partial one must not run something else")
        XCTAssertNil(ShortcutNameMatcher.resolveShortcut(named: "  ", among: exampleEntries))
    }

    func testAmbiguousNormalizedNameDoesNotResolve() {
        let collidingEntries = [
            AppleShortcutEntry(name: "Log-Water", identifier: nil),
            AppleShortcutEntry(name: "Log Water!", identifier: nil),
        ]
        XCTAssertNil(ShortcutNameMatcher.resolveShortcut(named: "log water", among: collidingEntries))
    }

    // MARK: - Matching a request to names

    private let exampleShortcutNames = ["Morning Routine", "Weather", "Log Water", "AI Recipe to Notes", "Start Focus Timer"]

    func testRequestMatchesShortcutByName() {
        XCTAssertEqual(
            ShortcutNameMatcher.matchingShortcutNames(forRequest: "run my morning routine", among: exampleShortcutNames).first,
            "Morning Routine"
        )
        XCTAssertEqual(
            ShortcutNameMatcher.matchingShortcutNames(forRequest: "can you log water for me", among: exampleShortcutNames),
            ["Log Water"]
        )
        XCTAssertEqual(
            ShortcutNameMatcher.matchingShortcutNames(forRequest: "start my focus timer please", among: exampleShortcutNames),
            ["Start Focus Timer"]
        )
    }

    func testOneWordNameNeedsAnInvocationCue() {
        XCTAssertEqual(
            ShortcutNameMatcher.matchingShortcutNames(forRequest: "what's the weather like", among: exampleShortcutNames),
            [],
            "an ordinary question must not offer to run a shortcut"
        )
        XCTAssertEqual(
            ShortcutNameMatcher.matchingShortcutNames(forRequest: "run the weather shortcut", among: exampleShortcutNames),
            ["Weather"]
        )
    }

    func testGrammarWordsAloneDoNotMatch() {
        XCTAssertEqual(
            ShortcutNameMatcher.matchingShortcutNames(forRequest: "what's the weather", among: ["What’s a shortcut?"]),
            [],
            "sharing only \"what's\" with a request is not a match"
        )
    }

    func testUnrelatedRequestMatchesNothing() {
        XCTAssertEqual(
            ShortcutNameMatcher.matchingShortcutNames(forRequest: "summarize this page", among: exampleShortcutNames),
            []
        )
    }

    func testMatchingIsCappedAndRanksWholePhraseFirst() {
        let manyNames = ["Morning Routine", "Morning Routine Extended", "Routine Morning", "Morning Routine Lite", "Morning Routine Plus"]
        let matchingNames = ShortcutNameMatcher.matchingShortcutNames(forRequest: "run morning routine", among: manyNames)
        XCTAssertEqual(matchingNames.count, ShortcutNameMatcher.maximumMatchingNames)
        XCTAssertEqual(matchingNames.first, "Morning Routine")
    }

    // MARK: - Routing

    func testRoutingBoostsBothToolsWhenShortcutsAreMentioned() {
        let routingHints = ShortcutsToolRouting.routingHints(forRequest: "what shortcuts do I have", knownShortcutNames: [])
        XCTAssertEqual(routingHints.boostedToolNames, ["list_shortcuts", "run_shortcut"])
        XCTAssertTrue(routingHints.matchingShortcutNames.isEmpty)
    }

    func testKeyboardShortcutRequestsAreNotAboutAppleShortcuts() {
        XCTAssertFalse(ShortcutsToolRouting.mentionsAppleShortcuts("change my keyboard shortcut for push to talk"))
        XCTAssertTrue(ShortcutsToolRouting.mentionsAppleShortcuts("run my Log Water shortcut"))
    }

    func testMatchedNameBoostsRunShortcutAndNamesItInTheDescription() {
        let routingHints = ShortcutsToolRouting.routingHints(
            forRequest: "run my morning routine",
            knownShortcutNames: exampleShortcutNames
        )
        XCTAssertTrue(routingHints.boostedToolNames.contains("run_shortcut"))
        XCTAssertEqual(routingHints.matchingShortcutNames, ["Morning Routine"])

        let routedDefinitions = ShortcutsToolRouting.applyingMatchingShortcutNames(
            routingHints.matchingShortcutNames,
            to: [ShortcutsToolRouting.runShortcutDefinition(), ShortcutsToolRouting.listShortcutsDefinition]
        )
        XCTAssertTrue(routedDefinitions[0].description.contains("\"Morning Routine\""))
        XCTAssertEqual(routedDefinitions[1].description, ShortcutsToolRouting.listShortcutsDefinition.description)
        XCTAssertFalse(ShortcutsToolRouting.runShortcutDefinition().description.contains("Morning Routine"),
                       "the registered description never carries names; only a routed turn does")
    }

    func testRouterSelectsRunShortcutForAMatchedRequest() {
        let registry = AgentToolRegistry.makeEmptyForTesting()
        registry.register(ShortcutsToolRouting.runShortcutDefinition()) { _ in "" }
        registry.register(ShortcutsToolRouting.listShortcutsDefinition) { _ in "" }
        for fillerToolName in ["list_windows", "read_clipboard", "read_page", "remember", "forget", "open_url", "click_element"] {
            registry.register(BuddyToolDefinition(
                name: fillerToolName,
                description: "a tool",
                inputSchema: .object([:]),
                metadata: .reading(.localMachine)
            )) { _ in "" }
        }

        let routingHints = ShortcutsToolRouting.routingHints(
            forRequest: "run my morning routine",
            knownShortcutNames: exampleShortcutNames
        )
        let selectedToolNames = AgentToolRouter.select(
            from: registry.definitions,
            for: "run my morning routine",
            limit: AgentToolScope.maximumExposedTools,
            boostedToolNames: routingHints.boostedToolNames
        ).map(\.name)
        XCTAssertTrue(selectedToolNames.contains("run_shortcut"))
    }

    // MARK: - Metadata and safety

    func testRunShortcutRequiresConfirmationAndListDoesNot() {
        XCTAssertTrue(ShortcutsToolRouting.runShortcutDefinition().requiresConfirmation)
        XCTAssertFalse(ShortcutsToolRouting.listShortcutsDefinition.requiresConfirmation)
    }

    func testRunShortcutAlwaysAsksEvenWithSessionAutoApprove() {
        let agentWorkingDirectoryPath = "/Users/tester/Projects/app"
        XCTAssertTrue(ToolCallSafety.mustAskEvenWithSessionAutoApprove(
            toolName: "run_shortcut",
            toolInput: .object(["name": .string("Log Water")]),
            agentWorkingDirectoryPath: agentWorkingDirectoryPath
        ))
        XCTAssertTrue(ToolCallSafety.mustAskEvenWithSessionAutoApprove(
            toolName: "run_shortcut",
            toolInput: .object([:]),
            agentWorkingDirectoryPath: agentWorkingDirectoryPath
        ))
        XCTAssertFalse(ToolCallSafety.mustAskEvenWithSessionAutoApprove(
            toolName: "list_shortcuts",
            toolInput: .object([:]),
            agentWorkingDirectoryPath: agentWorkingDirectoryPath
        ))
    }

    // MARK: - Confirmation card

    func testRunShortcutCardShowsNameAndInput() {
        let confirmationCard = ToolConfirmationCardBuilder.confirmationCard(
            forToolNamed: "run_shortcut",
            toolInput: .object(["name": .string("Morning Routine"), "input": .string("good\n\nmorning")]),
            agentWorkingDirectoryPath: nil
        )
        guard case .header(let headerTitle, _, _)? = confirmationCard?.blocks.first else {
            return XCTFail("expected a header block")
        }
        XCTAssertEqual(headerTitle, "Run Shortcut")

        var pairsByKey: [String: String] = [:]
        for block in confirmationCard?.blocks ?? [] {
            if case .keyValue(let pairs) = block {
                for pair in pairs { pairsByKey[pair.key] = pair.value }
            }
        }
        XCTAssertEqual(pairsByKey["Shortcut"], "Morning Routine")
        XCTAssertEqual(pairsByKey["Input"], "good morning", "whitespace is collapsed for the card")
    }

    func testRunShortcutCardWithoutInputOmitsTheInputRow() {
        let confirmationCard = ToolConfirmationCardBuilder.confirmationCard(
            forToolNamed: "run_shortcut",
            toolInput: .object(["name": .string("Log Water")]),
            agentWorkingDirectoryPath: nil
        )
        let keyValueKeys = (confirmationCard?.blocks ?? []).flatMap { block -> [String] in
            if case .keyValue(let pairs) = block { return pairs.map(\.key) }
            return []
        }
        XCTAssertEqual(keyValueKeys, ["Shortcut"])
    }

    // MARK: - Result text

    private func processResult(status: Int32, standardOutput: String = "", standardError: String = "", didTimeOut: Bool = false) -> ShortcutsProcessResult {
        ShortcutsProcessResult(
            terminationStatus: status,
            standardOutputText: standardOutput,
            standardErrorText: standardError,
            didTimeOut: didTimeOut,
            launchFailureDescription: nil
        )
    }

    func testResultTextPrefersOutputFileAndCapsIt() {
        let longOutput = String(repeating: "x", count: ShortcutRunResultFormatter.maximumOutputCharacters + 50)
        let resultText = ShortcutRunResultFormatter.resultText(
            shortcutName: "Log Water",
            processResult: processResult(status: 0, standardOutput: "ignored"),
            outputFileData: Data(longOutput.utf8),
            timeoutSeconds: 120
        )
        XCTAssertTrue(resultText.hasPrefix("ran the shortcut \"Log Water\". its output:"))
        XCTAssertTrue(resultText.contains("truncated"))
        XCTAssertFalse(resultText.contains("ignored"))
    }

    func testResultTextReportsFailureTimeoutAndNoOutput() {
        XCTAssertTrue(ShortcutRunResultFormatter.resultText(
            shortcutName: "Log Water",
            processResult: processResult(status: 1, standardError: "Error: The operation couldn’t be completed. Couldn’t find shortcut\n"),
            outputFileData: nil,
            timeoutSeconds: 120
        ).contains("failed: The operation couldn’t be completed. Couldn’t find shortcut"))

        XCTAssertTrue(ShortcutRunResultFormatter.resultText(
            shortcutName: "Log Water",
            processResult: processResult(status: 15, didTimeOut: true),
            outputFileData: nil,
            timeoutSeconds: 120
        ).contains("still running after 120 seconds"))

        XCTAssertEqual(ShortcutRunResultFormatter.resultText(
            shortcutName: "Log Water",
            processResult: processResult(status: 0),
            outputFileData: Data(),
            timeoutSeconds: 120
        ), "ran the shortcut \"Log Water\". it finished without any output.")
    }
}
