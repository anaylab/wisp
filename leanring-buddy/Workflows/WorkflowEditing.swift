//
//  WorkflowEditing.swift
//  leanring-buddy
//
//  The pure edits the canvas makes to a graph — add, move, connect, disconnect, delete, duplicate,
//  lock — and the store that saves workflows. Every edit returns a new graph (or a refusal), so the
//  canvas can push the old one on the undo stack and `Tests/Workflows` can check the rules.
//

import Combine
import Foundation

enum WorkflowEditing {
    static func newID(_ prefix: String) -> String { "\(prefix)-\(UUID().uuidString.prefix(8).lowercased())" }

    /// Adds a node of `kind` at a (snapped) world point, on top of the stack.
    static func adding(_ kind: WorkflowNodeKind, at point: WorkflowPoint, to graph: WorkflowGraph, fields: [String: WorkflowFieldValue]? = nil) -> (graph: WorkflowGraph, nodeID: String) {
        var updated = graph
        let node = WorkflowNode(
            id: newID("n"), kind: kind, at: WorkflowLayout.snapped(point), size: nil, locked: nil,
            fields: fields ?? WorkflowRules.defaultFields(for: kind)
        )
        updated.nodes.append(node)
        return (updated, node.id)
    }

    /// Moves the nodes by a world offset, snapped. Locked nodes stay where they are.
    static func moving(_ ids: Set<String>, byDx dx: Double, dy: Double, in graph: WorkflowGraph) -> WorkflowGraph {
        var updated = graph
        for index in updated.nodes.indices where ids.contains(updated.nodes[index].id) && updated.nodes[index].locked != true {
            updated.nodes[index].at.x = max(-1_000_000, min(1_000_000, updated.nodes[index].at.x + dx))
            updated.nodes[index].at.y = max(-1_000_000, min(1_000_000, updated.nodes[index].at.y + dy))
        }
        return updated
    }

    /// Snaps the nodes to the grid (the end of a drag).
    static func snapping(_ ids: Set<String>, in graph: WorkflowGraph) -> WorkflowGraph {
        var updated = graph
        for index in updated.nodes.indices where ids.contains(updated.nodes[index].id) {
            updated.nodes[index].at = WorkflowLayout.snapped(updated.nodes[index].at)
        }
        return updated
    }

    enum ConnectResult: Equatable {
        case connected(WorkflowGraph, edgeID: String)
        case refused(WorkflowGraphProblem)
        case unknownNode
    }

    /// Connects an output port to an input port. The edge's type is the first the two can share.
    static func connecting(from fromID: String, to toID: String, branch: WorkflowBranch?, in graph: WorkflowGraph) -> ConnectResult {
        guard fromID != toID,
              let from = graph.nodes.first(where: { $0.id == fromID }),
              let to = graph.nodes.first(where: { $0.id == toID }) else { return .unknownNode }
        guard from.kind.isStep, to.kind.isStep else { return .refused(.annotation) }
        guard let type = WorkflowPorts.outgoing(from.kind).first(where: { WorkflowPorts.incoming(to.kind).contains($0) }) else {
            return .refused(.port)
        }
        // A condition's connection says which branch it leaves from; nothing else has one.
        let resolvedBranch = from.kind == .condition ? (branch ?? .yes) : nil
        let edge = WorkflowEdge(id: newID("e"), from: fromID, to: toID, type: type, branch: resolvedBranch)
        if let problem = WorkflowRules.edgeProblem(from: from, to: to, edge: edge) { return .refused(problem) }
        var updated = graph
        updated.edges.append(edge)
        if let duplicate = WorkflowRules.graphProblem(updated), duplicate.problem == .duplicate { return .refused(.duplicate) }
        return .connected(updated, edgeID: edge.id)
    }

    static func disconnecting(_ edgeID: String, in graph: WorkflowGraph) -> WorkflowGraph {
        var updated = graph
        updated.edges.removeAll { $0.id == edgeID }
        return updated
    }

    /// Removes nodes (locked ones stay) and every connection that touched them.
    static func removing(_ ids: Set<String>, from graph: WorkflowGraph) -> WorkflowGraph {
        let removable = Set(graph.nodes.filter { ids.contains($0.id) && $0.locked != true }.map(\.id))
        var updated = graph
        updated.nodes.removeAll { removable.contains($0.id) }
        updated.edges.removeAll { removable.contains($0.from) || removable.contains($0.to) }
        return updated
    }

    /// Copies the nodes, offset, with the connections between them. Returns the new ids.
    static func duplicating(_ ids: Set<String>, in graph: WorkflowGraph) -> (graph: WorkflowGraph, newIDs: Set<String>) {
        var updated = graph
        var idMap: [String: String] = [:]
        for node in graph.nodes where ids.contains(node.id) {
            var copy = node
            copy = WorkflowNode(
                id: newID("n"), kind: node.kind,
                at: WorkflowPoint(x: node.at.x + WorkflowLayout.duplicateOffset, y: node.at.y + WorkflowLayout.duplicateOffset),
                size: node.size, locked: nil, fields: node.fields)
            idMap[node.id] = copy.id
            updated.nodes.append(copy)
        }
        for edge in graph.edges {
            if let from = idMap[edge.from], let to = idMap[edge.to] {
                updated.edges.append(WorkflowEdge(id: newID("e"), from: from, to: to, type: edge.type, branch: edge.branch))
            }
        }
        return (updated, Set(idMap.values))
    }

    static func setLocked(_ isLocked: Bool, _ ids: Set<String>, in graph: WorkflowGraph) -> WorkflowGraph {
        var updated = graph
        for index in updated.nodes.indices where ids.contains(updated.nodes[index].id) {
            updated.nodes[index].locked = isLocked ? true : nil
        }
        return updated
    }

    static func setField(_ name: String, to value: WorkflowFieldValue?, ofNode id: String, in graph: WorkflowGraph) -> WorkflowGraph {
        var updated = graph
        guard let index = updated.nodes.firstIndex(where: { $0.id == id }) else { return graph }
        updated.nodes[index].fields[name] = value
        return updated
    }

    /// Brings nodes to the top of the stack (the last is drawn on top).
    static func raising(_ ids: Set<String>, in graph: WorkflowGraph) -> WorkflowGraph {
        var updated = graph
        let raised = updated.nodes.filter { ids.contains($0.id) }
        updated.nodes.removeAll { ids.contains($0.id) }
        updated.nodes.append(contentsOf: raised)
        return updated
    }

    /// The nodes whose frame touches a world rectangle (a box selection).
    static func nodes(in rect: WorkflowRect, of graph: WorkflowGraph) -> Set<String> {
        Set(graph.nodes.filter { WorkflowLayout.frame(of: $0).intersects(rect) }.map(\.id))
    }

    /// The bounds of some nodes, for "fit".
    static func bounds(of nodes: [WorkflowNode]) -> WorkflowRect? {
        WorkflowRect.union(nodes.map(WorkflowLayout.frame(of:)))
    }

    /// A one-line summary of what a node does, for its card and for search.
    static func summary(of node: WorkflowNode) -> String {
        switch node.kind {
        case .trigger: return node.text("trigger") == WorkflowTriggerType.schedule.rawValue ? "On a schedule" : "Starts when you press run"
        case .prompt: return node.text("text")
        case .buddy: return node.text("task")
        case .condition: return node.text("rule")
        case .approval: return node.text("question")
        case .output: return node.text("target") == WorkflowOutputTarget.file.rawValue ? "Save to a file" : "Notify me"
        case .text, .note: return node.text("text")
        }
    }
}

/// Saves workflows to `~/Library/Application Support/Wisp/workflows.json` (0600, local only).
@MainActor
final class WorkflowStore: ObservableObject {
    static let shared = WorkflowStore()
    static let defaultFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Wisp/workflows.json")

    @Published private(set) var workflows: [Workflow] = []
    private let fileURL: URL

    init(fileURL: URL = WorkflowStore.defaultFileURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            workflows = (try? decoder.decode([Workflow].self, from: data)) ?? []
        }
    }

    func workflow(withID id: UUID) -> Workflow? { workflows.first { $0.id == id } }

    /// Most recently changed first.
    var ordered: [Workflow] { workflows.sorted { $0.updatedAt > $1.updatedAt } }

    @discardableResult
    func create(title: String = "Untitled workflow", graph: WorkflowGraph = WorkflowGraph()) -> Workflow {
        let workflow = Workflow(id: UUID(), title: title, graph: graph, updatedAt: Date(), revision: 1)
        workflows.append(workflow)
        persist()
        return workflow
    }

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = workflows.firstIndex(where: { $0.id == id }) else { return }
        workflows[index].title = trimmed
        workflows[index].updatedAt = Date()
        persist()
    }

    /// Saves a graph. Nothing is written when it did not change.
    func save(_ graph: WorkflowGraph, ofWorkflow id: UUID) {
        guard let index = workflows.firstIndex(where: { $0.id == id }), workflows[index].graph != graph else { return }
        workflows[index].graph = graph
        workflows[index].revision += 1
        workflows[index].updatedAt = Date()
        persist()
    }

    func setScheduled(_ id: UUID, _ isScheduled: Bool) {
        guard let index = workflows.firstIndex(where: { $0.id == id }) else { return }
        workflows[index].isScheduled = isScheduled ? true : nil
        persist()
    }

    func delete(_ id: UUID) {
        workflows.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(workflows) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
