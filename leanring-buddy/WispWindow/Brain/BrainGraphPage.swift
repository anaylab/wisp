//
//  BrainGraphPage.swift
//  leanring-buddy
//
//  Brain → Graph: the brain as a force-directed map — a dot per page (coloured
//  by kind, sized by how connected it is) and a line per `[[link]]`. Hover a
//  dot to see its name, summary and neighbours; drag dots around; drag empty
//  space to pan; pinch or use the zoom buttons; click a dot to read the page.
//
//  The physics lives in `BrainGraphLayout` (pure). This view runs it from a
//  `TimelineView` clock that pauses as soon as the layout settles, while the
//  window is hidden, and whenever the page is off screen (the view is only
//  built while Graph is the selected page) — an idle graph costs nothing.
//

import AppKit
import Combine
import SwiftUI

/// Holds the running layout outside SwiftUI's state so a tick can advance it
/// without invalidating the view; only "has it settled" is published, since
/// that's what starts and stops the clock.
@MainActor
final class BrainGraphSimulation: ObservableObject {
    private(set) var layout = BrainGraphLayout.empty
    @Published private(set) var isSettled = true
    /// Labels drawn even when zoomed out.
    private(set) var alwaysLabelledNodeIndices = Set<Int>()
    /// Bumped whenever nodes move outside a tick (a drag), to force a redraw.
    @Published private(set) var manualRedrawCounter = 0

    private var lastBuildSignature = ""

    /// Most simulation steps per displayed frame: settles faster than one step
    /// per frame without making dragging feel floaty.
    private let stepsPerFrame = 2

    func rebuild(pages: [BrainPage], kinds: Set<BrainPageKind>) {
        let buildSignature = Self.signature(pages: pages, kinds: kinds)
        guard buildSignature != lastBuildSignature else { return }
        lastBuildSignature = buildSignature

        var newLayout = BrainGraphLayout.build(
            pages: pages,
            kinds: kinds.count == BrainPageKind.allCases.count ? nil : kinds,
            resolver: BrainLinkResolver(pages: pages)
        )
        newLayout.adoptPositions(from: layout)
        layout = newLayout
        alwaysLabelledNodeIndices = newLayout.mostConnectedNodeIndices(limit: 14)
        setSettled(layout.isSettled)
    }

    /// Advances the layout for one displayed frame.
    func advanceFrame() {
        guard !layout.isSettled else { return }
        for _ in 0..<stepsPerFrame {
            layout.step()
        }
        if layout.isSettled {
            // Publishing mid-render is not allowed; the clock stops next turn.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.setSettled(self.layout.isSettled)
            }
        }
    }

    func beginDragging(nodeIndex: Int) {
        guard layout.nodes.indices.contains(nodeIndex) else { return }
        layout.nodes[nodeIndex].isPinned = true
        layout.targetTemperature = 0.25
        layout.reheat(to: 0.25)
        setSettled(false)
    }

    func moveDraggedNode(nodeIndex: Int, to layoutPoint: CGPoint) {
        guard layout.nodes.indices.contains(nodeIndex) else { return }
        layout.nodes[nodeIndex].position = layoutPoint
        manualRedrawCounter &+= 1
    }

    func endDragging(nodeIndex: Int) {
        if layout.nodes.indices.contains(nodeIndex) {
            layout.nodes[nodeIndex].isPinned = false
        }
        layout.targetTemperature = 0
    }

    /// Shakes the layout up again ("Re-layout").
    func reheat() {
        layout.reheat(to: 0.8)
        setSettled(false)
    }

    private func setSettled(_ newValue: Bool) {
        if isSettled != newValue { isSettled = newValue }
    }

    /// Pages, their links and the filter — the layout is rebuilt only when
    /// one of these changed, not on every unrelated store update.
    private static func signature(pages: [BrainPage], kinds: Set<BrainPageKind>) -> String {
        var hasher = Hasher()
        for page in pages {
            hasher.combine(page.slug)
            hasher.combine(page.title)
            hasher.combine(page.kind)
            hasher.combine(page.outgoingLinkTargets)
        }
        let kindList = kinds.map(\.rawValue).sorted().joined(separator: ",")
        return "\(pages.count)-\(hasher.finalize())-\(kindList)"
    }
}

struct BrainGraphPage: View {
    @ObservedObject private var brainStore = BrainStore.shared
    @StateObject private var simulation = BrainGraphSimulation()

    @State private var visibleKinds: Set<BrainPageKind> = Set(BrainPageKind.allCases)
    @State private var zoomScale: CGFloat = 1
    @State private var zoomScaleAtGestureStart: CGFloat?
    @State private var panOffset: CGSize = .zero
    @State private var panOffsetAtDragStart: CGSize?
    @State private var draggedNodeIndex: Int?
    @State private var hoveredNodeIndex: Int?
    @State private var isWindowVisible = true
    @State private var hasFittedToSettledLayout = false
    @State private var canvasSize: CGSize = .zero

    private static let minimumZoomScale: CGFloat = 0.15
    private static let maximumZoomScale: CGFloat = 4
    /// Past this zoom every node is labelled.
    private static let zoomScaleShowingAllLabels: CGFloat = 1.5
    /// A press that moves less than this is a click, not a drag.
    private static let clickMovementTolerance: CGFloat = 4

    var body: some View {
        Group {
            if brainStore.pages.isEmpty {
                ContentUnavailableView {
                    Label("Nothing to map yet", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("As Wisp fills your brain, each page becomes a dot here and each [[link]] a line between them.")
                } actions: {
                    Button("Add to Brain") { WispWindowRouter.shared.select(.brainInbox) }
                        .buttonStyle(.borderedProminent)
                        .pointerCursor()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                graphCanvas
                    .overlay(alignment: .topLeading) { controlsOverlay }
                    .overlay(alignment: .bottomLeading) { hoveredNodeCard }
            }
        }
        .background(WispColor.windowBackground)
        .background(BrainWindowVisibilityReader { isVisible in isWindowVisible = isVisible })
        .onAppear { rebuildGraph() }
        .onChange(of: brainStore.pages) { _, _ in rebuildGraph() }
        .onChange(of: visibleKinds) { _, _ in rebuildGraph() }
        .onChange(of: simulation.isSettled) { _, isNowSettled in
            // Frame the picture once, the first time it comes to rest.
            if isNowSettled && !hasFittedToSettledLayout {
                hasFittedToSettledLayout = true
                withAnimation(.easeInOut(duration: 0.35)) { fitGraphToView() }
            }
        }
    }

    private func rebuildGraph() {
        simulation.rebuild(pages: brainStore.pages, kinds: visibleKinds)
    }

    // MARK: - Canvas

    private var graphCanvas: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: simulation.isSettled || !isWindowVisible)) { timelineContext in
                let _ = timelineContext.date
                let _ = simulation.manualRedrawCounter
                let _ = simulation.advanceFrame()
                Canvas { graphicsContext, size in
                    drawGraph(in: &graphicsContext, size: size)
                }
            }
            .contentShape(Rectangle())
            .gesture(nodeDragOrPanGesture)
            .simultaneousGesture(pinchZoomGesture)
            .onContinuousHover { hoverPhase in
                switch hoverPhase {
                case .active(let hoverLocation):
                    let nodeUnderPointer = simulation.layout.nodeIndex(at: layoutPoint(fromViewPoint: hoverLocation))
                    if nodeUnderPointer != hoveredNodeIndex { hoveredNodeIndex = nodeUnderPointer }
                    // A dot is clickable, empty space is draggable.
                    (nodeUnderPointer == nil ? NSCursor.openHand : NSCursor.pointingHand).set()
                case .ended:
                    hoveredNodeIndex = nil
                    NSCursor.arrow.set()
                }
            }
            .onAppear { canvasSize = geometry.size }
            .onChange(of: geometry.size) { _, newSize in canvasSize = newSize }
        }
    }

    private func drawGraph(in graphicsContext: inout GraphicsContext, size: CGSize) {
        let layout = simulation.layout
        guard !layout.nodes.isEmpty else { return }
        let viewCenter = CGPoint(x: size.width / 2 + panOffset.width, y: size.height / 2 + panOffset.height)

        func viewPoint(_ layoutPosition: CGPoint) -> CGPoint {
            CGPoint(x: viewCenter.x + layoutPosition.x * zoomScale, y: viewCenter.y + layoutPosition.y * zoomScale)
        }

        let focusedNodeIndex = draggedNodeIndex ?? hoveredNodeIndex
        let focusedNeighborIndices = focusedNodeIndex.map { layout.neighborIndices(of: $0) } ?? []

        // Links first, so dots sit on top.
        var restingEdgesPath = Path()
        var focusedEdgesPath = Path()
        for edge in layout.edges {
            let sourcePoint = viewPoint(layout.nodes[edge.sourceIndex].position)
            let targetPoint = viewPoint(layout.nodes[edge.targetIndex].position)
            if let focusedNodeIndex, edge.sourceIndex == focusedNodeIndex || edge.targetIndex == focusedNodeIndex {
                focusedEdgesPath.move(to: sourcePoint)
                focusedEdgesPath.addLine(to: targetPoint)
            } else {
                restingEdgesPath.move(to: sourcePoint)
                restingEdgesPath.addLine(to: targetPoint)
            }
        }
        let restingEdgeOpacity: Double = focusedNodeIndex == nil ? 0.45 : 0.15
        graphicsContext.stroke(restingEdgesPath, with: .color(WispColor.textTertiary.opacity(restingEdgeOpacity)), lineWidth: 1)
        graphicsContext.stroke(focusedEdgesPath, with: .color(WispColor.accentText.opacity(0.8)), lineWidth: 1.5)

        let showsAllLabels = zoomScale >= Self.zoomScaleShowingAllLabels
        for nodeIndex in layout.nodes.indices {
            let node = layout.nodes[nodeIndex]
            let nodeCenter = viewPoint(node.position)
            let scaledRadius = max(node.radius * min(max(zoomScale, 0.6), 1.6), 2.5)
            let isFocused = nodeIndex == focusedNodeIndex
            let isNeighborOfFocus = focusedNeighborIndices.contains(nodeIndex)
            let isDimmed = focusedNodeIndex != nil && !isFocused && !isNeighborOfFocus
            let nodeColor = BrainKindStyle.color(for: node.kind)

            let nodeRect = CGRect(
                x: nodeCenter.x - scaledRadius, y: nodeCenter.y - scaledRadius,
                width: scaledRadius * 2, height: scaledRadius * 2
            )
            graphicsContext.fill(Path(ellipseIn: nodeRect), with: .color(nodeColor.opacity(isDimmed ? 0.25 : 0.95)))
            if node.kind == .me || isFocused {
                graphicsContext.stroke(
                    Path(ellipseIn: nodeRect.insetBy(dx: -3, dy: -3)),
                    with: .color(nodeColor.opacity(isDimmed ? 0.3 : 0.9)),
                    lineWidth: 1.5
                )
            }

            let showsLabel = isFocused || isNeighborOfFocus
                || (focusedNodeIndex == nil && (showsAllLabels || (zoomScale >= 0.6 && simulation.alwaysLabelledNodeIndices.contains(nodeIndex))))
            if showsLabel {
                let label = Text(node.title)
                    .font(.system(size: isFocused ? 12 : 10.5, weight: isFocused ? .semibold : .regular))
                    .foregroundStyle(isFocused ? WispColor.textPrimary : WispColor.textSecondary)
                graphicsContext.draw(label, at: CGPoint(x: nodeCenter.x, y: nodeCenter.y + scaledRadius + 3), anchor: .top)
            }
        }
    }

    // MARK: - Coordinates

    private func layoutPoint(fromViewPoint viewPoint: CGPoint) -> CGPoint {
        let viewCenter = CGPoint(x: canvasSize.width / 2 + panOffset.width, y: canvasSize.height / 2 + panOffset.height)
        return CGPoint(x: (viewPoint.x - viewCenter.x) / zoomScale, y: (viewPoint.y - viewCenter.y) / zoomScale)
    }

    private func fitGraphToView() {
        let boundingBox = simulation.layout.boundingBox
        guard boundingBox.width > 0, boundingBox.height > 0, canvasSize.width > 0, canvasSize.height > 0 else { return }
        // Leave room for the labels and the controls overlay.
        let paddedWidth = boundingBox.width + 80
        let paddedHeight = boundingBox.height + 120
        let fittedZoomScale = min(canvasSize.width / paddedWidth, canvasSize.height / paddedHeight)
        zoomScale = min(max(fittedZoomScale, Self.minimumZoomScale), 1.6)
        panOffset = CGSize(width: -boundingBox.midX * zoomScale, height: -boundingBox.midY * zoomScale)
    }

    private func zoom(by factor: CGFloat) {
        withAnimation(.easeOut(duration: 0.2)) {
            let newZoomScale = min(max(zoomScale * factor, Self.minimumZoomScale), Self.maximumZoomScale)
            // Keep the middle of the view where it is.
            panOffset = CGSize(
                width: panOffset.width * newZoomScale / zoomScale,
                height: panOffset.height * newZoomScale / zoomScale
            )
            zoomScale = newZoomScale
        }
    }

    // MARK: - Gestures

    private var nodeDragOrPanGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { dragValue in
                if draggedNodeIndex == nil && panOffsetAtDragStart == nil {
                    // The press decides: on a dot moves the dot, elsewhere pans.
                    if let pressedNodeIndex = simulation.layout.nodeIndex(at: layoutPoint(fromViewPoint: dragValue.startLocation)) {
                        draggedNodeIndex = pressedNodeIndex
                        simulation.beginDragging(nodeIndex: pressedNodeIndex)
                    } else {
                        panOffsetAtDragStart = panOffset
                        NSCursor.closedHand.set()
                    }
                }
                let dragDistance = hypot(dragValue.translation.width, dragValue.translation.height)
                if let draggedNodeIndex {
                    guard dragDistance >= Self.clickMovementTolerance else { return }
                    simulation.moveDraggedNode(nodeIndex: draggedNodeIndex, to: layoutPoint(fromViewPoint: dragValue.location))
                } else if let panOffsetAtDragStart {
                    panOffset = CGSize(
                        width: panOffsetAtDragStart.width + dragValue.translation.width,
                        height: panOffsetAtDragStart.height + dragValue.translation.height
                    )
                }
            }
            .onEnded { dragValue in
                let dragDistance = hypot(dragValue.translation.width, dragValue.translation.height)
                if let releasedNodeIndex = draggedNodeIndex {
                    simulation.endDragging(nodeIndex: releasedNodeIndex)
                    if dragDistance < Self.clickMovementTolerance,
                       simulation.layout.nodes.indices.contains(releasedNodeIndex) {
                        BrainNavigator.shared.show(slug: simulation.layout.nodes[releasedNodeIndex].slug)
                        WispWindowRouter.shared.select(.brainPages)
                    }
                }
                draggedNodeIndex = nil
                panOffsetAtDragStart = nil
            }
    }

    private var pinchZoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { magnifyValue in
                let startZoomScale = zoomScaleAtGestureStart ?? zoomScale
                zoomScaleAtGestureStart = startZoomScale
                let newZoomScale = min(max(startZoomScale * magnifyValue.magnification, Self.minimumZoomScale), Self.maximumZoomScale)
                panOffset = CGSize(
                    width: panOffset.width * newZoomScale / zoomScale,
                    height: panOffset.height * newZoomScale / zoomScale
                )
                zoomScale = newZoomScale
            }
            .onEnded { _ in zoomScaleAtGestureStart = nil }
    }

    // MARK: - Overlays

    private var controlsOverlay: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Show All Kinds") { visibleKinds = Set(BrainPageKind.allCases) }
                Divider()
                ForEach(BrainPageKind.allCases, id: \.self) { kind in
                    Toggle(isOn: Binding(
                        get: { visibleKinds.contains(kind) },
                        set: { isVisible in
                            if isVisible { visibleKinds.insert(kind) } else { visibleKinds.remove(kind) }
                        }
                    )) {
                        Label(kind.pluralDisplayName, systemImage: kind.symbolName)
                    }
                }
            } label: {
                Label(
                    visibleKinds.count == BrainPageKind.allCases.count ? "All kinds" : "\(visibleKinds.count) kinds",
                    systemImage: "line.3.horizontal.decrease.circle"
                )
            }
            .fixedSize()
            .pointerCursor()
            .help("Choose which kinds of page to show")

            ControlGroup {
                Button { zoom(by: 1 / 1.3) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom out")
                Button { withAnimation(.easeInOut(duration: 0.3)) { fitGraphToView() } } label: {
                    Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
                }
                .help("Fit everything in view")
                Button { zoom(by: 1.3) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom in")
            }
            .fixedSize()
            .pointerCursor()

            Button {
                hasFittedToSettledLayout = false
                simulation.reheat()
            } label: {
                Image(systemName: "wind")
            }
            .buttonStyle(.bordered)
            .pointerCursor()
            .help("Shake the layout up and let it settle again")

            Spacer(minLength: 8)

            Text(graphSummary)
                .font(.caption)
                .foregroundStyle(WispColor.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(.regularMaterial))
        }
        .padding(12)
    }

    private var graphSummary: String {
        let layout = simulation.layout
        let pageWord = layout.nodes.count == 1 ? "page" : "pages"
        let linkWord = layout.edges.count == 1 ? "link" : "links"
        var summary = "\(layout.nodes.count) \(pageWord) · \(layout.edges.count) \(linkWord)"
        if layout.wasTruncated {
            summary += " · most connected \(layout.nodes.count) of \(layout.matchingPageCount)"
        }
        return summary
    }

    @ViewBuilder
    private var hoveredNodeCard: some View {
        if let hoveredNodeIndex, simulation.layout.nodes.indices.contains(hoveredNodeIndex) {
            let hoveredNode = simulation.layout.nodes[hoveredNodeIndex]
            let hoveredPage = brainStore.pages.first { $0.slug == hoveredNode.slug }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: hoveredNode.kind.symbolName)
                        .foregroundStyle(BrainKindStyle.color(for: hoveredNode.kind))
                    Text(hoveredNode.title)
                        .font(.headline)
                }
                if let summary = hoveredPage?.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(WispColor.textSecondary)
                        .lineLimit(3)
                }
                Text("\(hoveredNode.kind.displayName) · \(hoveredNode.linkCount) \(hoveredNode.linkCount == 1 ? "link" : "links") · click to open")
                    .font(.caption)
                    .foregroundStyle(WispColor.textTertiary)
            }
            .padding(12)
            .frame(maxWidth: 320, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: WispRadius.medium, style: .continuous).fill(.regularMaterial))
            .overlay(
                RoundedRectangle(cornerRadius: WispRadius.medium, style: .continuous)
                    .strokeBorder(WispColor.cardSeparator, lineWidth: 0.5)
            )
            .padding(12)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}
