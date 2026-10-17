//
//  "Ask about a part" suite: selection validity, AppKit → screenshot pixels,
//  ScreenCaptureKit's source rect, and the prompt text.
//

import CoreGraphics
import Foundation

var failureCount = 0
var checkCount = 0

func check(_ condition: Bool, _ description: String) {
    checkCount += 1
    if !condition {
        failureCount += 1
        print("FAIL: \(description)")
    }
}

// A 1440x900 display whose AppKit frame starts at the origin.
let display = CGRect(x: 0, y: 0, width: 1440, height: 900)

// A click or tiny drag is not a selection.
check(FocusedScreenRegion(rectInAppKitCoordinates: CGRect(x: 100, y: 100, width: 5, height: 5), displayFrameInAppKitCoordinates: display) == nil, "a tiny drag is rejected")
check(FocusedScreenRegion(rectInAppKitCoordinates: CGRect(x: 100, y: 100, width: 200, height: 10), displayFrameInAppKitCoordinates: display) == nil, "a thin sliver is rejected")
check(FocusedScreenRegion(rectInAppKitCoordinates: CGRect(x: 2000, y: 2000, width: 200, height: 200), displayFrameInAppKitCoordinates: display) == nil, "a rect off the display is rejected")

// Clamped to the display.
let overhanging = FocusedScreenRegion(rectInAppKitCoordinates: CGRect(x: 1340, y: 800, width: 300, height: 300), displayFrameInAppKitCoordinates: display)!
check(overhanging.rectInAppKitCoordinates == CGRect(x: 1340, y: 800, width: 100, height: 100), "an overhanging rect is clamped to the display")

// AppKit is bottom-left origin; the screenshot is top-left. A rect near the
// bottom of the screen in AppKit lands near the bottom of the screenshot, and
// the 1440x900 display maps to an 896x560 screenshot (scale 0.6222).
let screenshotSize = CGSize(width: 896, height: 560)
let nearTop = FocusedScreenRegion(rectInAppKitCoordinates: CGRect(x: 144, y: 720, width: 288, height: 90), displayFrameInAppKitCoordinates: display)!
let nearTopPixels = nearTop.regionInScreenshotPixels(screenshotSize: screenshotSize)
check(nearTopPixels.minX == 90 && nearTopPixels.width == 179, "x and width scale to screenshot pixels")
check(nearTopPixels.minY == 56 && nearTopPixels.height == 56, "a rect near the top of the screen has a small top offset")
let nearBottom = FocusedScreenRegion(rectInAppKitCoordinates: CGRect(x: 0, y: 0, width: 144, height: 90), displayFrameInAppKitCoordinates: display)!
check(nearBottom.regionInScreenshotPixels(screenshotSize: screenshotSize).maxY == 560, "a rect at the bottom edge ends at the screenshot's bottom")

// ScreenCaptureKit's source rect: the display's own points, top-left origin.
check(nearTop.rectInDisplayPointsTopLeftOrigin == CGRect(x: 144, y: 90, width: 288, height: 90), "source rect is top-left origin in display points")

// A second display to the right and above the primary.
let secondDisplay = CGRect(x: 1440, y: 900, width: 1920, height: 1080)
let onSecond = FocusedScreenRegion(rectInAppKitCoordinates: CGRect(x: 1540, y: 1780, width: 200, height: 100), displayFrameInAppKitCoordinates: secondDisplay)!
check(onSecond.rectInDisplayPointsTopLeftOrigin == CGRect(x: 100, y: 100, width: 200, height: 100), "offset display: rect is relative to that display")

// MARK: Clicking something Wisp drew

let clickDisplaySize = CGSize(width: 1440, height: 900)
let clickScreenshotSize = CGSize(width: 896, height: 560)
func overlayAnnotation(_ style: ScreenAnnotation.Style, _ region: CGRect, _ label: String? = nil) -> ScreenAnnotation {
    ScreenAnnotation(style: style, regionInScreenshotPixels: region, label: label, screenNumber: nil)
}
let clickNote = overlayAnnotation(.note, CGRect(x: 100, y: 300, width: 0, height: 0), "3x = 18")
let clickCircle = overlayAnnotation(.circle, CGRect(x: 60, y: 100, width: 80, height: 30))
let clickMarker = overlayAnnotation(.marker, CGRect(x: 500, y: 100, width: 0, height: 0))
let clickHighlight = overlayAnnotation(.highlight, CGRect(x: 10, y: 10, width: 300, height: 300))
let unplacedStep = overlayAnnotation(.box, .zero, "click Appearance")
check(AnnotationClickTarget.isClickable(clickNote) && AnnotationClickTarget.isClickable(clickCircle), "notes and circles are clickable")
check(!AnnotationClickTarget.isClickable(clickMarker) && !AnnotationClickTarget.isClickable(clickHighlight), "markers and highlights are not")
check(!AnnotationClickTarget.isClickable(unplacedStep), "an unplaced walkthrough step is not")

// The note starts at its anchor (100/896 of the width = 160.7pt) and is centred on its y (300/560 of the height = 482pt).
let noteRect = AnnotationClickTarget.clickableRectInOverlayCoordinates(for: clickNote, screenshotSize: clickScreenshotSize, displaySize: clickDisplaySize)
check(abs(noteRect.minX - 160.7) < 0.5 && abs(noteRect.midY - 482.1) < 0.5, "a note's clickable rect starts at its anchor, centred on y")
let shortNoteSize = AnnotationClickTarget.measuredNoteSize(forText: "x = 6")
let longNoteSize = AnnotationClickTarget.measuredNoteSize(forText: "subtract 7 from both sides of the equation")
check(noteRect.size == AnnotationClickTarget.measuredNoteSize(forText: "3x = 18"), "a note's clickable size is its measured text size")
check(longNoteSize.width > shortNoteSize.width * 2, "a longer note is measurably wider")
check(shortNoteSize.height >= 26 && shortNoteSize.height <= 44, "a one-line note is about one line tall")
check(AnnotationClickTarget.measuredNoteSize(forText: "iiii").width < AnnotationClickTarget.measuredNoteSize(forText: "mmmm").width, "widths follow the letters, not the count")

let overNote = AnnotationClickTarget.annotation(atOverlayPoint: CGPoint(x: 200, y: 482), in: [clickCircle, clickNote], screenshotSize: clickScreenshotSize, displaySize: clickDisplaySize)
check(overNote?.style == .note, "a point inside the note hits the note")
let overNothing = AnnotationClickTarget.annotation(atOverlayPoint: CGPoint(x: 900, y: 800), in: [clickCircle, clickNote], screenshotSize: clickScreenshotSize, displaySize: clickDisplaySize)
check(overNothing == nil, "a point on nothing hits nothing")
let overHighlightOnly = AnnotationClickTarget.annotation(atOverlayPoint: CGPoint(x: 100, y: 100), in: [clickHighlight], screenshotSize: clickScreenshotSize, displaySize: clickDisplaySize)
check(overHighlightOnly == nil, "a highlight is never a click target")

// A note anchored to an element sits to the right of it.
let elementNote = overlayAnnotation(.note, CGRect(x: 100, y: 200, width: 60, height: 20), "x = 6")
let elementNoteRect = AnnotationClickTarget.clickableRectInOverlayCoordinates(for: elementNote, screenshotSize: clickScreenshotSize, displaySize: clickDisplaySize)
check(elementNoteRect.minX > 160.7 + 96 && abs(elementNoteRect.midY - 337.5) < 0.5, "an element note is written right of the element, centred on it")

// Pointer position conversion and the resulting region.
let overlayPoint = AnnotationClickTarget.overlayPoint(forAppKitPoint: CGPoint(x: 1540, y: 1780), displayFrame: secondDisplay)
check(overlayPoint == CGPoint(x: 100, y: 200), "AppKit pointer position maps to overlay coordinates")
let clickedRegion = AnnotationClickTarget.focusedRegion(forClickedRectInOverlayCoordinates: CGRect(x: 100, y: 100, width: 40, height: 10), displayFrame: display)
check(clickedRegion != nil && clickedRegion!.rectInAppKitCoordinates.width == 68 && clickedRegion!.rectInAppKitCoordinates.height == 38, "a thin note is padded into a valid region")
check(clickedRegion!.rectInDisplayPointsTopLeftOrigin == CGRect(x: 86, y: 86, width: 68, height: 38), "the padded region lines up with the clicked note")

// MARK: Nudging overlapping notes apart

func noteAt(_ x: Double, _ y: Double, _ text: String) -> ScreenAnnotation {
    ScreenAnnotation(style: .note, regionInScreenshotPixels: CGRect(x: x, y: y, width: 0, height: 0), label: text, screenNumber: nil)
}
func overlayRect(_ annotation: ScreenAnnotation) -> CGRect {
    AnnotationClickTarget.clickableRectInOverlayCoordinates(for: annotation, screenshotSize: clickScreenshotSize, displaySize: clickDisplaySize)
}
let stackedNotes = [noteAt(100, 300, "subtract 7 from both sides"), noteAt(100, 302, "3x = 18"), noteAt(100, 304, "divide both sides by 3")]
let arrangedNotes = AnnotationNoteLayout.separatingOverlappingNotes(in: stackedNotes, screenshotSize: clickScreenshotSize, displaySize: clickDisplaySize)
let arrangedRects = arrangedNotes.map(overlayRect)
check(!arrangedRects[0].intersects(arrangedRects[1]) && !arrangedRects[1].intersects(arrangedRects[2]) && !arrangedRects[0].intersects(arrangedRects[2]), "stacked notes no longer overlap")
check(arrangedNotes[0] == stackedNotes[0], "the first note stays where the model put it")
check(arrangedNotes.map(\.label) == stackedNotes.map(\.label), "nudging keeps each note's text and order")
check(arrangedRects[1].minY > arrangedRects[0].maxY && arrangedRects[2].minY > arrangedRects[1].maxY, "later notes move down, in order")

let spacedNotes = [noteAt(100, 100, "one"), noteAt(100, 300, "two")]
check(AnnotationNoteLayout.separatingOverlappingNotes(in: spacedNotes, screenshotSize: clickScreenshotSize, displaySize: clickDisplaySize) == spacedNotes, "notes that don't overlap are left alone")

let circleUnderNote = [overlayAnnotation(.circle, CGRect(x: 90, y: 290, width: 120, height: 30)), noteAt(100, 300, "x = 6")]
let avoidedCircle = AnnotationNoteLayout.separatingOverlappingNotes(in: circleUnderNote, screenshotSize: clickScreenshotSize, displaySize: clickDisplaySize)
check(!overlayRect(avoidedCircle[1]).intersects(overlayRect(avoidedCircle[0])), "a note is moved off a circle")
check(avoidedCircle[0] == circleUnderNote[0], "circles never move")

let nearBottomNote = [noteAt(100, 555, "last"), noteAt(100, 556, "also last")]
let keptOnScreen = AnnotationNoteLayout.separatingOverlappingNotes(in: nearBottomNote, screenshotSize: clickScreenshotSize, displaySize: clickDisplaySize)
check(keptOnScreen.allSatisfy { overlayRect($0).maxY <= clickDisplaySize.height + 40 }, "a note that can't be moved down stays put rather than leaving the screen")

// Prompt text.
let prompt = nearTop.promptText(screenshotSize: screenshotSize, screenNumber: nil, hasCloseUpImage: true)
check(prompt.contains("90,56,269,112"), "prompt names the region's pixel corners")
check(prompt.contains("close-up"), "prompt mentions the close-up when there is one")
check(!prompt.contains("of screen"), "no screen number with a single display")
let twoScreenPrompt = nearTop.promptText(screenshotSize: screenshotSize, screenNumber: 2, hasCloseUpImage: false)
check(twoScreenPrompt.contains("of screen 2") && !twoScreenPrompt.contains("close-up"), "screen number shown; no close-up line without the image")

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
