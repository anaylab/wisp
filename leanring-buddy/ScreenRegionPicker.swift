//
//  ScreenRegionPicker.swift
//  leanring-buddy
//
//  The drag-a-rectangle overlay behind "Ask About a Part…". A dimmed, full-screen
//  panel on the screen the pointer is on; the user drags over the part they mean,
//  and the result goes to `onFinish` (nil when cancelled with Esc or a stray
//  click). It is the one place besides the tool-confirmation card where a Wisp
//  overlay takes the mouse — and only while it is up, so the desktop is never
//  left unclickable.
//

import AppKit

@MainActor
final class ScreenRegionPickerController {
    private var panel: ScreenRegionPickerPanel?
    private let onFinish: (FocusedScreenRegion?) -> Void

    init(onFinish: @escaping (FocusedScreenRegion?) -> Void) {
        self.onFinish = onFinish
    }

    func show() {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main else {
            onFinish(nil)
            return
        }

        let pickerPanel = ScreenRegionPickerPanel(contentRect: screen.frame)
        let pickerView = ScreenRegionPickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
        pickerView.onFinish = { [weak self] selectedRectInViewCoordinates in
            guard let self else { return }
            // The view's origin is the screen's bottom-left, so adding the
            // screen's origin gives AppKit global coordinates.
            let focusedRegion = selectedRectInViewCoordinates.flatMap { selectedRect in
                FocusedScreenRegion(
                    rectInAppKitCoordinates: selectedRect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY),
                    displayFrameInAppKitCoordinates: screen.frame
                )
            }
            self.dismiss()
            self.onFinish(focusedRegion)
        }
        pickerPanel.contentView = pickerView
        pickerPanel.makeKeyAndOrderFront(nil)
        pickerPanel.makeFirstResponder(pickerView)
        panel = pickerPanel
    }

    private func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class ScreenRegionPickerPanel: NSPanel {
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
}

private final class ScreenRegionPickerView: NSView {
    var onFinish: ((CGRect?) -> Void)?

    private var dragStartPoint: CGPoint?
    private var currentSelectionRect: CGRect?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Dim everything, then cut the selection back out so the user sees the
        // part they're choosing at full brightness.
        let dimmingPath = NSBezierPath(rect: bounds)
        if let currentSelectionRect {
            dimmingPath.append(NSBezierPath(roundedRect: currentSelectionRect, xRadius: 6, yRadius: 6))
            dimmingPath.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.32).setFill()
        dimmingPath.fill()

        if let currentSelectionRect {
            let outline = NSBezierPath(roundedRect: currentSelectionRect, xRadius: 6, yRadius: 6)
            outline.lineWidth = 2
            NSColor.systemBlue.setStroke()
            outline.stroke()
        } else {
            drawHint()
        }
    }

    private func drawHint() {
        let hint = "Drag over the part you want to ask about  ·  Esc to cancel" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let hintSize = hint.size(withAttributes: attributes)
        let hintOrigin = CGPoint(x: bounds.midX - hintSize.width / 2, y: bounds.midY - hintSize.height / 2)
        hint.draw(at: hintOrigin, withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartPoint = convert(event.locationInWindow, from: nil)
        currentSelectionRect = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartPoint else { return }
        let currentPoint = convert(event.locationInWindow, from: nil)
        currentSelectionRect = CGRect(
            x: min(dragStartPoint.x, currentPoint.x),
            y: min(dragStartPoint.y, currentPoint.y),
            width: abs(currentPoint.x - dragStartPoint.x),
            height: abs(currentPoint.y - dragStartPoint.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        onFinish?(currentSelectionRect)
    }

    override func keyDown(with event: NSEvent) {
        // 53 is Escape.
        if event.keyCode == 53 {
            onFinish?(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}
