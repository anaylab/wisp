//
//  BuddyFlowEngine.swift
//  leanring-buddy
//
//  Runs buddy flows (`BuddyFlow.swift` holds the rules). When a buddy's job
//  answers, a flow run starts over the buddies its hand-off links reach; each
//  one gets a hand-off run (filed like a peer's request, "From …") once all
//  the buddies before it have finished, and its answer goes on in turn.
//
//  A buddy that is busy is retried on every task change for up to 30 minutes;
//  a hidden one, or one still busy after that, counts as failed, so what comes
//  after it is skipped unless it has another input. Flows live in memory: a
//  relaunch ends the ones in progress (the runs already started finish).
//

import Combine
import Foundation

@MainActor
final class BuddyFlowEngine: ObservableObject {
    static let shared = BuddyFlowEngine()

    /// Flows in progress, by id.
    @Published private(set) var runningFlows: [UUID: BuddyFlowRun] = [:]

    private struct WaitingStart {
        let flowID: UUID
        let buddyID: UUID
        let inputs: [(fromBuddyID: UUID, answer: String)]
        let waitingSince: Date
    }

    private var waitingStarts: [WaitingStart] = []
    /// Hand-off run task id → which flow and buddy it is.
    private var activeRuns: [UUID: (flowID: UUID, buddyID: UUID)] = [:]
    private var registryObservation: AnyCancellable?

    // Injected so the flow can be tested without the app.
    var buddyLookup: (UUID) -> WispBuddy? = { BuddyStore.shared.buddy(withID: $0) }
    var handOffGraph: () -> [UUID: [UUID]] = { BuddyStore.shared.handOffGraph }
    var mayFollow: (_ from: UUID, _ to: UUID) -> Bool = { BuddyStore.shared.mayFollowHandOff(from: $0, to: $1) }
    var startHandOffRun: (_ buddyID: UUID, _ message: String, _ fromNames: [String]) -> UUID? = {
        BuddyStore.shared.startHandOffRun(ofBuddyWithID: $0, message: $1, fromBuddyNames: $2)
    }
    var runRecord: (UUID) -> AgentTaskRecord? = { taskID in AgentTaskRegistry.shared.records.first { $0.id == taskID } }
    var appendStep: (AgentStepRecord, UUID) -> Void = { AgentTaskRegistry.shared.appendStep($0, to: $1) }
    var now: () -> Date = Date.init

    /// Starts watching run endings. Called once at launch.
    func start() {
        guard registryObservation == nil else { return }
        registryObservation = AgentTaskRegistry.shared.$records
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.process() }
            }
    }

    /// A buddy's job answered: hand it on along its links.
    func jobAnswered(buddyID: UUID, runTaskID: UUID, answer: String) {
        let graph = handOffGraph()
        guard !(graph[buddyID] ?? []).isEmpty else { return }
        var flowRun = BuddyFlowRun(
            sourceBuddyID: buddyID,
            sourceAnswer: answer,
            allLinks: graph,
            isBlocked: { [mayFollow] from, to in !mayFollow(from, to) }
        )
        let firstActions = flowRun.takeReadyActions()
        runningFlows[flowRun.id] = flowRun
        let startedNames = firstActions.compactMap { action -> String? in
            if case .start(let targetID, _) = action { return buddyLookup(targetID)?.name }
            return nil
        }
        if !startedNames.isEmpty {
            appendStep(AgentStepRecord(
                kind: .modelCall,
                summary: BuddyFlowPolicy.handedOnStepSummary(targetNames: startedNames),
                detail: nil, startedAt: now(), durationSeconds: 0
            ), runTaskID)
        }
        perform(firstActions, inFlowWithID: flowRun.id)
        process()
    }

    /// Notes runs that ended, retries buddies that were busy, and starts
    /// whoever is ready now.
    func process() {
        for (runTaskID, flowNode) in activeRuns {
            guard let record = runRecord(runTaskID), record.status.isTerminal else { continue }
            activeRuns[runTaskID] = nil
            guard var flowRun = runningFlows[flowNode.flowID] else { continue }
            if case .succeeded = record.status {
                flowRun.markAnswered(flowNode.buddyID, answer: AnswerDisplayText.cleaned(record.finalText ?? ""))
            } else {
                flowRun.markFailed(flowNode.buddyID)
            }
            runningFlows[flowNode.flowID] = flowRun
        }

        let startsToRetry = waitingStarts
        waitingStarts = []
        for waitingStart in startsToRetry {
            attemptStart(waitingStart)
        }

        for flowID in Array(runningFlows.keys) {
            guard var flowRun = runningFlows[flowID] else { continue }
            let actions = flowRun.takeReadyActions()
            runningFlows[flowID] = flowRun
            perform(actions, inFlowWithID: flowID)
        }

        // A flow is done once nothing in it waits, runs or is being retried.
        for (flowID, flowRun) in runningFlows where flowRun.isFinished
            && !waitingStarts.contains(where: { $0.flowID == flowID })
            && !activeRuns.values.contains(where: { $0.flowID == flowID }) {
            runningFlows[flowID] = nil
        }
    }

    private func perform(_ actions: [BuddyFlowRun.Action], inFlowWithID flowID: UUID) {
        for action in actions {
            guard case .start(let buddyID, let inputs) = action else { continue }
            attemptStart(WaitingStart(flowID: flowID, buddyID: buddyID, inputs: inputs, waitingSince: now()))
        }
    }

    private func attemptStart(_ waitingStart: WaitingStart) {
        guard var flowRun = runningFlows[waitingStart.flowID] else { return }
        guard let target = buddyLookup(waitingStart.buddyID), !target.isHiddenInList else {
            // Gone or hidden: it takes nothing, so it counts as failed.
            flowRun.markFailed(waitingStart.buddyID)
            runningFlows[waitingStart.flowID] = flowRun
            return
        }
        let senders = waitingStart.inputs.map { input in
            (fromName: buddyLookup(input.fromBuddyID)?.name ?? "Another buddy", answer: input.answer)
        }
        let message = BuddyFlowPolicy.handOffMessage(inputs: senders, targetJob: target.instruction)
        if let runTaskID = startHandOffRun(target.id, message, senders.map(\.fromName)) {
            activeRuns[runTaskID] = (waitingStart.flowID, target.id)
        } else if now().timeIntervalSince(waitingStart.waitingSince) < BuddyFlowPolicy.busyWaitSeconds {
            waitingStarts.append(waitingStart)   // busy: tried again on the next change
        } else {
            flowRun.markFailed(waitingStart.buddyID)
            runningFlows[waitingStart.flowID] = flowRun
        }
    }
}
