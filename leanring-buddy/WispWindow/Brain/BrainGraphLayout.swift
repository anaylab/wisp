//
//  BrainGraphLayout.swift
//  leanring-buddy
//
//  The pure half of the Brain graph: which pages become nodes, which links
//  become edges, and one step of a force-directed layout (d3-force style:
//  every node repels every other, links pull like springs, a weak gravity
//  keeps the picture centred, and a "temperature" cools each step so the
//  layout settles and the view can stop its clock).
//
//  Also `BrainLinkResolver`, an in-memory `[[link]]` → slug lookup built once
//  from the page list. `BrainStore.resolvePage(named:)` re-checks the wiki
//  folder on every call — right for one lookup, far too slow for the few
//  thousand a graph or a reader needs per render.
//
//  Foundation + CoreGraphics only, so `Tests/BrainUI` compiles it standalone.
//

import CoreGraphics
import Foundation

// MARK: - Link resolution

struct BrainLinkResolver {
    private let slugsByComparableName: [String: String]
    private let knownSlugs: Set<String>

    /// Mirrors `BrainStore.setPages`: slug file names first, then aliases,
    /// then titles, later writes winning — so a title always beats an alias
    /// that happens to match another page.
    init(pages: [BrainPage]) {
        var newSlugsByComparableName: [String: String] = [:]
        for page in pages {
            if let fileName = page.slug.split(separator: "/").last {
                newSlugsByComparableName[BrainSlug.comparableName(String(fileName))] = page.slug
            }
        }
        for page in pages {
            for alias in page.aliases {
                newSlugsByComparableName[BrainSlug.comparableName(alias)] = page.slug
            }
        }
        for page in pages {
            newSlugsByComparableName[BrainSlug.comparableName(page.title)] = page.slug
        }
        if pages.contains(where: { $0.slug == "me" }) {
            newSlugsByComparableName["me"] = "me"
        }
        slugsByComparableName = newSlugsByComparableName
        knownSlugs = Set(pages.map(\.slug))
    }

    /// The slug a `[[link]]` target, title, alias or slug points at.
    func slug(forTarget target: String) -> String? {
        let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if knownSlugs.contains(trimmedTarget) { return trimmedTarget }
        return slugsByComparableName[BrainSlug.comparableName(trimmedTarget)]
    }

    func isResolved(_ target: String) -> Bool {
        slug(forTarget: target) != nil
    }
}

// MARK: - Graph model

struct BrainGraphNode: Equatable, Sendable {
    var slug: String
    var title: String
    var kind: BrainPageKind
    /// Links in plus links out among the pages on the graph.
    var linkCount: Int
    var position: CGPoint
    var velocity: CGVector
    /// A node held by the pointer: forces don't move it.
    var isPinned: Bool

    var radius: CGFloat { BrainGraphLayout.radius(forLinkCount: linkCount) }
}

/// An undirected link between two nodes (indices into `nodes`, lower first).
struct BrainGraphEdge: Equatable, Hashable, Sendable {
    var sourceIndex: Int
    var targetIndex: Int
}

struct BrainGraphLayout {
    /// Beyond this the graph shows the most-connected pages only: past a few
    /// hundred nodes it is a hairball, and the O(n²) repulsion gets costly.
    static let defaultMaximumNodeCount = 400

    // Forces, in d3-force's vocabulary.
    static let repulsionStrength: CGFloat = 900
    /// Pairs further apart than this don't repel (cheap, and invisible).
    static let repulsionCutoffDistance: CGFloat = 520
    static let springLength: CGFloat = 70
    static let springStrength: CGFloat = 0.12
    static let gravityStrength: CGFloat = 0.035
    /// Fraction of velocity kept each step.
    static let velocityRetention: CGFloat = 0.6
    /// How fast the temperature approaches its target each step.
    static let temperatureDecay: Double = 0.0228
    /// Below this the layout counts as settled and the view stops its clock.
    static let settledTemperature: Double = 0.004

    var nodes: [BrainGraphNode]
    var edges: [BrainGraphEdge]
    /// d3's `alpha`: scales every force; cools towards `targetTemperature`.
    var temperature: Double
    /// Raised while a node is dragged so the neighbours follow, then 0.
    var targetTemperature: Double
    /// Pages that matched the filter (before the node cap).
    var matchingPageCount: Int

    static let empty = BrainGraphLayout(nodes: [], edges: [], temperature: 0, targetTemperature: 0, matchingPageCount: 0)

    var isSettled: Bool { temperature < Self.settledTemperature && targetTemperature == 0 }
    var wasTruncated: Bool { matchingPageCount > nodes.count }

    static func radius(forLinkCount linkCount: Int) -> CGFloat {
        min(4 + sqrt(CGFloat(linkCount)) * 2.6, 18)
    }

    // MARK: Building

    /// Nodes for the pages of the given kinds (all when `kinds` is nil),
    /// capped to the most-linked `maximumNodeCount` (the user's own page is
    /// always kept). Unresolved links and self-links are dropped; links are
    /// undirected and de-duplicated. Initial positions are a deterministic
    /// sunflower spiral with the best-connected pages at the centre.
    static func build(
        pages: [BrainPage],
        kinds: Set<BrainPageKind>? = nil,
        maximumNodeCount: Int = defaultMaximumNodeCount,
        resolver: BrainLinkResolver
    ) -> BrainGraphLayout {
        let matchingPages = pages.filter { kinds?.contains($0.kind) ?? true }
        let matchingSlugs = Set(matchingPages.map(\.slug))

        // Every undirected link among the matching pages.
        var undirectedLinks = Set<[String]>()
        for page in matchingPages {
            for target in page.outgoingLinkTargets {
                guard let targetSlug = resolver.slug(forTarget: target),
                      targetSlug != page.slug,
                      matchingSlugs.contains(targetSlug) else { continue }
                undirectedLinks.insert([page.slug, targetSlug].sorted())
            }
        }
        var linkCountBySlug: [String: Int] = [:]
        for link in undirectedLinks {
            linkCountBySlug[link[0], default: 0] += 1
            linkCountBySlug[link[1], default: 0] += 1
        }

        let pagesByImportance = matchingPages.sorted { lhs, rhs in
            if (lhs.kind == .me) != (rhs.kind == .me) { return lhs.kind == .me }
            let lhsLinkCount = linkCountBySlug[lhs.slug] ?? 0
            let rhsLinkCount = linkCountBySlug[rhs.slug] ?? 0
            if lhsLinkCount != rhsLinkCount { return lhsLinkCount > rhsLinkCount }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        let keptPages = Array(pagesByImportance.prefix(max(0, maximumNodeCount)))
        var nodeIndexBySlug: [String: Int] = [:]
        for (nodeIndex, page) in keptPages.enumerated() {
            nodeIndexBySlug[page.slug] = nodeIndex
        }

        var edges: [BrainGraphEdge] = []
        var keptLinkCountBySlug: [String: Int] = [:]
        for link in undirectedLinks.sorted(by: { $0.joined(separator: "\u{0}") < $1.joined(separator: "\u{0}") }) {
            guard let firstIndex = nodeIndexBySlug[link[0]], let secondIndex = nodeIndexBySlug[link[1]] else { continue }
            edges.append(BrainGraphEdge(sourceIndex: min(firstIndex, secondIndex), targetIndex: max(firstIndex, secondIndex)))
            keptLinkCountBySlug[link[0], default: 0] += 1
            keptLinkCountBySlug[link[1], default: 0] += 1
        }

        let goldenAngle = CGFloat.pi * (3 - sqrt(5))
        let nodes = keptPages.enumerated().map { nodeIndex, page in
            let spiralRadius = 28 * sqrt(CGFloat(nodeIndex))
            let spiralAngle = CGFloat(nodeIndex) * goldenAngle
            return BrainGraphNode(
                slug: page.slug,
                title: page.title,
                kind: page.kind,
                linkCount: keptLinkCountBySlug[page.slug] ?? 0,
                position: CGPoint(x: spiralRadius * cos(spiralAngle), y: spiralRadius * sin(spiralAngle)),
                velocity: .zero,
                isPinned: false
            )
        }

        return BrainGraphLayout(
            nodes: nodes,
            edges: edges,
            temperature: nodes.isEmpty ? 0 : 1,
            targetTemperature: 0,
            matchingPageCount: matchingPages.count
        )
    }

    /// Keeps the positions of pages that were already on screen, so adding a
    /// page or changing the filter doesn't throw the whole picture around.
    mutating func adoptPositions(from previousLayout: BrainGraphLayout) {
        var previousPositionsBySlug: [String: CGPoint] = [:]
        for previousNode in previousLayout.nodes {
            previousPositionsBySlug[previousNode.slug] = previousNode.position
        }
        var adoptedCount = 0
        for nodeIndex in nodes.indices {
            if let previousPosition = previousPositionsBySlug[nodes[nodeIndex].slug] {
                nodes[nodeIndex].position = previousPosition
                adoptedCount += 1
            }
        }
        // Mostly the same picture: a gentle nudge instead of a full re-layout.
        if !nodes.isEmpty, adoptedCount * 2 >= nodes.count {
            temperature = 0.3
        }
    }

    // MARK: Simulation

    /// One tick of the simulation.
    mutating func step() {
        guard !nodes.isEmpty else {
            temperature = 0
            return
        }
        let forceScale = CGFloat(temperature)
        var velocityChanges = [CGVector](repeating: .zero, count: nodes.count)

        // Repulsion between every pair (close enough to matter).
        let cutoffDistanceSquared = Self.repulsionCutoffDistance * Self.repulsionCutoffDistance
        for firstIndex in 0..<nodes.count {
            for secondIndex in (firstIndex + 1)..<nodes.count {
                var deltaX = nodes[firstIndex].position.x - nodes[secondIndex].position.x
                var deltaY = nodes[firstIndex].position.y - nodes[secondIndex].position.y
                var distanceSquared = deltaX * deltaX + deltaY * deltaY
                guard distanceSquared < cutoffDistanceSquared else { continue }
                if distanceSquared < 0.01 {
                    // Two nodes on the same spot: separate them deterministically.
                    deltaX = CGFloat((firstIndex % 7) + 1) * 0.1
                    deltaY = CGFloat((secondIndex % 5) + 1) * 0.1
                    distanceSquared = deltaX * deltaX + deltaY * deltaY
                }
                let pushPerUnit = Self.repulsionStrength * forceScale / max(distanceSquared, 25)
                velocityChanges[firstIndex].dx += deltaX * pushPerUnit
                velocityChanges[firstIndex].dy += deltaY * pushPerUnit
                velocityChanges[secondIndex].dx -= deltaX * pushPerUnit
                velocityChanges[secondIndex].dy -= deltaY * pushPerUnit
            }
        }

        // Springs along links.
        for edge in edges {
            let deltaX = nodes[edge.targetIndex].position.x - nodes[edge.sourceIndex].position.x
            let deltaY = nodes[edge.targetIndex].position.y - nodes[edge.sourceIndex].position.y
            let distance = max(sqrt(deltaX * deltaX + deltaY * deltaY), 0.1)
            let stretch = (distance - Self.springLength) / distance * Self.springStrength * forceScale
            velocityChanges[edge.sourceIndex].dx += deltaX * stretch * 0.5
            velocityChanges[edge.sourceIndex].dy += deltaY * stretch * 0.5
            velocityChanges[edge.targetIndex].dx -= deltaX * stretch * 0.5
            velocityChanges[edge.targetIndex].dy -= deltaY * stretch * 0.5
        }

        for nodeIndex in nodes.indices {
            if nodes[nodeIndex].isPinned {
                nodes[nodeIndex].velocity = .zero
                continue
            }
            // Gravity towards the origin keeps unlinked pages from drifting off.
            velocityChanges[nodeIndex].dx -= nodes[nodeIndex].position.x * Self.gravityStrength * forceScale
            velocityChanges[nodeIndex].dy -= nodes[nodeIndex].position.y * Self.gravityStrength * forceScale

            var velocity = nodes[nodeIndex].velocity
            velocity.dx = (velocity.dx + velocityChanges[nodeIndex].dx) * Self.velocityRetention
            velocity.dy = (velocity.dy + velocityChanges[nodeIndex].dy) * Self.velocityRetention
            nodes[nodeIndex].velocity = velocity
            nodes[nodeIndex].position.x += velocity.dx
            nodes[nodeIndex].position.y += velocity.dy
        }

        temperature += (targetTemperature - temperature) * Self.temperatureDecay
    }

    /// Wakes a settled layout (a drag, a new page).
    mutating func reheat(to newTemperature: Double = 0.3) {
        temperature = max(temperature, newTemperature)
    }

    // MARK: Queries

    /// The topmost node under a point (in layout space), with some slack for
    /// small nodes so they're still easy to hit.
    func nodeIndex(at point: CGPoint, extraHitRadius: CGFloat = 4) -> Int? {
        var closestIndex: Int?
        var closestDistance = CGFloat.greatestFiniteMagnitude
        for nodeIndex in nodes.indices.reversed() {
            let node = nodes[nodeIndex]
            let distance = hypot(node.position.x - point.x, node.position.y - point.y)
            if distance <= node.radius + extraHitRadius, distance < closestDistance {
                closestIndex = nodeIndex
                closestDistance = distance
            }
        }
        return closestIndex
    }

    func neighborIndices(of nodeIndex: Int) -> Set<Int> {
        var neighborIndices = Set<Int>()
        for edge in edges {
            if edge.sourceIndex == nodeIndex { neighborIndices.insert(edge.targetIndex) }
            if edge.targetIndex == nodeIndex { neighborIndices.insert(edge.sourceIndex) }
        }
        return neighborIndices
    }

    /// Smallest rectangle holding every node (with its radius).
    var boundingBox: CGRect {
        guard let firstNode = nodes.first else { return .zero }
        var minimumX = firstNode.position.x - firstNode.radius
        var maximumX = firstNode.position.x + firstNode.radius
        var minimumY = firstNode.position.y - firstNode.radius
        var maximumY = firstNode.position.y + firstNode.radius
        for node in nodes {
            minimumX = min(minimumX, node.position.x - node.radius)
            maximumX = max(maximumX, node.position.x + node.radius)
            minimumY = min(minimumY, node.position.y - node.radius)
            maximumY = max(maximumY, node.position.y + node.radius)
        }
        return CGRect(x: minimumX, y: minimumY, width: maximumX - minimumX, height: maximumY - minimumY)
    }

    /// Indices of the best-connected nodes, whose labels show even zoomed out.
    func mostConnectedNodeIndices(limit: Int) -> Set<Int> {
        let rankedIndices = nodes.indices
            .filter { nodes[$0].linkCount > 0 || nodes[$0].kind == .me }
            .sorted { nodes[$0].linkCount > nodes[$1].linkCount }
        return Set(rankedIndices.prefix(limit))
    }
}
