//
//  BrainGraphPage.swift
//  leanring-buddy
//
//  Brain → Graph: the brain as a force-directed map — a dot per page (coloured
//  by kind, sized by how connected it is) and a line per `[[link]]`. Hover a
//  dot to see its name, summary and neighbours; drag dots around; drag empty
//  space to pan; pinch or use the zoom buttons; click a dot to read the page.
//
//  Dots are coloured by Space by default (`BrainGraphSpaces`: clusters found
//  from the links, each a hue on a warm-to-cool spectrum, links inside a space
//  tinted to match) or by page kind. The legend lists the spaces with their
//  sizes — click one to bring it forward — over a sparkline of pages added
//  per week.
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
    /// Clusters of the current layout, recomputed only when it is rebuilt.
    private(set) var spaceAssignment = BrainGraphSpaceAssignment.empty
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
        spaceAssignment = BrainGraphSpaces.detect(in: newLayout)
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

/// What the graph's dot colours mean.
enum BrainGraphColorMode: String, CaseIterable {
    case space
    case kind

    var title: String {
        switch self {
        case .space: return "Spaces"
        case .kind: return "Kinds"
        }
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
    @AppStorage("brain.graph.colorMode") private var colorModeRawValue = BrainGraphColorMode.space.rawValue
    /// A space picked in the legend: its pages stay bright, the rest dim.
    @State private var highlightedSpaceIndex: Int?

    /// Weeks shown in the legend's sparkline.
    private static let sparklineWeekCount = 26

    private var colorMode: BrainGraphColorMode {
        BrainGraphColorMode(rawValue: colorModeRawValue) ?? .space
    }

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
                    Text("Each page becomes a dot, each [[link]] a line.")
                } actions: {
                    Button("Add to Brain") { WispWindowRouter.shared.select(.brainInbox) }
                        .buttonStyle(WispPillButtonStyle())
                        .pointerCursor()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                graphCanvas
                    .overlay(alignment: .topLeading) { controlsOverlay }
                    .overlay(alignment: .bottomLeading) { hoveredNodeCard }
                    .overlay(alignment: .bottomTrailing) { spacesLegend }
            }
        }
        .background(WispColor.windowBackground)
        .background(BrainWindowVisibilityReader { isVisible in isWindowVisible = isVisible })
        .onAppear { rebuildGraph() }
        .onChange(of: brainStore.pages) { _, _ in rebuildGraph() }
        .onChange(of: visibleKinds) { _, _ in
            highlightedSpaceIndex = nil
            rebuildGraph()
        }
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
        let spaceAssignment = simulation.spaceAssignment
        let isColoringBySpace = colorMode == .space

        // Links first, so dots sit on top. In Spaces mode a link inside one
        // coloured space is drawn in that space's hue, one path per space.
        var restingEdgesPath = Path()
        var focusedEdgesPath = Path()
        var spaceEdgesPathBySpaceIndex: [Int: Path] = [:]
        for edge in layout.edges {
            let sourcePoint = viewPoint(layout.nodes[edge.sourceIndex].position)
            let targetPoint = viewPoint(layout.nodes[edge.targetIndex].position)
            if let focusedNodeIndex, edge.sourceIndex == focusedNodeIndex || edge.targetIndex == focusedNodeIndex {
                focusedEdgesPath.move(to: sourcePoint)
                focusedEdgesPath.addLine(to: targetPoint)
            } else if isColoringBySpace,
                      let sourceSpace = spaceAssignment.space(ofNodeIndex: edge.sourceIndex),
                      sourceSpace.hue != nil,
                      spaceAssignment.spaceIndexByNodeIndex[edge.targetIndex] == sourceSpace.spaceIndex {
                spaceEdgesPathBySpaceIndex[sourceSpace.spaceIndex, default: Path()].move(to: sourcePoint)
                spaceEdgesPathBySpaceIndex[sourceSpace.spaceIndex, default: Path()].addLine(to: targetPoint)
            } else {
                restingEdgesPath.move(to: sourcePoint)
                restingEdgesPath.addLine(to: targetPoint)
            }
        }
        let isSomethingFocused = focusedNodeIndex != nil || highlightedSpaceIndex != nil
        let restingEdgeOpacity: Double = isSomethingFocused ? 0.15 : 0.45
        graphicsContext.stroke(restingEdgesPath, with: .color(WispColor.textTertiary.opacity(restingEdgeOpacity)), lineWidth: 1)
        for (spaceIndex, spaceEdgesPath) in spaceEdgesPathBySpaceIndex {
            let isHighlightedSpace = highlightedSpaceIndex == spaceIndex
            let spaceEdgeOpacity: Double = isHighlightedSpace ? 0.75 : (isSomethingFocused ? 0.12 : 0.4)
            graphicsContext.stroke(
                spaceEdgesPath,
                with: .color(Self.spaceColor(hue: spaceAssignment.spaces[spaceIndex].hue).opacity(spaceEdgeOpacity)),
                lineWidth: isHighlightedSpace ? 1.3 : 1
            )
        }
        graphicsContext.stroke(focusedEdgesPath, with: .color(WispColor.accentText.opacity(0.8)), lineWidth: 1.5)

        let showsAllLabels = zoomScale >= Self.zoomScaleShowingAllLabels
        for nodeIndex in layout.nodes.indices {
            let node = layout.nodes[nodeIndex]
            let nodeCenter = viewPoint(node.position)
            let scaledRadius = max(node.radius * min(max(zoomScale, 0.6), 1.6), 2.5)
            let isFocused = nodeIndex == focusedNodeIndex
            let isNeighborOfFocus = focusedNeighborIndices.contains(nodeIndex)
            let isOutsideHighlightedSpace = highlightedSpaceIndex != nil
                && spaceAssignment.spaceIndexByNodeIndex.indices.contains(nodeIndex)
                && spaceAssignment.spaceIndexByNodeIndex[nodeIndex] != highlightedSpaceIndex
            let isDimmed = focusedNodeIndex != nil
                ? (!isFocused && !isNeighborOfFocus)
                : isOutsideHighlightedSpace
            let nodeColor = color(forNodeIndex: nodeIndex, node: node)

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

    // MARK: - Colours

    private func color(forNodeIndex nodeIndex: Int, node: BrainGraphNode) -> Color {
        // The user's own page keeps its accent in both modes: it is the
        // centre the spaces orbit, not a member of one.
        guard colorMode == .space, node.kind != .me,
              let space = simulation.spaceAssignment.space(ofNodeIndex: nodeIndex) else {
            return BrainKindStyle.color(for: node.kind)
        }
        return Self.spaceColor(hue: space.hue)
    }

    /// A space's colour: a bright spectrum hue, or a quiet grey for Other /
    /// Unlinked so the real clusters carry the colour.
    static func spaceColor(hue: Double?) -> Color {
        guard let hue else { return WispColor.textTertiary }
        return Color(hue: hue, saturation: 0.72, brightness: 0.95)
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

            Picker("Colour by", selection: Binding(
                get: { colorMode },
                set: { newColorMode in
                    colorModeRawValue = newColorMode.rawValue
                    highlightedSpaceIndex = nil
                }
            )) {
                ForEach(BrainGraphColorMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .pointerCursor()
            .help("Colour the dots by the space they cluster into, or by page kind")

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
            .buttonStyle(WispPillButtonStyle(isProminent: false))
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

    private func hoveredNodeDetailLine(nodeIndex: Int, node: BrainGraphNode) -> String {
        var detailParts = [node.kind.displayName]
        if node.kind != .me, let space = simulation.spaceAssignment.space(ofNodeIndex: nodeIndex) {
            detailParts.append(space.hue == nil ? space.name : "in \(space.name)")
        }
        detailParts.append("\(node.linkCount) \(node.linkCount == 1 ? "link" : "links")")
        detailParts.append("click to open")
        return detailParts.joined(separator: " · ")
    }

    // MARK: - Spaces legend

    @ViewBuilder
    private var spacesLegend: some View {
        let spaces = simulation.spaceAssignment.spaces
        if colorMode == .space, !spaces.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(spaces.filter { $0.hue != nil }.count) spaces")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WispColor.textPrimary)
                    Spacer(minLength: 12)
                    if highlightedSpaceIndex != nil {
                        Button("Show all") { highlightedSpaceIndex = nil }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(WispColor.accentText)
                            .pointerCursor()
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(spaces, id: \.spaceIndex) { space in
                        spacesLegendRow(space)
                    }
                }
                pagesAddedSparkline
            }
            .padding(12)
            .frame(width: 220, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: WispRadius.medium, style: .continuous).fill(.regularMaterial))
            .overlay(
                RoundedRectangle(cornerRadius: WispRadius.medium, style: .continuous)
                    .strokeBorder(WispColor.cardSeparator, lineWidth: 0.5)
            )
            .padding(12)
        }
    }

    private func spacesLegendRow(_ space: BrainGraphSpace) -> some View {
        let isHighlighted = highlightedSpaceIndex == space.spaceIndex
        let isDimmed = highlightedSpaceIndex != nil && !isHighlighted
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                highlightedSpaceIndex = isHighlighted ? nil : space.spaceIndex
            }
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(Self.spaceColor(hue: space.hue))
                    .frame(width: 8, height: 8)
                Text(space.name)
                    .font(.caption.weight(isHighlighted ? .semibold : .regular))
                    .foregroundStyle(WispColor.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("\(space.memberCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(WispColor.textSecondary)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHighlighted ? WispColor.textPrimary.opacity(0.08) : Color.clear)
            )
            .opacity(isDimmed ? 0.45 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(space.hue == nil ? "Show these pages" : "Show the \(space.name) space")
    }

    /// Pages created per week over the last half year — how fast the brain grows.
    private var pagesAddedSparkline: some View {
        let creationDates = brainStore.pages.compactMap(\.createdDate)
        let weeklyCounts = BrainGraphSpaces.weeklyCounts(of: creationDates, endingAt: Date(), weekCount: Self.sparklineWeekCount)
        let highestWeeklyCount = max(weeklyCounts.max() ?? 0, 1)
        let pagesAddedThisPeriod = weeklyCounts.reduce(0, +)
        return VStack(alignment: .leading, spacing: 4) {
            Canvas { graphicsContext, size in
                guard weeklyCounts.count > 1 else { return }
                var sparklinePath = Path()
                for (weekOffset, weekCount) in weeklyCounts.enumerated() {
                    let pointX = size.width * CGFloat(weekOffset) / CGFloat(weeklyCounts.count - 1)
                    let pointY = size.height - size.height * CGFloat(weekCount) / CGFloat(highestWeeklyCount)
                    if weekOffset == 0 {
                        sparklinePath.move(to: CGPoint(x: pointX, y: pointY))
                    } else {
                        sparklinePath.addLine(to: CGPoint(x: pointX, y: pointY))
                    }
                }
                let spectrumGradient = Gradient(colors: stride(from: 0.0, through: BrainGraphSpaces.spectrumEndHue, by: 0.1).map {
                    Color(hue: $0, saturation: 0.72, brightness: 0.95)
                })
                graphicsContext.stroke(
                    sparklinePath,
                    with: .linearGradient(spectrumGradient, startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                )
            }
            .frame(height: 26)
            Text("\(pagesAddedThisPeriod) \(pagesAddedThisPeriod == 1 ? "page" : "pages") added in 6 months")
                .font(.caption2)
                .foregroundStyle(WispColor.textTertiary)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(pagesAddedThisPeriod) pages added in the last six months")
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
                Text(hoveredNodeDetailLine(nodeIndex: hoveredNodeIndex, node: hoveredNode))
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
