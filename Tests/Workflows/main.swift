//
//  Workflow suite: connection rules, loops, editing, history, camera, grid, store.
//

import Foundation

var failureCount = 0
var checkCount = 0

func check(_ condition: Bool, _ description: String) {
    checkCount += 1
    if !condition {
        failureCount += 1
        print("FAIL: \(description)")
    }
}

func node(_ id: String, _ kind: WorkflowNodeKind, x: Double = 0, y: Double = 0) -> WorkflowNode {
    WorkflowNode(id: id, kind: kind, at: WorkflowPoint(x: x, y: y), size: nil, locked: nil, fields: [:])
}
func edge(_ id: String, _ from: String, _ to: String, branch: WorkflowBranch? = nil) -> WorkflowEdge {
    WorkflowEdge(id: id, from: from, to: to, type: .text, branch: branch)
}

// MARK: - Ports and edge rules

let trigger = node("t", .trigger), buddy = node("b", .buddy), condition = node("c", .condition)
let output = node("o", .output), note = node("n", .note), approval = node("a", .approval)
check(WorkflowRules.edgeProblem(from: trigger, to: buddy, edge: edge("1", "t", "b")) == nil, "a trigger can feed a buddy")
check(WorkflowRules.edgeProblem(from: buddy, to: trigger, edge: edge("1", "b", "t")) == .port, "nothing feeds a trigger")
check(WorkflowRules.edgeProblem(from: output, to: buddy, edge: edge("1", "o", "b")) == .port, "an output sends nothing on")
check(WorkflowRules.edgeProblem(from: note, to: buddy, edge: edge("1", "n", "b")) == .annotation, "a note is not a step")
check(WorkflowRules.edgeProblem(from: condition, to: buddy, edge: edge("1", "c", "b")) == .conditionBranch, "a condition's connection needs a branch")
check(WorkflowRules.edgeProblem(from: condition, to: buddy, edge: edge("1", "c", "b", branch: .yes)) == nil, "a condition's connection with a branch is fine")
check(WorkflowRules.edgeProblem(from: buddy, to: output, edge: edge("1", "b", "o", branch: .no)) == .branch, "only a condition has branches")
check(WorkflowRules.edgeProblem(from: approval, to: output, edge: edge("1", "a", "o")) == nil, "an approval can feed an output")
check(!WorkflowNodeKind.note.isStep && !WorkflowNodeKind.text.isStep && WorkflowNodeKind.buddy.isStep, "notes and text are not steps")

let duplicateGraph = WorkflowGraph(nodes: [trigger, buddy], edges: [edge("1", "t", "b"), edge("2", "t", "b")])
check(WorkflowRules.graphProblem(duplicateGraph)?.problem == .duplicate && WorkflowRules.graphProblem(duplicateGraph)?.edge.id == "2", "a second identical connection is a duplicate")
check(WorkflowRules.graphProblem(WorkflowGraph(nodes: [trigger, buddy], edges: [edge("1", "t", "b")])) == nil, "a clean graph has no problem")
check(WorkflowRules.graphProblem(WorkflowGraph(nodes: [trigger], edges: [edge("1", "t", "gone")]))?.problem == .port, "an edge to a missing node is refused")

// MARK: - Loops

let chain = WorkflowGraph(nodes: [trigger, buddy, node("b2", .buddy)], edges: [edge("1", "t", "b"), edge("2", "b", "b2")])
check(WorkflowRules.loopEdges(nodes: chain.nodes, edges: chain.edges).isEmpty, "a chain has no loop")
let looped = WorkflowGraph(nodes: [trigger, buddy, condition], edges: [edge("1", "t", "b"), edge("2", "b", "c"), edge("3", "c", "b", branch: .no)])
check(WorkflowRules.loopEdges(nodes: looped.nodes, edges: looped.edges) == ["3"], "the edge back to an earlier step is the loop edge")
check(WorkflowRules.loops(of: looped)["3"] == WorkflowRules.Loop(body: ["b", "c"], endless: false), "a loop's body is the steps it repeats, and a condition can end it")
let endlessGraph = WorkflowGraph(nodes: [node("x", .buddy), node("y", .buddy)], edges: [edge("1", "x", "y"), edge("2", "y", "x")])
check(WorkflowRules.loops(of: endlessGraph).values.allSatisfy(\.endless), "a loop with no condition is endless")
var longChain = WorkflowGraph()
for index in 0..<20_000 { longChain.nodes.append(node("n\(index)", .buddy)) }
for index in 0..<19_999 { longChain.edges.append(edge("e\(index)", "n\(index)", "n\(index + 1)")) }
check(WorkflowRules.loopEdges(nodes: longChain.nodes, edges: longChain.edges).isEmpty, "a very long chain does not overflow the stack")

// MARK: - Editing

var graph = WorkflowGraph()
let addedTrigger = WorkflowEditing.adding(.trigger, at: WorkflowPoint(x: 13, y: 21), to: graph)
graph = addedTrigger.graph
check(graph.nodes.first?.at == WorkflowPoint(x: 16, y: 24), "a new node snaps to the 8px grid")
check(graph.nodes.first?.fields["trigger"] == .string("manual"), "a new trigger starts manual")
let addedBuddy = WorkflowEditing.adding(.buddy, at: WorkflowPoint(x: 400, y: 0), to: graph)
graph = addedBuddy.graph
if case .connected(let connected, let edgeID) = WorkflowEditing.connecting(from: addedTrigger.nodeID, to: addedBuddy.nodeID, branch: nil, in: graph) {
    graph = connected
    check(graph.edges.count == 1 && graph.edges[0].id == edgeID, "connecting adds an edge")
} else { check(false, "trigger to buddy connects") }
check(WorkflowEditing.connecting(from: addedTrigger.nodeID, to: addedBuddy.nodeID, branch: nil, in: graph) == .refused(.duplicate), "the same connection twice is refused")
check(WorkflowEditing.connecting(from: addedBuddy.nodeID, to: addedTrigger.nodeID, branch: nil, in: graph) == .refused(.port), "connecting into a trigger is refused")
check(WorkflowEditing.connecting(from: addedBuddy.nodeID, to: addedBuddy.nodeID, branch: nil, in: graph) == .unknownNode, "a node cannot connect to itself")
let addedCondition = WorkflowEditing.adding(.condition, at: WorkflowPoint(x: 800, y: 0), to: graph)
let addedOutput = WorkflowEditing.adding(.output, at: WorkflowPoint(x: 1200, y: 0), to: addedCondition.graph)
if case .connected(let withBranch, _) = WorkflowEditing.connecting(from: addedCondition.nodeID, to: addedOutput.nodeID, branch: nil, in: addedOutput.graph) {
    check(withBranch.edges.last?.branch == .yes, "a condition's connection defaults to the yes branch")
} else { check(false, "condition to output connects") }

let moved = WorkflowEditing.moving([addedBuddy.nodeID], byDx: 10, dy: -4, in: graph)
check(moved.nodes.first { $0.id == addedBuddy.nodeID }?.at == WorkflowPoint(x: 410, y: -4), "moving shifts the node")
let lockedGraph = WorkflowEditing.setLocked(true, [addedBuddy.nodeID], in: graph)
check(WorkflowEditing.moving([addedBuddy.nodeID], byDx: 50, dy: 50, in: lockedGraph) == lockedGraph, "a locked node does not move")
check(WorkflowEditing.removing([addedBuddy.nodeID], from: lockedGraph) == lockedGraph, "a locked node is not removed")
let afterRemove = WorkflowEditing.removing([addedBuddy.nodeID], from: graph)
check(afterRemove.nodes.count == 1 && afterRemove.edges.isEmpty, "removing a node removes its connections")
let duplicated = WorkflowEditing.duplicating(Set(graph.nodes.map(\.id)), in: graph)
check(duplicated.graph.nodes.count == 4 && duplicated.graph.edges.count == 2 && duplicated.newIDs.count == 2, "duplicating copies the nodes and the connection between them")
check(duplicated.graph.nodes.last?.at == WorkflowPoint(x: 432, y: 32), "a copy sits offset from its original")
check(WorkflowEditing.nodes(in: WorkflowRect(x: 0, y: 0, width: 100, height: 100), of: graph) == [addedTrigger.nodeID], "a box selects the nodes it touches")
check(WorkflowEditing.raising([addedTrigger.nodeID], in: graph).nodes.last?.id == addedTrigger.nodeID, "raising puts a node on top")
check(WorkflowEditing.disconnecting(graph.edges[0].id, in: graph).edges.isEmpty, "disconnecting removes the edge")
check(WorkflowEditing.setField("task", to: .string("Summarize"), ofNode: addedBuddy.nodeID, in: graph).nodes.first { $0.id == addedBuddy.nodeID }?.text("task") == "Summarize", "setting a field stores it")

// MARK: - History

var history = WorkflowHistory()
let empty = WorkflowGraph()
history.commit(empty)
check(history.canUndo && !history.canRedo, "a commit makes undo available")
let restored = history.undo(current: graph)
check(restored == empty && history.canRedo && !history.canUndo, "undo gives the earlier graph and enables redo")
check(history.redo(current: empty) == graph, "redo gives the graph back")
history.commit(empty); history.commit(empty)
let beforeJoin = history.past.count
history.beginJoin(empty); history.commit(graph); history.commit(graph); history.endJoin()
check(history.past.count == beforeJoin + 1, "changes inside a joined step make one undo")
var full = WorkflowHistory()
for _ in 0..<150 { full.commit(empty) }
check(full.past.count == WorkflowHistory.limit, "history keeps the last 100 steps")
history.commit(graph)
check(!history.canRedo, "a new change clears redo")

// MARK: - Camera

let camera = WorkflowCamera(x: 100, y: 50, scale: 1)
let anchor = WorkflowPoint(x: 300, y: 250)
let worldBefore = camera.worldPoint(anchor)
let zoomedCamera = camera.zoomedIn(around: anchor)
let worldAfter = zoomedCamera.worldPoint(anchor)
check(abs(worldBefore.x - worldAfter.x) < 1e-9 && abs(worldBefore.y - worldAfter.y) < 1e-9, "zooming keeps the point under the cursor still")
check(abs(zoomedCamera.scale - 1.2) < 1e-9, "a zoom step is 1.2")
check(WorkflowCamera(scale: 1.9).zoomedIn(around: anchor).scale == 2, "zoom stops at 200%")
check(WorkflowCamera(scale: 0.3).zoomedOut(around: anchor).scale == 0.25, "zoom stops at 25%")
check(WorkflowCamera(scale: 1).percentText == "100%" && WorkflowCamera(scale: 0.5).percentText == "50%", "the zoom reads as a percentage")
let panned = camera.panned(byScreenDx: 20, dy: -10)
check(panned.x == 120 && panned.y == 40 && panned.scale == 1, "panning moves the offset")
let fit = WorkflowCamera.fitting(bounds: WorkflowRect(x: 0, y: 0, width: 4000, height: 2000), viewWidth: 1000, viewHeight: 600)
check(fit.scale < 0.3 && fit.scale >= 0.25, "fit zooms out to show a wide graph")
let fitSmall = WorkflowCamera.fitting(bounds: WorkflowRect(x: 0, y: 0, width: 100, height: 100), viewWidth: 1000, viewHeight: 600)
check(fitSmall.scale == 1, "fit never zooms in past 100%")
let centre = fitSmall.screenPoint(WorkflowPoint(x: 50, y: 50))
check(abs(centre.x - 500) < 1e-9 && abs(centre.y - 300) < 1e-9, "fit centres the graph")
check(WorkflowCamera.fitting(bounds: WorkflowRect(x: 0, y: 0, width: 0, height: 0), viewWidth: 100, viewHeight: 100) == WorkflowCamera(), "fit with nothing resets the camera")

// MARK: - Geometry and grid

check(WorkflowLayout.snapped(13) == 16 && WorkflowLayout.snapped(11) == 8 && WorkflowLayout.snapped(-5) == -8, "snap rounds to 8")
let curve = WorkflowLayout.edgeCurve(from: WorkflowPoint(x: 0, y: 0), to: WorkflowPoint(x: 400, y: 100))
check(curve.control1 == WorkflowPoint(x: 200, y: 0) && curve.control2 == WorkflowPoint(x: 200, y: 100), "the curve bends half the gap")
let near = WorkflowLayout.edgeCurve(from: WorkflowPoint(x: 0, y: 0), to: WorkflowPoint(x: 20, y: 0))
check(near.control1.x == 48, "the bend is at least 48")
check(WorkflowLayout.point(on: curve, at: 0) == curve.start && WorkflowLayout.point(on: curve, at: 1) == curve.end, "a curve starts and ends at its ports")
check(WorkflowLayout.distance(from: WorkflowLayout.point(on: curve, at: 0.5), toCurve: curve) < 1e-9, "a point on the curve is at distance zero")
let conditionNode = node("c2", .condition, x: 100, y: 100)
check(WorkflowLayout.portPoint(of: conditionNode, isOutput: true, branch: .yes).y < WorkflowLayout.portPoint(of: conditionNode, isOutput: true, branch: .no).y, "a condition's yes port sits above its no port")
check(WorkflowLayout.portPoint(of: buddy, isOutput: true).x - WorkflowLayout.portPoint(of: buddy, isOutput: false).x == WorkflowLayout.defaultSize(of: .buddy).width, "output and input ports are a card width apart")
check(WorkflowLayout.arrowhead(into: WorkflowPoint(x: 100, y: 50)).count == 3, "an arrowhead has three points")
let grid = WorkflowDotGrid.make(for: WorkflowCamera(x: 0, y: 0, scale: 1))
check(grid.step == 20 && grid.minorOpacity == 0 && grid.quarter == 5, "at 100% the dots are 20px apart with no half-step dots")
let farGrid = WorkflowDotGrid.make(for: WorkflowCamera(x: 0, y: 0, scale: 0.25))
check(farGrid.step >= 20 && farGrid.step <= 40, "zoomed out, the screen step stays between one and two grid steps")
check(WorkflowDotGrid.make(for: WorkflowCamera(x: -37, y: 91, scale: 1)).originX >= 0, "the grid offset always wraps to a positive value")

// MARK: - Store

MainActor.assumeIsolated {
let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-workflows-\(UUID().uuidString).json")
let store = WorkflowStore(fileURL: storeURL)
let created = store.create(title: "Morning")
store.save(graph, ofWorkflow: created.id)
check(store.workflow(withID: created.id)?.revision == 2, "a save raises the revision")
store.save(graph, ofWorkflow: created.id)
check(store.workflow(withID: created.id)?.revision == 2, "saving the same graph changes nothing")
store.rename(created.id, to: "  ")
check(store.workflow(withID: created.id)?.title == "Morning", "a blank title is ignored")
check(((try? FileManager.default.attributesOfItem(atPath: storeURL.path)[.posixPermissions]) as? Int) == 0o600, "the file is private")
let reloadedStore = WorkflowStore(fileURL: storeURL)
check(reloadedStore.workflow(withID: created.id)?.graph == graph, "a saved graph survives a restart")
check(reloadedStore.workflow(withID: created.id)?.stepCount == 2, "steps count only the nodes a run goes through")
reloadedStore.delete(created.id)
check(reloadedStore.workflows.isEmpty, "a workflow can be deleted")
try? FileManager.default.removeItem(at: storeURL)

}

// MARK: - Running

final class FakeExecutor: WorkflowStepExecutor {
    var buddyOutputs: [String: String] = [:]
    var decisions: [String: [Bool]] = [:]
    var approves = true
    var failBuddyNodeID: String?
    private(set) var ran: [String] = []
    private(set) var delivered: [String] = []
    private(set) var inputs: [String: [String]] = [:]

    func runBuddy(node: WorkflowNode, input: String) async throws -> String {
        ran.append(node.id); inputs[node.id, default: []].append(input)
        if node.id == failBuddyNodeID { throw WorkflowStepError(message: "Choose a buddy") }
        return buddyOutputs[node.id] ?? "out(\(node.id))"
    }
    func decide(node: WorkflowNode, input: String) async throws -> Bool {
        ran.append(node.id)
        var answers = decisions[node.id] ?? [true]
        let answer = answers.isEmpty ? false : answers.removeFirst()
        decisions[node.id] = answers
        return answer
    }
    func approve(node: WorkflowNode, input: String) async -> Bool { ran.append(node.id); return approves }
    func deliver(node: WorkflowNode, input: String) async throws { ran.append(node.id); delivered.append(input) }
}

func runGraph(_ graph: WorkflowGraph, _ executor: FakeExecutor, cancelAfter: Int = .max) async -> (WorkflowRunOutcome, [WorkflowStepUpdate]) {
    var updates: [WorkflowStepUpdate] = []
    let outcome = await WorkflowRunCore.run(
        graph: graph, startNodeIDs: WorkflowRunCore.startNodeIDs(in: graph), executor: executor,
        onUpdate: { updates.append($0) }, isCancelled: { updates.count >= cancelAfter })
    return (outcome, updates)
}

var promptNode = node("p", .prompt); promptNode.fields["text"] = .string("hello")
let linear = WorkflowGraph(nodes: [trigger, promptNode, buddy, output], edges: [edge("1", "t", "b"), edge("2", "p", "b"), edge("3", "b", "o")])
let linearExecutor = FakeExecutor()
linearExecutor.buddyOutputs["b"] = "SUMMARY"
let (linearOutcome, linearUpdates) = await runGraph(linear, linearExecutor)
check(linearOutcome == .done, "a linear workflow runs to the end")
check(linearExecutor.ran == ["b", "b", "o", "o"], "the buddy runs once for each input that arrives, then the outputs")
check(linearExecutor.inputs["b"] == ["", "hello"], "a step receives what the one before handed on")
check(linearExecutor.delivered == ["SUMMARY", "SUMMARY"], "the output receives the buddy's result")
check(linearUpdates.filter { $0.status == .done }.count == 6, "every step reports done")
check(linearUpdates.first?.status == .running && linearUpdates.first?.nodeID == "t", "a run starts at the trigger")

let branching = WorkflowGraph(
    nodes: [trigger, buddy, condition, node("yesOut", .output), node("noOut", .output)],
    edges: [edge("1", "t", "b"), edge("2", "b", "c"), edge("3", "c", "yesOut", branch: .yes), edge("4", "c", "noOut", branch: .no)])
let yesExecutor = FakeExecutor(); yesExecutor.decisions["c"] = [true]
_ = await runGraph(branching, yesExecutor)
check(yesExecutor.ran == ["b", "c", "yesOut"], "a yes follows only the yes edge")
let noExecutor = FakeExecutor(); noExecutor.decisions["c"] = [false]
_ = await runGraph(branching, noExecutor)
check(noExecutor.ran == ["b", "c", "noOut"], "a no follows only the no edge")

let gated = WorkflowGraph(nodes: [trigger, approval, output], edges: [edge("1", "t", "a"), edge("2", "a", "o")])
let declining = FakeExecutor(); declining.approves = false
let (declinedOutcome, declinedUpdates) = await runGraph(gated, declining)
check(declinedOutcome == .stopped("Not approved") && declining.delivered.isEmpty, "a declined approval stops the run before anything after it")
check(declinedUpdates.contains { $0.nodeID == "a" && $0.status == .waitingForApproval }, "an approval reports that it is waiting")
let approving = FakeExecutor()
_ = await runGraph(gated, approving)
check(approving.delivered.count == 1, "an approved run goes on")

let failing = FakeExecutor(); failing.failBuddyNodeID = "b"
let (failedOutcome, failedUpdates) = await runGraph(linear, failing)
check(failedOutcome == .failed("Choose a buddy") && failedUpdates.last?.status == .failed && failedUpdates.last?.error == "Choose a buddy", "a failing step fails the run with its reason")
check(failing.delivered.isEmpty, "nothing after a failed step runs")

let loopGraph = WorkflowGraph(nodes: [trigger, buddy, condition], edges: [edge("1", "t", "b"), edge("2", "b", "c"), edge("3", "c", "b", branch: .no)])
let loopExecutor = FakeExecutor(); loopExecutor.decisions["c"] = Array(repeating: false, count: 20)
let (loopOutcome, _) = await runGraph(loopGraph, loopExecutor)
check(loopOutcome == .done, "a loop that never gets a yes still ends")
check(loopExecutor.ran.filter { $0 == "b" }.count == WorkflowRunCore.maximumPassesPerLoopEdge + 1, "a loop edge is taken at most three times")
let endingLoop = FakeExecutor(); endingLoop.decisions["c"] = [false, true]
_ = await runGraph(loopGraph, endingLoop)
check(endingLoop.ran.filter { $0 == "b" }.count == 2, "a loop ends as soon as its condition says yes")

let (cancelledOutcome, _) = await runGraph(linear, FakeExecutor(), cancelAfter: 2)
check(cancelledOutcome == .stopped("Stopped"), "a cancelled run stops")
check(await runGraph(WorkflowGraph(nodes: [trigger, buddy], edges: [edge("1", "b", "t")]), FakeExecutor()).0 == .failed("That step does not take this type"), "a graph that cannot run is refused before any step")
check(await runGraph(WorkflowGraph(nodes: [buddy], edges: []), FakeExecutor()).0 == .done, "a graph with no trigger runs nothing and ends")

check(WorkflowPromptBuilder.stepPrompt(task: "Summarize", input: "text") == "Summarize\n\nFrom the previous step:\ntext", "a step's prompt carries the previous output")
check(WorkflowPromptBuilder.stepPrompt(task: "Summarize", input: "  ") == "Summarize", "no input, just the task")
check(WorkflowPromptBuilder.stepPrompt(task: "", input: "x") == "x", "no task, just the input")
check(WorkflowPromptBuilder.yesOrNo(from: "Yes, it is.") && WorkflowPromptBuilder.yesOrNo(from: "**yes**") && !WorkflowPromptBuilder.yesOrNo(from: "No.") && !WorkflowPromptBuilder.yesOrNo(from: "Maybe") && !WorkflowPromptBuilder.yesOrNo(from: ""), "a yes/no reply is read by its first word, and unclear means no")
check(WorkflowPromptBuilder.preview(of: "a\n  b   c", limit: 140) == "a b c" && WorkflowPromptBuilder.preview(of: String(repeating: "x", count: 300)).count == 140, "a preview is one clipped line")
check(WorkflowScheduleTime.parse("08:05")! == (8, 5) && WorkflowScheduleTime.parse("24:00") == nil && WorkflowScheduleTime.parse("9") == nil, "schedule times are 24-hour HH:MM")
var calendarForSchedule = Calendar(identifier: .gregorian); calendarForSchedule.timeZone = TimeZone(identifier: "UTC")!
check(WorkflowScheduleTime.isDue("08:00", at: ISO8601DateFormatter().date(from: "2026-10-31T08:00:30Z")!, calendar: calendarForSchedule), "a trigger is due during its minute")
check(!WorkflowScheduleTime.isDue("08:00", at: ISO8601DateFormatter().date(from: "2026-10-31T08:01:00Z")!, calendar: calendarForSchedule), "and not the minute after")

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
