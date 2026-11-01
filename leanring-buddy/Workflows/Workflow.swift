//
//  Workflow.swift
//  leanring-buddy
//
//  Workflows: a canvas of nodes that a trigger starts. A buddy can be any step, and a step hands its
//  output on along the edges. This file is the pure side — the graph, which connections are allowed,
//  loops, undo history, the camera (pan and zoom), the dot grid and the shape of a connection — so
//  `Tests/Workflows` checks it with nothing but Foundation. The canvas is `WorkflowCanvasView`.
//
//  Translated from OpenBot's workflow canvas (`ipc-workflows.ts`, `workflow-history.ts`,
//  `workflow-loops.ts`, `workflow-camera.ts`, `WorkflowCanvas.tsx`): the same node kinds, port table,
//  loop walk, snap size, zoom limits and grid.
//

import Foundation

// MARK: - Kinds and ports

enum WorkflowNodeKind: String, Codable, CaseIterable, Identifiable {
    case trigger
    /// A fixed piece of text to start from.
    case prompt
    /// A buddy does a task with the text it receives.
    case buddy
    /// A yes-or-no question about its input; the edges that leave it are the yes and no branches.
    case condition
    /// Waits for the user's go-ahead before anything after it runs.
    case approval
    case output
    /// Annotations for people: a run never goes through them.
    case text
    case note

    var id: String { rawValue }

    /// Text and notes are for people; a run never goes through them.
    var isStep: Bool { self != .text && self != .note }

    var title: String {
        switch self {
        case .trigger: return "Trigger"
        case .prompt: return "Prompt"
        case .buddy: return "Buddy"
        case .condition: return "Condition"
        case .approval: return "Approval"
        case .output: return "Output"
        case .text: return "Text"
        case .note: return "Sticky note"
        }
    }

    var symbolName: String {
        switch self {
        case .trigger: return "bolt"
        case .prompt: return "text.quote"
        case .buddy: return "person.crop.circle"
        case .condition: return "arrow.triangle.branch"
        case .approval: return "checkmark.shield"
        case .output: return "square.and.arrow.up"
        case .text: return "textformat"
        case .note: return "note.text"
        }
    }

    /// The kinds the add menu offers for steps (annotations have their own tools).
    static var stepKinds: [WorkflowNodeKind] { allCases.filter(\.isStep) }
}

enum WorkflowPortType: String, Codable, CaseIterable {
    case text
    case file
}

enum WorkflowBranch: String, Codable, CaseIterable {
    case yes
    case no
}

enum WorkflowTriggerType: String, Codable, CaseIterable {
    case manual
    case schedule
}

enum WorkflowOutputTarget: String, Codable, CaseIterable {
    case notify
    case file
}

/// The port types each step kind takes in and sends out. The canvas offers only these, so a
/// connection that cannot run cannot be drawn.
enum WorkflowPorts {
    static let all: [WorkflowPortType] = WorkflowPortType.allCases

    static func incoming(_ kind: WorkflowNodeKind) -> [WorkflowPortType] {
        switch kind {
        case .trigger, .prompt, .text, .note: return []
        case .buddy, .output: return all
        case .condition, .approval: return [.text]
        }
    }

    static func outgoing(_ kind: WorkflowNodeKind) -> [WorkflowPortType] {
        switch kind {
        case .trigger, .prompt, .buddy, .condition, .approval: return [.text]
        case .output, .text, .note: return []
        }
    }
}

// MARK: - Graph

/// A value a node keeps: a text, a choice, a number or a switch.
enum WorkflowFieldValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let boolValue = try? container.decode(Bool.self) { self = .bool(boolValue) }
        else if let numberValue = try? container.decode(Double.self) { self = .number(numberValue) }
        else { self = .string(try container.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

struct WorkflowPoint: Codable, Equatable {
    var x: Double
    var y: Double
}

/// A size the user set. A missing side keeps the node's default.
struct WorkflowNodeSize: Codable, Equatable {
    var width: Double?
    var height: Double?
}

struct WorkflowNode: Codable, Identifiable, Equatable {
    let id: String
    var kind: WorkflowNodeKind
    var at: WorkflowPoint
    var size: WorkflowNodeSize?
    var locked: Bool?
    /// The node's fields by name: a trigger's `trigger` and `time`, a buddy's `buddyID` and `task`,
    /// a condition's `rule`, an approval's `question`, an output's `target`, a prompt's `text`.
    var fields: [String: WorkflowFieldValue]

    func text(_ fieldName: String) -> String { fields[fieldName]?.stringValue ?? "" }
}

struct WorkflowEdge: Codable, Identifiable, Equatable {
    let id: String
    var from: String
    var to: String
    var type: WorkflowPortType
    /// The branch of a condition that the edge leaves from.
    var branch: WorkflowBranch?
}

struct WorkflowGraph: Codable, Equatable {
    /// In stack order: the last one is drawn on top.
    var nodes: [WorkflowNode] = []
    var edges: [WorkflowEdge] = []
}

/// One saved workflow.
struct Workflow: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var graph: WorkflowGraph
    var updatedAt: Date
    /// Goes up by one on each save.
    var revision: Int
    /// Starts its schedule triggers at their time while Wisp is running. Off unless the user turns it on.
    var isScheduled: Bool? = nil

    /// The nodes a run goes through.
    var stepCount: Int { graph.nodes.filter { $0.kind.isStep }.count }
}

// MARK: - Rules

enum WorkflowGraphProblem: Equatable {
    case annotation
    case port
    case branch
    case conditionBranch
    case duplicate

    var message: String {
        switch self {
        case .annotation: return "Notes and text are not steps"
        case .port: return "That step does not take this type"
        case .branch: return "Only a condition has branches"
        case .conditionBranch: return "A condition's connection needs yes or no"
        case .duplicate: return "Already connected"
        }
    }
}

enum WorkflowRules {
    /// Why one edge cannot be in a workflow that runs, or nil when it can.
    static func edgeProblem(from: WorkflowNode, to: WorkflowNode, edge: WorkflowEdge) -> WorkflowGraphProblem? {
        if !from.kind.isStep || !to.kind.isStep { return .annotation }
        if !WorkflowPorts.outgoing(from.kind).contains(edge.type) || !WorkflowPorts.incoming(to.kind).contains(edge.type) {
            return .port
        }
        if from.kind == .condition { return edge.branch == nil ? .conditionBranch : nil }
        return edge.branch == nil ? nil : .branch
    }

    /// The first edge that stops the graph from running, with the reason, or nil when it can run. A
    /// loop is allowed: the run takes its edge back as the next pass (`loopEdges`).
    static func graphProblem(_ graph: WorkflowGraph) -> (problem: WorkflowGraphProblem, edge: WorkflowEdge)? {
        let nodesByID = Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        for edge in graph.edges {
            guard let from = nodesByID[edge.from], let to = nodesByID[edge.to] else { return (.port, edge) }
            if let problem = edgeProblem(from: from, to: to, edge: edge) { return (problem, edge) }
            let key = "\(edge.from)\u{0}\(edge.to)\u{0}\(edge.type.rawValue)\u{0}\(edge.branch?.rawValue ?? "")"
            if !seen.insert(key).inserted { return (.duplicate, edge) }
        }
        return nil
    }

    /// The edges that go back to an earlier step and so close a loop. A walk goes depth first from
    /// the nodes no edge enters, then from the rest, each in canvas order; an edge to a node the walk
    /// is still inside is a loop edge. Without the loop edges the graph has no loop.
    static func loopEdges(nodes: [WorkflowNode], edges: [WorkflowEdge]) -> Set<String> {
        var next: [String: [WorkflowEdge]] = [:]
        var entered = Set<String>()
        for edge in edges {
            next[edge.from, default: []].append(edge)
            entered.insert(edge.to)
        }
        var loops = Set<String>()
        var done = Set<String>()
        var open = Set<String>()
        let starts = nodes.filter { !entered.contains($0.id) } + nodes.filter { entered.contains($0.id) }
        // Without recursion: a long chain must not reach the stack limit.
        for start in starts {
            if done.contains(start.id) { continue }
            var stack: [(id: String, index: Int)] = [(start.id, 0)]
            open.insert(start.id)
            while let top = stack.last {
                let outgoing = next[top.id] ?? []
                guard top.index < outgoing.count else {
                    stack.removeLast()
                    open.remove(top.id)
                    done.insert(top.id)
                    continue
                }
                stack[stack.count - 1].index += 1
                let edge = outgoing[top.index]
                if open.contains(edge.to) {
                    loops.insert(edge.id)
                } else if !done.contains(edge.to) {
                    open.insert(edge.to)
                    stack.append((edge.to, 0))
                }
            }
        }
        return loops
    }

    /// The nodes each pass of a loop runs again, and whether anything in them can end the loop.
    struct Loop: Equatable {
        let body: [String]
        /// No condition in the body can end the loop, so it repeats until the user stops the run.
        let endless: Bool
    }

    /// The loop of each connection that goes back to an earlier node, by connection id.
    static func loops(of graph: WorkflowGraph) -> [String: Loop] {
        let backs = loopEdges(nodes: graph.nodes, edges: graph.edges)
        let forward = graph.edges.filter { !backs.contains($0.id) }
        let kinds = Dictionary(graph.nodes.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        var result: [String: Loop] = [:]
        for edge in graph.edges where backs.contains(edge.id) {
            let after = reach(from: edge.to, along: forward, forwards: true)
            let before = reach(from: edge.from, along: forward, forwards: false)
            let body = graph.nodes.map(\.id).filter { after.contains($0) && before.contains($0) }
            result[edge.id] = Loop(body: body, endless: !body.contains { kinds[$0] == .condition })
        }
        return result
    }

    private static func reach(from origin: String, along edges: [WorkflowEdge], forwards: Bool) -> Set<String> {
        var seen: Set<String> = [origin]
        var pending = [origin]
        while let id = pending.popLast() {
            for edge in edges {
                let source = forwards ? edge.from : edge.to
                let target = forwards ? edge.to : edge.from
                if source == id, !seen.contains(target) {
                    seen.insert(target)
                    pending.append(target)
                }
            }
        }
        return seen
    }

    /// The fields a new node of this kind starts with.
    static func defaultFields(for kind: WorkflowNodeKind) -> [String: WorkflowFieldValue] {
        switch kind {
        case .trigger: return ["trigger": .string(WorkflowTriggerType.manual.rawValue)]
        case .output: return ["target": .string(WorkflowOutputTarget.notify.rawValue)]
        default: return [:]
        }
    }
}

// MARK: - Undo history

/// The undo and redo stacks. Each entry is the graph before one change. While a step is joined,
/// further changes belong to it, so one drag is one undo.
struct WorkflowHistory {
    static let limit = 100

    private(set) var past: [WorkflowGraph] = []
    private(set) var future: [WorkflowGraph] = []
    private var joinDepth = 0

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    /// Saves the graph before a change. Does nothing while a step is joined and already saved.
    mutating func commit(_ graph: WorkflowGraph) {
        guard joinDepth == 0 else { return }
        push(graph)
    }

    mutating func push(_ graph: WorkflowGraph) {
        past.append(graph)
        if past.count > Self.limit { past.removeFirst(past.count - Self.limit) }
        future = []
    }

    /// Opens a step: the graph is saved once now, and changes until `endJoin` join it.
    mutating func beginJoin(_ graph: WorkflowGraph) {
        if joinDepth == 0 { push(graph) }
        joinDepth += 1
    }

    mutating func endJoin() { joinDepth = max(0, joinDepth - 1) }

    /// The graph to show after undo, given the one on screen now.
    mutating func undo(current: WorkflowGraph) -> WorkflowGraph? {
        guard let saved = past.popLast() else { return nil }
        future.append(current)
        return saved
    }

    mutating func redo(current: WorkflowGraph) -> WorkflowGraph? {
        guard let saved = future.popLast() else { return nil }
        past.append(current)
        return saved
    }

    mutating func clear() {
        past = []
        future = []
        joinDepth = 0
    }
}

// MARK: - Camera

/// Where the canvas looks: the screen offset of the world's origin and the zoom.
struct WorkflowCamera: Equatable {
    var x: Double = 0
    var y: Double = 0
    var scale: Double = 1

    static let minimumScale = 0.25
    static let maximumScale = 2.0
    /// One press of a zoom button.
    static let zoomStep = 1.2
    static let fitMargin = 64.0

    /// A world point as it sits on screen.
    func screenPoint(_ world: WorkflowPoint) -> WorkflowPoint {
        WorkflowPoint(x: world.x * scale + x, y: world.y * scale + y)
    }

    /// A screen point as it sits in the world.
    func worldPoint(_ screen: WorkflowPoint) -> WorkflowPoint {
        WorkflowPoint(x: (screen.x - x) / scale, y: (screen.y - y) / scale)
    }

    /// Zooms to `newScale` (clamped) keeping the world point under `anchor` (a screen point) still.
    func zoomed(to newScale: Double, around anchor: WorkflowPoint) -> WorkflowCamera {
        let clamped = min(Self.maximumScale, max(Self.minimumScale, newScale))
        let world = worldPoint(anchor)
        return WorkflowCamera(x: anchor.x - world.x * clamped, y: anchor.y - world.y * clamped, scale: clamped)
    }

    func zoomedIn(around anchor: WorkflowPoint) -> WorkflowCamera { zoomed(to: scale * Self.zoomStep, around: anchor) }
    func zoomedOut(around anchor: WorkflowPoint) -> WorkflowCamera { zoomed(to: scale / Self.zoomStep, around: anchor) }

    func panned(byScreenDx dx: Double, dy: Double) -> WorkflowCamera {
        WorkflowCamera(x: x + dx, y: y + dy, scale: scale)
    }

    /// The camera that shows `bounds` (world) inside a view of `viewSize`, with a margin, never
    /// zoomed in past 100%.
    static func fitting(bounds: WorkflowRect, viewWidth: Double, viewHeight: Double) -> WorkflowCamera {
        guard bounds.width > 0 || bounds.height > 0, viewWidth > 0, viewHeight > 0 else { return WorkflowCamera() }
        let availableWidth = max(1, viewWidth - 2 * fitMargin)
        let availableHeight = max(1, viewHeight - 2 * fitMargin)
        let scale = min(1, min(availableWidth / max(bounds.width, 1), availableHeight / max(bounds.height, 1)))
        let clamped = min(maximumScale, max(minimumScale, scale))
        return WorkflowCamera(
            x: viewWidth / 2 - (bounds.x + bounds.width / 2) * clamped,
            y: viewHeight / 2 - (bounds.y + bounds.height / 2) * clamped,
            scale: clamped
        )
    }

    /// "100%".
    var percentText: String { "\(Int((scale * 100).rounded()))%" }
}

struct WorkflowRect: Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }

    func contains(_ point: WorkflowPoint) -> Bool {
        point.x >= x && point.x <= maxX && point.y >= y && point.y <= maxY
    }

    func intersects(_ other: WorkflowRect) -> Bool {
        x < other.maxX && maxX > other.x && y < other.maxY && maxY > other.y
    }

    static func union(_ rects: [WorkflowRect]) -> WorkflowRect? {
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { partial, rect in
            let left = min(partial.x, rect.x), top = min(partial.y, rect.y)
            return WorkflowRect(x: left, y: top, width: max(partial.maxX, rect.maxX) - left, height: max(partial.maxY, rect.maxY) - top)
        }
    }
}

// MARK: - Layout and geometry

enum WorkflowLayout {
    /// The snap step and the grid, in world pixels.
    static let snap = 8.0
    static let gridSpacing = 20.0
    static let dragThreshold = 4.0
    /// How far a copy sits from its original.
    static let duplicateOffset = 32.0
    static let arrowKeyStep = snap
    static let arrowKeyLargeStep = snap * 4
    /// A port is this far across, in world pixels.
    static let portSize = 14.0

    static func snapped(_ value: Double) -> Double { (value / snap).rounded() * snap }
    static func snapped(_ point: WorkflowPoint) -> WorkflowPoint { WorkflowPoint(x: snapped(point.x), y: snapped(point.y)) }

    /// The default size of each kind (the width is fixed by the card; the height is the card's own).
    static func defaultSize(of kind: WorkflowNodeKind) -> (width: Double, height: Double) {
        switch kind {
        case .trigger: return (264, 112)
        case .prompt: return (296, 151)
        case .buddy: return (304, 160)
        case .condition: return (272, 144)
        case .approval: return (272, 120)
        case .output: return (264, 112)
        case .text: return (200, 40)
        case .note: return (240, 240)
        }
    }

    static func size(of node: WorkflowNode) -> (width: Double, height: Double) {
        let fallback = defaultSize(of: node.kind)
        return (node.size?.width ?? fallback.width, node.size?.height ?? fallback.height)
    }

    static func frame(of node: WorkflowNode) -> WorkflowRect {
        let size = size(of: node)
        return WorkflowRect(x: node.at.x, y: node.at.y, width: size.width, height: size.height)
    }

    /// Where a port's centre sits in the world. A port is on the node's edge, level with the card's
    /// first line; a condition has two outputs, one under the other, for yes and no.
    static func portPoint(of node: WorkflowNode, isOutput: Bool, branch: WorkflowBranch? = nil) -> WorkflowPoint {
        let frame = frame(of: node)
        let x = isOutput ? frame.maxX : frame.x
        var y = frame.y + 36
        if isOutput, node.kind == .condition {
            y = frame.y + (branch == .no ? 100 : 68)
        }
        return WorkflowPoint(x: x, y: y)
    }

    /// The control distance of the S-curve: half the horizontal gap, at least 48.
    private static func bend(from: WorkflowPoint, to: WorkflowPoint) -> Double { max(48, abs(to.x - from.x) / 2) }

    /// A horizontal S-curve from an output port to an input port, as its four Bézier points.
    static func edgeCurve(from: WorkflowPoint, to: WorkflowPoint) -> (start: WorkflowPoint, control1: WorkflowPoint, control2: WorkflowPoint, end: WorkflowPoint) {
        let bend = bend(from: from, to: to)
        return (from, WorkflowPoint(x: from.x + bend, y: from.y), WorkflowPoint(x: to.x - bend, y: to.y), to)
    }

    static let loopDrop = 56.0
    static let loopBend = 48.0

    /// A loop: out of its port to the right, down and back under its nodes, then into the earlier
    /// node's port. Returned as the two Bézier segments joined by a straight line along `y`.
    static func loopSegments(from: WorkflowPoint, to: WorkflowPoint, y: Double) -> (
        first: (start: WorkflowPoint, control1: WorkflowPoint, control2: WorkflowPoint, end: WorkflowPoint),
        second: (start: WorkflowPoint, control1: WorkflowPoint, control2: WorkflowPoint, end: WorkflowPoint)
    ) {
        let out = from.x + loopBend
        let back = to.x - loopBend
        return (
            (from, WorkflowPoint(x: out, y: from.y), WorkflowPoint(x: out, y: y), WorkflowPoint(x: from.x, y: y)),
            (WorkflowPoint(x: to.x, y: y), WorkflowPoint(x: back, y: y), WorkflowPoint(x: back, y: to.y), to)
        )
    }

    /// The point on a cubic Bézier at `t` (0...1).
    static func point(on curve: (start: WorkflowPoint, control1: WorkflowPoint, control2: WorkflowPoint, end: WorkflowPoint), at t: Double) -> WorkflowPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return WorkflowPoint(
            x: a * curve.start.x + b * curve.control1.x + c * curve.control2.x + d * curve.end.x,
            y: a * curve.start.y + b * curve.control1.y + c * curve.control2.y + d * curve.end.y
        )
    }

    /// The distance from a point to a curve, by sampling (32 steps), for hovering an edge.
    static func distance(from point: WorkflowPoint, toCurve curve: (start: WorkflowPoint, control1: WorkflowPoint, control2: WorkflowPoint, end: WorkflowPoint)) -> Double {
        var nearest = Double.infinity
        for step in 0...32 {
            let sample = Self.point(on: curve, at: Double(step) / 32)
            nearest = min(nearest, hypot(sample.x - point.x, sample.y - point.y))
        }
        return nearest
    }

    /// The arrowhead where a connection enters an input port: a tip 6 before the port and 9 long.
    static func arrowhead(into end: WorkflowPoint) -> [WorkflowPoint] {
        let tip = end.x - 6
        let base = tip - 9
        return [WorkflowPoint(x: base, y: end.y - 5.5), WorkflowPoint(x: tip, y: end.y), WorkflowPoint(x: base, y: end.y + 5.5)]
    }
}

/// The dot grid follows the canvas. A dot is one screen pixel at every zoom. Above 100% the dots
/// spread with the zoom. Below it, each halving of the zoom doubles the world step, so the screen
/// step stays between one and two grid steps; the dots of the half step fade in as they spread.
struct WorkflowDotGrid: Equatable {
    let originX: Double
    let originY: Double
    let step: Double
    let quarter: Double
    /// 0...1: how visible the half-step dots are.
    let minorOpacity: Double

    static func make(for camera: WorkflowCamera) -> WorkflowDotGrid {
        let level = max(0, Int(ceil(log2(1 / camera.scale) - 1e-9)))
        let step = WorkflowLayout.gridSpacing * pow(2, Double(level)) * camera.scale
        let quarter = step / 4
        func wrap(_ value: Double) -> Double {
            let remainder = (value - quarter).truncatingRemainder(dividingBy: step)
            return (remainder + step).truncatingRemainder(dividingBy: step)
        }
        return WorkflowDotGrid(
            originX: wrap(camera.x), originY: wrap(camera.y), step: step, quarter: quarter,
            minorOpacity: level == 0 ? 0 : smoothstep(from: WorkflowLayout.gridSpacing * 2 / 3, to: WorkflowLayout.gridSpacing, value: step / 2)
        )
    }

    static func smoothstep(from: Double, to: Double, value: Double) -> Double {
        let t = min(1, max(0, (value - from) / (to - from)))
        return t * t * (3 - 2 * t)
    }
}
