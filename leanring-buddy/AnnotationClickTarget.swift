//
//  AnnotationClickTarget.swift
//  leanring-buddy
//
//  Pure side of "click something Wisp drew to ask about it": which annotations
//  are clickable, how big a note is on screen, and which one the pointer is
//  over. The mouse plumbing that uses this lives in `AnnotationClickRouter`.
//

import CoreGraphics
import Foundation

enum AnnotationClickTarget {
    /// Only the things the model draws to explain something. Markers and arrows
    /// are pointers rather than content, and the highlight is the selected
    /// region's own frame.
    static func isClickable(_ annotation: ScreenAnnotation) -> Bool {
        switch annotation.style {
        case .note, .circle, .box:
            return !annotation.isUnplacedWalkthroughStep
        case .highlight, .arrow, .marker:
            return false
        }
    }

    /// Handwritten text's rough size at the 22pt note font: the layer lays text
    /// out itself, so the router estimates its box from the character count.
    static func estimatedNoteSize(forText noteText: String) -> CGSize {
        CGSize(width: 16 + CGFloat(noteText.count) * 11, height: 32)
    }

    /// The annotation's clickable rectangle in overlay coordinates (top-left
    /// origin, points). A note is written from its anchor, or to the right of an
    /// element's frame, exactly as `ScreenAnnotationLayer.noteView` places it.
    static func clickableRectInOverlayCoordinates(
        for annotation: ScreenAnnotation,
        screenshotSize: CGSize,
        displaySize: CGSize
    ) -> CGRect {
        let regionRect = annotation.regionInOverlayCoordinates(
            screenshotSize: screenshotSize,
            displaySize: displaySize
        )
        guard annotation.style == .note else {
            // A circle is drawn a little outside its region.
            return annotation.style == .circle ? regionRect.insetBy(dx: -8, dy: -5) : regionRect
        }

        let noteSize = estimatedNoteSize(forText: annotation.label ?? "")
        let isAnchoredToElement = regionRect.width > 0 || regionRect.height > 0
        let leadingEdge = isAnchoredToElement ? regionRect.maxX + 12 : regionRect.minX
        let verticalCentre = isAnchoredToElement ? regionRect.midY : regionRect.minY
        return CGRect(
            x: leadingEdge,
            y: verticalCentre - noteSize.height / 2,
            width: noteSize.width,
            height: noteSize.height
        )
    }

    /// The topmost clickable annotation under a pointer position given in
    /// overlay coordinates, or nil. Later annotations draw on top, so they win.
    static func annotation(
        atOverlayPoint overlayPoint: CGPoint,
        in annotations: [ScreenAnnotation],
        screenshotSize: CGSize,
        displaySize: CGSize
    ) -> ScreenAnnotation? {
        annotations.last { annotation in
            isClickable(annotation) && clickableRectInOverlayCoordinates(
                for: annotation,
                screenshotSize: screenshotSize,
                displaySize: displaySize
            ).contains(overlayPoint)
        }
    }

    /// A pointer position in AppKit global coordinates (bottom-left origin)
    /// expressed in one display's overlay coordinates (top-left origin).
    static func overlayPoint(forAppKitPoint appKitPoint: CGPoint, displayFrame: CGRect) -> CGPoint {
        CGPoint(x: appKitPoint.x - displayFrame.minX, y: displayFrame.maxY - appKitPoint.y)
    }

    /// The region to ask about for a clicked annotation, padded so a note keeps
    /// a little of what it sits beside, and so a thin note still clears the
    /// minimum selection size.
    static func focusedRegion(
        forClickedRectInOverlayCoordinates clickedRect: CGRect,
        displayFrame: CGRect
    ) -> FocusedScreenRegion? {
        let paddedRect = clickedRect.insetBy(dx: -14, dy: -14)
        let appKitRect = CGRect(
            x: displayFrame.minX + paddedRect.minX,
            y: displayFrame.maxY - paddedRect.maxY,
            width: paddedRect.width,
            height: paddedRect.height
        )
        return FocusedScreenRegion(
            rectInAppKitCoordinates: appKitRect,
            displayFrameInAppKitCoordinates: displayFrame
        )
    }
}
