//
//  BuddyFlowTests.swift
//
//  Phase 7 of docs/openbot-buddies-plan.md: buddy flows. The store's link
//  rules (loops, confirming answers that leave this Mac, deleted buddies) and
//  the flow engine end to end with fake runs.
//

import Foundation

@MainActor func buddyFlowSuite() async {
    section("flows: the store's links")
    do {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("flows-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let store = BuddyStore(buddiesFileURL: sandbox.appendingPathComponent("buddies.json"))
        let local = BuddyModelChoice(providerKind: .localOllama, claudeModel: nil)
        let claude = BuddyModelChoice(providerKind: .anthropic, claudeModel: .sonnet)
        let briefer = store.createBuddy(instruction: "brief me", schedule: .once, modelChoice: local, name: "Briefer", runImmediately: false)
        let planner = store.createBuddy(instruction: "plan my day", schedule: .once, modelChoice: local, name: "Planner", runImmediately: false)
        let researcher = store.createBuddy(instruction: "research", schedule: .once, modelChoice: claude, name: "Researcher", runImmediately: false)

        check("links: a local-to-local link is added", store.addHandOffLink(fromBuddyWithID: briefer.id, toBuddyWithID: planner.id) == .added)
        check("links: a repeat is refused", store.addHandOffLink(fromBuddyWithID: briefer.id, toBuddyWithID: planner.id) == .alreadyLinked)
        check("links: a loop is refused", store.addHandOffLink(fromBuddyWithID: planner.id, toBuddyWithID: briefer.id) == .wouldMakeLoop)
        let crossing = store.addHandOffLink(fromBuddyWithID: planner.id, toBuddyWithID: researcher.id)
        if case .needsConfirmation(let names) = crossing {
            check("links: a link off this Mac needs confirming, naming where it goes", names.contains("Claude") || names.contains("Anthropic"), names)
        } else { check("links: a link off this Mac needs confirming", false, "\(crossing)") }
        check("links: unconfirmed, it isn't added", store.buddy(withID: planner.id)?.handOffs.isEmpty == true)
        check("links: confirmed, it is", store.addHandOffLink(fromBuddyWithID: planner.id, toBuddyWithID: researcher.id, acknowledgesLeavingThisMac: true) == .added)
        check("links: the confirmed link may be followed", store.mayFollowHandOff(from: planner.id, to: researcher.id))
        check("links: the graph has both", store.handOffGraph[briefer.id] == [planner.id] && store.handOffGraph[planner.id] == [researcher.id])

        // A model change after linking can make a link leave the Mac; it then needs confirming again.
        store.updateModelChoice(ofBuddyWithID: planner.id, to: claude)
        store.updateModelChoice(ofBuddyWithID: briefer.id, to: local)
        store.updateModelChoice(ofBuddyWithID: planner.id, to: BuddyModelChoice(providerKind: .gemini, claudeModel: nil))
        check("links: a model change that makes an old link leave the Mac stops it", !store.mayFollowHandOff(from: briefer.id, to: planner.id))

        var startedRequests: [BuddyRunRequest] = []
        store.start(runStarter: { _, request in startedRequests.append(request); return UUID() })
        let handOffID = store.startHandOffRun(ofBuddyWithID: researcher.id, message: "use this", fromBuddyNames: ["Planner"])
        check("hand-off run: started like a peer's request", handOffID != nil && startedRequests.first?.origin == .delegated
              && startedRequests.first?.requesterName == "Planner" && startedRequests.first?.extraSystemPrompt?.contains("hand-off") == true)

        store.deleteBuddy(withID: researcher.id)
        check("links: deleting a buddy removes links to it", store.buddy(withID: planner.id)?.handOffs.isEmpty == true)
    }

    section("flows: the engine")
    do {
        let briefer = WispBuddy(id: UUID(), name: "Briefer", instruction: "brief me", colorIndex: 0, schedule: .once, createdAt: Date(), runTaskIDs: [], nextScheduledRunAt: nil)
        let planner = WispBuddy(id: UUID(), name: "Planner", instruction: "plan my day", colorIndex: 1, schedule: .once, createdAt: Date(), runTaskIDs: [], nextScheduledRunAt: nil)
        let inbox = WispBuddy(id: UUID(), name: "Inbox", instruction: "triage mail", colorIndex: 2, schedule: .once, createdAt: Date(), runTaskIDs: [], nextScheduledRunAt: nil)
        var hiddenWriter = WispBuddy(id: UUID(), name: "Writer", instruction: "write", colorIndex: 3, schedule: .once, createdAt: Date(), runTaskIDs: [], nextScheduledRunAt: nil)
        hiddenWriter.isHidden = true
        let buddies = [briefer, planner, inbox, hiddenWriter]

        final class Runs {
            var records: [UUID: AgentTaskRecord] = [:]
            var started: [(buddyName: String, message: String, from: [String])] = []
            var busy: Set<UUID> = []
            var steps: [String] = []
        }
        let runs = Runs()
        let engine = BuddyFlowEngine()
        engine.buddyLookup = { id in buddies.first { $0.id == id } }
        engine.handOffGraph = { [briefer.id: [planner.id, inbox.id], planner.id: [hiddenWriter.id], inbox.id: [planner.id]] }
        engine.mayFollow = { _, _ in true }
        engine.runRecord = { runs.records[$0] }
        engine.appendStep = { step, _ in runs.steps.append(step.summary) }
        engine.startHandOffRun = { buddyID, message, fromNames in
            guard !runs.busy.contains(buddyID), let buddy = buddies.first(where: { $0.id == buddyID }) else { return nil }
            let taskID = UUID()
            runs.records[taskID] = AgentTaskRecord(id: taskID, title: buddy.name, kind: .background)
            runs.started.append((buddy.name, message, fromNames))
            return taskID
        }
        func finish(_ buddyName: String, with answer: String?) {
            for (taskID, record) in runs.records where record.title == buddyName && !record.status.isTerminal {
                runs.records[taskID]?.status = answer == nil ? .failed("no") : .succeeded
                runs.records[taskID]?.finalText = answer
            }
            engine.process()
        }

        runs.busy = [inbox.id]
        engine.jobAnswered(buddyID: briefer.id, runTaskID: UUID(), answer: "3 meetings today")
        // Planner also takes Inbox's answer, so it waits for Inbox, who is busy: nothing can start yet.
        check("engine: a buddy that also waits on another input doesn't start early", !runs.started.contains { $0.buddyName == "Planner" })
        check("engine: the busy buddy hasn't started", runs.started.isEmpty)
        check("engine: the source's run says where its answer went", runs.steps == ["Handed its answer to Inbox"], runs.steps.description)

        runs.busy = []
        engine.process()
        check("engine: a busy buddy starts once free", runs.started.map(\.buddyName) == ["Inbox"])
        check("engine: it gets the job's answer, fenced", runs.started.first?.message.contains("<<<\n3 meetings today\n>>>") == true
              && runs.started.first?.from == ["Briefer"])

        finish("Inbox", with: "2 replies due")
        check("engine: fan-in starts once every input answered", runs.started.last?.buddyName == "Planner")
        let plannerMessage = runs.started.last?.message ?? ""
        check("engine: and gets both answers in one message", plannerMessage.contains("3 meetings today") && plannerMessage.contains("2 replies due")
              && plannerMessage.hasSuffix("plan my day"), plannerMessage)

        finish("Planner", with: "plan: gym at 6")
        check("engine: a hidden buddy is never started", !runs.started.contains { $0.buddyName == "Writer" })
        check("engine: the flow ends", engine.runningFlows.isEmpty)
    }
    do {
        let source = WispBuddy(id: UUID(), name: "A", instruction: "a", colorIndex: 0, schedule: .once, createdAt: Date(), runTaskIDs: [], nextScheduledRunAt: nil)
        let middle = WispBuddy(id: UUID(), name: "B", instruction: "b", colorIndex: 0, schedule: .once, createdAt: Date(), runTaskIDs: [], nextScheduledRunAt: nil)
        let last = WispBuddy(id: UUID(), name: "C", instruction: "c", colorIndex: 0, schedule: .once, createdAt: Date(), runTaskIDs: [], nextScheduledRunAt: nil)
        let buddies = [source, middle, last]
        final class Runs { var records: [UUID: AgentTaskRecord] = [:]; var startedNames: [String] = [] }
        let runs = Runs()
        let engine = BuddyFlowEngine()
        var clock = Date()
        engine.now = { clock }
        engine.buddyLookup = { id in buddies.first { $0.id == id } }
        engine.handOffGraph = { [source.id: [middle.id], middle.id: [last.id]] }
        engine.mayFollow = { _, _ in true }
        engine.runRecord = { runs.records[$0] }
        engine.appendStep = { _, _ in }
        engine.startHandOffRun = { buddyID, _, _ in
            guard let buddy = buddies.first(where: { $0.id == buddyID }) else { return nil }
            if buddy.name == "B" { return nil }   // always busy
            let taskID = UUID()
            runs.records[taskID] = AgentTaskRecord(id: taskID, title: buddy.name, kind: .background)
            runs.startedNames.append(buddy.name)
            return taskID
        }
        engine.jobAnswered(buddyID: source.id, runTaskID: UUID(), answer: "x")
        check("engine: a busy buddy is retried, not dropped", engine.runningFlows.count == 1)
        clock = clock.addingTimeInterval(BuddyFlowPolicy.busyWaitSeconds + 1)
        engine.process()
        check("engine: still busy after 30 minutes counts as failed, and what follows is skipped",
              runs.startedNames.isEmpty && engine.runningFlows.isEmpty)
        engine.handOffGraph = { [:] }
        engine.jobAnswered(buddyID: source.id, runTaskID: UUID(), answer: "x")
        check("engine: a buddy with no links starts no flow", engine.runningFlows.isEmpty)
    }
}
