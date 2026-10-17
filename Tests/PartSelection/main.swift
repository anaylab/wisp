//
//  Voice part-selection suite: the conservative spoken-target parser, list
//  marker detection and ordinals over realistic OCR line sets, ambiguity
//  resolving to nothing, and the screenshot-pixels -> FocusedScreenRegion
//  round trip.
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

// MARK: Parser

func parsed(_ transcript: String) -> PartSelectionRequest? {
    PartSelectionRequestParser.request(from: transcript)
}
let defaultResidual = PartSelectionRequestParser.defaultResidualQuestion

func expect(_ transcript: String, _ target: PartSelectionTarget, residual: String = defaultResidual) {
    let request = parsed(transcript)
    check(request?.target == target, "\"\(transcript)\" -> target \(String(describing: request?.target)), expected \(target)")
    check(request?.residualQuestion == residual, "\"\(transcript)\" -> residual \"\(request?.residualQuestion ?? "nil")\", expected \"\(residual)\"")
}
func expectNoMatch(_ transcript: String) {
    check(parsed(transcript) == nil, "\"\(transcript)\" must fall through to the model (got \(String(describing: parsed(transcript))))")
}

expect("ask about the third answer", .ordinalItem(position: .index(3), noun: .answer))
expect("Ask about the third answer.", .ordinalItem(position: .index(3), noun: .answer))
expect("hey wisp, ask about the second option", .ordinalItem(position: .index(2), noun: .option))
expect("explain option C", .labeledItem(label: "c", noun: .option))
expect("can you explain option see please", .labeledItem(label: "c", noun: .option))
expect("explain answer B", .labeledItem(label: "b", noun: .answer))
expect("tell me about step 2", .labeledItem(label: "2", noun: .step))
expect("tell me about step number two", .labeledItem(label: "2", noun: .step))
expect("explain the last answer", .ordinalItem(position: .last, noun: .answer))
expect("ask about the final bullet", .ordinalItem(position: .last, noun: .bullet))
expect("explain the 4th item", .ordinalItem(position: .index(4), noun: .item))
expect("look at line 3", .labeledItem(label: "3", noun: .line))
expect("explain the tenth row on the screen", .ordinalItem(position: .index(10), noun: .row))
expect("walk me through the first step", .ordinalItem(position: .index(1), noun: .step))
expect("ask about the third answer and tell me why it's wrong", .ordinalItem(position: .index(3), noun: .answer), residual: "tell me why it's wrong")
expect("explain option C then solve it", .labeledItem(label: "c", noun: .option), residual: "solve it")
expect("ask about step 2 is it correct", .labeledItem(label: "2", noun: .step), residual: "is it correct")
expect("what does the second line mean", .ordinalItem(position: .index(2), noun: .line), residual: "what does this part mean")
expect("what does option B say?", .labeledItem(label: "b", noun: .option), residual: "what does this part say")
expect("what is the third choice", .ordinalItem(position: .index(3), noun: .choice), residual: "what is this part")
expect("why is option D wrong", .labeledItem(label: "d", noun: .option), residual: "why is this part wrong")
expect("is the second answer correct?", .ordinalItem(position: .index(2), noun: .answer), residual: "is this part correct")
expect("tell me about \"x = 6\"", .onScreenText("x = 6"))
expect("explain the line \"x = 6\"", .onScreenText("x = 6"))
expect("ask about the equation “3x = 18” and show the steps", .onScreenText("3x = 18"), residual: "show the steps")
expect("explain the part that says total due", .onScreenText("total due"))
expect("ask about the text where it says net profit margin", .onScreenText("net profit margin"))

// False-positive guards: anything the parser isn't sure is a screen part goes
// to the model.
expectNoMatch("ask about the third quarter results")
expectNoMatch("explain the second law of thermodynamics")
expectNoMatch("tell me about the first world war")
expectNoMatch("explain the third step of photosynthesis")
expectNoMatch("tell me about step 2 of the recipe")
expectNoMatch("what is the first option for dinner")
expectNoMatch("explain option a question")
expectNoMatch("what does the second line of defense mean")
expectNoMatch("explain how DNS works")
expectNoMatch("tell me about swift concurrency")
expectNoMatch("ask about the answer")
expectNoMatch("explain the first one")
expectNoMatch("what is the third")
expectNoMatch("is this correct")
expectNoMatch("where is option C")
expectNoMatch("set a timer for three minutes")
expectNoMatch("explain third answers")
expectNoMatch("explain option z")
expectNoMatch("explain step 250")
expectNoMatch("")
expectNoMatch("explain")
expectNoMatch("the third answer")
expectNoMatch("explain the part that says")
expectNoMatch("text mom i'll be there in ten")

// MARK: Fixtures

var nextLineNumber = 0
func line(_ left: CGFloat, _ top: CGFloat, _ right: CGFloat, _ bottom: CGFloat, _ text: String, screen: Int = 1) -> ScreenTextSnapshotEntry {
    nextLineNumber += 1
    return ScreenTextSnapshotEntry(
        lineID: "t\(nextLineNumber)",
        text: text,
        boundingBoxInScreenshotPixels: CGRect(x: left, y: top, width: right - left, height: bottom - top),
        screenNumber: screen
    )
}
func resolvedRect(_ resolution: PartSelectionResolution) -> CGRect? {
    if case .resolved(let region) = resolution { return region.regionInScreenshotPixels }
    return nil
}

// A quiz: a title, one question, lettered options, a wrapped option, and chrome.
let quizEntries = [
    line(0, 0, 880, 14, "File Edit View Window Help"),
    line(60, 80, 520, 96, "Question 1. What is the capital of France?"),
    line(60, 130, 160, 144, "A) London"),
    line(60, 156, 200, 170, "B) Paris, the city on the"),
    line(78, 171, 190, 185, "Seine river"),
    line(60, 200, 170, 214, "C) Berlin"),
    line(60, 226, 175, 240, "D) Madrid"),
    line(60, 300, 300, 314, "Submit your answer before 5 pm"),
]

check(resolvedRect(PartSelectionResolver.resolve(.ordinalItem(position: .index(1), noun: .answer), in: quizEntries)) == CGRect(x: 60, y: 130, width: 100, height: 14), "first answer is the A) line")
check(resolvedRect(PartSelectionResolver.resolve(.ordinalItem(position: .index(3), noun: .answer), in: quizEntries)) == CGRect(x: 60, y: 200, width: 110, height: 14), "third answer is the C) line")
check(resolvedRect(PartSelectionResolver.resolve(.ordinalItem(position: .last, noun: .option), in: quizEntries)) == CGRect(x: 60, y: 226, width: 115, height: 14), "last option is D)")
// The wrapped second line belongs to B.
check(resolvedRect(PartSelectionResolver.resolve(.labeledItem(label: "b", noun: .option), in: quizEntries)) == CGRect(x: 60, y: 156, width: 140, height: 29), "option B includes its wrapped line")
check(resolvedRect(PartSelectionResolver.resolve(.ordinalItem(position: .index(2), noun: .choice), in: quizEntries)) == CGRect(x: 60, y: 156, width: 140, height: 29), "second choice includes its wrapped line")
// The last item must not swallow the unrelated line 60px below.
check(resolvedRect(PartSelectionResolver.resolve(.labeledItem(label: "d", noun: .answer), in: quizEntries))?.maxY == 240, "the last option stops before distant text")
check(PartSelectionResolver.resolve(.ordinalItem(position: .index(5), noun: .answer), in: quizEntries) == .notFound, "a fifth answer doesn't exist")
check(PartSelectionResolver.resolve(.labeledItem(label: "h", noun: .option), in: quizEntries) == .notFound, "option H doesn't exist")
check(PartSelectionResolver.resolve(.ordinalItem(position: .index(1), noun: .bullet), in: quizEntries) == .notFound, "no bullets on a quiz screen")
// "Question 1." alone is one number marker, not a list.
check(PartSelectionResolver.resolve(.ordinalItem(position: .index(1), noun: .step), in: quizEntries) == .notFound, "a lone Question 1 line is not a list of steps")

// Marker detection on single lines.
func markerKind(_ text: String) -> PartSelectionMarkerKind? {
    PartSelectionResolver.marker(for: line(0, 0, 50, 10, text))?.kind
}
func markerLabel(_ text: String) -> String? {
    PartSelectionResolver.marker(for: line(0, 0, 50, 10, text))?.label
}
check(markerKind("A) London") == .letter && markerLabel("A) London") == "a", "A) is a letter marker")
check(markerKind("(b) Paris") == .letter && markerLabel("(b) Paris") == "b", "(b) is a letter marker")
check(markerKind("C. Berlin") == .letter, "C. with a space is a letter marker")
check(markerKind("A") == .letter, "a bare uppercase A is a letter marker")
check(markerKind("e.g. the Seine") == nil, "e.g. is not a marker")
check(markerKind("A.I. is here") == nil, "A.I. is not a marker")
check(markerKind("a lot of people") == nil, "a lowercase article is not a marker")
check(markerKind("I") == nil, "I is not a marker")
check(markerKind("2. Divide both sides") == .number && markerLabel("2. Divide both sides") == "2", "2. is a number marker")
check(markerKind("3) Add") == .number, "3) is a number marker")
check(markerKind("2.5 million users") == nil, "2.5 million is not a marker")
check(markerKind("2024 was a year") == nil, "a year is not a marker")
check(markerKind("Step 3: Mix") == .step && markerLabel("Step 3: Mix") == "3", "Step 3 is a step marker")
check(markerKind("• Milk") == .bullet, "a bullet is a bullet marker")
check(markerKind("- Eggs") == .bullet, "a dash then space is a bullet marker")
check(markerKind("-5 degrees") == nil, "a negative number is not a bullet")

// A worked-solution screen: numbered steps, each wrapping onto a second line.
let stepEntries = [
    line(80, 60, 400, 76, "Solve 3x + 4 = 22"),
    line(80, 110, 340, 124, "1. Subtract 4 from both sides"),
    line(98, 126, 220, 140, "3x = 18"),
    line(80, 170, 340, 184, "2. Divide both sides by 3"),
    line(98, 186, 200, 200, "x = 6"),
    line(80, 230, 300, 244, "3. Check the answer"),
]
check(resolvedRect(PartSelectionResolver.resolve(.labeledItem(label: "2", noun: .step), in: stepEntries)) == CGRect(x: 80, y: 170, width: 260, height: 30), "step 2 spans its two lines")
check(resolvedRect(PartSelectionResolver.resolve(.ordinalItem(position: .index(1), noun: .step), in: stepEntries)) == CGRect(x: 80, y: 110, width: 260, height: 30), "first step spans its two lines")
check(resolvedRect(PartSelectionResolver.resolve(.ordinalItem(position: .index(3), noun: .line), in: stepEntries))?.minY == 230, "third line over a numbered list is item 3")
check(resolvedRect(PartSelectionResolver.resolve(.ordinalItem(position: .last, noun: .row), in: stepEntries))?.minY == 230, "last row is item 3")
// "answer" prefers letters, falls back to numbers when there are none.
check(resolvedRect(PartSelectionResolver.resolve(.ordinalItem(position: .index(2), noun: .answer), in: stepEntries))?.minY == 170, "answer falls back to a numbered list")
// On-screen text inside that screen.
check(resolvedRect(PartSelectionResolver.resolve(.onScreenText("x = 6"), in: stepEntries)) == CGRect(x: 98, y: 186, width: 102, height: 14), "x = 6 is found exactly")
check(resolvedRect(PartSelectionResolver.resolve(.onScreenText("X=6"), in: stepEntries)) == CGRect(x: 98, y: 186, width: 102, height: 14), "spacing and case don't matter")
check(resolvedRect(PartSelectionResolver.resolve(.onScreenText("3x = 18"), in: stepEntries)) == CGRect(x: 98, y: 126, width: 122, height: 14), "3x = 18 is not confused with x = 6")
check(PartSelectionResolver.resolve(.onScreenText("y = 99"), in: stepEntries) == .notFound, "absent text is not found")
check(resolvedRect(PartSelectionResolver.resolve(.onScreenText("divide both sides"), in: stepEntries))?.minY == 170, "text inside a longer line matches that line")
check(PartSelectionResolver.resolve(.onScreenText("both sides"), in: stepEntries) == .ambiguous, "text on two lines is ambiguous")
check(PartSelectionResolver.resolve(.onScreenText("x"), in: stepEntries) == .notFound, "a one-character target is refused")

// Bare letters on their own lines, answer text to the right (how Vision reads
// radio-button style choices).
let bareLetterEntries = [
    line(60, 100, 74, 114, "A"), line(90, 100, 200, 114, "Mercury"),
    line(60, 130, 74, 144, "B"), line(90, 130, 200, 144, "Venus"),
    line(60, 160, 74, 174, "C"), line(90, 160, 200, 174, "Earth"),
]
check(resolvedRect(PartSelectionResolver.resolve(.labeledItem(label: "c", noun: .option), in: bareLetterEntries)) == CGRect(x: 60, y: 160, width: 140, height: 14), "option C joins the bare letter and its answer text")
check(resolvedRect(PartSelectionResolver.resolve(.ordinalItem(position: .index(2), noun: .answer), in: bareLetterEntries)) == CGRect(x: 60, y: 130, width: 140, height: 14), "second answer joins the bare letter and its text")

// A row of options: A. 4   B. 6   C. 8
let rowEntries = [
    line(60, 100, 300, 114, "What is 2 + 2?"),
    line(60, 140, 110, 154, "A. 4"), line(180, 140, 230, 154, "B. 6"), line(300, 140, 350, 154, "C. 8"),
]
check(resolvedRect(PartSelectionResolver.resolve(.labeledItem(label: "b", noun: .option), in: rowEntries)) == CGRect(x: 180, y: 140, width: 50, height: 14), "option B in a row")
check(resolvedRect(PartSelectionResolver.resolve(.ordinalItem(position: .index(3), noun: .option), in: rowEntries)) == CGRect(x: 300, y: 140, width: 50, height: 14), "third option in a row counts left to right")

// Bullets.
let bulletEntries = [
    line(70, 100, 200, 114, "Shopping list"),
    line(70, 130, 160, 144, "• Milk"), line(70, 154, 160, 168, "• Eggs"), line(70, 178, 160, 192, "• Bread"),
]
check(resolvedRect(PartSelectionResolver.resolve(.ordinalItem(position: .index(2), noun: .bullet), in: bulletEntries))?.minY == 154, "second bullet is Eggs")
check(resolvedRect(PartSelectionResolver.resolve(.ordinalItem(position: .last, noun: .item), in: bulletEntries))?.minY == 178, "last item is Bread")
check(PartSelectionResolver.resolve(.ordinalItem(position: .index(1), noun: .answer), in: bulletEntries) != .notFound, "answer falls back to bullets when nothing else is a list")

// Ambiguity: two questions on one screen, each with A-D, must not guess.
let twoQuestionEntries = [
    line(60, 100, 300, 114, "1. First question"),
    line(80, 130, 160, 144, "A) one"), line(80, 154, 160, 168, "B) two"),
    line(60, 300, 300, 314, "2. Second question"),
    line(80, 330, 160, 344, "A) uno"), line(80, 354, 160, 368, "B) dos"),
]
check(PartSelectionResolver.resolve(.ordinalItem(position: .index(1), noun: .answer), in: twoQuestionEntries) == .ambiguous, "two lettered lists make an ordinal ambiguous")
check(PartSelectionResolver.resolve(.labeledItem(label: "a", noun: .option), in: twoQuestionEntries) == .ambiguous, "option A appearing twice is ambiguous")
// The two numbered headings are 200px apart: different lists of one, so no
// list of steps exists and "step 2" is not guessed.
check(PartSelectionResolver.resolve(.labeledItem(label: "2", noun: .step), in: twoQuestionEntries) == .notFound, "far-apart numbered headings are not a list of steps")
// Two side-by-side columns of bullets.
let twoColumnBullets = [
    line(60, 100, 150, 114, "• Red"), line(60, 124, 150, 138, "• Green"),
    line(400, 100, 490, 114, "• Cat"), line(400, 124, 490, 138, "• Dog"),
]
check(PartSelectionResolver.resolve(.ordinalItem(position: .index(1), noun: .bullet), in: twoColumnBullets) != .notFound
      && resolvedRect(PartSelectionResolver.resolve(.ordinalItem(position: .index(1), noun: .bullet), in: twoColumnBullets)) == nil,
      "two bullet columns: the first bullet is ambiguous, not a guess")
// Out-of-order letters aren't a list (A, C, B).
let scrambled = [line(60, 100, 150, 114, "C) x"), line(60, 124, 150, 138, "A) y"), line(60, 148, 150, 162, "B) z")]
check(PartSelectionResolver.resolve(.ordinalItem(position: .index(1), noun: .answer), in: scrambled) == .notFound, "letters out of order are not a list")
// A second display: lists on different screens are different lists.
let twoScreenEntries = [
    line(60, 100, 150, 114, "A) a", screen: 1), line(60, 124, 150, 138, "B) b", screen: 1),
    line(60, 100, 150, 114, "A) a", screen: 2), line(60, 124, 150, 138, "B) b", screen: 2),
]
check(PartSelectionResolver.resolve(.labeledItem(label: "b", noun: .option), in: twoScreenEntries) == .ambiguous, "the same list on two screens is ambiguous")
let secondScreenOnly = [
    line(10, 10, 100, 24, "nothing here", screen: 1),
    line(60, 100, 150, 114, "A) a", screen: 2), line(60, 124, 150, 138, "B) b", screen: 2),
]
if case .resolved(let region) = PartSelectionResolver.resolve(.labeledItem(label: "b", noun: .option), in: secondScreenOnly) {
    check(region.screenNumber == 2, "a list on screen 2 resolves with screen number 2")
} else {
    check(false, "a list on screen 2 resolves")
}
check(PartSelectionResolver.resolve(.ordinalItem(position: .index(1), noun: .answer), in: []) == .notFound, "no OCR lines: nothing to resolve")

// MARK: Pixels -> FocusedScreenRegion round trip

let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
let screenshotSize = CGSize(width: 896, height: 560)

let draggedRegion = FocusedScreenRegion(
    rectInAppKitCoordinates: CGRect(x: 144, y: 720, width: 288, height: 90),
    displayFrameInAppKitCoordinates: display
)!
let draggedPixels = draggedRegion.regionInScreenshotPixels(screenshotSize: screenshotSize)
let roundTripped = FocusedScreenRegion(
    regionInScreenshotPixels: draggedPixels,
    screenshotSize: screenshotSize,
    displayFrameInAppKitCoordinates: display
)!
check(abs(roundTripped.rectInAppKitCoordinates.minX - 144) <= 2 && abs(roundTripped.rectInAppKitCoordinates.minY - 720) <= 2
      && abs(roundTripped.rectInAppKitCoordinates.width - 288) <= 2 && abs(roundTripped.rectInAppKitCoordinates.height - 90) <= 2,
      "pixels -> region inverts region -> pixels within rounding (got \(roundTripped.rectInAppKitCoordinates))")
check(roundTripped.displayFrameInAppKitCoordinates == display, "the round trip stays on the same display")

// Near the top of the screenshot is near the top of AppKit's frame.
let topLine = FocusedScreenRegion(regionInScreenshotPixels: CGRect(x: 100, y: 0, width: 200, height: 40), screenshotSize: screenshotSize, displayFrameInAppKitCoordinates: display)!
check(topLine.rectInAppKitCoordinates.maxY == 900, "a line at the top of the screenshot touches the top of the display")

// A short OCR line (14px = ~22pt) is grown to the 24pt minimum; padding grows it more.
let shortLine = CGRect(x: 60, y: 130, width: 100, height: 14)
let unpadded = FocusedScreenRegion(regionInScreenshotPixels: shortLine, screenshotSize: screenshotSize, displayFrameInAppKitCoordinates: display)!
check(unpadded.rectInAppKitCoordinates.height >= FocusedScreenRegion.minimumSideLengthInPoints, "a short line grows to the minimum selection height")
check(abs(unpadded.rectInAppKitCoordinates.midX - shortLine.midX * 1440 / 896) < 1, "growth is about the line's centre horizontally")
let paddedRegion = FocusedScreenRegion(regionInScreenshotPixels: shortLine, screenshotSize: screenshotSize, displayFrameInAppKitCoordinates: display, paddingInPoints: 6)!
check(paddedRegion.rectInAppKitCoordinates.width > unpadded.rectInAppKitCoordinates.width, "padding widens the region")
// And the padded region still covers the line when converted back.
let paddedPixels = paddedRegion.regionInScreenshotPixels(screenshotSize: screenshotSize)
check(paddedPixels.contains(shortLine), "the padded region contains the original line in screenshot pixels")

// A second display above and to the right of the primary.
let secondDisplay = CGRect(x: 1440, y: 900, width: 1920, height: 1080)
let secondScreenshotSize = CGSize(width: 896, height: 504)
let onSecond = FocusedScreenRegion(regionInScreenshotPixels: CGRect(x: 100, y: 50, width: 200, height: 60), screenshotSize: secondScreenshotSize, displayFrameInAppKitCoordinates: secondDisplay)!
check(secondDisplay.contains(onSecond.rectInAppKitCoordinates), "a region on a second display lies within that display")
let backOnSecond = onSecond.regionInScreenshotPixels(screenshotSize: secondScreenshotSize)
check(abs(backOnSecond.minX - 100) <= 1 && abs(backOnSecond.minY - 50) <= 1, "second display round trip returns the same pixels")

// Rejects bad input.
check(FocusedScreenRegion(regionInScreenshotPixels: CGRect(x: 0, y: 0, width: 10, height: 10), screenshotSize: .zero, displayFrameInAppKitCoordinates: display) == nil, "a zero screenshot size is rejected")
check(FocusedScreenRegion(regionInScreenshotPixels: CGRect(x: 5000, y: 5000, width: 10, height: 10), screenshotSize: screenshotSize, displayFrameInAppKitCoordinates: display) == nil, "a region off the display is rejected")

print("\(checkCount) checks, \(failureCount) failed")
if failureCount > 0 { exit(1) }
print("PASS")
