//
//  RadialMenuController.swift
//  leanring-buddy
//
//  The radial quick menu: hold the Talk chord and press R, and a ring of quick actions
//  pops out around the pointer. Point toward one (it swells and lights up in the theme's
//  accent) and click, or press its number; Esc, a click in the middle or a click on the
//  dimmed screen closes it. Like the region picker, it is one of the few Wisp overlays
//  that takes the mouse, and only while it is up, so the desktop is never left
//  unclickable.
//
//  The geometry (which wedge a direction chooses) is pure and tested in
//  `RadialMenuGeometry`; this file is the panel and the drawing around it.
//

import AppKit
import SwiftUI

struct RadialMenuItem: Identifiable {
    let id: String
    let title: String
    let symbolName: String
    let perform: @MainActor () -> Void
}

@MainActor
final class RadialMenuController {
    private var panel: RadialMenuPanel?

    var isShowing: Bool { panel != nil }

    func show(items: [RadialMenuItem]) {
        guard panel == nil, !items.isEmpty else { return }
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main else { return }

        // The ring is centred on the pointer, but nudged inward near an edge so every
        // button stays on screen.
        let ringReach: CGFloat = RadialMenuView.ringRadius + RadialMenuView.buttonDiameter
        let centreInView = CGPoint(
            x: min(max(mouseLocation.x - screen.frame.minX, ringReach), screen.frame.width - ringReach),
            // SwiftUI's y runs down; AppKit's runs up.
            y: min(max(screen.frame.height - (mouseLocation.y - screen.frame.minY), ringReach), screen.frame.height - ringReach)
        )

        let menuPanel = RadialMenuPanel(contentRect: screen.frame)
        let menuView = RadialMenuView(
            centre: centreInView,
            items: items,
            onChoose: { [weak self] chosenItem in
                self?.dismiss()
                // After the panel is gone, so the action sees the user's own app in front.
                DispatchQueue.main.async { chosenItem.perform() }
            },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        menuPanel.contentView = NSHostingView(rootView: menuView)
        menuPanel.onEscape = { [weak self] in self?.dismiss() }
        menuPanel.onNumberKey = { [weak self] number in
            guard items.indices.contains(number - 1) else { return }
            self?.dismiss()
            let chosenItem = items[number - 1]
            DispatchQueue.main.async { chosenItem.perform() }
        }
        menuPanel.makeKeyAndOrderFront(nil)
        panel = menuPanel
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class RadialMenuPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onNumberKey: ((Int) -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = false
    }

    // A borderless panel can't be key by default, and Esc needs a key window.
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if let typedCharacter = event.charactersIgnoringModifiers, let number = Int(typedCharacter), number > 0 {
            onNumberKey?(number)
        } else {
            super.keyDown(with: event)
        }
    }
}

struct RadialMenuView: View {
    let centre: CGPoint
    let items: [RadialMenuItem]
    var onChoose: (RadialMenuItem) -> Void
    var onDismiss: () -> Void

    static let ringRadius: CGFloat = 104
    static let buttonDiameter: CGFloat = 62
    private let deadZoneRadius: CGFloat = 30

    @State private var hoveredIndex: Int?
    @State private var isPresented = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // The dimmed screen: a click anywhere off the ring closes the menu.
            Color.black.opacity(isPresented ? 0.30 : 0)
                .contentShape(Rectangle())

            GlassEffectContainer(spacing: 8) {
                ZStack {
                    centreHub
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        wedgeButton(item: item, index: index)
                    }
                }
            }
            .position(centre)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onContinuousHover { hoverPhase in
            switch hoverPhase {
            case .active(let location):
                let newHoveredIndex = RadialMenuGeometry.wedgeIndex(
                    pointerOffsetX: Double(location.x - centre.x),
                    pointerOffsetY: Double(location.y - centre.y),
                    wedgeCount: items.count,
                    deadZoneRadius: Double(deadZoneRadius)
                )
                if newHoveredIndex != hoveredIndex {
                    withAnimation(reduceMotion ? nil : WispMotion.hover) { hoveredIndex = newHoveredIndex }
                }
            case .ended:
                hoveredIndex = nil
            }
        }
        .onTapGesture {
            if let hoveredIndex, items.indices.contains(hoveredIndex) {
                onChoose(items[hoveredIndex])
            } else {
                onDismiss()
            }
        }
        .onAppear {
            withAnimation(reduceMotion ? WispMotion.quick : WispMotion.pop) { isPresented = true }
        }
        .environment(\.colorScheme, .dark)
    }

    /// Wisp's mark in the middle, and the name of the wedge being pointed at.
    private var centreHub: some View {
        VStack(spacing: 6) {
            WispMark(state: .idle, size: 26)
            Text(hoveredIndex.flatMap { items.indices.contains($0) ? items[$0].title : nil } ?? "Quick menu")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.opacity)
        }
        .frame(width: 104, height: 104)
        .glassEffect(.regular.tint(Color.black.opacity(0.35)), in: .circle)
        .scaleEffect(isPresented ? 1 : 0.4)
        .opacity(isPresented ? 1 : 0)
    }

    private func wedgeButton(item: RadialMenuItem, index: Int) -> some View {
        let isHovered = hoveredIndex == index
        let offset = RadialMenuGeometry.offset(ofWedge: index, wedgeCount: items.count, radius: Double(Self.ringRadius))
        return VStack(spacing: 4) {
            Image(systemName: item.symbolName)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.bounce, value: isHovered)
            Text("\(index + 1)")
                .font(.system(size: 9, weight: .bold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(width: Self.buttonDiameter, height: Self.buttonDiameter)
        .glassEffect(
            .regular.tint(isHovered ? WispColor.accent.opacity(0.75) : Color.black.opacity(0.30)),
            in: .circle
        )
        .scaleEffect(isHovered ? 1.2 : 1)
        .shadow(color: WispColor.accent.opacity(isHovered ? 0.6 : 0), radius: 14)
        // Each button flies out from the hub, one after another.
        .offset(
            x: isPresented ? offset.x : 0,
            y: isPresented ? offset.y : 0
        )
        .scaleEffect(isPresented ? 1 : 0.2)
        .opacity(isPresented ? 1 : 0)
        .animation(reduceMotion ? nil : WispMotion.pop.delay(Double(index) * 0.03), value: isPresented)
        .accessibilityLabel(item.title)
    }
}
