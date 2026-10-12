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

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
