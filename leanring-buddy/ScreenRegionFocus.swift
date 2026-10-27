//
//  ScreenRegionFocus.swift
//  leanring-buddy
//
//  "Ask about this part": the user drags a rectangle over a piece of the
//  screen — one line of an equation, a chart bar, a paragraph — and then asks
//  questions about just that. This file is the pure side: the selected region,
//  the conversion into the screenshot's pixel space the model works in, and the
//  words that tell the model what the user is pointing at.
//
//  The region is remembered, not consumed by one question, so follow-ups
//  ("why?", "show me the next step") keep talking about the same part until the
//  user picks another or starts a fresh question.
//

import CoreGraphics
import Foundation

nonisolated struct FocusedScreenRegion: Equatable {
    /// The selected rectangle in AppKit global coordinates (bottom-left origin),
    /// clamped to the display it was drawn on.
    let rectInAppKitCoordinates: CGRect
    /// That display's frame, in the same coordinates.
    let displayFrameInAppKitCoordinates: CGRect

    /// A drag smaller than this in either direction is a click, not a selection.
    static let minimumSideLengthInPoints: CGFloat = 24

    init?(rectInAppKitCoordinates selectedRect: CGRect, displayFrameInAppKitCoordinates displayFrame: CGRect) {
        let clampedRect = selectedRect.standardized.intersection(displayFrame)
        guard !clampedRect.isNull,
              clampedRect.width >= Self.minimumSideLengthInPoints,
              clampedRect.height >= Self.minimumSideLengthInPoints else { return nil }
        self.rectInAppKitCoordinates = clampedRect
        self.displayFrameInAppKitCoordinates = displayFrame
    }

    /// The inverse of `regionInScreenshotPixels`: a rectangle found in the
    /// screenshot's pixel space (an OCR line, a list item) as a selection on
    /// the display that screenshot was taken of. This is how a spoken "the third
    /// answer" becomes the same region a drag would have produced.
    ///
    /// `paddingInPoints` grows the rectangle on every side so the highlight and
    /// close-up don't clip glyphs; a rectangle still smaller than the minimum
    /// selection (one short line is ~20pt tall) is grown evenly about its
    /// centre to reach it. Clamped to the display like a dragged selection.
    init?(
        regionInScreenshotPixels screenshotRegion: CGRect,
        screenshotSize: CGSize,
        displayFrameInAppKitCoordinates displayFrame: CGRect,
        paddingInPoints: CGFloat = 0
    ) {
        guard screenshotSize.width > 0, screenshotSize.height > 0,
              displayFrame.width > 0, displayFrame.height > 0 else { return nil }

        let pointsPerPixelHorizontally = displayFrame.width / screenshotSize.width
        let pointsPerPixelVertically = displayFrame.height / screenshotSize.height

        var widthInPoints = screenshotRegion.width * pointsPerPixelHorizontally + paddingInPoints * 2
        var heightInPoints = screenshotRegion.height * pointsPerPixelVertically + paddingInPoints * 2
        let centerXInPoints = screenshotRegion.midX * pointsPerPixelHorizontally
        let centerYFromTopInPoints = screenshotRegion.midY * pointsPerPixelVertically
        widthInPoints = max(widthInPoints, Self.minimumSideLengthInPoints)
        heightInPoints = max(heightInPoints, Self.minimumSideLengthInPoints)

        // Screenshot y grows downward; AppKit's grows upward from the display's bottom.
        let rectInAppKitCoordinates = CGRect(
            x: displayFrame.minX + centerXInPoints - widthInPoints / 2,
            y: displayFrame.maxY - centerYFromTopInPoints - heightInPoints / 2,
            width: widthInPoints,
            height: heightInPoints
        )
        self.init(rectInAppKitCoordinates: rectInAppKitCoordinates, displayFrameInAppKitCoordinates: displayFrame)
    }

    /// The region in the screenshot's pixel space (top-left origin) — the same
    /// space every annotation tag and `[POINT:]` uses. AppKit's y axis points up
    /// and the screenshot's points down, so the vertical edge is flipped here.
    func regionInScreenshotPixels(screenshotSize: CGSize) -> CGRect {
        guard displayFrameInAppKitCoordinates.width > 0,
              displayFrameInAppKitCoordinates.height > 0 else { return .zero }

        let horizontalScale = screenshotSize.width / displayFrameInAppKitCoordinates.width
        let verticalScale = screenshotSize.height / displayFrameInAppKitCoordinates.height

        let distanceFromDisplayLeft = rectInAppKitCoordinates.minX - displayFrameInAppKitCoordinates.minX
        let distanceFromDisplayTop = displayFrameInAppKitCoordinates.maxY - rectInAppKitCoordinates.maxY

        return CGRect(
            x: (distanceFromDisplayLeft * horizontalScale).rounded(),
            y: (distanceFromDisplayTop * verticalScale).rounded(),
            width: (rectInAppKitCoordinates.width * horizontalScale).rounded(),
            height: (rectInAppKitCoordinates.height * verticalScale).rounded()
        )
    }

    /// The same region as a rectangle in the display's own top-left-origin
    /// points, which is what ScreenCaptureKit's `sourceRect` wants.
    var rectInDisplayPointsTopLeftOrigin: CGRect {
        CGRect(
            x: rectInAppKitCoordinates.minX - displayFrameInAppKitCoordinates.minX,
            y: displayFrameInAppKitCoordinates.maxY - rectInAppKitCoordinates.maxY,
            width: rectInAppKitCoordinates.width,
            height: rectInAppKitCoordinates.height
        )
    }

    /// Added to the per-turn screen-context block on the user's message, so it
    /// applies to this request without touching the system prompt (which stays
    /// identical between turns for the prefix cache) and is stripped from the
    /// stored transcript like the other per-turn context.
    func promptText(screenshotSize: CGSize, screenNumber: Int?, hasCloseUpImage: Bool) -> String {
        let region = regionInScreenshotPixels(screenshotSize: screenshotSize)
        let screenPhrase = screenNumber.map { " of screen \($0)" } ?? ""
        var lines = [
            "the user has selected one part of the screen and is asking about just that part: pixels \(Int(region.minX)),\(Int(region.minY)),\(Int(region.maxX)),\(Int(region.maxY))\(screenPhrase), in the screenshot's coordinate space.",
            "answer about that part, using the rest of the screen only for context. keep any marks, circles and notes on or right next to it.",
        ]
        if hasCloseUpImage {
            lines.insert("a close-up of exactly that part is the last image — read small text and symbols from it.", at: 1)
        }
        return lines.joined(separator: "\n")
    }
}
