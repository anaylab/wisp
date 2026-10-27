//
//  BuddyBotTests.swift
//  AgentRuntimeIntegration
//
//  Buddies as persistent bots: each one's own memory, its choice of model, and
//  what that choice changes — which tools it may use, how many can run at once,
//  and whether it queues behind the one local model. Real `AgentTurnRunner`,
//  `BuddyMemoryStore` and `BuddyRunToolkitBuilder`; only the model is scripted.
//

import Foundation

@MainActor func buddyBotSuite() async {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("buddy-bot-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    // MARK: Memory

    section("buddy memory: remember, dedupe, forget, persist")
    do {
        let buddyID = UUID()
        let otherBuddyID = UUID()
        let memoryStore = BuddyMemoryStore(memoryDirectoryURL: temporaryDirectory)

        check("a note is saved", memoryStore.remember("already reported the v2 launch", forBuddyWithID: buddyID)
              == .added("already reported the v2 launch"))
        check("the same note is recognised", memoryStore.remember("Already reported the V2 launch", forBuddyWithID: buddyID)
              == .alreadyKnown)
        check("an empty note is nothing", memoryStore.remember("   ", forBuddyWithID: buddyID) == .nothingToRemember)
        check("notes are per buddy", memoryStore.facts(ofBuddyWithID: otherBuddyID).isEmpty)

        let reloadedStore = BuddyMemoryStore(memoryDirectoryURL: temporaryDirectory)
        check("notes survive a restart", reloadedStore.facts(ofBuddyWithID: buddyID) == ["already reported the v2 launch"])

        _ = memoryStore.remember("skip anything about crypto", forBuddyWithID: buddyID)
        check("forget by description removes one", memoryStore.forget(matching: "crypto", forBuddyWithID: buddyID)
              == .removed(["skip anything about crypto"]))
        check("forget with no match says so", memoryStore.forget(matching: "zzz", forBuddyWithID: buddyID) == .nothingMatched)

        for noteNumber in 1...4 { _ = memoryStore.remember("shared topic note \(noteNumber)", forBuddyWithID: buddyID) }
        if case .tooManyMatches = memoryStore.forget(matching: "shared topic", forBuddyWithID: buddyID) {
            check("a vague forget is refused", true)
        } else {
            check("a vague forget is refused", false, "matched four notes and removed them")
        }

        memoryStore.forgetExactFact("shared topic note 1", forBuddyWithID: buddyID)
        check("an exact fact can be forgotten", !memoryStore.facts(ofBuddyWithID: buddyID).contains("shared topic note 1"))

        memoryStore.deleteMemory(ofBuddyWithID: buddyID)
        check("deleting a buddy deletes its notes",
              BuddyMemoryStore(memoryDirectoryURL: temporaryDirectory).facts(ofBuddyWithID: buddyID).isEmpty)
    }

    section("buddy memory: the cap and the prompt block")
    do {
        let buddyID = UUID()
        let memoryStore = BuddyMemoryStore(memoryDirectoryURL: temporaryDirectory)
        for noteNumber in 1...(BuddyMemoryPolicy.maximumStoredFacts + 5) {
            _ = memoryStore.remember("note \(noteNumber)", forBuddyWithID: buddyID)
        }
        let storedNotes = memoryStore.facts(ofBuddyWithID: buddyID)
        check("stored notes are capped", storedNotes.count == BuddyMemoryPolicy.maximumStoredFacts)
        check("the oldest notes fall off", storedNotes.first == "note 6")

        check("no notes means no prompt block", BuddyMemoryPolicy.promptInstructions(forFacts: []).isEmpty)
        let promptBlock = BuddyMemoryPolicy.promptInstructions(forFacts: ["a", "b"])
        check("the block lists the notes", promptBlock.contains("- a") && promptBlock.contains("- b"))
        check("the block frames notes as data, not instructions", promptBlock.contains("not instructions"))
    }

    // MARK: Model choice

    section("model choice: persistence and defaults")
    do {
        let choices = BuddyModelChoice.allChoices
        check("local is offered first and stays on this Mac", choices.first?.providerKind == .localOllama
              && choices.first?.sendsDataOffThisMachine == false)
        check("every Claude model is offered",
              AnthropicModelChoice.allCases.allSatisfy { claudeModel in
                  choices.contains { $0.providerKind == .anthropic && $0.claudeModel == claudeModel }
              })
        check("choice ids are unique", Set(choices.map(\.id)).count == choices.count)
        check("Apple on-device is offered and stays on this Mac",
              choices.contains { $0.providerKind == .appleOnDevice && !$0.sendsDataOffThisMachine })
        check("every cloud choice is flagged as leaving this Mac",
              choices.filter { $0.providerKind != .localOllama && $0.providerKind != .appleOnDevice }
                  .allSatisfy(\.sendsDataOffThisMachine))

        let sonnetChoice = BuddyModelChoice(providerKind: .anthropic, claudeModel: .sonnet)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let buddy = WispBuddy(id: UUID(), name: "Test", instruction: "job", colorIndex: 0, schedule: .once,
                              createdAt: Date(), runTaskIDs: [], nextScheduledRunAt: nil, modelChoice: sonnetChoice)
        let roundTrippedBuddy = try? decoder.decode(WispBuddy.self, from: encoder.encode(buddy))
        check("a buddy's model choice survives encoding", roundTrippedBuddy?.modelChoice == sonnetChoice)

        // A buddies.json written before model choice existed has no such key.
        let legacyJSON = """
        {"id":"\(UUID().uuidString)","name":"Old","instruction":"job","colorIndex":1,"schedule":{"once":{}},
         "createdAt":"2026-01-01T00:00:00Z","runTaskIDs":[]}
        """
        let legacyBuddy = try? decoder.decode(WispBuddy.self, from: Data(legacyJSON.utf8))
        check("an older buddy with no choice still loads", legacyBuddy != nil)
        check("and follows Wisp's model", legacyBuddy?.modelChoice == nil)
    }

    section("model choice: how many runs at once")
    do {
        typealias Capacity = BackgroundTaskCapacityPolicy
        check("local: two may run", Capacity.canStart(runsOffThisMachine: false, runningTotal: 1, runningOffThisMachine: 0))
        check("local: a third waits", !Capacity.canStart(runsOffThisMachine: false, runningTotal: 2, runningOffThisMachine: 0))
        check("cloud runs don't use up the local slots",
              Capacity.canStart(runsOffThisMachine: false, runningTotal: 3, runningOffThisMachine: 3))
        check("cloud: several run side by side",
              Capacity.canStart(runsOffThisMachine: true, runningTotal: 3, runningOffThisMachine: 3))
        check("cloud: still has a ceiling",
              !Capacity.canStart(runsOffThisMachine: true, runningTotal: 4, runningOffThisMachine: Capacity.maximumCloudTasks))
        check("local runs don't use up the cloud slots",
              Capacity.canStart(runsOffThisMachine: true, runningTotal: 2, runningOffThisMachine: 0))
    }

    // MARK: Tools

    section("a cloud buddy can't reach the brain or personal memory")
    do {
        let cloudExclusions = BuddyRunToolPolicy.excludedToolNames(modelSendsDataOffThisMachine: true)
        check("cloud: brain search is excluded", cloudExclusions.contains("search_brain"))
        check("cloud: brain pages are excluded", cloudExclusions.contains("read_brain_page"))
        check("cloud: personal memory is excluded", cloudExclusions.contains("remember") && cloudExclusions.contains("forget"))
        check("local: nothing is excluded", BuddyRunToolPolicy.excludedToolNames(modelSendsDataOffThisMachine: false).isEmpty)

        let registry = AgentToolRegistry.makeEmptyForTesting()
        let brainSearchRan = Ran()
        registry.register(definition("search_brain", .reading())) { _ in brainSearchRan.value = true; return "me.md: private" }
        let buddyID = UUID()
        let memoryStore = BuddyMemoryStore(memoryDirectoryURL: temporaryDirectory)

        // Control: a local buddy is offered the brain tool and can use it.
        let localProvider = ScriptedProvider(turns: [
            BuddyChatTurn(text: "", toolUses: [toolCall("t1", "search_brain")], stopReason: .toolUse),
            BuddyChatTurn(text: "ok", stopReason: .endTurn),
        ])
        _ = try? await run(
            AgentTurnRunner(modelProvider: localProvider, toolRegistry: registry,
                            toolkit: BuddyRunToolkitBuilder.toolkit(forBuddyWithID: buddyID, modelSendsDataOffThisMachine: false,
                                                                    memoryStore: memoryStore),
                            speakConfirmation: { _ in }),
            text: "search my brain for atlas")
        check("control: a local buddy is offered the brain tool",
              localProvider.receivedRequests.first?.tools.contains { $0.name == "search_brain" } == true)
        check("control: and can run it", brainSearchRan.value)

        // A cloud buddy: hidden from the model, and refused even when called by name.
        brainSearchRan.value = false
        let cloudProvider = NativeToolCallProvider(script: [
            .init(text: "", toolCalls: [toolCall("t1", "search_brain")]),
            .init(text: "ok"),
        ])
        let cloudOutcome = try? await run(
            AgentTurnRunner(modelProvider: cloudProvider, toolRegistry: registry,
                            toolkit: BuddyRunToolkitBuilder.toolkit(forBuddyWithID: buddyID, modelSendsDataOffThisMachine: true,
                                                                    memoryStore: memoryStore),
                            speakConfirmation: { _ in }),
            text: "search my brain for atlas")
        check("a cloud buddy is not offered the brain tool",
              cloudProvider.receivedRequests.first?.tools.contains { $0.name == "search_brain" } == false)
        check("a cloud buddy calling it by name is refused", !brainSearchRan.value)
        check("the refusal is reported to the model", cloudOutcome?.messages.contains { message in
            message.blocks.contains { block in
                if case .toolResult(_, _, let content, let isError) = block { return isError && content.contains("isn't available") }
                return false
            }
        } == true)
    }

    section("a buddy's own memory tools")
    do {
        let buddyID = UUID()
        let memoryStore = BuddyMemoryStore(memoryDirectoryURL: temporaryDirectory)
        let provider = NativeToolCallProvider(script: [
            .init(text: "", toolCalls: [toolCall("t1", BuddyRunToolkitBuilder.rememberToolName,
                                                 .object(["fact": .string("user only wants AI news")]))]),
            .init(text: "saved."),
        ])
        let outcome = try? await run(
            AgentTurnRunner(modelProvider: provider, toolRegistry: AgentToolRegistry.makeEmptyForTesting(),
                            toolkit: BuddyRunToolkitBuilder.toolkit(forBuddyWithID: buddyID, modelSendsDataOffThisMachine: true,
                                                                    memoryStore: memoryStore),
                            speakConfirmation: { _ in }),
            text: "digest")
        check("the memory tool is offered", provider.receivedRequests.first?.tools.contains {
            $0.name == BuddyRunToolkitBuilder.rememberToolName } == true)
        check("calling it saves to that buddy's memory", memoryStore.facts(ofBuddyWithID: buddyID) == ["user only wants AI news"])
        check("without asking for approval, and the run finishes", outcome?.terminalText == "saved.")
        check("another buddy's memory is untouched", memoryStore.facts(ofBuddyWithID: UUID()).isEmpty)
    }

    // MARK: Tool allow-list

    section("tool allow-list: the policy")
    do {
        typealias Policy = BuddyToolAccessPolicy
        let browserOnly = BuddyToolAccess(allowedGroupIDs: [BuddyToolGroup.browser.rawValue])
        func permitted(_ name: String, _ access: BuddyToolAccess?, cloud: Bool = false) -> Bool {
            Policy.isPermitted(toolNamed: name, access: access, modelSendsDataOffThisMachine: cloud)
        }

        check("no limit allows a built-in tool", permitted("send_imessage", nil))
        check("no limit allows a connected app's tool", permitted("github__search_issues", nil))
        check("a limited buddy keeps its group", permitted("browser_task", browserOnly) && permitted("chrome_list_tabs", browserOnly))
        check("and loses the others", !permitted("send_imessage", browserOnly) && !permitted("run_shortcut", browserOnly)
              && !permitted("create_reminder", browserOnly) && !permitted("delegate_coding_task", browserOnly))
        check("a connected app is its own group", !permitted("github__search_issues", browserOnly)
              && permitted("github__search_issues", browserOnly.setting(groupID: Policy.groupID(forServerNamed: "github"), isAllowed: true)))
        check("allowing one server doesn't allow another",
              !permitted("slack__post", browserOnly.setting(groupID: Policy.groupID(forServerNamed: "github"), isAllowed: true)))
        check("the clock and skills are always there", permitted("get_current_time", BuddyToolAccess.nothing)
              && permitted("load_skill", BuddyToolAccess.nothing))
        check("a tool in no group is refused to a limited buddy", !permitted("some_future_tool", browserOnly))
        check("but allowed to an unlimited one", permitted("some_future_tool", nil))
        check("do_in_background is never available", !permitted("do_in_background", nil)
              && !permitted("do_in_background", browserOnly))
        check("a cloud buddy never gets brain or memory even if allowed",
              !permitted("search_brain", BuddyToolAccess(allowedGroupIDs: ["brain"]), cloud: true)
              && !permitted("remember", BuddyToolAccess(allowedGroupIDs: ["memory"]), cloud: true)
              && !permitted("remember", nil, cloud: true))
        check("a local buddy can be given the brain", permitted("search_brain", BuddyToolAccess(allowedGroupIDs: ["brain"])))

        check("every built-in group has a name, summary and icon",
              BuddyToolGroup.allCases.allSatisfy { !$0.title.isEmpty && !$0.summary.isEmpty && !$0.symbolName.isEmpty })
        check("servers are listed from tool names",
              Policy.serverNames(inToolNames: ["browser_task", "github__a", "github__b", "slack__x", "remember"]) == ["github", "slack"])
        check("summaries read plainly", Policy.summary(of: nil) == "All tools"
              && Policy.summary(of: .nothing) == "No extra tools"
              && Policy.summary(of: browserOnly) == "Browser"
              && Policy.summary(of: BuddyToolAccess(allowedGroupIDs: ["browser", "screen", "brain"])) == "Browser, Screen +1")

        let encodedAccess = try? JSONEncoder().encode(browserOnly)
        check("the allow-list survives encoding",
              encodedAccess.flatMap { try? JSONDecoder().decode(BuddyToolAccess.self, from: $0) } == browserOnly)
        let legacyBuddyJSON = """
        {"id":"\(UUID().uuidString)","name":"Old","instruction":"job","colorIndex":1,"schedule":{"once":{}},
         "createdAt":"2026-01-01T00:00:00Z","runTaskIDs":[]}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        check("an older buddy has no limit", (try? decoder.decode(WispBuddy.self, from: Data(legacyBuddyJSON.utf8)))?.toolAccess == nil)
    }

    section("tool allow-list: what the model is shown and can call")
    do {
        let registry = AgentToolRegistry.makeEmptyForTesting()
        let ran = Ran()
        let sentMessage = Ran()
        for toolName in ["browser_task", "read_page", "list_windows", "run_shortcut", "create_reminder", "github__search_issues"] {
            registry.register(definition(toolName, .reading())) { _ in ran.value = true; return "\(toolName) ok" }
        }
        registry.register(definition("send_imessage", .reading())) { _ in sentMessage.value = true; return "sent" }
        let requestText = "browse the page, list windows, run a shortcut, add a reminder, search github issues, send a message"

        let browserOnly = BuddyToolAccess(allowedGroupIDs: [BuddyToolGroup.browser.rawValue])
        let browserOnlyToolkit = BuddyRunToolkitBuilder.toolkit(
            forBuddyWithID: UUID(), modelSendsDataOffThisMachine: false, toolAccess: browserOnly,
            memoryStore: BuddyMemoryStore(memoryDirectoryURL: temporaryDirectory))

        let shownNames = Set(registry.definitions(forRequest: requestText, isToolPermitted: browserOnlyToolkit.permits(_:)).map(\.name))
        check("a limited buddy is shown only its group's tools", shownNames.isSubset(of: ["browser_task", "read_page", "get_current_time", "load_skill"]),
              shownNames.sorted().joined(separator: ","))
        check("and does get them", shownNames.contains("browser_task") && shownNames.contains("read_page"))

        let unlimitedShown = Set(registry.definitions(forRequest: requestText).map(\.name))
        check("control: without a limit the other tools are offered", unlimitedShown.contains("send_imessage")
              || unlimitedShown.contains("github__search_issues"))

        // Held to it at call time too — including a tool that registers after the run began.
        registry.register(definition("slack__post_message", .reading())) { _ in ran.value = true; return "posted" }
        let provider = NativeToolCallProvider(script: [
            .init(text: "", toolCalls: [toolCall("t1", "send_imessage"), toolCall("t2", "slack__post_message"),
                                        toolCall("t3", "do_in_background")]),
            .init(text: "done"),
        ])
        let outcome = try? await run(
            AgentTurnRunner(modelProvider: provider, toolRegistry: registry, toolkit: browserOnlyToolkit, speakConfirmation: { _ in }),
            text: requestText)
        let refusalCount = outcome?.messages.flatMap(\.blocks).filter { block in
            if case .toolResult(_, _, let content, let isError) = block { return isError && content.contains("isn't available") }
            return false
        }.count
        check("calling a tool outside the list by name is refused", !sentMessage.value && refusalCount == 3,
              "refusals: \(refusalCount ?? -1)")
        check("including one that registered late, and do_in_background", !ran.value)
    }

    // MARK: Delegation

    func makeBuddy(_ name: String, job: String = "do the job", model: BuddyModelChoice? = nil, toolAccess: BuddyToolAccess? = nil) -> WispBuddy {
        WispBuddy(id: UUID(), name: name, instruction: job, colorIndex: 0, schedule: .once,
                  createdAt: Date(), runTaskIDs: [], nextScheduledRunAt: nil, modelChoice: model, toolAccess: toolAccess)
    }
    let claudeChoice = BuddyModelChoice(providerKind: .anthropic, claudeModel: .sonnet)
    let localChoice = BuddyModelChoice(providerKind: .localOllama, claudeModel: nil)

    section("delegation: choosing the peer and where the data goes")
    do {
        let caller = makeBuddy("Caller")
        let gmail = makeBuddy("Gmail Digest"), news = makeBuddy("News Digest"), scout = makeBuddy("Scout")
        let everyone = [caller, gmail, news, scout]
        typealias Policy = BuddyDelegationPolicy

        check("an exact name (any case) is found", Policy.resolveTarget(named: "gmail digest", among: everyone, excludingBuddyWithID: caller.id) == .found(gmail))
        check("a unique part of a name is found", Policy.resolveTarget(named: "scou", among: everyone, excludingBuddyWithID: caller.id) == .found(scout))
        check("two matches are ambiguous, not guessed",
              Policy.resolveTarget(named: "digest", among: everyone, excludingBuddyWithID: caller.id) == .ambiguous(["Gmail Digest", "News Digest"]))
        check("a buddy can't ask itself", Policy.resolveTarget(named: "Caller", among: everyone, excludingBuddyWithID: caller.id) == .notFound)
        check("an unknown name is not found", Policy.resolveTarget(named: "nobody", among: everyone, excludingBuddyWithID: caller.id) == .notFound)
        check("a blank name is not found", Policy.resolveTarget(named: "  ", among: everyone, excludingBuddyWithID: caller.id) == .notFound)

        check("same model: no approval", !Policy.requiresApproval(callerProvider: .localOllama, targetProvider: .localOllama)
              && !Policy.requiresApproval(callerProvider: .anthropic, targetProvider: .anthropic))
        check("local to cloud asks", Policy.requiresApproval(callerProvider: .localOllama, targetProvider: .anthropic))
        check("cloud to local asks", Policy.requiresApproval(callerProvider: .anthropic, targetProvider: .localOllama))
        check("cloud to a different cloud asks", Policy.requiresApproval(callerProvider: .anthropic, targetProvider: .openAI))

        let toCloud = Policy.boundaryNote(callerName: "A", callerProvider: .localOllama, targetName: "B", targetProvider: .anthropic)
        let fromCloud = Policy.boundaryNote(callerName: "A", callerProvider: .anthropic, targetName: "B", targetProvider: .localOllama)
        check("the note says a message to the cloud leaves the Mac", toCloud.contains("leaves your Mac") && toCloud.contains("Claude"))
        check("the note says a cloud caller gets a local answer back", fromCloud.contains("B runs on your Mac") && fromCloud.contains("Claude"))

        let longJob = makeBuddy("Long", job: String(repeating: "x", count: 200))
        let listing = Policy.peerListing(of: [caller, longJob], excludingBuddyWithID: caller.id)
        check("the listing leaves out the caller and clips jobs", !listing.contains("Caller") && listing.contains("Long") && listing.contains("…") && listing.count < 150)
        check("no peers, no listing", Policy.peerListing(of: [caller], excludingBuddyWithID: caller.id).isEmpty)
    }

    section("delegation: the flow")
    do {
        final class RunBoard {
            var records: [UUID: AgentTaskRecord] = [:]
            var startedRequests: [(target: String, message: String, from: String)] = []
            var cancelledRunIDs: [UUID] = []
        }
        func makeService(
            board: RunBoard, buddies: [WispBuddy], broker: ToolPermissionBroker,
            finishWith: AgentTaskRecord.Status? = .succeeded, answer: String = "3 new emails",
            canStart: Bool = true, timeout: TimeInterval = 5
        ) -> BuddyDelegationService {
            BuddyDelegationService(
                buddies: { buddies },
                startRun: { target, message, from in
                    guard canStart else { return nil }
                    let taskID = UUID()
                    board.records[taskID] = AgentTaskRecord(id: taskID, title: target.name, kind: .background)
                    board.startedRequests.append((target.name, message, from))
                    if let finishWith {
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 120_000_000)
                            board.records[taskID]?.status = finishWith
                            board.records[taskID]?.finalText = answer
                        }
                    }
                    return taskID
                },
                runRecord: { board.records[$0] },
                cancelRun: { taskID in
                    board.cancelledRunIDs.append(taskID)
                    board.records[taskID]?.status = .cancelled
                },
                broker: broker,
                providerKind: { $0.modelChoice?.providerKind ?? .localOllama },
                pollIntervalSeconds: 0.03,
                answerTimeoutSeconds: timeout)
        }

        let caller = makeBuddy("Caller"), gmail = makeBuddy("Gmail Digest")
        let approvingBroker = StubBroker(decision: .approved)
        let decliningBroker = StubBroker(decision: .declined(reason: "no"))

        // Same model: answered with no approval.
        var board = RunBoard()
        var answer = await makeService(board: board, buddies: [caller, gmail], broker: decliningBroker)
            .askBuddy(from: caller, targetName: "gmail", message: "anything new?")
        check("same model: the peer's answer comes back", answer == "Gmail Digest says: 3 new emails", answer)
        check("same model: the peer was asked the message by name", board.startedRequests.first?.target == "Gmail Digest"
              && board.startedRequests.first?.message == "anything new?" && board.startedRequests.first?.from == "Caller")
        check("same model: nobody was asked for approval", decliningBroker.askedAbout.isEmpty)

        // Local asking cloud: approval card input, declined → nothing starts.
        let cloudGmail = makeBuddy("Gmail Digest", model: claudeChoice)
        board = RunBoard()
        answer = await makeService(board: board, buddies: [caller, cloudGmail], broker: decliningBroker)
            .askBuddy(from: caller, targetName: "Gmail Digest", message: "private plans")
        check("a declined crossing never starts the peer", board.startedRequests.isEmpty && answer.contains("didn't approve"), answer)
        check("the user was asked", decliningBroker.askedAbout == [BuddyDelegationToolNames.askBuddy])

        board = RunBoard()
        answer = await makeService(board: board, buddies: [caller, cloudGmail], broker: approvingBroker)
            .askBuddy(from: caller, targetName: "Gmail Digest", message: "ok to send")
        check("an approved crossing goes through", answer.hasPrefix("Gmail Digest says:") && board.startedRequests.count == 1, answer)

        // Busy / unknown / ambiguous / empty.
        board = RunBoard()
        answer = await makeService(board: board, buddies: [caller, gmail], broker: approvingBroker, canStart: false)
            .askBuddy(from: caller, targetName: "Gmail Digest", message: "hi")
        check("a busy peer is reported at once", answer.contains("busy"), answer)
        answer = await makeService(board: board, buddies: [caller], broker: approvingBroker)
            .askBuddy(from: caller, targetName: "x", message: "hi")
        check("no peers is said plainly", answer.contains("no other buddies"), answer)
        answer = await makeService(board: board, buddies: [caller, gmail], broker: approvingBroker)
            .askBuddy(from: caller, targetName: "Gmail Digest", message: "   ")
        check("an empty message is refused", answer.contains("need a message"), answer)

        // Failure and timeout.
        board = RunBoard()
        answer = await makeService(board: board, buddies: [caller, gmail], broker: approvingBroker, finishWith: .failed("no key"))
            .askBuddy(from: caller, targetName: "Gmail Digest", message: "hi")
        check("a failed peer run is reported", answer.contains("couldn't answer") && answer.contains("no key"), answer)

        board = RunBoard()
        answer = await makeService(board: board, buddies: [caller, gmail], broker: approvingBroker, finishWith: nil, timeout: 0.25)
            .askBuddy(from: caller, targetName: "Gmail Digest", message: "hi")
        check("a peer that never answers is stopped and reported", answer.contains("didn't answer in time") && board.cancelledRunIDs.count == 1, answer)
    }

    section("delegation: the tool a buddy is given")
    do {
        let caller = makeBuddy("Caller"), peer = makeBuddy("Peer")
        let service = BuddyDelegationService(
            buddies: { [caller, peer] }, startRun: { _, _, _ in nil }, runRecord: { _ in nil },
            cancelRun: { _ in }, broker: StubBroker(decision: .approved))
        let memoryStore = BuddyMemoryStore(memoryDirectoryURL: temporaryDirectory)
        func toolkit(access: BuddyToolAccess? = nil, delegation: Bool = true, cloud: Bool = false) -> AgentRunToolkit {
            BuddyRunToolkitBuilder.toolkit(
                forBuddyWithID: caller.id, modelSendsDataOffThisMachine: cloud, toolAccess: access,
                delegation: delegation ? (caller: caller, service: service) : nil, memoryStore: memoryStore)
        }
        func offersAskBuddy(_ kit: AgentRunToolkit) -> Bool { kit.additionalTool(named: BuddyDelegationToolNames.askBuddy) != nil }

        check("a buddy with a peer is given the tool", offersAskBuddy(toolkit()))
        check("the tool names the peers", toolkit().additionalTool(named: BuddyDelegationToolNames.askBuddy)?.definition.description.contains("Peer") == true)
        check("a run a peer started is not (no chains)", !offersAskBuddy(toolkit(delegation: false)))
        check("a limited buddy without the group is not", !offersAskBuddy(toolkit(access: BuddyToolAccess(allowedGroupIDs: ["browser"]))))
        check("a limited buddy with the group is",
              offersAskBuddy(toolkit(access: BuddyToolAccess(allowedGroupIDs: [BuddyToolGroup.delegation.rawValue]))))
        check("a cloud buddy can still ask (the card handles the boundary)", offersAskBuddy(toolkit(cloud: true)))

        let loneService = BuddyDelegationService(
            buddies: { [caller] }, startRun: { _, _, _ in nil }, runRecord: { _ in nil },
            cancelRun: { _ in }, broker: StubBroker(decision: .approved))
        let loneKit = BuddyRunToolkitBuilder.toolkit(forBuddyWithID: caller.id, modelSendsDataOffThisMachine: false,
                                                     delegation: (caller: caller, service: loneService), memoryStore: memoryStore)
        check("no peers, no tool", !offersAskBuddy(loneKit))

        // Through the real runner: the model calls it and gets the answer.
        let answeringService = BuddyDelegationService(
            buddies: { [caller, peer] },
            startRun: { _, _, _ in
                let taskID = UUID()
                return taskID
            },
            runRecord: { taskID in AgentTaskRecord(id: taskID, title: "Peer", kind: .background, status: .succeeded, finalText: "peer says hi") },
            cancelRun: { _ in }, broker: StubBroker(decision: .approved), pollIntervalSeconds: 0.01)
        let provider = NativeToolCallProvider(script: [
            .init(text: "", toolCalls: [toolCall("t1", BuddyDelegationToolNames.askBuddy,
                                                 .object(["buddy": .string("Peer"), "message": .string("hello?")]))]),
            .init(text: "done"),
        ])
        let outcome = try? await run(
            AgentTurnRunner(modelProvider: provider, toolRegistry: AgentToolRegistry.makeEmptyForTesting(),
                            toolkit: BuddyRunToolkitBuilder.toolkit(
                                forBuddyWithID: caller.id, modelSendsDataOffThisMachine: true,
                                delegation: (caller: caller, service: answeringService), memoryStore: memoryStore),
                            speakConfirmation: { _ in }),
            text: "ask the peer")
        let toolResults = outcome?.messages.flatMap(\.blocks).compactMap { block -> String? in
            if case .toolResult(_, _, let content, _) = block { return content }
            return nil
        }
        check("the model gets the peer's answer as the tool result", toolResults == ["Peer says: peer says hi"], "\(toolResults ?? [])")
    }

    section("delegation: the thread, the store and the approval card")
    do {
        let delegatedExchange = BuddyThreadExchange(taskID: UUID(), startedAt: Date(), origin: .delegated,
                                                    userText: "any news?", answerText: "yes", requesterName: "Scout")
        let history = BuddyThreadPolicy.historyMessages(from: [delegatedExchange])
        check("a peer's request is shown to the model with who sent it", history.first?.combinedText == "Scout asked you: any news?")
        check("the delegated addendum says it isn't the user",
              BuddyThreadPolicy.delegatedRequestAddendum(requesterName: "Scout").contains("not from the user"))

        let encoded = try? JSONEncoder().encode(delegatedExchange)
        check("the requester survives encoding", encoded.flatMap { try? JSONDecoder().decode(BuddyThreadExchange.self, from: $0) }?.requesterName == "Scout")
        let legacyExchangeJSON = "{\"taskID\":\"\(UUID().uuidString)\",\"startedAt\":\"2026-01-01T00:00:00Z\",\"origin\":\"message\",\"userText\":\"hi\"}"
        let isoDecoder = JSONDecoder(); isoDecoder.dateDecodingStrategy = .iso8601
        check("an older exchange with no requester still loads",
              (try? isoDecoder.decode(BuddyThreadExchange.self, from: Data(legacyExchangeJSON.utf8)))?.requesterName == nil)

        let askInput: JSONValue = .object([
            "from": .string("Caller"), "from_model": .string("Local (Ollama)"),
            "to": .string("Gmail Digest"), "to_model": .string("Claude (Anthropic)"),
            "message": .string("private plans"), "note": .string("This message leaves your Mac: it goes to Claude (Anthropic)."),
        ])
        let card = ToolConfirmationCardBuilder.confirmationCard(forToolNamed: BuddyDelegationToolNames.askBuddy, toolInput: askInput, agentWorkingDirectoryPath: nil)
        let cardText = "\(card as Any)"
        check("the approval card exists and names both buddies, the message and where it goes",
              card != nil && cardText.contains("Ask Buddy") && cardText.contains("Gmail Digest") && cardText.contains("private plans")
              && cardText.contains("leaves your Mac"))
        check("it asks even with session auto-approve", ToolCallSafety.mustAskEvenWithSessionAutoApprove(
            toolName: BuddyDelegationToolNames.askBuddy, toolInput: askInput, agentWorkingDirectoryPath: "/tmp"))

        let storeFileURL = temporaryDirectory.appendingPathComponent("delegation-buddies.json")
        let buddyStore = BuddyStore(buddiesFileURL: storeFileURL)
        var receivedRequests: [BuddyRunRequest] = []
        buddyStore.start { _, runRequest in
            receivedRequests.append(runRequest)
            return UUID()
        }
        let target = buddyStore.createBuddy(instruction: "summarize my Gmail", schedule: .daily(hour: 9, minute: 0), runImmediately: false)
        let delegatedRunID = buddyStore.startDelegatedRun(to: target.id, message: "anything new?", fromBuddyNamed: "Scout")
        check("a delegated run starts with the requester and message",
              delegatedRunID != nil && receivedRequests.last?.origin == .delegated
              && receivedRequests.last?.requesterName == "Scout" && receivedRequests.last?.text == "anything new?")
        check("the run is recorded on the target buddy", buddyStore.buddy(withID: target.id)?.runTaskIDs.last == delegatedRunID)
        check("an unknown buddy can't be delegated to", buddyStore.startDelegatedRun(to: UUID(), message: "x", fromBuddyNamed: "Scout") == nil)
    }

    // MARK: The shared local model

    section("a cloud buddy doesn't queue behind the local model")
    do {
        // Something holds the one local model for a while — a live conversation.
        let holderStarted = Date()
        let localModelHolder = Task { @MainActor in
            await ModelAccessGate.shared.withAccess(priority: .interactive) {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        try? await Task.sleep(nanoseconds: 150_000_000)

        let cloudStartedAt = Date()
        let cloudProvider = NativeToolCallProvider(script: [.init(text: "cloud answer")])
        let cloudOutcome = try? await run(
            AgentTurnRunner(modelProvider: cloudProvider, toolRegistry: AgentToolRegistry.makeEmptyForTesting(),
                            priority: .background, speakConfirmation: { _ in }))
        let cloudSeconds = Date().timeIntervalSince(cloudStartedAt)
        check("the cloud buddy answered", cloudOutcome?.terminalText == "cloud answer")
        check("without waiting for the local model", cloudSeconds < 0.8, "took \(cloudSeconds)s")

        let localProvider = ScriptedProvider(turns: [BuddyChatTurn(text: "local answer", stopReason: .endTurn)])
        _ = try? await run(
            AgentTurnRunner(modelProvider: localProvider, toolRegistry: AgentToolRegistry.makeEmptyForTesting(),
                            priority: .background, speakConfirmation: { _ in }))
        check("a local buddy still waits its turn", Date().timeIntervalSince(holderStarted) >= 1.3)
        await localModelHolder.value
    }
}
