//
//  BuddyDelegation.swift
//  leanring-buddy
//
//  One buddy asking another for help. A buddy that is mid-job can call
//  `ask_buddy` with a peer's name and a message; the peer answers in *its own*
//  thread (so the exchange is part of its history and shows in its page, with a
//  "From <buddy>" label) and its answer comes back to the caller as the tool's
//  result. The caller waits for it, which costs nothing while it waits — the
//  model is only held during an actual model call, not between them.
//
//  Three rules keep it safe:
//
//  1. **Crossing a model boundary asks you.** A buddy on the local model
//     messaging one on Claude sends that text off this Mac; a cloud buddy asking
//     a local one gets that buddy's answer — which may draw on the brain, files
//     or the browser — sent back to the cloud. Either way (and between two
//     different cloud providers) the confirmation card shows who is asking whom,
//     the message, and where it goes, even under session auto-approve. Between
//     two buddies on the same model nothing leaves any boundary, so it doesn't ask.
//  2. **No chains.** A run that was itself started by a delegation can't
//     delegate, so buddies can't loop or fan out into each other.
//  3. **It's an allow-list item.** `ask_buddy` belongs to the "Other buddies"
//     group, so a limited buddy only has it if given it.
//
//  A peer that is already busy, or a full run queue, is reported back at once
//  ("Gmail Digest is busy") rather than waited on, so two buddies waiting on each
//  other can never deadlock the queue.
//

import Foundation

enum BuddyDelegationToolNames {
    static let askBuddy = "ask_buddy"
}

/// The pure rules for delegation, tested without the app.
enum BuddyDelegationPolicy {
    /// How long a caller waits for a peer's answer before giving up and
    /// stopping the peer's run.
    static let answerTimeoutSeconds: TimeInterval = 5 * 60
    static let maximumMessageCharacters = 1500
    static let maximumAnswerCharacters = 2000
    /// Peers named in the tool's description, so it stays short.
    static let maximumPeersInDescription = 8
    static let maximumJobCharactersInDescription = 70

    enum TargetResolution: Equatable {
        case found(WispBuddy)
        case notFound
        case ambiguous([String])
    }

    /// The model a buddy really runs on: a kept Claude Code session is the
    /// user's Claude subscription; otherwise its own choice, else Wisp's.
    static func effectiveProviderKind(of buddy: WispBuddy) -> BuddyChatProviderKind {
        if buddy.runtimeKind == .claudeCodeSession { return .claudeSubscription }
        return buddy.modelChoice?.providerKind ?? BuddyChatProviderSelection.current
    }

    /// Whether a message between two buddies crosses a boundary the user should
    /// approve: different models means a different recipient for the message
    /// (and for the answer coming back).
    static func requiresApproval(callerProvider: BuddyChatProviderKind, targetProvider: BuddyChatProviderKind) -> Bool {
        callerProvider != targetProvider
    }

    /// One plain sentence saying where the data goes, for the card.
    static func boundaryNote(
        callerName: String, callerProvider: BuddyChatProviderKind,
        targetName: String, targetProvider: BuddyChatProviderKind
    ) -> String {
        switch (callerProvider.sendsScreenshotsOffThisMachine, targetProvider.sendsScreenshotsOffThisMachine) {
        case (false, true):
            return "This message leaves your Mac: it goes to \(targetProvider.displayName)."
        case (true, false):
            return "\(targetName) runs on your Mac, and its answer goes back to \(callerProvider.displayName), off your Mac."
        default:
            return "This goes to \(targetProvider.displayName), and \(targetName)'s answer goes back to \(callerProvider.displayName)."
        }
    }

    /// Finds the buddy a model named. An exact name (ignoring case) wins; else a
    /// name containing the words; a name matching more than one is ambiguous
    /// rather than guessed, since the message goes to whoever is picked.
    static func resolveTarget(named requestedName: String, among buddies: [WispBuddy], excludingBuddyWithID callerID: UUID) -> TargetResolution {
        let comparableName = requestedName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !comparableName.isEmpty else { return .notFound }
        let peers = buddies.filter { $0.id != callerID }
        let exactMatches = peers.filter { $0.name.lowercased() == comparableName }
        if exactMatches.count == 1 { return .found(exactMatches[0]) }
        if exactMatches.count > 1 { return .ambiguous(exactMatches.map(\.name)) }
        let partialMatches = peers.filter { $0.name.lowercased().contains(comparableName) }
        if partialMatches.count == 1 { return .found(partialMatches[0]) }
        if partialMatches.count > 1 { return .ambiguous(partialMatches.map(\.name)) }
        return .notFound
    }

    /// "Gmail Digest (summarize my Gmail every morning); …" for the tool description.
    static func peerListing(of buddies: [WispBuddy], excludingBuddyWithID callerID: UUID) -> String {
        buddies.filter { $0.id != callerID }
            .prefix(maximumPeersInDescription)
            .map { peer in
                let job = peer.instruction.prefix(maximumJobCharactersInDescription)
                return "\(peer.name) (\(job)\(peer.instruction.count > maximumJobCharactersInDescription ? "…" : ""))"
            }
            .joined(separator: "; ")
    }
}

/// Everything delegation touches, injectable so the whole flow can be tested
/// without the app, a user or a model.
@MainActor
struct BuddyDelegationService {
    var buddies: () -> [WispBuddy]
    /// Starts the peer's run; nil when it couldn't start (busy, or the queue is full).
    var startRun: (_ target: WispBuddy, _ message: String, _ fromBuddyName: String) -> UUID?
    var runRecord: (_ taskID: UUID) -> AgentTaskRecord?
    var cancelRun: (_ taskID: UUID) -> Void
    var broker: ToolPermissionBroker
    var providerKind: (WispBuddy) -> BuddyChatProviderKind = BuddyDelegationPolicy.effectiveProviderKind(of:)
    var pollIntervalSeconds: TimeInterval = 0.5
    var answerTimeoutSeconds: TimeInterval = BuddyDelegationPolicy.answerTimeoutSeconds
    /// What `list_buddies` says about a peer.
    var peerStatus: (WispBuddy) -> BuddyPeerStatus = { _ in BuddyPeerStatus() }
    /// Starts `task` in a new side thread of `caller` (`start_thread`).
    var startSideThread: (_ caller: WispBuddy, _ task: String) -> BuddyTeamPolicy.ThreadStart = { _, _ in .failed }
    /// Makes a new buddy with the creator's model, runtime and tool limits; nil on failure.
    var createBuddy: (_ draft: BuddyTeamPolicy.NewBuddyDraft, _ creator: WispBuddy) -> WispBuddy? = { _, _ in nil }
    /// Buddies this run has created so far, shared by every copy of the service.
    let createdBuddyLedger = CreatedBuddyLedger()

    /// The live service, backed by the real buddy store and task registry.
    static func live(buddyStore: BuddyStore = .shared) -> BuddyDelegationService {
        BuddyDelegationService(
            buddies: { buddyStore.buddies },
            startRun: { target, message, fromBuddyName in
                buddyStore.startDelegatedRun(to: target.id, message: message, fromBuddyNamed: fromBuddyName)
            },
            runRecord: { taskID in AgentTaskRegistry.shared.records.first { $0.id == taskID } },
            cancelRun: { taskID in AgentTaskRegistry.shared.cancelTask(taskID) },
            broker: ToolConfirmationCoordinator.shared,
            peerStatus: { peer in
                let mood = buddyStore.mood(of: peer)
                let latestRun = buddyStore.latestRunRecord(of: peer)
                return BuddyPeerStatus(
                    state: mood == .waiting ? .waitingForApproval : (buddyStore.isRunning(peer) ? .working : .free),
                    waitingMessageCount: buddyStore.waitingMessages(of: peer).count,
                    lastActivityAt: latestRun?.startedAt ?? BuddyThreadStore.shared.exchanges(ofBuddyWithID: peer.id).last?.startedAt
                )
            },
            startSideThread: { caller, task in
                let openSideThreadCount = BuddyThreadPolicy.threadSummaries(
                    from: BuddyThreadStore.shared.exchanges(ofBuddyWithID: caller.id), draftThreadIDs: []
                ).filter { !$0.isMain }.count
                guard openSideThreadCount < BuddyTeamPolicy.maximumOpenSideThreads else { return .tooManyOpenThreads }
                let newThreadID = UUID()
                guard buddyStore.sendMessage(task, toBuddyWithID: caller.id, inThread: newThreadID) else { return .failed }
                return buddyStore.isRunning(caller, inConversation: newThreadID) ? .started : .queued
            },
            createBuddy: { draft, creator in
                let newBuddy = buddyStore.createBuddy(
                    instruction: draft.job,
                    schedule: draft.schedule,
                    // The creator's limits, never more: no buddy can make itself a freer copy.
                    modelChoice: creator.modelChoice,
                    toolAccess: creator.toolAccess,
                    name: draft.name,
                    runImmediately: false
                )
                buddyStore.updateRuntime(ofBuddyWithID: newBuddy.id, to: creator.runtimeKind)
                return buddyStore.buddy(withID: newBuddy.id)
            }
        )
    }

    /// Runs one `ask_buddy` call for `caller` and returns what the model is told.
    func askBuddy(from caller: WispBuddy, targetName: String, message rawMessage: String) async -> String {
        await askBuddies(from: caller, targetNames: [targetName], message: rawMessage)
    }

    /// The same message to one or several peers at once; their answers come
    /// back together, each under its buddy's name, in the order asked. A
    /// crossing of a model boundary is asked about once, on one card naming
    /// every peer it reaches.
    func askBuddies(from caller: WispBuddy, targetNames: [String], message rawMessage: String) async -> String {
        let message = String(rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(BuddyDelegationPolicy.maximumMessageCharacters))
        guard !message.isEmpty else { return "i need a message to send." }
        guard !targetNames.isEmpty else { return "i need the name of the buddy to ask." }

        let allBuddies = buddies()
        var targets: [WispBuddy] = []
        var unresolvedReplies: [String] = []
        for targetName in targetNames {
            switch BuddyDelegationPolicy.resolveTarget(named: targetName, among: allBuddies, excludingBuddyWithID: caller.id) {
            case .found(let foundBuddy):
                if !targets.contains(where: { $0.id == foundBuddy.id }) { targets.append(foundBuddy) }
            case .ambiguous(let candidateNames):
                unresolvedReplies.append("\"\(targetName)\" could be \(candidateNames.joined(separator: " or ")). say which.")
            case .notFound:
                let peerNames = allBuddies.filter { $0.id != caller.id }.map(\.name)
                unresolvedReplies.append(peerNames.isEmpty
                    ? "you have no other buddies to ask."
                    : "no buddy called \"\(targetName)\". your peers are: \(peerNames.joined(separator: ", ")).")
            }
        }
        guard !targets.isEmpty else { return BuddyTeamPolicy.gatheredAnswers(unresolvedReplies) }

        let callerProvider = providerKind(caller)
        let crossingTargets = targets.filter {
            BuddyDelegationPolicy.requiresApproval(callerProvider: callerProvider, targetProvider: providerKind($0))
        }
        if !crossingTargets.isEmpty {
            let approval = await broker.requestApproval(
                toolName: BuddyDelegationToolNames.askBuddy,
                toolInput: .object([
                    "from": .string(caller.name),
                    "from_model": .string(callerProvider.displayName),
                    "to": .string(crossingTargets.map(\.name).joined(separator: ", ")),
                    "to_model": .string(Array(Set(crossingTargets.map { providerKind($0).displayName })).sorted().joined(separator: ", ")),
                    "message": .string(message),
                    "note": .string(crossingTargets.map { target in
                        BuddyDelegationPolicy.boundaryNote(
                            callerName: caller.name, callerProvider: callerProvider,
                            targetName: target.name, targetProvider: providerKind(target))
                    }.joined(separator: " ")),
                ])
            )
            if !approval.isApproved {
                let refusedNames = crossingTargets.map(\.name).joined(separator: " and ")
                let refusal = "the user didn't approve sending that to \(refusedNames). carry on without it."
                // Peers on the caller's own model were never in question.
                targets.removeAll { target in crossingTargets.contains { $0.id == target.id } }
                guard !targets.isEmpty else { return BuddyTeamPolicy.gatheredAnswers(unresolvedReplies + [refusal]) }
                unresolvedReplies.append(refusal)
            }
        }

        var replyByTargetID: [UUID: String] = [:]
        var runTaskIDByTargetID: [UUID: UUID] = [:]
        for target in targets {
            if let runTaskID = startRun(target, message, caller.name) {
                runTaskIDByTargetID[target.id] = runTaskID
            } else {
                replyByTargetID[target.id] = "\(target.name) is busy right now. carry on without it, or try again later."
            }
        }
        // Peers each run in their own lane, so they answer side by side.
        let answeredReplies = await waitForAnswers(
            of: targets.filter { runTaskIDByTargetID[$0.id] != nil },
            runTaskIDByTargetID: runTaskIDByTargetID
        )
        replyByTargetID.merge(answeredReplies) { _, answered in answered }
        return BuddyTeamPolicy.gatheredAnswers(targets.compactMap { replyByTargetID[$0.id] } + unresolvedReplies)
    }

    private func waitForAnswers(of targets: [WispBuddy], runTaskIDByTargetID: [UUID: UUID]) async -> [UUID: String] {
        var replyByTargetID: [UUID: String] = [:]
        let deadline = Date().addingTimeInterval(answerTimeoutSeconds)
        while replyByTargetID.count < targets.count {
            for target in targets where replyByTargetID[target.id] == nil {
                guard let runTaskID = runTaskIDByTargetID[target.id] else { continue }
                if let record = runRecord(runTaskID), record.status.isTerminal {
                    replyByTargetID[target.id] = outcomeText(for: record, from: target)
                }
            }
            if replyByTargetID.count == targets.count { break }
            let unansweredTargets = targets.filter { replyByTargetID[$0.id] == nil }
            if Task.isCancelled || Date() >= deadline {
                let timedOut = !Task.isCancelled
                for target in unansweredTargets {
                    if let runTaskID = runTaskIDByTargetID[target.id] { cancelRun(runTaskID) }
                    replyByTargetID[target.id] = timedOut
                        ? "\(target.name) didn't answer in time, so i stopped it."
                        : "stopped before \(target.name) answered."
                }
                break
            }
            try? await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
        }
        return replyByTargetID
    }

    /// `list_buddies`: every peer with its job and whether it is free.
    func listBuddies(for caller: WispBuddy, now: Date = Date()) -> String {
        let peers = buddies().filter { $0.id != caller.id && !$0.isHiddenInList }
        return BuddyTeamPolicy.peerListing(peers.map { ($0, peerStatus($0)) }, now: now)
    }

    /// `start_thread`: hands a piece of the caller's own work to a new side thread.
    func startThread(for caller: WispBuddy, task rawTask: String) -> String {
        let task = String(rawTask.trimmingCharacters(in: .whitespacesAndNewlines).prefix(BuddyTeamPolicy.maximumThreadTaskCharacters))
        guard !task.isEmpty else { return "i need the task for the new thread." }
        return BuddyTeamPolicy.threadStartReply(startSideThread(caller, task), taskText: task)
    }

    /// `create_buddy`: a new teammate, only after the user says yes on a card.
    func createBuddy(for caller: WispBuddy, name: String?, job: String?) async -> String {
        let draft: BuddyTeamPolicy.NewBuddyDraft
        switch BuddyTeamPolicy.newBuddyDraft(name: name, job: job) {
        case .success(let validDraft): draft = validDraft
        case .failure(let refusal): return refusal.replyText
        }
        guard createdBuddyLedger.createdCount < BuddyTeamPolicy.maximumBuddiesCreatedPerRun else {
            return "you've already made \(BuddyTeamPolicy.maximumBuddiesCreatedPerRun) buddies in this run. ask the user before making more."
        }
        let approval = await broker.requestApproval(
            toolName: BuddyTeamToolNames.createBuddy,
            toolInput: .object([
                "from": .string(caller.name),
                "name": .string(draft.name ?? "(Wisp picks one)"),
                "job": .string(draft.job),
                "runs": .string(BuddyTeamPolicy.firstRunText(for: draft.schedule)),
                "model": .string(caller.runtimeKind == .claudeCodeSession
                    ? caller.runtimeKind.displayName
                    : providerKind(caller).displayName),
                "tools": .string(caller.toolAccess == nil ? "Every tool, like \(caller.name)" : "The same tools as \(caller.name)"),
            ])
        )
        guard approval.isApproved else { return "the user didn't want a new buddy. carry on without one." }
        guard let newBuddy = createBuddy(draft, caller) else { return "couldn't make the buddy." }
        createdBuddyLedger.createdCount += 1
        return "made \(newBuddy.name) (\(BuddyTeamPolicy.firstRunText(for: newBuddy.schedule).lowercased())). tell the user it exists; you can ask it with ask_buddy from your next run."
    }

    private func outcomeText(for record: AgentTaskRecord, from target: WispBuddy) -> String {
        switch record.status {
        case .succeeded:
            let answer = AnswerDisplayText.cleaned(record.finalText ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else { return "\(target.name) finished but had nothing to say." }
            return "\(target.name) says: " + String(answer.prefix(BuddyDelegationPolicy.maximumAnswerCharacters))
        case .failed(let reason):
            return "\(target.name) couldn't answer: \(reason)"
        default:
            return "\(target.name)'s run was stopped."
        }
    }
}

/// Counts the buddies one run created, across copies of its service.
final class CreatedBuddyLedger {
    var createdCount = 0
}

@MainActor
enum BuddyDelegationToolBuilder {
    /// The `ask_buddy` tool for `caller`, or nil when it has no peer to ask.
    static func tool(for caller: WispBuddy, service: BuddyDelegationService) -> AgentRunTool? {
        let peerListing = BuddyDelegationPolicy.peerListing(of: service.buddies(), excludingBuddyWithID: caller.id)
        guard !peerListing.isEmpty else { return nil }
        return AgentRunTool(
            definition: BuddyToolDefinition(
                name: BuddyDelegationToolNames.askBuddy,
                description: "Ask one or a few of your fellow buddies for help with a part of your job and get their answers back. "
                    + "Use it only when another buddy's job covers what you need; name several to hear each one's view. "
                    + "Your peers: \(peerListing). " + BuddyTeamPolicy.answerHandlingRules,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "buddy": .object([
                            "type": .string("string"),
                            "description": .string("The peer's name, e.g. \"Gmail Digest\""),
                        ]),
                        "buddies": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Several peers' names, to ask them all at once (up to \(BuddyTeamPolicy.maximumBuddiesPerAsk))"),
                        ]),
                        "message": .object([
                            "type": .string("string"),
                            "description": .string("What you need, in a sentence or two. Include any context it needs; it can't see your conversation."),
                        ]),
                    ]),
                    "required": .array([.string("message")]),
                ]),
                // The approval (when one is needed) is asked inside the call, with
                // a card naming both buddies — the registry's generic prompt would not.
                metadata: .writing(.localMachine)
            ),
            run: { input in
                guard case .object(let arguments) = input,
                      case .string(let message)? = arguments["message"] else {
                    return "i need the buddy's name and a message."
                }
                var singleName: String?
                if case .string(let name)? = arguments["buddy"] { singleName = name }
                var severalNames: [String] = []
                if case .array(let nameValues)? = arguments["buddies"] {
                    severalNames = nameValues.compactMap { if case .string(let name) = $0 { return name } else { return nil } }
                }
                let targetNames = BuddyTeamPolicy.requestedNames(single: singleName, several: severalNames)
                guard !targetNames.isEmpty else { return "i need the buddy's name and a message." }
                return await service.askBuddies(from: caller, targetNames: targetNames, message: message)
            }
        )
    }

    /// `list_buddies`, `start_thread` and `create_buddy` for `caller`. Offered
    /// with `ask_buddy` (same gate: not in a run a peer started, and only with
    /// the "Other buddies" group); `list_buddies` only when there is a peer.
    static func teamTools(for caller: WispBuddy, service: BuddyDelegationService) -> [AgentRunTool] {
        var tools: [AgentRunTool] = []
        let hasPeers = service.buddies().contains { $0.id != caller.id }
        if hasPeers {
            tools.append(AgentRunTool(
                definition: BuddyToolDefinition(
                    name: BuddyTeamToolNames.listBuddies,
                    description: "List your fellow buddies: each one's job and whether it is free, working or waiting. "
                        + "Check it before saying something is outside what you can do; a buddy whose job covers it can be asked with ask_buddy.",
                    inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
                    metadata: .reading(.localMachine)
                ),
                run: { _ in service.listBuddies(for: caller) }
            ))
        }
        tools.append(AgentRunTool(
            definition: BuddyToolDefinition(
                name: BuddyTeamToolNames.startThread,
                description: "Split off a separate piece of your own work into a new side thread of yours. It runs on its own, "
                    + "beside this one, and its answer shows in that thread, not here. Use it for long work that doesn't block your answer. "
                    + "Threads share your files and notes; don't give two threads the same thing to change.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["task": .object([
                        "type": .string("string"),
                        "description": .string("Everything the thread needs to do the work; it can't see this conversation."),
                    ])]),
                    "required": .array([.string("task")]),
                ]),
                metadata: .writing(.localMachine)
            ),
            run: { input in
                guard case .object(let arguments) = input, case .string(let task)? = arguments["task"] else {
                    return "i need the task for the new thread."
                }
                return service.startThread(for: caller, task: task)
            }
        ))
        tools.append(AgentRunTool(
            definition: BuddyToolDefinition(
                name: BuddyTeamToolNames.createBuddy,
                description: "Make a new buddy for a job none of your peers covers. Only when the user asked for one or agreed to it: "
                    + "the user approves a card first. It gets your model and your tool limits.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object(["type": .string("string"), "description": .string("Optional; Wisp picks one from the job")]),
                        "job": .object(["type": .string("string"), "description": .string("Its standing job, e.g. \"every morning, summarize my unread email\"")]),
                    ]),
                    "required": .array([.string("job")]),
                ]),
                // The approval is asked inside the call, with a card naming the job.
                metadata: .writing(.localMachine)
            ),
            run: { input in
                guard case .object(let arguments) = input else { return BuddyTeamPolicy.NewBuddyRefusal.noJob.replyText }
                var name: String?
                if case .string(let value)? = arguments["name"] { name = value }
                var job: String?
                if case .string(let value)? = arguments["job"] { job = value }
                return await service.createBuddy(for: caller, name: name, job: job)
            }
        ))
        return tools
    }
}
