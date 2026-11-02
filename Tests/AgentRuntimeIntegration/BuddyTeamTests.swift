//
//  BuddyTeamTests.swift
//
//  Phase 4 of docs/openbot-buddies-plan.md: list_buddies, ask_buddy with
//  several names, start_thread and create_buddy, through the real delegation
//  service and toolkit with fake stores, and the pure team rules.
//

import Foundation

/// Approves or declines like StubBroker, and keeps each structured input.
final class CapturingBroker: ToolPermissionBroker {
    var decision: ToolConfirmationCoordinator.Decision
    private(set) var askedInputs: [(toolName: String, toolInput: JSONValue)] = []
    init(decision: ToolConfirmationCoordinator.Decision) { self.decision = decision }
    func requestApproval(toolName: String, argumentSummary: String) async -> ToolConfirmationCoordinator.Decision { decision }
    func requestApproval(toolName: String, toolInput: JSONValue) async -> ToolConfirmationCoordinator.Decision {
        askedInputs.append((toolName, toolInput))
        return decision
    }
}

@MainActor func buddyTeamSuite() async {
    func makeTeamBuddy(_ name: String, job: String = "do the job", model: BuddyModelChoice? = nil, toolAccess: BuddyToolAccess? = nil) -> WispBuddy {
        WispBuddy(id: UUID(), name: name, instruction: job, colorIndex: 0, schedule: .once,
                  createdAt: Date(), runTaskIDs: [], nextScheduledRunAt: nil, modelChoice: model, toolAccess: toolAccess)
    }
    func string(_ key: String, in input: JSONValue) -> String? {
        if case .object(let object) = input, case .string(let value)? = object[key] { return value }
        return nil
    }
    let claudeChoice = BuddyModelChoice(providerKind: .anthropic, claudeModel: .sonnet)

    final class Board {
        var records: [UUID: AgentTaskRecord] = [:]
        var started: [String] = []
        var cancelled: [UUID] = []
    }
    func service(
        board: Board, buddies: [WispBuddy], broker: ToolPermissionBroker,
        answers: [String: String] = [:], busyNames: Set<String> = [], neverAnswer: Set<String> = [], timeout: TimeInterval = 5
    ) -> BuddyDelegationService {
        BuddyDelegationService(
            buddies: { buddies },
            startRun: { target, _, _ in
                guard !busyNames.contains(target.name) else { return nil }
                let taskID = UUID()
                board.records[taskID] = AgentTaskRecord(id: taskID, title: target.name, kind: .background)
                board.started.append(target.name)
                if !neverAnswer.contains(target.name) {
                    // The later-asked peer answers first, to prove order follows the asking.
                    let delay: UInt64 = board.started.count == 1 ? 150_000_000 : 40_000_000
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: delay)
                        board.records[taskID]?.status = .succeeded
                        board.records[taskID]?.finalText = answers[target.name] ?? "ok"
                    }
                }
                return taskID
            },
            runRecord: { board.records[$0] },
            cancelRun: { taskID in board.cancelled.append(taskID); board.records[taskID]?.status = .cancelled },
            broker: broker,
            providerKind: { $0.modelChoice?.providerKind ?? .localOllama },
            pollIntervalSeconds: 0.02,
            answerTimeoutSeconds: timeout
        )
    }

    section("team: asking several buddies at once")
    do {
        let caller = makeTeamBuddy("Planner"), mail = makeTeamBuddy("Inbox"), notes = makeTeamBuddy("Writer")
        let board = Board()
        let broker = CapturingBroker(decision: .declined(reason: "no"))
        let reply = await service(board: board, buddies: [caller, mail, notes], broker: broker,
                                  answers: ["Inbox": "2 replies due", "Writer": "draft is half done"])
            .askBuddies(from: caller, targetNames: ["Inbox", "Writer"], message: "status?")
        check("several: both were asked", Set(board.started) == ["Inbox", "Writer"], board.started.description)
        check("several: answers come back in the order asked", reply == "Inbox says: 2 replies due\n\nWriter says: draft is half done", reply)
        check("several: same model, nobody was asked to approve", broker.askedInputs.isEmpty)
    }
    do {
        let caller = makeTeamBuddy("Planner"), local = makeTeamBuddy("Inbox"), cloud = makeTeamBuddy("Researcher", model: claudeChoice)
        let board = Board()
        let decliningBroker = CapturingBroker(decision: .declined(reason: "no"))
        let reply = await service(board: board, buddies: [caller, local, cloud], broker: decliningBroker, answers: ["Inbox": "fine"])
            .askBuddies(from: caller, targetNames: ["Inbox", "Researcher"], message: "private plans")
        check("mixed: one card for the crossing", decliningBroker.askedInputs.count == 1)
        check("mixed: the card names only the peer across the boundary", decliningBroker.askedInputs.first.flatMap { string("to", in: $0.toolInput) } == "Researcher")
        check("mixed: a declined crossing never starts that peer", board.started == ["Inbox"], board.started.description)
        check("mixed: the same-model peer still answers, and the refusal is said",
              reply.hasPrefix("Inbox says: fine") && reply.contains("didn't approve sending that to Researcher"), reply)
    }
    do {
        let caller = makeTeamBuddy("Planner"), mail = makeTeamBuddy("Inbox"), slow = makeTeamBuddy("Slow")
        let board = Board()
        let reply = await service(board: board, buddies: [caller, mail, slow], broker: CapturingBroker(decision: .approved),
                                  busyNames: ["Inbox"], neverAnswer: ["Slow"], timeout: 0.3)
            .askBuddies(from: caller, targetNames: ["Inbox", "Slow", "Nobody"], message: "hi")
        check("several: a busy peer is reported", reply.contains("Inbox is busy"), reply)
        check("several: a peer that never answers is stopped", reply.contains("Slow didn't answer in time") && board.cancelled.count == 1, reply)
        check("several: an unknown name is said", reply.contains("no buddy called \"Nobody\""), reply)
    }
    check("names: one and several merge, repeats and blanks dropped",
          BuddyTeamPolicy.requestedNames(single: "Inbox", several: ["inbox", " ", "Writer"]) == ["Inbox", "Writer"])
    check("names: capped", BuddyTeamPolicy.requestedNames(single: nil, several: ["a", "b", "c", "d", "e"]).count == BuddyTeamPolicy.maximumBuddiesPerAsk)

    section("team: list_buddies")
    do {
        let caller = makeTeamBuddy("Planner")
        let mail = makeTeamBuddy("Inbox", job: String(repeating: "triage mail ", count: 40))
        var hidden = makeTeamBuddy("Secret")
        hidden.isHidden = true
        var listingService = service(board: Board(), buddies: [caller, mail, hidden], broker: CapturingBroker(decision: .approved))
        let now = Date()
        listingService.peerStatus = { peer in
            BuddyPeerStatus(state: .working, waitingMessageCount: 2, lastActivityAt: now.addingTimeInterval(-300))
        }
        let listing = listingService.listBuddies(for: caller, now: now)
        check("list: names the peer, not the caller", listing.contains("- Inbox:") && !listing.contains("Planner"), listing)
        check("list: a hidden buddy is left out", !listing.contains("Secret"), listing)
        check("list: the job is capped", listing.contains("…"), listing)
        check("list: status, queue and activity", listing.contains("[working, 2 messages waiting, last active 5 min ago]"), listing)
        check("list: no peers is said", BuddyTeamPolicy.peerListing([]) == "you have no other buddies.")
    }

    section("team: start_thread")
    do {
        let caller = makeTeamBuddy("Planner")
        var threadService = service(board: Board(), buddies: [caller], broker: CapturingBroker(decision: .approved))
        var startedTasks: [String] = []
        threadService.startSideThread = { _, task in startedTasks.append(task); return .started }
        let reply = threadService.startThread(for: caller, task: "  research flights to Lisbon  ")
        check("thread: the task is handed over trimmed", startedTasks == ["research flights to Lisbon"])
        check("thread: the caller is told the answer lands there", reply.contains("its answer shows in that thread"), reply)
        check("thread: an empty task is refused", threadService.startThread(for: caller, task: " ").contains("need the task"))
        threadService.startSideThread = { _, _ in .tooManyOpenThreads }
        check("thread: too many open threads is said", threadService.startThread(for: caller, task: "x").contains("\(BuddyTeamPolicy.maximumOpenSideThreads) side threads"))
        threadService.startSideThread = { _, _ in .queued }
        check("thread: a queued thread says it waits", threadService.startThread(for: caller, task: "x").contains("as soon as one of your other threads finishes"))
    }

    section("team: create_buddy")
    do {
        let limitedAccess = BuddyToolAccess(allowedGroupIDs: [BuddyToolGroup.browser.rawValue])
        let caller = makeTeamBuddy("Planner", model: claudeChoice, toolAccess: limitedAccess)
        let approvingBroker = CapturingBroker(decision: .approved)
        var creationService = service(board: Board(), buddies: [caller], broker: approvingBroker)
        var createdWith: [(draft: BuddyTeamPolicy.NewBuddyDraft, creator: WispBuddy)] = []
        creationService.createBuddy = { draft, creator in
            createdWith.append((draft, creator))
            var made = makeTeamBuddy(draft.name ?? "Mail Digest", job: draft.job, model: creator.modelChoice, toolAccess: creator.toolAccess)
            made.schedule = draft.schedule
            return made
        }
        let reply = await creationService.createBuddy(for: caller, name: "Mail Digest", job: "every morning, summarize my unread email")
        check("create: the user is asked first", approvingBroker.askedInputs.first?.toolName == BuddyTeamToolNames.createBuddy)
        let cardInput = approvingBroker.askedInputs.first?.toolInput ?? .null
        check("create: the card names the job and when it runs",
              string("job", in: cardInput) == "every morning, summarize my unread email" && string("runs", in: cardInput)?.hasPrefix("Every day") == true)
        check("create: the card says it has the creator's tool limits", string("tools", in: cardInput) == "The same tools as Planner")
        check("create: the schedule is read from the job", createdWith.first?.draft.schedule.isRepeating == true)
        check("create: it is made from the creator (its limits are applied there)", createdWith.first?.creator.id == caller.id)
        check("create: the caller is told", reply.hasPrefix("made Mail Digest"), reply)

        _ = await creationService.createBuddy(for: caller, name: nil, job: "watch the build")
        let thirdReply = await creationService.createBuddy(for: caller, name: nil, job: "a third one")
        check("create: at most \(BuddyTeamPolicy.maximumBuddiesCreatedPerRun) per run", createdWith.count == 2 && thirdReply.contains("already made"), thirdReply)

        let decliningBroker = CapturingBroker(decision: .declined(reason: "no"))
        var declinedService = service(board: Board(), buddies: [caller], broker: decliningBroker)
        var madeAfterDecline = false
        declinedService.createBuddy = { _, _ in madeAfterDecline = true; return nil }
        let declinedReply = await declinedService.createBuddy(for: caller, name: nil, job: "do something")
        check("create: a declined card makes nothing", !madeAfterDecline && declinedReply.contains("didn't want"), declinedReply)
        check("create: no job is refused before asking",
              await declinedService.createBuddy(for: caller, name: "x", job: "  ").contains("need the new buddy's job") && decliningBroker.askedInputs.count == 1)
        check("create: always asks, even under session auto-approve",
              ToolCallSafety.mustAskEvenWithSessionAutoApprove(toolName: BuddyTeamToolNames.createBuddy, toolInput: .object([:]), agentWorkingDirectoryPath: "/tmp"))
        let card = ToolConfirmationCardBuilder.confirmationCard(forToolNamed: BuddyTeamToolNames.createBuddy, toolInput: cardInput, agentWorkingDirectoryPath: "/tmp")
        check("create: the card is a New Buddy card", card.map { if case .header(let title, _, _)? = $0.blocks.first { return title == "New Buddy" } else { return false } } ?? false)
    }

    section("team: which runs get the tools")
    do {
        let caller = makeTeamBuddy("Planner"), peer = makeTeamBuddy("Inbox")
        let teamService = service(board: Board(), buddies: [caller, peer], broker: CapturingBroker(decision: .approved))
        let memoryStore = BuddyMemoryStore(memoryDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("team-\(UUID().uuidString)"))
        func names(access: BuddyToolAccess? = nil, delegation: Bool = true, service: BuddyDelegationService? = nil) -> Set<String> {
            Set(BuddyRunToolkitBuilder.toolkit(
                forBuddyWithID: caller.id, modelSendsDataOffThisMachine: false, toolAccess: access,
                delegation: delegation ? (caller: caller, service: service ?? teamService) : nil, memoryStore: memoryStore
            ).additionalTools.map(\.definition.name))
        }
        check("tools: the user's own run gets all four", BuddyTeamToolNames.all.isSubset(of: names()))
        check("tools: a run a peer started gets none (no chains)", names(delegation: false).isDisjoint(with: BuddyTeamToolNames.all))
        check("tools: a limited buddy without Other buddies gets none",
              names(access: BuddyToolAccess(allowedGroupIDs: [BuddyToolGroup.browser.rawValue])).isDisjoint(with: BuddyTeamToolNames.all))
        let loneService = service(board: Board(), buddies: [caller], broker: CapturingBroker(decision: .approved))
        let loneNames = names(service: loneService)
        check("tools: with no peers, no list or ask, but it can still split work or make a buddy",
              !loneNames.contains(BuddyTeamToolNames.listBuddies) && !loneNames.contains(BuddyDelegationToolNames.askBuddy)
              && loneNames.contains(BuddyTeamToolNames.startThread) && loneNames.contains(BuddyTeamToolNames.createBuddy))
        check("tools: all four are in the Other buddies group",
              BuddyTeamToolNames.all.allSatisfy { BuddyToolGroup.group(forToolNamed: $0) == .delegation })
        check("report rules: a peer's request asks for the four-line blocker report",
              BuddyThreadPolicy.delegatedRequestAddendum(requesterName: "Planner").contains("Unblock:"))
    }

    if ProcessInfo.processInfo.environment["WISP_LIVE_CLAUDE"] == "1" {
        section("team: live (real claude CLI asks two buddies at once)")
        let caller = makeTeamBuddy("Planner", job: "plan the user's week")
        let mail = makeTeamBuddy("Inbox", job: "triage the user's email")
        let writer = makeTeamBuddy("Writer", job: "draft the user's essays")
        // Haiku sometimes says what it will do ("I'll check in with both of them") and stops without
        // calling the tool: measured 2 times in 6. That is the model, not the code, so one retry.
        var board = Board()
        var outcome: AgentTurnRunner.Outcome?
        var attemptCount = 0
        do {
            for attempt in 1...2 {
                attemptCount = attempt
                board = Board()
                let liveService = service(board: board, buddies: [caller, mail, writer], broker: CapturingBroker(decision: .approved),
                                          answers: ["Inbox": "2 replies due today", "Writer": "essay draft is 80% done"])
                let memoryStore = BuddyMemoryStore(memoryDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("team-live-\(UUID().uuidString)"))
                let toolkit = BuddyRunToolkitBuilder.toolkit(
                    forBuddyWithID: caller.id, modelSendsDataOffThisMachine: true,
                    delegation: (caller: caller, service: liveService), memoryStore: memoryStore
                )
                let runner = AgentTurnRunner(
                    modelProvider: ClaudeSubscriptionProvider(modelChoice: .haiku, effortLevel: .low),
                    toolRegistry: AgentToolRegistry.makeEmptyForTesting(), toolkit: toolkit, speakConfirmation: { _ in }
                )
                outcome = try await runner.run(
                    userText: "Send one question to both Inbox and Writer at once: what progress have you made today? Then tell me both of their answers in one short line.",
                    images: [], systemPrompt: "You are Planner, one of the user's buddies. Be brief.", conversationHistory: [],
                    onNarration: { _ in }, onStep: { _ in }
                )
                if !board.started.isEmpty { break }
                print("        live team: attempt \(attempt) called no tool; it said: \(outcome?.terminalText ?? "")")
            }
            let askCalls = outcome?.executedToolCalls.filter { $0.toolName == BuddyDelegationToolNames.askBuddy } ?? []
            check("live team: both buddies were asked", Set(board.started) == ["Inbox", "Writer"], "\(board.started) after \(attemptCount) attempt(s)")
            check("live team: in one ask_buddy call", askCalls.count == 1, "\(askCalls.map(\.toolInput.compactDescription))")
            let answer = outcome?.terminalText.lowercased() ?? ""
            check("live team: the answer uses both replies", answer.contains("2 replies") && answer.contains("80"), outcome?.terminalText ?? "")
        } catch {
            check("live team: no error", false, "\(error.localizedDescription)")
        }
    }
}
