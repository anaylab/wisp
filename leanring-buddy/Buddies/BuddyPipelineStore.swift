//
//  BuddyPipelineStore.swift
//  leanring-buddy
//
//  Owns the user's pipelines (`BuddyPipeline`) and runs them: one buddy after
//  another, each handed the previous answer. A pipeline run is a task that
//  starts each step as an ordinary buddy run — so every step lands in that
//  buddy's own thread and in History — and waits for it before starting the
//  next. It stops at the first step that fails, is stopped, or has nothing to
//  pass on. Steps run one at a time, so a pipeline never holds more of the
//  local model than a single buddy would.
//
//  Pipelines run on their own schedule (checked once a minute while Wisp is
//  open, like buddies') or when the user presses Run. "Pause all automation"
//  holds scheduled pipeline runs too; a manual run still works. A scheduled run
//  never asks anything: if a model hand-off hasn't been approved, or a buddy
//  was deleted, it is skipped and the pipeline's page says why.
//
//  Stored at `~/Library/Application Support/Wisp/buddy-pipelines.json`.
//

import Combine
import Foundation

/// Everything a running pipeline touches, injectable so the flow is tested
/// without the app or a model.
@MainActor
struct BuddyPipelineEnvironment {
    var buddies: () -> [WispBuddy]
    var isBuddyRunning: (WispBuddy) -> Bool
    /// Starts one step's run; nil when the buddy is busy or the queue is full.
    var startStep: (_ buddyID: UUID, _ text: String, _ displayText: String, _ suppressesNotification: Bool, _ pipelineName: String) -> UUID?
    var runRecord: (_ taskID: UUID) -> AgentTaskRecord?
    var cancelRun: (_ taskID: UUID) -> Void
    var providerKind: (WispBuddy) -> BuddyChatProviderKind = BuddyDelegationPolicy.effectiveProviderKind(of:)
    var arePipelinesHeld: () -> Bool = { false }
    var pollIntervalSeconds: TimeInterval = 0.5
    var stepTimeoutSeconds: TimeInterval = BuddyPipelinePolicy.stepTimeoutSeconds
    var busyWaitSeconds: TimeInterval = BuddyPipelinePolicy.busyWaitSeconds

    static func live(buddyStore: BuddyStore = .shared) -> BuddyPipelineEnvironment {
        BuddyPipelineEnvironment(
            buddies: { buddyStore.buddies },
            isBuddyRunning: { buddyStore.isRunning($0) },
            startStep: { buddyID, text, displayText, suppressesNotification, pipelineName in
                buddyStore.startPipelineStepRun(
                    buddyID: buddyID, text: text, displayText: displayText,
                    suppressesNotification: suppressesNotification, pipelineName: pipelineName
                )
            },
            runRecord: { taskID in AgentTaskRegistry.shared.records.first { $0.id == taskID } },
            cancelRun: { taskID in AgentTaskRegistry.shared.cancelTask(taskID) },
            arePipelinesHeld: { buddyStore.areAllAutomationsPaused }
        )
    }
}

@MainActor
final class BuddyPipelineStore: ObservableObject {
    static let shared = BuddyPipelineStore()

    static let defaultFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Wisp/buddy-pipelines.json")
    private static let scheduleCheckIntervalSeconds: TimeInterval = 60

    @Published private(set) var pipelines: [BuddyPipeline] = []
    /// The run in progress for each running pipeline, updated step by step.
    @Published private(set) var liveRunsByPipelineID: [UUID: BuddyPipelineRun] = [:]

    private let fileURL: URL
    private let environment: BuddyPipelineEnvironment
    private var scheduleCheckTimer: Timer?
    private var runningTasksByPipelineID: [UUID: Task<Void, Never>] = [:]
    private var currentStepTaskIDsByPipelineID: [UUID: UUID] = [:]
    private var stoppedPipelineIDs: Set<UUID> = []

    init(fileURL: URL = BuddyPipelineStore.defaultFileURL, environment: BuddyPipelineEnvironment? = nil) {
        self.fileURL = fileURL
        self.environment = environment ?? .live()
        pipelines = loadPipelines()
    }

    // MARK: - Queries

    func pipeline(withID pipelineID: UUID) -> BuddyPipeline? {
        pipelines.first { $0.id == pipelineID }
    }

    func isRunning(_ pipeline: BuddyPipeline) -> Bool {
        runningTasksByPipelineID[pipeline.id] != nil
    }

    func providerKinds(for stepBuddyIDs: [UUID]) -> [BuddyChatProviderKind] {
        let buddies = environment.buddies()
        return stepBuddyIDs.map { buddyID in
            buddies.first { $0.id == buddyID }.map(environment.providerKind) ?? BuddyChatProviderSelection.current
        }
    }

    /// The hand-offs between models this pipeline would make right now.
    func boundaryCrossings(for stepBuddyIDs: [UUID]) -> [BuddyPipelinePolicy.BoundaryCrossing] {
        let buddies = environment.buddies()
        let providers = providerKinds(for: stepBuddyIDs)
        let steps = zip(stepBuddyIDs, providers).map { buddyID, provider in
            (name: buddies.first { $0.id == buddyID }?.name ?? "A buddy", provider: provider)
        }
        return BuddyPipelinePolicy.boundaryCrossings(steps: steps)
    }

    func currentBoundarySignature(for stepBuddyIDs: [UUID]) -> String {
        BuddyPipelinePolicy.boundarySignature(stepBuddyIDs: stepBuddyIDs, providers: providerKinds(for: stepBuddyIDs))
    }

    /// Why a pipeline can't run right now, or nil when it can.
    func problemPreventingRun(of pipeline: BuddyPipeline) -> String? {
        if let problem = BuddyPipelinePolicy.validationProblem(stepBuddyIDs: pipeline.stepBuddyIDs, buddies: environment.buddies()) {
            return problem.message
        }
        if !BuddyPipelinePolicy.isApproved(pipeline, currentSignature: currentBoundarySignature(for: pipeline.stepBuddyIDs)) {
            return "Needs your approval to pass answers between models."
        }
        return nil
    }

    // MARK: - Scheduling

    /// Begins the once-a-minute schedule check. Safe to call more than once.
    func start() {
        guard scheduleCheckTimer == nil else { return }
        let timer = Timer(timeInterval: Self.scheduleCheckIntervalSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.runDuePipelines(now: Date())
            }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        scheduleCheckTimer = timer
        runDuePipelines(now: Date())
    }

    /// Runs the pipelines whose time has come. One that is paused, held, already
    /// running or can't run (unapproved, a buddy gone) is moved past its slot;
    /// the page shows why.
    func runDuePipelines(now: Date) {
        for pipeline in pipelines {
            guard let dueAt = pipeline.nextScheduledRunAt, dueAt <= now else { continue }
            let isHeld = environment.arePipelinesHeld() || pipeline.isPaused
            if isHeld || isRunning(pipeline) || problemPreventingRun(of: pipeline) != nil {
                advanceSchedule(ofPipelineWithID: pipeline.id, after: now)
                continue
            }
            switch BuddyRunReliabilityPolicy.dueDecision(dueAt: dueAt, now: now, catchUpPolicy: .runOnce) {
            case .skip:
                advanceSchedule(ofPipelineWithID: pipeline.id, after: now)
            case .run(let reason):
                if case .started = startRun(ofPipelineWithID: pipeline.id, reason: reason) {
                    advanceSchedule(ofPipelineWithID: pipeline.id, after: now)
                }
            }
        }
    }

    private func advanceSchedule(ofPipelineWithID pipelineID: UUID, after date: Date) {
        mutatePipeline(withID: pipelineID) { pipeline in
            pipeline.nextScheduledRunAt = pipeline.schedule.nextRunDate(after: date, calendar: .current)
        }
    }

    // MARK: - Changes

    enum CreationResult: Equatable {
        case created(UUID)
        case invalid(String)
    }

    @discardableResult
    func createPipeline(name: String, stepBuddyIDs: [UUID], schedule: BuddySchedule = .once) -> CreationResult {
        if let problem = BuddyPipelinePolicy.validationProblem(stepBuddyIDs: stepBuddyIDs, buddies: environment.buddies()) {
            return .invalid(problem.message)
        }
        let buddies = environment.buddies()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let pipelineName = trimmedName.isEmpty
            ? BuddyPipelinePolicy.defaultName(forStepNames: stepBuddyIDs.compactMap { id in buddies.first { $0.id == id }?.name })
            : trimmedName
        let now = Date()
        let pipeline = BuddyPipeline(
            id: UUID(), name: pipelineName, stepBuddyIDs: stepBuddyIDs, schedule: schedule,
            nextScheduledRunAt: schedule.nextRunDate(after: now, calendar: .current), createdAt: now
        )
        pipelines.insert(pipeline, at: 0)
        savePipelines()
        return .created(pipeline.id)
    }

    /// Changes the steps. Approval for model hand-offs is tied to the steps, so
    /// a changed set needs approving again (`isApproved` compares signatures).
    @discardableResult
    func updateSteps(ofPipelineWithID pipelineID: UUID, to stepBuddyIDs: [UUID]) -> String? {
        if let problem = BuddyPipelinePolicy.validationProblem(stepBuddyIDs: stepBuddyIDs, buddies: environment.buddies()) {
            return problem.message
        }
        mutatePipeline(withID: pipelineID) { $0.stepBuddyIDs = stepBuddyIDs }
        return nil
    }

    func rename(pipelineWithID pipelineID: UUID, to newName: String) {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        mutatePipeline(withID: pipelineID) { $0.name = trimmedName }
    }

    func updateSchedule(ofPipelineWithID pipelineID: UUID, to newSchedule: BuddySchedule) {
        mutatePipeline(withID: pipelineID) { pipeline in
            pipeline.schedule = newSchedule
            pipeline.nextScheduledRunAt = newSchedule.nextRunDate(after: Date(), calendar: .current)
        }
    }

    /// The user approved passing answers between the models in the pipeline as it is now.
    func approveModelHandoffs(ofPipelineWithID pipelineID: UUID) {
        guard let pipeline = pipeline(withID: pipelineID) else { return }
        let signature = currentBoundarySignature(for: pipeline.stepBuddyIDs)
        mutatePipeline(withID: pipelineID) { $0.approvedBoundarySignature = signature.isEmpty ? nil : signature }
    }

    func resume(pipelineWithID pipelineID: UUID) {
        mutatePipeline(withID: pipelineID) { pipeline in
            pipeline.pausedReason = nil
            pipeline.consecutiveFailedRuns = nil
        }
    }

    func delete(pipelineWithID pipelineID: UUID) {
        stop(pipelineWithID: pipelineID)
        pipelines.removeAll { $0.id == pipelineID }
        savePipelines()
    }

    // MARK: - Running

    enum StartResult: Equatable {
        case started
        case refused(String)
    }

    /// Starts a run now. Refused when it is already running, invalid, or has
    /// model hand-offs the user hasn't approved.
    @discardableResult
    func startRun(ofPipelineWithID pipelineID: UUID, reason: BuddyRunReason = .manual) -> StartResult {
        guard let pipeline = pipeline(withID: pipelineID) else { return .refused("That pipeline no longer exists.") }
        guard !isRunning(pipeline) else { return .refused("It's already running.") }
        if let problem = problemPreventingRun(of: pipeline) { return .refused(problem) }

        let runningTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.execute(pipeline, reason: reason)
        }
        runningTasksByPipelineID[pipelineID] = runningTask
        return .started
    }

    func stop(pipelineWithID pipelineID: UUID) {
        stoppedPipelineIDs.insert(pipelineID)
        if let currentStepTaskID = currentStepTaskIDsByPipelineID[pipelineID] {
            environment.cancelRun(currentStepTaskID)
        }
        runningTasksByPipelineID[pipelineID]?.cancel()
    }

    /// Waits for a pipeline's run to finish. For tests.
    func waitUntilFinished(pipelineWithID pipelineID: UUID) async {
        await runningTasksByPipelineID[pipelineID]?.value
    }

    private func execute(_ pipeline: BuddyPipeline, reason: BuddyRunReason) async {
        let pipelineID = pipeline.id
        stoppedPipelineIDs.remove(pipelineID)
        let buddies = environment.buddies()
        let stepBuddies = pipeline.stepBuddyIDs.compactMap { id in buddies.first { $0.id == id } }

        var run = BuddyPipelineRun(
            id: UUID(), startedAt: Date(), finishedAt: nil,
            steps: stepBuddies.map { BuddyPipelineStepRun(buddyID: $0.id, buddyName: $0.name) },
            finalAnswerPreview: nil, stoppedReason: nil, reason: reason
        )
        liveRunsByPipelineID[pipelineID] = run

        var previousStepName: String?
        var previousAnswer: String?

        stepLoop: for (stepIndex, stepBuddy) in stepBuddies.enumerated() {
            let isLastStep = stepIndex == stepBuddies.count - 1
            let stepText = BuddyPipelinePolicy.stepText(
                instruction: stepBuddy.instruction, previousStepName: previousStepName, previousAnswer: previousAnswer
            )
            let displayText = BuddyPipelinePolicy.stepDisplayText(
                instruction: stepBuddy.instruction, pipelineName: pipeline.name, stepNumber: stepIndex + 1,
                stepCount: stepBuddies.count, previousStepName: previousStepName
            )

            guard let stepTaskID = await startStepWaitingForRoom(
                buddy: stepBuddy, text: stepText, displayText: displayText,
                suppressesNotification: !isLastStep, pipelineName: pipeline.name
            ) else {
                run.steps[stepIndex].outcome = Task.isCancelled ? .stopped : .failed("\(stepBuddy.name) was busy")
                run.stoppedReason = Task.isCancelled ? "Stopped" : "\(stepBuddy.name) was busy and couldn't start"
                liveRunsByPipelineID[pipelineID] = run
                break stepLoop
            }
            currentStepTaskIDsByPipelineID[pipelineID] = stepTaskID
            run.steps[stepIndex].taskID = stepTaskID
            liveRunsByPipelineID[pipelineID] = run

            let finishedRecord = await waitForFinish(of: stepTaskID)
            currentStepTaskIDsByPipelineID[pipelineID] = nil

            switch finishedRecord?.status {
            case .succeeded:
                let answer = AnswerDisplayText.cleaned(finishedRecord?.finalText ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !answer.isEmpty else {
                    run.steps[stepIndex].outcome = .failed("nothing to pass on")
                    run.stoppedReason = "\(stepBuddy.name) finished but had nothing to pass on"
                    break stepLoop
                }
                run.steps[stepIndex].outcome = .succeeded
                previousStepName = stepBuddy.name
                previousAnswer = answer
                if isLastStep { run.finalAnswerPreview = BuddyPipelinePolicy.answerPreview(answer) }
            case .failed(let failureMessage):
                run.steps[stepIndex].outcome = .failed(failureMessage)
                run.stoppedReason = "\(stepBuddy.name) failed: \(failureMessage)"
                break stepLoop
            case .none:
                run.steps[stepIndex].outcome = .failed("took too long")
                run.stoppedReason = "\(stepBuddy.name) took too long, so the pipeline stopped"
                break stepLoop
            default:
                run.steps[stepIndex].outcome = .stopped
                run.stoppedReason = "Stopped at \(stepBuddy.name)"
                break stepLoop
            }
            liveRunsByPipelineID[pipelineID] = run
        }

        run.finishedAt = Date()
        let wasStoppedByUser = stoppedPipelineIDs.remove(pipelineID) != nil
        liveRunsByPipelineID[pipelineID] = nil
        runningTasksByPipelineID[pipelineID] = nil
        currentStepTaskIDsByPipelineID[pipelineID] = nil

        let didSucceed = run.succeeded
        mutatePipeline(withID: pipelineID) { pipeline in
            pipeline.recentRuns = BuddyPipelinePolicy.trimmedRuns((pipeline.recentRuns ?? []) + [run])
            let failureState = BuddyPipelinePolicy.failureState(
                afterRunSucceeded: didSucceed, wasStoppedByUser: wasStoppedByUser,
                previousConsecutiveFailures: pipeline.consecutiveFailedRuns ?? 0
            )
            pipeline.consecutiveFailedRuns = failureState.consecutiveFailedRuns == 0 ? nil : failureState.consecutiveFailedRuns
            if let pausedReason = failureState.pausedReason { pipeline.pausedReason = pausedReason }
            if didSucceed { pipeline.pausedReason = nil }
        }
    }

    /// Starts a step as soon as its buddy is free and there is room in the run
    /// queue, waiting up to `busyWaitSeconds`. Nil if that never happens or the
    /// pipeline was stopped.
    private func startStepWaitingForRoom(
        buddy: WispBuddy, text: String, displayText: String, suppressesNotification: Bool, pipelineName: String
    ) async -> UUID? {
        let deadline = Date().addingTimeInterval(environment.busyWaitSeconds)
        while !Task.isCancelled {
            if let currentBuddy = environment.buddies().first(where: { $0.id == buddy.id }),
               !environment.isBuddyRunning(currentBuddy),
               let stepTaskID = environment.startStep(buddy.id, text, displayText, suppressesNotification, pipelineName) {
                return stepTaskID
            }
            if Date() >= deadline { return nil }
            try? await Task.sleep(nanoseconds: UInt64(environment.pollIntervalSeconds * 1_000_000_000))
        }
        return nil
    }

    /// The finished record of a step, or nil if it didn't finish in time. A
    /// cancelled wait stops the step's run.
    private func waitForFinish(of stepTaskID: UUID) async -> AgentTaskRecord? {
        let deadline = Date().addingTimeInterval(environment.stepTimeoutSeconds)
        while true {
            if let record = environment.runRecord(stepTaskID), record.status.isTerminal { return record }
            if Task.isCancelled {
                environment.cancelRun(stepTaskID)
                return environment.runRecord(stepTaskID).map { record in
                    var stoppedRecord = record
                    stoppedRecord.status = .cancelled
                    return stoppedRecord
                }
            }
            if Date() >= deadline {
                environment.cancelRun(stepTaskID)
                return nil
            }
            try? await Task.sleep(nanoseconds: UInt64(environment.pollIntervalSeconds * 1_000_000_000))
        }
    }

    // MARK: - Persistence

    private func mutatePipeline(withID pipelineID: UUID, _ mutate: (inout BuddyPipeline) -> Void) {
        guard let pipelineIndex = pipelines.firstIndex(where: { $0.id == pipelineID }) else { return }
        mutate(&pipelines[pipelineIndex])
        savePipelines()
    }

    private func loadPipelines() -> [BuddyPipeline] {
        guard let fileData = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([BuddyPipeline].self, from: fileData)) ?? []
    }

    private func savePipelines() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let fileData = try? encoder.encode(pipelines) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileData.write(to: fileURL, options: .atomic)
    }
}
