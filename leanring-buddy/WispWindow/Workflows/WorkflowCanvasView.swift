//
//  WorkflowCanvasView.swift
//  leanring-buddy
//
//  The workflow canvas, after OpenBot's: a dotted grid you pan and zoom, nodes you drag, ports you
//  drag a connection out of, a toolbar at the bottom. The geometry (grid, curves, snapping, zoom
//  limits) is the tested `Workflow.swift`; this file draws it and turns gestures into edits.
//

import AppKit
import SwiftUI

private let canvasSpace = "workflow-canvas"

struct WorkflowCanvasView: View {
    @ObservedObject var model: WorkflowEditorModel

    @FocusState private var isCanvasFocused: Bool
    @State private var panOrigin: WorkflowCamera?
    @State private var magnifyOrigin: Double?
    @State private var clickWasDrag = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                backgroundLayer
                edgeLayer.allowsHitTesting(false)
                nodeLayer
                boxSelectionLayer.allowsHitTesting(false)

                if model.graph.nodes.isEmpty { emptyState }
                if let notice = model.notice { noticeChip(notice) }

                WorkflowToolbar(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 16)
                WorkflowZoomControl(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(16)
            }
            .coordinateSpace(name: canvasSpace)
            .clipped()
            .onAppear { model.viewSizeChanged(to: geometry.size) }
            .onChange(of: geometry.size) { _, newSize in model.viewSizeChanged(to: newSize) }
        }
        .background(WorkflowScrollMonitor { dx, dy, location, modifiers in handleScroll(dx: dx, dy: dy, location: location, modifiers: modifiers) })
        .focusable()
        .focused($isCanvasFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .simultaneousGesture(magnifyGesture)
        .contextMenu { addMenuItems(at: nil) }
        .animation(WispMotion.quick, value: model.notice)
    }

    // MARK: Layers

    /// The dotted grid, and the gestures for the empty canvas: pan with the pan tool, box select
    /// with the select tool, place a note or text, click an edge or the void.
    private var backgroundLayer: some View {
        ZStack {
            WispColor.background
            Canvas { context, size in
                let grid = WorkflowDotGrid.make(for: model.camera)
                guard grid.step > 4 else { return }
                // One path and one fill per opacity. Resolving the theme colour is slow (a dynamic
                // colour is rebuilt from hex on every use), so it is resolved once, never per dot.
                var majorDots = Path()
                var minorDots = Path()
                let far = grid.quarter * 3
                var y = grid.originY - grid.step
                while y < size.height + grid.step {
                    var x = grid.originX - grid.step
                    while x < size.width + grid.step {
                        majorDots.addRect(CGRect(x: x + grid.quarter - 0.5, y: y + grid.quarter - 0.5, width: 1, height: 1))
                        if grid.minorOpacity > 0 {
                            minorDots.addRect(CGRect(x: x + far - 0.5, y: y + grid.quarter - 0.5, width: 1, height: 1))
                            minorDots.addRect(CGRect(x: x + grid.quarter - 0.5, y: y + far - 0.5, width: 1, height: 1))
                            minorDots.addRect(CGRect(x: x + far - 0.5, y: y + far - 0.5, width: 1, height: 1))
                        }
                        x += grid.step
                    }
                    y += grid.step
                }
                let dotColor = Color(WispColor.textTertiary.resolve(in: context.environment))
                context.fill(majorDots, with: .color(dotColor.opacity(0.55)))
                if grid.minorOpacity > 0 {
                    context.fill(minorDots, with: .color(dotColor.opacity(0.55 * grid.minorOpacity)))
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(backgroundDrag)
    }

    private var backgroundDrag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(canvasSpace))
            .onChanged { value in
                isCanvasFocused = true
                let moved = hypot(value.translation.width, value.translation.height)
                if moved > WorkflowLayout.dragThreshold { clickWasDrag = true }
                guard clickWasDrag else { return }
                if model.tool == .pan {
                    if panOrigin == nil { panOrigin = model.camera }
                    if let origin = panOrigin {
                        model.camera = origin.panned(byScreenDx: value.translation.width, dy: value.translation.height)
                    }
                } else if model.tool == .select {
                    let start = model.camera.worldPoint(WorkflowPoint(x: value.startLocation.x, y: value.startLocation.y))
                    let end = model.camera.worldPoint(WorkflowPoint(x: value.location.x, y: value.location.y))
                    let rect = WorkflowRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
                    model.boxSelection = rect
                    model.selection = WorkflowEditing.nodes(in: rect, of: model.graph)
                    model.selectedEdgeID = nil
                }
            }
            .onEnded { value in
                defer { clickWasDrag = false; panOrigin = nil; model.boxSelection = nil }
                guard !clickWasDrag else { return }
                clicked(at: WorkflowPoint(x: value.location.x, y: value.location.y))
            }
    }

    /// A click on the empty canvas: place a note or text, else pick an edge, else clear.
    private func clicked(at screen: WorkflowPoint) {
        let world = model.camera.worldPoint(screen)
        switch model.tool {
        case .note, .text:
            let kind: WorkflowNodeKind = model.tool == .note ? .note : .text
            let size = WorkflowLayout.defaultSize(of: kind)
            model.addNode(kind, at: WorkflowPoint(x: world.x - size.width / 2, y: world.y - size.height / 2))
            model.tool = .select
        case .select, .pan:
            if let edgeID = nearestEdge(to: world) {
                model.selectedEdgeID = edgeID
                model.selection = []
            } else {
                model.clearSelection()
            }
        }
    }

    // MARK: Edges

    private func curve(for edge: WorkflowEdge) -> (start: WorkflowPoint, control1: WorkflowPoint, control2: WorkflowPoint, end: WorkflowPoint)? {
        guard let from = model.node(edge.from), let to = model.node(edge.to) else { return nil }
        return WorkflowLayout.edgeCurve(
            from: WorkflowLayout.portPoint(of: from, isOutput: true, branch: edge.branch),
            to: WorkflowLayout.portPoint(of: to, isOutput: false))
    }

    private func nearestEdge(to world: WorkflowPoint) -> String? {
        let reach = 10 / model.camera.scale
        var best: (id: String, distance: Double)?
        for edge in model.graph.edges {
            guard let curve = curve(for: edge) else { continue }
            let distance = WorkflowLayout.distance(from: world, toCurve: curve)
            if distance <= reach, best == nil || distance < best!.distance { best = (edge.id, distance) }
        }
        return best?.id
    }

    private var edgeLayer: some View {
        Canvas { context, _ in
            let camera = model.camera
            let loops = model.loopEdgeIDs
            func screen(_ point: WorkflowPoint) -> CGPoint {
                let mapped = camera.screenPoint(point)
                return CGPoint(x: mapped.x, y: mapped.y)
            }
            for edge in model.graph.edges {
                guard let from = model.node(edge.from), let to = model.node(edge.to) else { continue }
                let isSelected = model.selectedEdgeID == edge.id
                let start = WorkflowLayout.portPoint(of: from, isOutput: true, branch: edge.branch)
                let end = WorkflowLayout.portPoint(of: to, isOutput: false)
                var path = Path()
                if loops.contains(edge.id) {
                    let bottom = max(WorkflowLayout.frame(of: from).maxY, WorkflowLayout.frame(of: to).maxY) + WorkflowLayout.loopDrop
                    let segments = WorkflowLayout.loopSegments(from: start, to: end, y: bottom)
                    path.move(to: screen(segments.first.start))
                    path.addCurve(to: screen(segments.first.end), control1: screen(segments.first.control1), control2: screen(segments.first.control2))
                    path.addLine(to: screen(segments.second.start))
                    path.addCurve(to: screen(segments.second.end), control1: screen(segments.second.control1), control2: screen(segments.second.control2))
                } else {
                    let curve = WorkflowLayout.edgeCurve(from: start, to: end)
                    path.move(to: screen(curve.start))
                    path.addCurve(to: screen(curve.end), control1: screen(curve.control1), control2: screen(curve.control2))
                }
                let color = isSelected ? WispColor.textPrimary : WispColor.textSecondary.opacity(0.7)
                context.stroke(path, with: .color(color), style: StrokeStyle(
                    lineWidth: 1.5, lineCap: .round, dash: isSelected ? [] : [5, 5]))
                var arrow = Path()
                let points = WorkflowLayout.arrowhead(into: end).map(screen)
                arrow.move(to: points[0]); arrow.addLine(to: points[1]); arrow.addLine(to: points[2]); arrow.closeSubpath()
                context.fill(arrow, with: .color(color))
            }
            if let pending = model.pending, let from = model.node(pending.fromID) {
                let curve = WorkflowLayout.edgeCurve(
                    from: WorkflowLayout.portPoint(of: from, isOutput: true, branch: pending.branch),
                    to: pending.pointer)
                var path = Path()
                path.move(to: screen(curve.start))
                path.addCurve(to: screen(curve.end), control1: screen(curve.control1), control2: screen(curve.control2))
                context.stroke(path, with: .color(WispColor.intelligence), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
    }

    // MARK: Nodes

    private var nodeLayer: some View {
        // The world: every node at its own coordinates, scaled and shifted by the camera. It is an
        // overlay on a clear view the size of the canvas, so its large frame never stretches the
        // layout (it once pushed the toolbar off-screen).
        Color.clear.overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: 1, height: 1)
                ForEach(model.graph.nodes) { node in
                    let size = WorkflowLayout.size(of: node)
                    WorkflowNodeView(model: model, node: node)
                        .frame(width: size.width, height: size.height)
                        .offset(x: node.at.x, y: node.at.y)
                }
            }
            .frame(width: 40_000, height: 40_000, alignment: .topLeading)
            .scaleEffect(model.camera.scale, anchor: .topLeading)
            .offset(x: model.camera.x, y: model.camera.y)
        }
    }

    private var boxSelectionLayer: some View {
        Canvas { context, _ in
            guard let box = model.boxSelection else { return }
            let topLeft = model.camera.screenPoint(WorkflowPoint(x: box.x, y: box.y))
            let rect = CGRect(x: topLeft.x, y: topLeft.y, width: box.width * model.camera.scale, height: box.height * model.camera.scale)
            context.fill(Path(rect), with: .color(WispColor.accentText.opacity(0.08)))
            context.stroke(Path(rect), with: .color(WispColor.accentText.opacity(0.6)), lineWidth: 1)
        }
    }

    // MARK: Empty state and notice

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "bolt")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(WispColor.warning)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WispColor.warning.opacity(0.14)))
            Text("Start with a trigger")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(WispColor.textSecondary)
            Button {
                model.addNode(.trigger)
            } label: {
                Label("Add trigger", systemImage: "plus")
            }
            .buttonStyle(WispPillButtonStyle())
            .pointerCursor()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func noticeChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(WispColor.warningText)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(WispColor.surface3))
            .overlay(Capsule().strokeBorder(WispColor.cardSeparator, lineWidth: 0.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 14)
            .transition(.opacity)
    }

    // MARK: Menus

    @ViewBuilder
    private func addMenuItems(at screen: WorkflowPoint?) -> some View {
        ForEach(WorkflowNodeKind.stepKinds) { kind in
            Button(kind.title, systemImage: kind.symbolName) { model.addNode(kind) }
        }
        Divider()
        Button(WorkflowNodeKind.note.title, systemImage: WorkflowNodeKind.note.symbolName) { model.addNode(.note) }
        Button(WorkflowNodeKind.text.title, systemImage: WorkflowNodeKind.text.symbolName) { model.addNode(.text) }
    }

    // MARK: Input

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if magnifyOrigin == nil { magnifyOrigin = model.camera.scale }
                if let origin = magnifyOrigin {
                    model.camera = model.camera.zoomed(
                        to: origin * value.magnification,
                        around: WorkflowPoint(x: value.startLocation.x, y: value.startLocation.y))
                }
            }
            .onEnded { _ in magnifyOrigin = nil }
    }

    /// Two-finger scroll pans; ⌘ (or Ctrl) with scroll zooms around the pointer. One scroll event
    /// zooms no more than one press of the zoom button, so a fast wheel does not jump.
    private func handleScroll(dx: Double, dy: Double, location: CGPoint, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) || modifiers.contains(.control) {
            let rate = 0.004
            let limit = log(WorkflowCamera.zoomStep)
            let change = max(-limit, min(limit, -dy * rate))
            model.camera = model.camera.zoomed(
                to: model.camera.scale * exp(change),
                around: WorkflowPoint(x: location.x, y: location.y))
        } else {
            model.camera = model.camera.panned(byScreenDx: dx * 0.8, dy: dy * 0.8)
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let isCommand = press.modifiers.contains(.command)
        let isShift = press.modifiers.contains(.shift)
        switch press.key {
        case .delete, .deleteForward:
            model.removeSelection(); return .handled
        case .escape:
            model.clearSelection(); model.tool = .select; return .handled
        case .leftArrow: model.nudgeSelection(dx: -1, dy: 0, large: isShift); return .handled
        case .rightArrow: model.nudgeSelection(dx: 1, dy: 0, large: isShift); return .handled
        case .upArrow: model.nudgeSelection(dx: 0, dy: -1, large: isShift); return .handled
        case .downArrow: model.nudgeSelection(dx: 0, dy: 1, large: isShift); return .handled
        default: break
        }
        guard isCommand else { return .ignored }
        switch press.characters.lowercased() {
        case "z": if isShift { model.redo() } else { model.undo() }; return .handled
        case "d": model.duplicateSelection(); return .handled
        case "a": model.selectAll(); return .handled
        case "0": model.fit(); return .handled
        case "=", "+": model.zoomIn(); return .handled
        case "-": model.zoomOut(); return .handled
        default: return .ignored
        }
    }
}

// MARK: - Scroll wheel

/// Reports scroll-wheel and trackpad scrolls over the canvas (SwiftUI has no scroll event of its
/// own), in the canvas's own top-left coordinates. It never takes a click.
private struct WorkflowScrollMonitor: NSViewRepresentable {
    var onScroll: (_ dx: Double, _ dy: Double, _ location: CGPoint, _ modifiers: NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) { view.onScroll = onScroll }

    final class MonitorView: NSView {
        var onScroll: ((Double, Double, CGPoint, NSEvent.ModifierFlags) -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                self.onScroll?(Double(event.scrollingDeltaX), Double(event.scrollingDeltaY), point, event.modifierFlags)
                return nil
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
