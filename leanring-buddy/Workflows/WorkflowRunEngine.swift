//
//  WorkflowRunEngine.swift
//  leanring-buddy
//
//  Runs workflows for real. `WorkflowRunCore` walks the graph; this file is what each kind of step
//  does in Wisp: a buddy step is an ordinary buddy run (`BuddyStore.startGroupRun`, so its own tool
//  limits, confirmation cards and model apply, with no memory of other chats), a condition asks a
//  buddy a yes-or-no question, an approval asks the user (and a "no" stops the run), and an output
//  notifies or saves a file. A workflow set to run on a schedule starts its schedule triggers
//  at their minute; a run missed while Wisp was closed is not made up.
//

import AppKit
import Combine
import Foundation
import UserNotifications

@MainActor
final class WorkflowRunEngine: ObservableObject {
    static let shared = WorkflowRunEngine()

    enum RunStatus: Equatable {
        case running
        case done
        case failed(String)
        case stopped(String)
    }

    struct StepState: Equatable {
        var status: WorkflowStepStatus
        var output: String?
        var error: String?
    }

    struct Run: Equatable {
        var status: RunStatus
        /// The state of each node, by node id, for the canvas.
        var steps: [String: StepState]
        let startedAt: Date
    }

    /// The latest run of each workflow, by workflow id (kept until the next run starts).
    @Published private(set) var runs: [UUID: Run] = [:]

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var executors: [UUID: WorkflowLiveExecutor] = [:]
    private var scheduleTimer: Timer?
    private var lastScheduledMinuteKeys: [String: String] = [:]
    private let store: WorkflowStore

    init(store: WorkflowStore = .shared) { self.store = store }

    func isRunning(_ workflowID: UUID) -> Bool { runs[workflowID]?.status == .running }

    // MARK: Starting and stopping

    /// Runs a workflow from its triggers, or from the given nodes ("run from here").
    func start(workflowID: UUID, fromNodeIDs: [String]? = nil) {
        guard !isRunning(workflowID), let workflow = store.workflow(withID: workflowID) else { return }
        let graph = workflow.graph
        let startIDs = fromNodeIDs ?? WorkflowRunCore.startNodeIDs(in: graph)
        guard !startIDs.isEmpty else {
            runs[workflowID] = Run(status: .failed("Add a trigger first"), steps: [:], startedAt: Date())
            return
        }
        runs[workflowID] = Run(status: .running, steps: [:], startedAt: Date())
        let executor = WorkflowLiveExecutor(workflow: workflow)
        executors[workflowID] = executor
        tasks[workflowID] = Task { @MainActor [weak self] in
            let outcome = await WorkflowRunCore.run(
                graph: graph, startNodeIDs: startIDs, executor: executor,
                onUpdate: { update in self?.record(update, workflowID: workflowID) },
                isCancelled: { Task.isCancelled }
            )
            self?.finish(workflowID: workflowID, outcome: outcome)
        }
    }

    func stop(workflowID: UUID) {
        tasks[workflowID]?.cancel()
        executors[workflowID]?.cancelCurrentBuddyRun()
    }

    private func record(_ update: WorkflowStepUpdate, workflowID: UUID) {
        guard var run = runs[workflowID] else { return }
        run.steps[update.nodeID] = StepState(status: update.status, output: update.output, error: update.error)
        runs[workflowID] = run
    }

    private func finish(workflowID: UUID, outcome: WorkflowRunOutcome) {
        guard var run = runs[workflowID] else { return }
        switch outcome {
        case .done: run.status = .done
        case .failed(let message): run.status = .failed(message)
        case .stopped(let message): run.status = .stopped(message)
        }
        runs[workflowID] = run
        tasks[workflowID] = nil
        executors[workflowID] = nil
    }

    func clearRun(workflowID: UUID) {
        guard !isRunning(workflowID) else { return }
        runs[workflowID] = nil
    }

    // MARK: Schedule

    /// Checks twice a minute whether a schedule trigger of a scheduled workflow is due.
    func beginScheduleClock() {
        guard scheduleTimer == nil else { return }
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.startDueScheduledWorkflows(now: Date()) }
        }
        RunLoop.main.add(timer, forMode: .common)
        scheduleTimer = timer
    }

    func startDueScheduledWorkflows(now: Date, calendar: Calendar = .current) {
        let minuteKey = DateFormatter.localizedString(from: now, dateStyle: .short, timeStyle: .short)
        for workflow in store.workflows where workflow.isScheduled == true {
            let dueTriggers = workflow.graph.nodes.filter {
                $0.kind == .trigger && $0.text("trigger") == WorkflowTriggerType.schedule.rawValue
                    && WorkflowScheduleTime.isDue($0.text("time"), at: now, calendar: calendar)
            }
            guard !dueTriggers.isEmpty, lastScheduledMinuteKeys[workflow.id.uuidString] != minuteKey else { continue }
            lastScheduledMinuteKeys[workflow.id.uuidString] = minuteKey
            start(workflowID: workflow.id, fromNodeIDs: dueTriggers.map(\.id))
        }
    }
}

// MARK: - The live executor

@MainActor
final class WorkflowLiveExecutor: WorkflowStepExecutor {
    private let workflow: Workflow
    private var currentBuddyTaskID: UUID?

    init(workflow: Workflow) { self.workflow = workflow }

    func cancelCurrentBuddyRun() {
        if let currentBuddyTaskID { AgentTaskRegistry.shared.cancelTask(currentBuddyTaskID) }
    }

    func runBuddy(node: WorkflowNode, input: String) async throws -> String {
        guard let buddyID = UUID(uuidString: node.text("buddyID")), BuddyStore.shared.buddy(withID: buddyID) != nil else {
            throw WorkflowStepError(message: "Choose a buddy")
        }
        let task = node.text("task")
        return try await runBuddyTask(
            buddyID: buddyID,
            prompt: WorkflowPromptBuilder.stepPrompt(task: task, input: input),
            displayText: task.isEmpty ? "Workflow step" : task
        )
    }

    func decide(node: WorkflowNode, input: String) async throws -> Bool {
        let deciderID = workflow.graph.nodes
            .compactMap { $0.kind == .buddy ? UUID(uuidString: $0.text("buddyID")) : nil }
            .first { BuddyStore.shared.buddy(withID: $0) != nil }
            ?? BuddyStore.shared.buddies.first?.id
        guard let deciderID else { throw WorkflowStepError(message: "A condition needs a buddy to ask") }
        let rule = node.text("rule")
        let reply = try await runBuddyTask(
            buddyID: deciderID,
            prompt: WorkflowPromptBuilder.conditionPrompt(rule: rule, input: input),
            displayText: rule.isEmpty ? "Workflow condition" : rule
        )
        return WorkflowPromptBuilder.yesOrNo(from: reply)
    }

    func approve(node: WorkflowNode, input: String) async -> Bool {
        let alert = NSAlert()
        let question = node.text("question").trimmingCharacters(in: .whitespacesAndNewlines)
        alert.messageText = question.isEmpty ? "Continue this workflow?" : question
        let preview = WorkflowPromptBuilder.preview(of: input, limit: 400)
        alert.informativeText = preview.isEmpty ? "“\(workflow.title)” is waiting for your go-ahead." : preview
        alert.addButton(withTitle: "Approve")
        alert.addButton(withTitle: "Stop")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func deliver(node: WorkflowNode, input: String) async throws {
        switch node.text("target") {
        case WorkflowOutputTarget.file.rawValue:
            try saveToFile(input)
        default:
            let content = UNMutableNotificationContent()
            content.title = workflow.title
            content.body = WorkflowPromptBuilder.preview(of: input, limit: 300)
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // MARK: Helpers

    /// A buddy run for one step: no earlier conversation, the workflow's note in its prompt. It waits up
    /// to two minutes for the buddy to be free, then for the run to end.
    private func runBuddyTask(buddyID: UUID, prompt: String, displayText: String) async throws -> String {
        let request = BuddyRunRequest(
            origin: .message,
            text: prompt,
            displayText: displayText,
            threadID: workflow.id,
            groupID: workflow.id,
            historyOverride: [],
            extraSystemPrompt: WorkflowPromptBuilder.systemAddendum(workflowTitle: workflow.title)
        )
        var startedTaskID: UUID?
        for _ in 0..<240 {
            try Task.checkCancellation()
            startedTaskID = BuddyStore.shared.startGroupRun(ofBuddyWithID: buddyID, request: request)
            if startedTaskID != nil { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        guard let taskID = startedTaskID else { throw WorkflowStepError(message: "The buddy stayed busy") }
        currentBuddyTaskID = taskID
        defer { currentBuddyTaskID = nil }
        while true {
            try Task.checkCancellation()
            if let record = AgentTaskRegistry.shared.records.first(where: { $0.id == taskID }), record.status.isTerminal {
                switch record.status {
                case .succeeded: return AnswerDisplayText.cleaned(record.finalText ?? "")
                case .failed(let reason): throw WorkflowStepError(message: reason)
                default: throw CancellationError()
                }
            }
            try await Task.sleep(for: .milliseconds(400))
        }
    }

    private func saveToFile(_ text: String) throws {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wisp Workflows", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HHmm"
        let safeTitle = workflow.title.replacingOccurrences(of: "/", with: "-")
        try text.write(to: folder.appendingPathComponent("\(safeTitle) \(stamp.string(from: Date())).md"), atomically: true, encoding: .utf8)
    }
}
