//
//  AnnotationClickRouter.swift
//  leanring-buddy
//
//  Lets the user click a note, circle or box Wisp drew and ask about it.
//
//  The overlay is click-through, and must stay so: it covers the whole screen
//  above nearly everything. So it only starts taking the mouse while the pointer
//  is over something clickable, and gives it back the moment the pointer leaves.
//  Pointer movement is watched with mouse-moved monitors (global while the
//  overlay ignores the mouse, local once it doesn't — an event goes to exactly
//  one of the two), and the click itself is consumed by a local monitor so it
//  never also reaches the app underneath.
//
//  It also notices scrolling in other apps. Annotations are pinned to screen
//  positions, so once the content under them scrolls they sit on the wrong
//  text — better gone than misleading.
//

import AppKit

@MainActor
final class AnnotationClickRouter {
    struct DisplayAnnotations {
        let displayFrame: CGRect
        let screenshotSize: CGSize
        let annotations: [ScreenAnnotation]
    }

    private let annotationsOnEachDisplay: () -> [DisplayAnnotations]
    /// True while a confirmation card owns the overlay's mouse handling.
    private let isOverlayReservedForConfirmation: () -> Bool
    private let setOverlayAcceptsMouseEvents: (Bool) -> Void
    private let onClickedRegion: (FocusedScreenRegion, CGRect, CGRect) -> Void
    private let onContentScrolled: () -> Void

    private var globalScrollMonitor: Any?
    private var globalMouseMovedMonitor: Any?
    private var localMouseMonitor: Any?
    private var isHoveringClickableAnnotation = false

    init(
        annotationsOnEachDisplay: @escaping () -> [DisplayAnnotations],
        isOverlayReservedForConfirmation: @escaping () -> Bool,
        setOverlayAcceptsMouseEvents: @escaping (Bool) -> Void,
        onClickedRegion: @escaping (FocusedScreenRegion, CGRect, CGRect) -> Void,
        onContentScrolled: @escaping () -> Void
    ) {
        self.annotationsOnEachDisplay = annotationsOnEachDisplay
        self.isOverlayReservedForConfirmation = isOverlayReservedForConfirmation
        self.setOverlayAcceptsMouseEvents = setOverlayAcceptsMouseEvents
        self.onClickedRegion = onClickedRegion
        self.onContentScrolled = onContentScrolled
    }

    func start() {
        guard globalMouseMovedMonitor == nil else { return }
        globalMouseMovedMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHoverState() }
        }
        // Global scroll events are those going to other apps, which is exactly
        // the content the annotations sit over. A zero-delta event (a trackpad
        // gesture's phase change) moves nothing.
        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            guard event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 else { return }
            MainActor.assumeIsolated { self?.onContentScrolled() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                if event.type == .leftMouseDown {
                    return self.handleClick() ? nil : event
                }
                self.updateHoverState()
                return event
            }
        }
    }

    func stop() {
        if let globalMouseMovedMonitor { NSEvent.removeMonitor(globalMouseMovedMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalScrollMonitor { NSEvent.removeMonitor(globalScrollMonitor) }
        globalScrollMonitor = nil
        globalMouseMovedMonitor = nil
        localMouseMonitor = nil
        endHoverIfNeeded()
    }

    /// The clickable annotation under the pointer, with its clickable rectangle
    /// and its display's frame.
    private func annotationUnderPointer() -> (rectInOverlay: CGRect, displayFrame: CGRect)? {
        let pointerLocation = NSEvent.mouseLocation
        for displayAnnotations in annotationsOnEachDisplay() where displayAnnotations.displayFrame.contains(pointerLocation) {
            let overlayPoint = AnnotationClickTarget.overlayPoint(
                forAppKitPoint: pointerLocation,
                displayFrame: displayAnnotations.displayFrame
            )
            guard let hitAnnotation = AnnotationClickTarget.annotation(
                atOverlayPoint: overlayPoint,
                in: displayAnnotations.annotations,
                screenshotSize: displayAnnotations.screenshotSize,
                displaySize: displayAnnotations.displayFrame.size
            ) else { return nil }
            return (
                AnnotationClickTarget.clickableRectInOverlayCoordinates(
                    for: hitAnnotation,
                    screenshotSize: displayAnnotations.screenshotSize,
                    displaySize: displayAnnotations.displayFrame.size
                ),
                displayAnnotations.displayFrame
            )
        }
        return nil
    }

    private func updateHoverState() {
        // A confirmation card owns the overlay's mouse handling. If we were
        // hovering when it appeared, give the cursor back (a bare reset would
        // leave the pointing hand pushed with nothing to pop it).
        guard !isOverlayReservedForConfirmation() else {
            endHoverIfNeeded()
            return
        }
        let isOverClickableAnnotation = annotationUnderPointer() != nil
        guard isOverClickableAnnotation != isHoveringClickableAnnotation else { return }
        isHoveringClickableAnnotation = isOverClickableAnnotation
        setOverlayAcceptsMouseEvents(isOverClickableAnnotation)
        if isOverClickableAnnotation {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
    }

    private func endHoverIfNeeded() {
        guard isHoveringClickableAnnotation else { return }
        isHoveringClickableAnnotation = false
        if !isOverlayReservedForConfirmation() {
            setOverlayAcceptsMouseEvents(false)
        }
        NSCursor.pop()
    }

    /// Returns true when the click was on an annotation and has been handled.
    private func handleClick() -> Bool {
        guard isHoveringClickableAnnotation,
              let (clickedRect, displayFrame) = annotationUnderPointer(),
              let focusedRegion = AnnotationClickTarget.focusedRegion(
                  forClickedRectInOverlayCoordinates: clickedRect,
                  displayFrame: displayFrame
              ) else { return false }

        endHoverIfNeeded()
        onClickedRegion(focusedRegion, clickedRect, displayFrame)
        return true
    }
}
