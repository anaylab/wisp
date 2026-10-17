//
//  Guided walkthrough suite: plan building and stepping, turning an
//  instruction into a label to find, and whether a click lands on a target.
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

func stepAnnotation(_ stepNumber: Int?, _ label: String?) -> ScreenAnnotation {
    ScreenAnnotation(
        style: .box,
        regionInScreenshotPixels: CGRect(x: 10, y: 10, width: 40, height: 20),
        label: label,
        screenNumber: nil,
        stepNumber: stepNumber
    )
}

// MARK: Plan

check(GuidedWalkthroughPlan(annotations: []) == nil, "no annotations → no plan")
check(GuidedWalkthroughPlan(annotations: [stepAnnotation(1, "click export")]) == nil, "one step is a pointer, not a walkthrough")
check(GuidedWalkthroughPlan(annotations: [stepAnnotation(nil, "a"), stepAnnotation(nil, "b")]) == nil, "unnumbered annotations are not steps")
check(GuidedWalkthroughPlan(annotations: [stepAnnotation(1, "click export"), stepAnnotation(2, nil)]) == nil, "a step with no words doesn't count")

var plan = GuidedWalkthroughPlan(annotations: [
    stepAnnotation(2, "then pick dark"),
    stepAnnotation(1, "open appearance"),
    stepAnnotation(3, "close settings"),
])!
check(plan.steps.map(\.instruction) == ["open appearance", "then pick dark", "close settings"], "steps ordered by number")
check(plan.currentStepIndex == 0, "starts on the first step")
check(!plan.isFinished, "not finished at the start")

plan.completeCurrentStep()
check(plan.steps[0].status == .done && plan.currentStepIndex == 1, "completing advances")
plan.skipCurrentStep()
check(plan.steps[1].status == .skipped && plan.currentStepIndex == 2, "skipping advances without credit")
check(plan.completedStepCount == 1, "a skipped step is not counted done")
plan.completeCurrentStep()
check(plan.isFinished && plan.currentStep == nil, "finished after the last step")
plan.completeCurrentStep()
check(plan.isFinished && plan.completedStepCount == 2, "stepping past the end changes nothing")

// MARK: [STEP:] tags

let stepReply = ScreenAnnotationParser.parse("Open Appearance, then pick Dark. [STEP:click Appearance] [STEP:then pick Dark]")
check(stepReply.spokenText == "Open Appearance, then pick Dark.", "step tags are stripped from speech")
check(stepReply.annotations.map(\.label) == ["click Appearance", "then pick Dark"], "step labels in order")
check(stepReply.annotations.allSatisfy(\.isUnplacedWalkthroughStep), "steps carry no position")
check(stepReply.annotations.map(\.stepNumber) == [1, 2], "two steps are numbered")
check(GuidedWalkthroughPlan(annotations: stepReply.annotations) != nil, "step tags make a plan")
let loneStep = ScreenAnnotationParser.parse("Click it. [STEP:click Appearance]")
check(loneStep.annotations.count == 1 && loneStep.annotations[0].stepNumber == nil, "a lone step isn't numbered")
check(GuidedWalkthroughPlan(annotations: loneStep.annotations) == nil, "a lone step is no walkthrough")
let boxReply = ScreenAnnotationParser.parse("[BOX:10,10,50,40:save]")
check(!boxReply.annotations[0].isUnplacedWalkthroughStep, "a real box is placed")

// MARK: [CIRCLE:] and [NOTE:] tags

let workedReply = ScreenAnnotationParser.parse(
    "Let's balance it. [NOTE:300,200:235 + 1 = 236] [NOTE:t4:top right: 141 + 3 = 144] [CIRCLE:10,10,50,40] [CIRCLE:t5] [NOTE:t99:ghost]",
    accessibilityElementRegionResolver: { elementID in
        switch elementID {
        case "t4": return AccessibilityElementResolvedRegion(regionInScreenshotPixels: CGRect(x: 100, y: 120, width: 60, height: 20), screenNumber: 1)
        case "t5": return AccessibilityElementResolvedRegion(regionInScreenshotPixels: CGRect(x: 100, y: 160, width: 60, height: 20), screenNumber: 1)
        default: return nil
        }
    }
)
check(workedReply.spokenText == "Let's balance it.", "note and circle tags are stripped from speech")
check(workedReply.annotations.map(\.style) == [.note, .note, .circle, .circle], "notes and circles parse in order; unknown id note draws nothing")
check(workedReply.annotations[0].label == "235 + 1 = 236" && workedReply.annotations[0].regionInScreenshotPixels == CGRect(x: 300, y: 200, width: 0, height: 0), "coordinate note keeps its text and anchor")
check(workedReply.annotations[1].label == "top right: 141 + 3 = 144", "note text may contain colons")
check(workedReply.annotations[1].regionInScreenshotPixels.width == 60, "element note keeps the element frame")
check(workedReply.annotations.allSatisfy { $0.stepNumber == nil }, "notes and circles are never numbered steps")
check(GuidedWalkthroughPlan(annotations: workedReply.annotations) == nil, "notes and circles make no walkthrough")

let manyNotes = ScreenAnnotationParser.parse((1...15).map { "[NOTE:10,\($0 * 10):line \($0)]" }.joined())
check(manyNotes.annotations.count == 12, "notes are capped at twelve")

let boxesAndNote = ScreenAnnotationParser.parse("[BOX:10,10,50,40:a] [NOTE:60,20:hi] [BOX:10,60,50,90:b]")
check(boxesAndNote.annotations.map(\.stepNumber) == [1, nil, 2], "a note between boxes doesn't take a step number")

// MARK: Prompt sections

let teachingPrompt = ScreenAnnotationParser.promptInstructions(includingTeaching: true)
let plainPrompt = ScreenAnnotationParser.promptInstructions(includingTeaching: false)
check(teachingPrompt.contains("[NOTE:") && teachingPrompt.contains("[CIRCLE:"), "the teaching prompt names notes and circles")
check(!plainPrompt.contains("[NOTE:") && !plainPrompt.contains("[CIRCLE:") && !plainPrompt.contains("teaching math"), "the plain prompt leaves the teaching section out")
check(plainPrompt.contains("[BOX:") && plainPrompt.contains("[STEP:label]") && plainPrompt.contains("[POINT:a12:label]"), "the plain prompt keeps boxes, steps and pointing")
check(plainPrompt.count < teachingPrompt.count - 800, "the teaching section is a real saving for the local model")
check(ScreenAnnotationParser.promptInstructions == teachingPrompt, "the default prompt is the full one")

// MARK: Target text

func target(_ instruction: String) -> (String, String?) {
    let request = GuidedWalkthroughTargetText.pointingRequest(forInstruction: instruction)
    return (request.targetText, request.roleHint)
}

check(target("click export") == ("export", nil), "leading verb stripped")
check(target("then choose PDF") == ("pdf", nil), "then + verb stripped, lowercased")
check(target("Open Appearance in the sidebar") == ("appearance", nil), "location clause dropped")
check(target("click the Export button") == ("export", "button"), "role word becomes the hint")
check(target("turn on Dark Mode") == ("dark mode", nil), "multi-word label kept")
check(target("click") == ("click", nil), "nothing left → the whole instruction")
check(target("Privacy & Security") == ("privacy & security", nil), "plain label untouched")

// MARK: Click matching

// A 1440×900-point display at the origin, screenshotted at 896 px wide
// (scale 0.6222 on both axes, so 560 px tall).
let displayFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
let screenshotSize = CGSize(width: 896, height: 560)
// The box sits at screenshot (100, 100)–(200, 140), i.e. points
// x 160.7…321.4, y(top-left) 160.7…225.

func clickLands(_ x: CGFloat, topLeftY: CGFloat, region: CGRect) -> Bool {
    GuidedWalkthroughClickMatcher.clickLandsOnRegion(
        clickLocationInAppKitGlobalPoints: CGPoint(x: x, y: displayFrame.maxY - topLeftY),
        displayFrameInAppKitCoordinates: displayFrame,
        screenshotSize: screenshotSize,
        regionInScreenshotPixels: region
    )
}

let box = CGRect(x: 100, y: 100, width: 100, height: 40)
check(clickLands(240, topLeftY: 190, region: box), "click in the middle of the box")
check(clickLands(158, topLeftY: 190, region: box), "click just outside the left edge is within the slop")
check(!clickLands(100, topLeftY: 190, region: box), "click well left of the box misses")
check(!clickLands(240, topLeftY: 700, region: box), "click far below misses (y is flipped correctly)")
check(!clickLands(240, topLeftY: 900 - 190, region: box), "a click at the mirrored height misses")

let pointMarker = CGRect(x: 150, y: 120, width: 0, height: 0)
check(clickLands(241, topLeftY: 193, region: pointMarker), "click on a point marker")
check(clickLands(260, topLeftY: 193, region: pointMarker), "a point marker has a generous reach")
check(!clickLands(400, topLeftY: 193, region: pointMarker), "far from a point marker misses")

// A second display to the right of the first, clicks on the first don't count.
let secondDisplay = CGRect(x: 1440, y: 0, width: 1440, height: 900)
check(!GuidedWalkthroughClickMatcher.clickLandsOnRegion(
    clickLocationInAppKitGlobalPoints: CGPoint(x: 240, y: 710),
    displayFrameInAppKitCoordinates: secondDisplay,
    screenshotSize: screenshotSize,
    regionInScreenshotPixels: box
), "a click on another display doesn't count")
check(GuidedWalkthroughClickMatcher.clickLandsOnRegion(
    clickLocationInAppKitGlobalPoints: CGPoint(x: 1440 + 240, y: 710),
    displayFrameInAppKitCoordinates: secondDisplay,
    screenshotSize: screenshotSize,
    regionInScreenshotPixels: box
), "the same position on the target display counts")

// MARK: Auto-click point

// Same 1440×900 display, region centre at screenshot (150, 120).
let autoClickRegion = CGRect(x: 100, y: 100, width: 100, height: 40)
let autoClickPoint = GuidedWalkthroughAutoClickPoint.quartzGlobalPoint(
    displayFrameInAppKitCoordinates: displayFrame,
    screenshotSize: screenshotSize,
    regionInScreenshotPixels: autoClickRegion,
    primaryDisplayHeight: 900
)!
check(abs(autoClickPoint.x - 241.07) < 0.1 && abs(autoClickPoint.y - 192.86) < 0.1, "centre of the box in Quartz points")
// A display to the right of and above the primary (primary is 900 tall):
// AppKit frame x 1440…2880, y 900…1800.
let displayAbovePrimary = CGRect(x: 1440, y: 900, width: 1440, height: 900)
let pointOnUpperDisplay = GuidedWalkthroughAutoClickPoint.quartzGlobalPoint(
    displayFrameInAppKitCoordinates: displayAbovePrimary,
    screenshotSize: screenshotSize,
    regionInScreenshotPixels: autoClickRegion,
    primaryDisplayHeight: 900
)!
check(abs(pointOnUpperDisplay.x - (1440 + 241.07)) < 0.1 && abs(pointOnUpperDisplay.y - (192.86 - 900)) < 0.1, "a display above the primary has negative Quartz y")
// The click point must land back on the region under the click test.
check(clickLands(autoClickPoint.x, topLeftY: autoClickPoint.y, region: autoClickRegion), "the auto-click point passes the click test")

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
