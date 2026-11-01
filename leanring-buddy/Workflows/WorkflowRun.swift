//
//  WorkflowRun.swift
//  leanring-buddy
//
//  Running a workflow. The graph is walked from a trigger: each step receives the text its incoming
//  edge carries and hands its own output on along the edges that leave it. A condition follows only
//  its yes or no edges; an approval stops the run when declined; a loop edge may be taken a few
//  times, never forever; and the whole run is capped. This is the pure core (it asks an executor to
//  do each kind of step), so `Tests/Workflows` checks the walk with a fake executor. The real
//  executor, which runs buddies, is `WorkflowRunEngine`.
//

import Foundation

enum WorkflowStepStatus: Equatable {
    case running
    case waitingForApproval
    case done
    case failed
    case stopped
}

struct WorkflowStepUpdate: Equatable {
    let nodeID: String
    let status: WorkflowStepStatus
    let output: String?
    let error: String?
}

enum WorkflowRunOutcome: Equatable {
    case done
    case failed(String)
    case stopped(String)
}

/// What each kind of step does. The live one runs buddies; tests use a fake.
protocol WorkflowStepExecutor {
    func runBuddy(node: WorkflowNode, input: String) async throws -> String
    /// A yes-or-no question about the input.
    func decide(node: WorkflowNode, input: String) async throws -> Bool
    /// True to go on, false to stop the run.
    func approve(node: WorkflowNode, input: String) async -> Bool
    func deliver(node: WorkflowNode, input: String) async throws
}

enum WorkflowRunCore {
    /// No run goes through more steps than this, so a loop that never ends still ends.
    static let maximumSteps = 60
    /// A loop edge is taken at most this many times.
    static let maximumPassesPerLoopEdge = 3

    private struct Pending {
        let nodeID: String
        let input: String
    }

    /// Walks the graph from `startNodeIDs` (a trigger, or the node the user chose to run from).
    static func run(
        graph: WorkflowGraph,
        startNodeIDs: [String],
        executor: WorkflowStepExecutor,
        onUpdate: (WorkflowStepUpdate) -> Void,
        isCancelled: () -> Bool
    ) async -> WorkflowRunOutcome {
        if let problem = WorkflowRules.graphProblem(graph) { return .failed(problem.problem.message) }
        let nodesByID = Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let loopEdgeIDs = WorkflowRules.loopEdges(nodes: graph.nodes, edges: graph.edges)
        var loopPasses: [String: Int] = [:]
        var queue = startNodeIDs.map { Pending(nodeID: $0, input: "") }
        var stepsRun = 0

        while !queue.isEmpty {
            if isCancelled() { return .stopped("Stopped") }
            let pending = queue.removeFirst()
            guard let node = nodesByID[pending.nodeID], node.kind.isStep else { continue }
            if stepsRun >= maximumSteps { return .failed("Stopped after \(maximumSteps) steps") }
            stepsRun += 1
            onUpdate(WorkflowStepUpdate(nodeID: node.id, status: .running, output: nil, error: nil))

            var output = pending.input
            var chosenBranch: WorkflowBranch?
            do {
                switch node.kind {
                case .trigger:
                    output = ""
                case .prompt:
                    output = node.text("text")
                case .buddy:
                    output = try await executor.runBuddy(node: node, input: pending.input)
                case .condition:
                    chosenBranch = try await executor.decide(node: node, input: pending.input) ? .yes : .no
                case .approval:
                    onUpdate(WorkflowStepUpdate(nodeID: node.id, status: .waitingForApproval, output: nil, error: nil))
                    guard await executor.approve(node: node, input: pending.input) else {
                        onUpdate(WorkflowStepUpdate(nodeID: node.id, status: .stopped, output: nil, error: nil))
                        return .stopped("Not approved")
                    }
                case .output:
                    try await executor.deliver(node: node, input: pending.input)
                case .text, .note:
                    break
                }
            } catch is CancellationError {
                onUpdate(WorkflowStepUpdate(nodeID: node.id, status: .stopped, output: nil, error: nil))
                return .stopped("Stopped")
            } catch {
                let message = (error as? WorkflowStepError)?.message ?? error.localizedDescription
                onUpdate(WorkflowStepUpdate(nodeID: node.id, status: .failed, output: nil, error: message))
                return .failed(message)
            }

            onUpdate(WorkflowStepUpdate(nodeID: node.id, status: .done, output: output, error: nil))
            for edge in graph.edges where edge.from == node.id && (chosenBranch == nil || edge.branch == chosenBranch) {
                if loopEdgeIDs.contains(edge.id) {
                    loopPasses[edge.id, default: 0] += 1
                    if loopPasses[edge.id, default: 0] > maximumPassesPerLoopEdge { continue }
                }
                queue.append(Pending(nodeID: edge.to, input: output))
            }
        }
        return .done
    }

    /// The nodes a manual "Run" starts from: the triggers, and prompts nothing feeds, in canvas order.
    static func startNodeIDs(in graph: WorkflowGraph) -> [String] {
        let fed = Set(graph.edges.map(\.to))
        return graph.nodes.filter { $0.kind == .trigger || ($0.kind == .prompt && !fed.contains($0.id)) }.map(\.id)
    }
}

/// A step that cannot run, with a plain-words reason for the node to show.
struct WorkflowStepError: Error, Equatable {
    let message: String
}

enum WorkflowPromptBuilder {
    /// A buddy step's request: its task, then what the previous step handed on.
    static func stepPrompt(task: String, input: String) -> String {
        let trimmedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return trimmedTask }
        return trimmedTask.isEmpty ? trimmedInput : "\(trimmedTask)\n\nFrom the previous step:\n\(trimmedInput)"
    }

    /// A condition's request: the model answers with the one word yes or no.
    static func conditionPrompt(rule: String, input: String) -> String {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Answer with only the single word "yes" or "no".

        Question: \(rule.trimmingCharacters(in: .whitespacesAndNewlines))

        Text:
        \(trimmedInput.isEmpty ? "(nothing)" : trimmedInput)
        """
    }

    /// Added to the system prompt of a workflow step so the buddy answers briefly.
    static func systemAddendum(workflowTitle: String) -> String {
        "\n\nYou are one step in an automated workflow called \"\(workflowTitle)\". Do the task below and reply with just the result, briefly, so the next step can use it."
    }

    /// Reads a model's reply to a yes/no question. The first word decides; anything unclear is "no"
    /// (a loop must be able to end, and a wrong "no" is the safer side of an approval-free branch).
    static func yesOrNo(from reply: String) -> Bool {
        let firstWord = reply
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(CharacterSet(charactersIn: "*\"'`")))
            .lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .first
        return firstWord.map { ["yes", "y", "true", "yep", "yeah"].contains(String($0)) } ?? false
    }

    /// A one-line preview of a step's output for its card.
    static func preview(of output: String, limit: Int = 140) -> String {
        let singleLine = output.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return singleLine.count > limit ? String(singleLine.prefix(limit - 1)) + "…" : singleLine
    }
}

/// "08:00" → (8, 0), or nil for anything that is not a 24-hour time.
enum WorkflowScheduleTime {
    static func parse(_ text: String) -> (hour: Int, minute: Int)? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    /// Whether a trigger set to `text` is due at `date` (to the minute).
    static func isDue(_ text: String, at date: Date, calendar: Calendar = .current) -> Bool {
        guard let time = parse(text) else { return false }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return components.hour == time.hour && components.minute == time.minute
    }
}
