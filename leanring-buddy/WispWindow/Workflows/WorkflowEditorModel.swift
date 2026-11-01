//
//  WorkflowEditorModel.swift
//  leanring-buddy
//
//  The state behind one open workflow canvas: the graph, what is selected, the camera, the tool,
//  a connection being drawn, and the undo history. Every edit goes through `WorkflowEditing`, so the
//  rules are the tested ones; this class only holds state and saves (`WorkflowStore`).
//  Translated from OpenBot's `WorkflowCanvas` / `workflow-board` state.
//

import Combine
import SwiftUI

enum WorkflowTool: String, CaseIterable, Identifiable {
    case select, pan, note, text
    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .pan: return "hand.raised"
        case .note: return "note.text"
        case .text: return "textformat"
        }
    }

    var title: String {
        switch self {
        case .select: return "Select"
        case .pan: return "Pan"
        case .note: return "Sticky note"
        case .text: return "Text"
        }
    }
}

/// A connection the user is drawing from an output port, following the pointer.
struct WorkflowPendingConnection: Equatable {
    let fromID: String
    let branch: WorkflowBranch?
    /// The pointer, in world coordinates.
    var pointer: WorkflowPoint
}

@MainActor
final class WorkflowEditorModel: ObservableObject {
    let workflowID: UUID

    @Published private(set) var graph: WorkflowGraph
    @Published var selection: Set<String> = []
    @Published var selectedEdgeID: String?
    @Published var camera = WorkflowCamera()
    @Published var tool: WorkflowTool = .select
    @Published var pending: WorkflowPendingConnection?
    /// The rectangle of a box selection, in world coordinates.
    @Published var boxSelection: WorkflowRect?
    /// A short line about the last refused action ("That step does not take this type").
    @Published var notice: String?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// The size of the canvas view, kept current by the view, for fit and for placing new nodes.
    var viewSize = CGSize(width: 900, height: 600)
    private var hasFittedToRealSize = false

    /// The first time the view reports its real size, fit what is on the canvas to it (the camera
    /// made at init could only guess the size).
    func viewSizeChanged(to size: CGSize) {
        viewSize = size
        guard !hasFittedToRealSize, size.width > 300, size.height > 200 else { return }
        hasFittedToRealSize = true
        if !graph.nodes.isEmpty { fit() }
    }

    private let store: WorkflowStore
    private var history = WorkflowHistory()
    private var dragOrigins: [String: WorkflowPoint] = [:]
    /// True between `beginDrag` and `endDrag`.
    private(set) var isDragging = false
    private var lastTypingKey: String?
    private var lastTypingAt = Date.distantPast

    init(workflowID: UUID, store: WorkflowStore = .shared) {
        self.workflowID = workflowID
        self.store = store
        graph = store.workflow(withID: workflowID)?.graph ?? WorkflowGraph()
        if !graph.nodes.isEmpty, let bounds = WorkflowEditing.bounds(of: graph.nodes) {
            camera = WorkflowCamera.fitting(bounds: bounds, viewWidth: 900, viewHeight: 600)
        } else {
            camera = WorkflowCamera(x: 120, y: 120, scale: 1)
        }
    }

    // MARK: Applying edits

    private func refreshHistoryFlags() {
        canUndo = history.canUndo
        canRedo = history.canRedo
    }

    /// Replaces the graph. `recordsHistory` saves the old one for undo; `persists` writes the file.
    func apply(_ newGraph: WorkflowGraph, recordsHistory: Bool = true, persists: Bool = true) {
        guard newGraph != graph else { return }
        if recordsHistory { history.commit(graph) }
        graph = newGraph
        refreshHistoryFlags()
        if persists { store.save(graph, ofWorkflow: workflowID) }
    }

    func undo() {
        guard let restored = history.undo(current: graph) else { return }
        graph = restored
        selection.formIntersection(Set(graph.nodes.map(\.id)))
        selectedEdgeID = nil
        refreshHistoryFlags()
        store.save(graph, ofWorkflow: workflowID)
    }

    func redo() {
        guard let restored = history.redo(current: graph) else { return }
        graph = restored
        selection.formIntersection(Set(graph.nodes.map(\.id)))
        refreshHistoryFlags()
        store.save(graph, ofWorkflow: workflowID)
    }

    // MARK: Nodes

    func node(_ id: String) -> WorkflowNode? { graph.nodes.first { $0.id == id } }

    /// Adds a node at a world point (or the middle of the view) and selects it.
    @discardableResult
    func addNode(_ kind: WorkflowNodeKind, at point: WorkflowPoint? = nil) -> String {
        let target = point ?? placementAtViewCentre(for: kind)
        let result = WorkflowEditing.adding(kind, at: target, to: graph)
        apply(result.graph)
        selection = [result.nodeID]
        selectedEdgeID = nil
        return result.nodeID
    }

    /// The middle of the view, nudged so a second new node does not hide the first.
    private func placementAtViewCentre(for kind: WorkflowNodeKind) -> WorkflowPoint {
        let size = WorkflowLayout.defaultSize(of: kind)
        let centre = camera.worldPoint(WorkflowPoint(x: viewSize.width / 2, y: viewSize.height / 2))
        let stackOffset = Double(graph.nodes.count % 6) * 24
        return WorkflowPoint(x: centre.x - size.width / 2 + stackOffset, y: centre.y - size.height / 2 + stackOffset)
    }

    func removeSelection() {
        if let edgeID = selectedEdgeID {
            apply(WorkflowEditing.disconnecting(edgeID, in: graph))
            selectedEdgeID = nil
            return
        }
        guard !selection.isEmpty else { return }
        apply(WorkflowEditing.removing(selection, from: graph))
        selection = []
    }

    func duplicateSelection() {
        guard !selection.isEmpty else { return }
        let result = WorkflowEditing.duplicating(selection, in: graph)
        apply(result.graph)
        selection = result.newIDs
    }

    func toggleLockOnSelection() {
        guard !selection.isEmpty else { return }
        let allLocked = selection.allSatisfy { node($0)?.locked == true }
        apply(WorkflowEditing.setLocked(!allLocked, selection, in: graph))
    }

    func selectAll() { selection = Set(graph.nodes.map(\.id)); selectedEdgeID = nil }

    func select(_ id: String, extending: Bool) {
        selectedEdgeID = nil
        if extending {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else if !selection.contains(id) {
            selection = [id]
        }
        apply(WorkflowEditing.raising(selection, in: graph), recordsHistory: false, persists: false)
    }

    func clearSelection() { selection = []; selectedEdgeID = nil }

    /// Arrow keys move the selection one snap step (four with Shift).
    func nudgeSelection(dx: Double, dy: Double, large: Bool) {
        guard !selection.isEmpty else { return }
        let step = large ? WorkflowLayout.arrowKeyLargeStep : WorkflowLayout.arrowKeyStep
        apply(WorkflowEditing.moving(selection, byDx: dx * step, dy: dy * step, in: graph))
    }

    // MARK: Dragging nodes

    /// A drag starts: remember where the selection was, and open one undo step.
    func beginDrag() {
        dragOrigins = Dictionary(graph.nodes.filter { selection.contains($0.id) && $0.locked != true }.map { ($0.id, $0.at) },
                                 uniquingKeysWith: { first, _ in first })
        history.beginJoin(graph)
        isDragging = true
        refreshHistoryFlags()
    }

    /// Moves the dragged nodes to their origin plus the screen translation (divided by the zoom).
    func drag(byScreenTranslation translation: CGSize) {
        var updated = graph
        for index in updated.nodes.indices {
            guard let origin = dragOrigins[updated.nodes[index].id] else { continue }
            updated.nodes[index].at = WorkflowPoint(x: origin.x + translation.width / camera.scale,
                                                    y: origin.y + translation.height / camera.scale)
        }
        apply(updated, recordsHistory: false, persists: false)
    }

    func endDrag() {
        apply(WorkflowEditing.snapping(Set(dragOrigins.keys), in: graph), recordsHistory: false, persists: true)
        dragOrigins = [:]
        isDragging = false
        history.endJoin()
        refreshHistoryFlags()
    }

    // MARK: Connecting

    func beginConnection(from nodeID: String, branch: WorkflowBranch?, pointerWorld: WorkflowPoint) {
        pending = WorkflowPendingConnection(fromID: nodeID, branch: branch, pointer: pointerWorld)
        notice = nil
    }

    func updateConnection(pointerWorld: WorkflowPoint) { pending?.pointer = pointerWorld }

    /// Releases the connection: onto the input port (or card) of another node, or nowhere.
    func finishConnection() {
        defer { pending = nil }
        guard let pending else { return }
        guard let target = connectionTarget(for: pending) else { return }
        switch WorkflowEditing.connecting(from: pending.fromID, to: target, branch: pending.branch, in: graph) {
        case .connected(let updated, let edgeID):
            apply(updated)
            selectedEdgeID = edgeID
            selection = []
        case .refused(let problem):
            showNotice(problem.message)
        case .unknownNode:
            break
        }
    }

    /// The node whose input port is nearest the pointer (within 28px), else the node card under it.
    private func connectionTarget(for pending: WorkflowPendingConnection) -> String? {
        var best: (id: String, distance: Double)?
        for candidate in graph.nodes where candidate.id != pending.fromID {
            let port = WorkflowLayout.portPoint(of: candidate, isOutput: false)
            let distance = hypot(port.x - pending.pointer.x, port.y - pending.pointer.y)
            let inside = WorkflowLayout.frame(of: candidate).contains(pending.pointer)
            let effective = inside ? 0 : distance
            if effective <= 28, best == nil || effective < best!.distance { best = (candidate.id, effective) }
        }
        return best?.id
    }

    func showNotice(_ text: String) {
        notice = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            if self?.notice == text { self?.notice = nil }
        }
    }

    // MARK: Fields

    func text(_ nodeID: String, _ fieldName: String) -> String { node(nodeID)?.text(fieldName) ?? "" }

    /// Sets a field. Typing joins one undo step until the user pauses for a second.
    func setField(_ nodeID: String, _ fieldName: String, to value: String, typing: Bool = false) {
        let key = "\(nodeID)/\(fieldName)"
        let startsNewStep = !typing || key != lastTypingKey || Date().timeIntervalSince(lastTypingAt) > 1
        lastTypingKey = typing ? key : nil
        lastTypingAt = Date()
        apply(WorkflowEditing.setField(fieldName, to: .string(value), ofNode: nodeID, in: graph), recordsHistory: startsNewStep)
    }

    // MARK: Camera

    func fit() {
        let nodes = selection.isEmpty ? graph.nodes : graph.nodes.filter { selection.contains($0.id) }
        guard let bounds = WorkflowEditing.bounds(of: nodes) else { camera = WorkflowCamera(x: 120, y: 120, scale: 1); return }
        camera = WorkflowCamera.fitting(bounds: bounds, viewWidth: viewSize.width, viewHeight: viewSize.height)
    }

    func zoomIn() { camera = camera.zoomedIn(around: viewCentre) }
    func zoomOut() { camera = camera.zoomedOut(around: viewCentre) }
    func resetZoom() { camera = camera.zoomed(to: 1, around: viewCentre) }

    private var viewCentre: WorkflowPoint { WorkflowPoint(x: viewSize.width / 2, y: viewSize.height / 2) }

    // MARK: Derived

    var loopEdgeIDs: Set<String> { WorkflowRules.loopEdges(nodes: graph.nodes, edges: graph.edges) }
}
