//
//  AnnotationClickTarget.swift
//  leanring-buddy
//
//  Pure side of "click something Wisp drew to ask about it": which annotations
//  are clickable, how big a note is on screen, and which one the pointer is
//  over. The mouse plumbing that uses this lives in `AnnotationClickRouter`.
//

import AppKit
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

    /// The font `ScreenAnnotationLayer.noteView` writes notes in. Both read the
    /// same size and padding from here so the clickable area is the drawn area.
    static let noteFontSize: CGFloat = 22
    static let noteHorizontalPadding: CGFloat = 8
    static let noteVerticalPadding: CGFloat = 2

    /// The note's size on screen, measured with the same font the layer uses
    /// (Bradley Hand Bold, falling back to the system's bold like SwiftUI does
    /// when a face is missing) rather than guessed from the character count —
    /// handwriting is far from fixed-width, so a guess missed the right edge of
    /// long notes and clipped short ones.
    static func measuredNoteSize(forText noteText: String) -> CGSize {
        if let cachedSize = measuredNoteSizeCache[noteText] { return cachedSize }

        let textSize = (noteText as NSString).size(withAttributes: [.font: noteFont])
        let measuredSize = CGSize(
            width: ceil(textSize.width) + noteHorizontalPadding * 2,
            height: ceil(textSize.height) + noteVerticalPadding * 2
        )
        // The router hit-tests on every pointer move; measuring the same few
        // strings each time would be wasted work on the main thread.
        if measuredNoteSizeCache.count > 200 { measuredNoteSizeCache.removeAll() }
        measuredNoteSizeCache[noteText] = measuredSize
        return measuredSize
    }

    private static let noteFont: NSFont = NSFont(name: "BradleyHandITCTT-Bold", size: noteFontSize)
        ?? NSFont.systemFont(ofSize: noteFontSize, weight: .bold)

    private static var measuredNoteSizeCache: [String: CGSize] = [:]

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

        let noteSize = measuredNoteSize(forText: annotation.label ?? "")
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

/// Moves handwritten notes that landed on each other, or on a circle or box,
/// just far enough apart to read. The model's note coordinates are guesses, and
/// it often stacks several lines of working at nearly the same spot.
enum AnnotationNoteLayout {
    /// Gap kept between a nudged note and what it was nudged away from.
    private static let gapInPoints: CGFloat = 6
    private static let maximumNudgesPerNote = 12

    static func separatingOverlappingNotes(
        in annotations: [ScreenAnnotation],
        screenshotSize: CGSize,
        displaySize: CGSize
    ) -> [ScreenAnnotation] {
        guard screenshotSize.width > 0, screenshotSize.height > 0,
              annotations.contains(where: { $0.style == .note }) else { return annotations }

        func clickableRect(_ annotation: ScreenAnnotation) -> CGRect {
            AnnotationClickTarget.clickableRectInOverlayCoordinates(
                for: annotation, screenshotSize: screenshotSize, displaySize: displaySize
            )
        }

        // Circles and boxes the model drew are obstacles. The one exception: a
        // note lying wholly inside a *box* was put there on purpose (beside a
        // row of a boxed table). A circle's inside is the thing being circled,
        // so a note over it is never deliberate.
        let shapes: [(rect: CGRect, isBox: Bool)] = annotations
            .filter { $0.style == .circle || $0.style == .box }
            .filter { !$0.isUnplacedWalkthroughStep }
            .map { (rect: clickableRect($0), isBox: $0.style == .box) }
        var placedNoteRects: [CGRect] = []

        var arrangedAnnotations = annotations
        for annotationIndex in arrangedAnnotations.indices where arrangedAnnotations[annotationIndex].style == .note {
            let note = arrangedAnnotations[annotationIndex]
            var noteRect = clickableRect(note)
            let originalRect = noteRect
            let obstacleRectsForThisNote = shapes
                .filter { !($0.isBox && $0.rect.contains(originalRect)) }
                .map(\.rect)

            var nudgeCount = 0
            while nudgeCount < maximumNudgesPerNote,
                  let obstacle = (obstacleRectsForThisNote + placedNoteRects)
                      .first(where: { $0.insetBy(dx: -2, dy: -3).intersects(noteRect) }) {
                noteRect.origin.y = obstacle.maxY + gapInPoints
                nudgeCount += 1
            }

            // Pushed off the bottom of the screen is worse than overlapping.
            let wasMoved = noteRect != originalRect
            if wasMoved && noteRect.maxY <= displaySize.height {
                let horizontalScale = screenshotSize.width / displaySize.width
                let verticalScale = screenshotSize.height / displaySize.height
                // A nudged note is anchored at a point, which is where its text starts.
                arrangedAnnotations[annotationIndex] = ScreenAnnotation(
                    id: note.id,
                    style: .note,
                    regionInScreenshotPixels: CGRect(
                        x: noteRect.minX * horizontalScale,
                        y: noteRect.midY * verticalScale,
                        width: 0,
                        height: 0
                    ),
                    label: note.label,
                    screenNumber: note.screenNumber,
                    stepNumber: note.stepNumber
                )
                placedNoteRects.append(noteRect)
            } else {
                placedNoteRects.append(originalRect)
            }
        }
        return arrangedAnnotations
    }
}

/// Revealing a worked solution one note at a time. A reply with several lines
/// of working shows the first, and the user steps through the rest — the way a
/// tutor writes a line, lets it land, then writes the next.
enum AnnotationNoteReveal {
    /// Fewer notes than this are just shown all at once.
    static let minimumNotesToStepThrough = 3

    static let nextButtonSize = CGSize(width: 104, height: 30)

    /// How many notes to show first: one when there are enough to step through,
    /// nil (everything) otherwise.
    static func initialLimit(forNoteCount noteCount: Int) -> Int? {
        noteCount >= minimumNotesToStepThrough ? 1 : nil
    }

    static func noteCount(in annotations: [ScreenAnnotation]) -> Int {
        annotations.filter { $0.style == .note }.count
    }

    /// The annotations to draw for a limit, in their original order, and how
    /// many notes are still hidden. Shapes are always shown; only notes past the
    /// limit are held back.
    static func visibleAnnotations(
        _ annotations: [ScreenAnnotation],
        noteLimit: Int?
    ) -> (visible: [ScreenAnnotation], hiddenNoteCount: Int) {
        guard let noteLimit else { return (annotations, 0) }
        var shownNoteCount = 0
        var hiddenNoteCount = 0
        var visibleAnnotations: [ScreenAnnotation] = []
        for annotation in annotations {
            if annotation.style == .note {
                if shownNoteCount < noteLimit {
                    shownNoteCount += 1
                    visibleAnnotations.append(annotation)
                } else {
                    hiddenNoteCount += 1
                }
            } else {
                visibleAnnotations.append(annotation)
            }
        }
        return (visibleAnnotations, hiddenNoteCount)
    }

    /// Where the Next button sits: just right of the most recently revealed note.
    /// Nil when nothing is hidden or no note is showing.
    static func nextButtonRect(
        visibleAnnotations: [ScreenAnnotation],
        hiddenNoteCount: Int,
        screenshotSize: CGSize,
        displaySize: CGSize
    ) -> CGRect? {
        guard hiddenNoteCount > 0,
              let latestNote = visibleAnnotations.last(where: { $0.style == .note }) else { return nil }
        let noteRect = AnnotationClickTarget.clickableRectInOverlayCoordinates(
            for: latestNote, screenshotSize: screenshotSize, displaySize: displaySize
        )
        var buttonRect = CGRect(
            x: noteRect.maxX + 10,
            y: noteRect.midY - nextButtonSize.height / 2,
            width: nextButtonSize.width,
            height: nextButtonSize.height
        )
        // Keep it on screen when the note runs close to the right edge.
        if buttonRect.maxX > displaySize.width - 8 {
            buttonRect.origin.x = max(8, displaySize.width - 8 - nextButtonSize.width)
        }
        return buttonRect
    }

    /// A stepped limit, kept between one note and all of them.
    static func limit(afterStepping step: Int, from currentLimit: Int, noteCount: Int) -> Int {
        min(max(currentLimit + step, 1), noteCount)
    }
}
