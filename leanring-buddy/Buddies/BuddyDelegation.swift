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

    /// The model a buddy really runs on: its own choice, else Wisp's.
    static func effectiveProviderKind(of buddy: WispBuddy) -> BuddyChatProviderKind {
        buddy.modelChoice?.providerKind ?? BuddyChatProviderSelection.current
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

    /// The live service, backed by the real buddy store and task registry.
    static func live(buddyStore: BuddyStore = .shared) -> BuddyDelegationService {
        BuddyDelegationService(
            buddies: { buddyStore.buddies },
            startRun: { target, message, fromBuddyName in
                buddyStore.startDelegatedRun(to: target.id, message: message, fromBuddyNamed: fromBuddyName)
            },
            runRecord: { taskID in AgentTaskRegistry.shared.records.first { $0.id == taskID } },
            cancelRun: { taskID in AgentTaskRegistry.shared.cancelTask(taskID) },
            broker: ToolConfirmationCoordinator.shared
        )
    }

    /// Runs one `ask_buddy` call for `caller` and returns what the model is told.
    func askBuddy(from caller: WispBuddy, targetName: String, message rawMessage: String) async -> String {
        let message = String(rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(BuddyDelegationPolicy.maximumMessageCharacters))
        guard !message.isEmpty else { return "i need a message to send." }

        let allBuddies = buddies()
        let target: WispBuddy
        switch BuddyDelegationPolicy.resolveTarget(named: targetName, among: allBuddies, excludingBuddyWithID: caller.id) {
        case .found(let foundBuddy):
            target = foundBuddy
        case .ambiguous(let candidateNames):
            return "\"\(targetName)\" could be \(candidateNames.joined(separator: " or ")). say which."
        case .notFound:
            let peerNames = allBuddies.filter { $0.id != caller.id }.map(\.name)
            return peerNames.isEmpty
                ? "you have no other buddies to ask."
                : "no buddy called \"\(targetName)\". your peers are: \(peerNames.joined(separator: ", "))."
        }

        let callerProvider = providerKind(caller)
        let targetProvider = providerKind(target)
        if BuddyDelegationPolicy.requiresApproval(callerProvider: callerProvider, targetProvider: targetProvider) {
            let approval = await broker.requestApproval(
                toolName: BuddyDelegationToolNames.askBuddy,
                toolInput: .object([
                    "from": .string(caller.name),
                    "from_model": .string(callerProvider.displayName),
                    "to": .string(target.name),
                    "to_model": .string(targetProvider.displayName),
                    "message": .string(message),
                    "note": .string(BuddyDelegationPolicy.boundaryNote(
                        callerName: caller.name, callerProvider: callerProvider,
                        targetName: target.name, targetProvider: targetProvider)),
                ])
            )
            guard approval.isApproved else {
                return "the user didn't approve sending that to \(target.name). carry on without it."
            }
        }

        guard let runTaskID = startRun(target, message, caller.name) else {
            return "\(target.name) is busy right now. carry on without it, or try again later."
        }
        return await waitForAnswer(of: target, runTaskID: runTaskID)
    }

    private func waitForAnswer(of target: WispBuddy, runTaskID: UUID) async -> String {
        let deadline = Date().addingTimeInterval(answerTimeoutSeconds)
        while true {
            if let record = runRecord(runTaskID), record.status.isTerminal {
                return outcomeText(for: record, from: target)
            }
            if Task.isCancelled {
                cancelRun(runTaskID)
                return "stopped before \(target.name) answered."
            }
            if Date() >= deadline {
                cancelRun(runTaskID)
                return "\(target.name) didn't answer in time, so i stopped it."
            }
            try? await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
        }
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

@MainActor
enum BuddyDelegationToolBuilder {
    /// The `ask_buddy` tool for `caller`, or nil when it has no peer to ask.
    static func tool(for caller: WispBuddy, service: BuddyDelegationService) -> AgentRunTool? {
        let peerListing = BuddyDelegationPolicy.peerListing(of: service.buddies(), excludingBuddyWithID: caller.id)
        guard !peerListing.isEmpty else { return nil }
        return AgentRunTool(
            definition: BuddyToolDefinition(
                name: BuddyDelegationToolNames.askBuddy,
                description: "Ask one of your fellow buddies for help with a part of your job and get its answer back. "
                    + "Use it only when another buddy's job covers what you need. Your peers: \(peerListing).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "buddy": .object([
                            "type": .string("string"),
                            "description": .string("The peer's name, e.g. \"Gmail Digest\""),
                        ]),
                        "message": .object([
                            "type": .string("string"),
                            "description": .string("What you need, in a sentence or two. Include any context it needs; it can't see your conversation."),
                        ]),
                    ]),
                    "required": .array([.string("buddy"), .string("message")]),
                ]),
                // The approval (when one is needed) is asked inside the call, with
                // a card naming both buddies — the registry's generic prompt would not.
                metadata: .writing(.localMachine)
            ),
            run: { input in
                guard case .object(let arguments) = input,
                      case .string(let targetName)? = arguments["buddy"],
                      case .string(let message)? = arguments["message"] else {
                    return "i need the buddy's name and a message."
                }
                return await service.askBuddy(from: caller, targetName: targetName, message: message)
            }
        )
    }
}
