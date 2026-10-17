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

// Prompt text.
let prompt = nearTop.promptText(screenshotSize: screenshotSize, screenNumber: nil, hasCloseUpImage: true)
check(prompt.contains("90,56,269,112"), "prompt names the region's pixel corners")
check(prompt.contains("close-up"), "prompt mentions the close-up when there is one")
check(!prompt.contains("of screen"), "no screen number with a single display")
let twoScreenPrompt = nearTop.promptText(screenshotSize: screenshotSize, screenNumber: 2, hasCloseUpImage: false)
check(twoScreenPrompt.contains("of screen 2") && !twoScreenPrompt.contains("close-up"), "screen number shown; no close-up line without the image")

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
