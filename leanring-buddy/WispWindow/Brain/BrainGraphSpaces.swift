//
//  BrainGraphSpaces.swift
//  leanring-buddy
//
//  "Spaces" for Brain → Graph: the clusters the brain's pages fall into on
//  their own, found from the `[[link]]` graph alone — no model call, so they
//  are instant, deterministic and the same on every open.
//
//  Clusters come from greedy modularity moves (the first phase of Louvain):
//  every page starts alone, then each page in turn moves to the neighbouring
//  cluster that raises modularity most — links inside clusters versus what
//  chance would give — until no move helps. Unlike plain label propagation it
//  keeps two dense groups apart when a single link bridges them. The user's
//  own page is left out, because it links to nearly everything and would pull
//  the whole brain into one space.
//
//  A space is named after its best-connected page and gets a hue from a
//  warm-to-cool spectrum by size (biggest warmest). Past `maximumSpaceCount`
//  the smaller clusters (and any page left alone despite having links) are
//  folded into "Other"; pages with no links among the shown pages are
//  "Unlinked". Both are drawn grey.
//
//  Also the weekly counts behind the timeline sparkline.
//
//  Foundation + CoreGraphics only, so `Tests/BrainUI` compiles it standalone.
//

import CoreGraphics
import Foundation

nonisolated struct BrainGraphSpace: Equatable, Sendable {
    /// Position in `BrainGraphSpaceAssignment.spaces`.
    var spaceIndex: Int
    var name: String
    /// The page the space is named after (nil for Other / Unlinked).
    var hubSlug: String?
    var memberNodeIndices: [Int]
    /// 0…1 hue for a real cluster; nil for the grey Other / Unlinked buckets.
    var hue: Double?

    var memberCount: Int { memberNodeIndices.count }
}

nonisolated struct BrainGraphSpaceAssignment: Equatable, Sendable {
    var spaces: [BrainGraphSpace]
    /// For each node, its index in `spaces`, or nil (the user's own page).
    var spaceIndexByNodeIndex: [Int?]

    static let empty = BrainGraphSpaceAssignment(spaces: [], spaceIndexByNodeIndex: [])

    func space(ofNodeIndex nodeIndex: Int) -> BrainGraphSpace? {
        guard spaceIndexByNodeIndex.indices.contains(nodeIndex),
              let spaceIndex = spaceIndexByNodeIndex[nodeIndex] else { return nil }
        return spaces[spaceIndex]
    }
}

enum BrainGraphSpaces {
    /// Named clusters shown; anything smaller joins "Other". Eleven keeps the
    /// legend readable and the hues far enough apart to tell apart.
    static let defaultMaximumSpaceCount = 11
    /// The local moves settle in a handful of rounds; this is a safety cap.
    static let maximumMoveRounds = 30
    /// Spectrum used for the clusters: red (0) through to violet (~0.8). The
    /// last bit of the wheel (magenta back to red) is skipped so the first and
    /// last space don't look alike.
    static let spectrumEndHue = 0.8

    static let otherSpaceName = "Other"
    static let unlinkedSpaceName = "Unlinked"

    static func detect(
        in layout: BrainGraphLayout,
        maximumSpaceCount: Int = defaultMaximumSpaceCount
    ) -> BrainGraphSpaceAssignment {
        let nodeCount = layout.nodes.count
        guard nodeCount > 0 else { return .empty }

        let excludedNodeIndices = Set(layout.nodes.indices.filter { layout.nodes[$0].kind == .me })

        var neighborIndicesByNode = [[Int]](repeating: [], count: nodeCount)
        for edge in layout.edges {
            guard !excludedNodeIndices.contains(edge.sourceIndex), !excludedNodeIndices.contains(edge.targetIndex) else { continue }
            neighborIndicesByNode[edge.sourceIndex].append(edge.targetIndex)
            neighborIndicesByNode[edge.targetIndex].append(edge.sourceIndex)
        }

        // Greedy modularity moves, in a fixed node order so the result never
        // depends on dictionary ordering.
        let degreeByNode = neighborIndicesByNode.map(\.count)
        let doubledEdgeCount = Double(degreeByNode.reduce(0, +))
        var clusterByNode = Array(0..<nodeCount)
        var totalDegreeByCluster = degreeByNode
        if doubledEdgeCount > 0 {
            for _ in 0..<maximumMoveRounds {
                var didMoveAnyNode = false
                for nodeIndex in 0..<nodeCount where degreeByNode[nodeIndex] > 0 {
                    let nodeDegree = Double(degreeByNode[nodeIndex])
                    let currentCluster = clusterByNode[nodeIndex]
                    // Take the node out, then see where it fits best.
                    totalDegreeByCluster[currentCluster] -= degreeByNode[nodeIndex]
                    var linksIntoCluster: [Int: Int] = [:]
                    for neighborIndex in neighborIndicesByNode[nodeIndex] {
                        linksIntoCluster[clusterByNode[neighborIndex], default: 0] += 1
                    }
                    var bestCluster = currentCluster
                    var bestGain = Double(linksIntoCluster[currentCluster] ?? 0)
                        - Double(totalDegreeByCluster[currentCluster]) * nodeDegree / doubledEdgeCount
                    for candidateCluster in linksIntoCluster.keys.sorted() where candidateCluster != currentCluster {
                        let gain = Double(linksIntoCluster[candidateCluster] ?? 0)
                            - Double(totalDegreeByCluster[candidateCluster]) * nodeDegree / doubledEdgeCount
                        // Strictly better only, so ties keep the node where it is.
                        if gain > bestGain + 1e-9 {
                            bestGain = gain
                            bestCluster = candidateCluster
                        }
                    }
                    totalDegreeByCluster[bestCluster] += degreeByNode[nodeIndex]
                    if bestCluster != currentCluster {
                        clusterByNode[nodeIndex] = bestCluster
                        didMoveAnyNode = true
                    }
                }
                if !didMoveAnyNode { break }
            }
        }

        // Group into clusters of two or more pages. A page with no links is
        // Unlinked; one left alone despite its links goes to Other.
        var memberIndicesByCluster: [Int: [Int]] = [:]
        var unlinkedNodeIndices: [Int] = []
        var loneLinkedNodeIndices: [Int] = []
        for nodeIndex in 0..<nodeCount where !excludedNodeIndices.contains(nodeIndex) {
            if degreeByNode[nodeIndex] == 0 {
                unlinkedNodeIndices.append(nodeIndex)
            } else {
                memberIndicesByCluster[clusterByNode[nodeIndex], default: []].append(nodeIndex)
            }
        }
        var clusters: [[Int]] = []
        for (_, memberIndices) in memberIndicesByCluster {
            if memberIndices.count >= 2 {
                clusters.append(memberIndices.sorted())
            } else {
                loneLinkedNodeIndices.append(contentsOf: memberIndices)
            }
        }

        func hubIndex(of memberIndices: [Int]) -> Int {
            memberIndices.min { lhs, rhs in
                let lhsNode = layout.nodes[lhs]
                let rhsNode = layout.nodes[rhs]
                if lhsNode.linkCount != rhsNode.linkCount { return lhsNode.linkCount > rhsNode.linkCount }
                return lhsNode.title.localizedCaseInsensitiveCompare(rhsNode.title) == .orderedAscending
            } ?? memberIndices[0]
        }

        // Biggest first; equal sizes by hub title, so the order is stable.
        clusters.sort { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return layout.nodes[hubIndex(of: lhs)].title.localizedCaseInsensitiveCompare(layout.nodes[hubIndex(of: rhs)].title) == .orderedAscending
        }

        let namedClusterLimit = max(0, maximumSpaceCount)
        let namedClusters = Array(clusters.prefix(namedClusterLimit))
        let foldedNodeIndices = clusters.dropFirst(namedClusterLimit).flatMap { $0 } + loneLinkedNodeIndices

        var spaces: [BrainGraphSpace] = []
        for (clusterRank, memberIndices) in namedClusters.enumerated() {
            let hubNodeIndex = hubIndex(of: memberIndices)
            let hue = namedClusters.count <= 1
                ? 0.0
                : spectrumEndHue * Double(clusterRank) / Double(namedClusters.count - 1)
            spaces.append(BrainGraphSpace(
                spaceIndex: spaces.count,
                name: layout.nodes[hubNodeIndex].title,
                hubSlug: layout.nodes[hubNodeIndex].slug,
                memberNodeIndices: memberIndices,
                hue: hue
            ))
        }
        if !foldedNodeIndices.isEmpty {
            spaces.append(BrainGraphSpace(spaceIndex: spaces.count, name: otherSpaceName, hubSlug: nil, memberNodeIndices: foldedNodeIndices.sorted(), hue: nil))
        }
        if !unlinkedNodeIndices.isEmpty {
            spaces.append(BrainGraphSpace(spaceIndex: spaces.count, name: unlinkedSpaceName, hubSlug: nil, memberNodeIndices: unlinkedNodeIndices.sorted(), hue: nil))
        }

        var spaceIndexByNodeIndex = [Int?](repeating: nil, count: nodeCount)
        for space in spaces {
            for memberNodeIndex in space.memberNodeIndices {
                spaceIndexByNodeIndex[memberNodeIndex] = space.spaceIndex
            }
        }
        return BrainGraphSpaceAssignment(spaces: spaces, spaceIndexByNodeIndex: spaceIndexByNodeIndex)
    }

    // MARK: - Timeline

    /// How many of `dates` fall in each of the `weekCount` weeks ending with
    /// the week holding `endDate`, oldest first. Dates outside are ignored.
    static func weeklyCounts(of dates: [Date], endingAt endDate: Date, weekCount: Int, calendar: Calendar = .current) -> [Int] {
        guard weekCount > 0,
              let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: endDate)?.start,
              let firstWeekStart = calendar.date(byAdding: .weekOfYear, value: -(weekCount - 1), to: currentWeekStart) else {
            return []
        }
        var counts = [Int](repeating: 0, count: weekCount)
        for date in dates {
            guard date >= firstWeekStart,
                  let weekStart = calendar.dateInterval(of: .weekOfYear, for: date)?.start,
                  let weekOffset = calendar.dateComponents([.weekOfYear], from: firstWeekStart, to: weekStart).weekOfYear,
                  counts.indices.contains(weekOffset) else { continue }
            counts[weekOffset] += 1
        }
        return counts
    }
}
