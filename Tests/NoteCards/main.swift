//
//  Note cards suite: building a card from notes, placement, tether end points, lifecycle.
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

// A 1440x900 display, screenshot at the same size so pixels equal points.
let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
let screenshotSize = CGSize(width: 1440, height: 900)

func note(_ text: String?, at region: CGRect) -> ScreenAnnotation {
    ScreenAnnotation(style: .note, regionInScreenshotPixels: region, label: text, screenNumber: nil)
}
func circle(at region: CGRect) -> ScreenAnnotation {
    ScreenAnnotation(style: .circle, regionInScreenshotPixels: region, label: nil, screenNumber: nil)
}
func makeCard(stepCount: Int = 1, pinned: Bool = false, engaged: Bool = false) -> NoteCard {
    let notes = (0..<stepCount).map { note("step \($0)", at: CGRect(x: 100, y: 100 + $0 * 40, width: 0, height: 0)) }
    var card = NoteCardBuilder.card(fromAnnotations: notes, screenshotSize: screenshotSize, displayFrameInAppKitPoints: display)!
    card.isPinned = pinned
    card.hasBeenEngaged = engaged
    return card
}

// MARK: Building

check(NoteCardBuilder.card(fromAnnotations: [circle(at: CGRect(x: 10, y: 10, width: 50, height: 50))], screenshotSize: screenshotSize, displayFrameInAppKitPoints: display) == nil, "shapes alone make no card")
check(NoteCardBuilder.card(fromAnnotations: [note("  ", at: .zero), note(nil, at: .zero)], screenshotSize: screenshotSize, displayFrameInAppKitPoints: display) == nil, "blank notes make no card")

let built = NoteCardBuilder.card(
    fromAnnotations: [
        circle(at: CGRect(x: 200, y: 200, width: 100, height: 40)),
        note("  x = 6  ", at: CGRect(x: 320, y: 210, width: 0, height: 0)),
        note("so y = 12", at: CGRect(x: 320, y: 250, width: 0, height: 0))
    ],
    screenshotSize: screenshotSize,
    displayFrameInAppKitPoints: display
)!
check(built.steps.count == 2, "each note becomes a step")
check(built.steps.map(\.text) == ["x = 6", "so y = 12"], "steps keep order and are trimmed")
check(built.activeStepIndex == 0 && !built.isPinned && !built.hasBeenEngaged && !built.isDetached, "a new card is untouched")
check(built.explainedAreaInOverlayPoints == CGRect(x: 200, y: 200, width: 120, height: 50), "explained area merges shapes and note anchors")

// A smaller screenshot than the display scales anchors up.
let scaled = NoteCardBuilder.card(
    fromAnnotations: [note("hi", at: CGRect(x: 100, y: 50, width: 0, height: 0))],
    screenshotSize: CGSize(width: 720, height: 450),
    displayFrameInAppKitPoints: display
)!
check(scaled.steps[0].anchorRectInOverlayPoints.origin == CGPoint(x: 200, y: 100), "anchors scale from screenshot pixels to points")

// MARK: Geometry

let visible = CGRect(x: 0, y: 0, width: 1440, height: 860)
let cardSize = CGSize(width: 340, height: 200)
let area = CGRect(x: 400, y: 400, width: 100, height: 40)

let right = NoteCardGeometry.cardFrame(explainedAreaInAppKitPoints: area, cardSize: cardSize, visibleFrame: visible, occupiedFrames: [])
check(right.minX == 516 && right.midY == area.midY, "the card goes to the right of the area, centred on it")
check(!right.intersects(area), "the card never covers the explained area")

let nearRightEdge = CGRect(x: 1250, y: 400, width: 100, height: 40)
let flipped = NoteCardGeometry.cardFrame(explainedAreaInAppKitPoints: nearRightEdge, cardSize: cardSize, visibleFrame: visible, occupiedFrames: [])
check(flipped.maxX <= nearRightEdge.minX - NoteCardGeometry.gapFromExplainedArea + 0.5, "near the right edge the card flips to the left")

let nearTop = CGRect(x: 400, y: 840, width: 100, height: 20)
let nearTopFrame = NoteCardGeometry.cardFrame(explainedAreaInAppKitPoints: nearTop, cardSize: cardSize, visibleFrame: visible, occupiedFrames: [])
check(visible.contains(nearTopFrame), "a card beside an area at the top stays on screen")

let occupied = [right]
let avoiding = NoteCardGeometry.cardFrame(explainedAreaInAppKitPoints: area, cardSize: cardSize, visibleFrame: visible, occupiedFrames: occupied)
check(!avoiding.intersects(right), "a second card avoids the first when a clean spot exists")

let tinyScreen = CGRect(x: 0, y: 0, width: 360, height: 220)
let squeezed = NoteCardGeometry.cardFrame(explainedAreaInAppKitPoints: CGRect(x: 150, y: 100, width: 40, height: 20), cardSize: cardSize, visibleFrame: tinyScreen, occupiedFrames: [])
check(tinyScreen.contains(squeezed), "even with no good spot the card is clamped on screen")

let fullyBlocked = NoteCardGeometry.cardFrame(
    explainedAreaInAppKitPoints: area, cardSize: cardSize, visibleFrame: visible,
    occupiedFrames: [visible]
)
check(visible.contains(fullyBlocked), "when every spot is taken the card still lands on screen")

check(NoteCardGeometry.estimatedHeight(forStepTexts: ["a"]) >= 130, "a short note still gets a sensible minimum height")
check(NoteCardGeometry.estimatedHeight(forStepTexts: Array(repeating: String(repeating: "word ", count: 60), count: 10)) == 440, "a long explanation is capped")

let appKitRect = NoteCardGeometry.appKitRect(
    fromOverlayRect: CGRect(x: 100, y: 50, width: 200, height: 30),
    displayFrameInAppKitPoints: CGRect(x: 1440, y: 0, width: 1440, height: 900)
)
check(appKitRect == CGRect(x: 1540, y: 820, width: 200, height: 30), "overlay rect flips into AppKit space on a second display")

check(NoteCardGeometry.tetherEndPoint(anchorRect: CGRect(x: 100, y: 100, width: 200, height: 40), nearestTo: CGPoint(x: 500, y: 120)) == CGPoint(x: 300, y: 120), "the tether meets a wide element at its near edge")
check(NoteCardGeometry.tetherEndPoint(anchorRect: CGRect(x: 100, y: 100, width: 0, height: 0), nearestTo: CGPoint(x: 500, y: 500)) == CGPoint(x: 100, y: 100), "a point anchor is the point")
let askRect = NoteCardGeometry.askRegionRect(forAnchorRect: CGRect(x: 100, y: 100, width: 0, height: 0))
check(askRect.width >= 140 && askRect.height >= 80 && askRect.midX == 100 && askRect.midY == 100, "a point anchor grows to an askable region around it")
check(NoteCardGeometry.askRegionRect(forAnchorRect: CGRect(x: 0, y: 0, width: 400, height: 300)).size == CGSize(width: 400, height: 300), "a large anchor is left as it is")

// MARK: Lifecycle

let untouched = makeCard()
let engagedCard = makeCard(engaged: true)
let pinnedCard = makeCard(pinned: true)
let all = [untouched, engagedCard, pinnedCard]

check(NoteCardLifecycle.afterNewUtterance(all).map(\.id) == [engagedCard.id, pinnedCard.id], "a new question clears untouched cards only")
check(NoteCardLifecycle.afterEscape(all).map(\.id) == [pinnedCard.id], "Esc keeps pinned cards only")
let afterScroll = NoteCardLifecycle.afterContentScrolled(all)
check(afterScroll.map(\.id) == [engagedCard.id, pinnedCard.id], "scrolling drops untouched cards")
check(afterScroll.allSatisfy(\.isDetached), "scrolling detaches the cards that stay")

var evictionCards: [NoteCard] = []
var firstID: UUID?
for index in 0..<5 {
    let card = makeCard()
    if index == 0 { firstID = card.id }
    evictionCards = NoteCardLifecycle.adding(card, to: evictionCards).cards
}
check(evictionCards.count == NoteCardLifecycle.maximumCards, "the card count is capped")
check(!evictionCards.contains { $0.id == firstID }, "the oldest card is the one evicted")

let pinnedOldest = makeCard(pinned: true)
var withPinned = [pinnedOldest]
for _ in 0..<4 { withPinned = NoteCardLifecycle.adding(makeCard(), to: withPinned).cards }
check(withPinned.contains { $0.id == pinnedOldest.id }, "a pinned card is never evicted")
check(withPinned.count == NoteCardLifecycle.maximumCards, "eviction still holds the cap around a pinned card")

let allPinned = (0..<4).map { _ in makeCard(pinned: true) }
let overflow = NoteCardLifecycle.adding(makeCard(), to: allPinned)
check(overflow.cards.count == 5 && overflow.evictedIDs.isEmpty, "with every card pinned nothing is evicted")

check(NoteCardLifecycle.steppedIndex(from: 0, by: 1, stepCount: 3) == 1, "stepping forward moves on")
check(NoteCardLifecycle.steppedIndex(from: 2, by: 1, stepCount: 3) == 2, "stepping past the last stays on the last")
check(NoteCardLifecycle.steppedIndex(from: 0, by: -1, stepCount: 3) == 0, "stepping back from the first stays put")
check(NoteCardLifecycle.steppedIndex(from: 0, by: 1, stepCount: 0) == 0, "no steps is index zero")


// MARK: Thread

var threadCard = makeCard()
check(threadCard.thread.isEmpty && !threadCard.isAnswering, "a new card has no thread")
check(!threadCard.beginFollowUp(question: "   "), "a blank question is refused")
check(threadCard.beginFollowUp(question: "  why 4?  "), "a question starts a follow-up")
check(threadCard.thread.count == 2 && threadCard.thread[0].text == "why 4?" && threadCard.thread[0].role == .user, "the question is trimmed and filed as the user's")
check(threadCard.thread[1].role == .assistant && threadCard.thread[1].isStreaming && threadCard.isAnswering, "an empty streaming answer waits under it")
check(!threadCard.beginFollowUp(question: "and 5?"), "a second question waits while an answer is arriving")
threadCard.setStreamingReplyText("Because ")
threadCard.setStreamingReplyText("Because it is half.")
check(threadCard.thread[1].text == "Because it is half.", "the streaming text is replaced with what has arrived so far")
threadCard.finishReply(finalText: "Because it is half.")
check(!threadCard.isAnswering && !threadCard.thread[1].isStreaming, "finishing ends the streaming")
threadCard.setStreamingReplyText("late")
check(threadCard.thread[1].text == "Because it is half.", "text after the end is ignored")
check(threadCard.beginFollowUp(question: "and 5?"), "a new question is fine once the answer is done")
threadCard.failReply(message: "nope")
check(threadCard.thread.last?.isFailure == true && !threadCard.isAnswering, "a failed turn ends the answer and marks it")

var longThreadCard = makeCard()
for index in 0..<15 {
    longThreadCard.beginFollowUp(question: "q\(index)")
    longThreadCard.finishReply(finalText: "a\(index)")
}
check(longThreadCard.thread.count == NoteCard.maximumThreadMessages, "the thread is capped")
check(longThreadCard.thread.last?.text == "a14", "the cap drops the oldest, keeps the newest")

// MARK: Follow-up prompt

let promptCard = makeCard(stepCount: 2)
let prompt = NoteCardFollowUp.systemPrompt(for: promptCard)
check(prompt.contains("1. step 0") && prompt.contains("2. step 1"), "the prompt quotes numbered steps")
check(NoteCardFollowUp.systemPrompt(for: makeCard()).contains("step 0") && !NoteCardFollowUp.systemPrompt(for: makeCard()).contains("1. step 0"), "a single step is quoted without a number")
check(prompt.contains("never any square-bracket tags"), "the prompt forbids machine tags")

var historyCard = makeCard()
historyCard.beginFollowUp(question: "first?")
historyCard.finishReply(finalText: "first answer")
historyCard.beginFollowUp(question: "second?")
let historyNow = NoteCardFollowUp.history(from: historyCard)
check(historyNow.count == 2 && historyNow[0].text == "first?" && historyNow[1].text == "first answer", "history is the earlier exchange without the question being asked now")

var failedHistoryCard = makeCard()
failedHistoryCard.beginFollowUp(question: "broken?")
failedHistoryCard.failReply(message: "nope")
failedHistoryCard.beginFollowUp(question: "again?")
check(NoteCardFollowUp.history(from: failedHistoryCard).map(\.text) == ["broken?"], "a failed answer is left out of history")

var clippedHistoryCard = makeCard()
clippedHistoryCard.beginFollowUp(question: String(repeating: "x", count: 5000))
clippedHistoryCard.finishReply(finalText: "ok")
clippedHistoryCard.beginFollowUp(question: "next")
check(NoteCardFollowUp.history(from: clippedHistoryCard)[0].text.count == NoteCardFollowUp.maximumCharactersPerHistoryMessage, "long history messages are clipped")

var manyHistoryCard = makeCard()
for index in 0..<8 {
    manyHistoryCard.beginFollowUp(question: "q\(index)")
    manyHistoryCard.finishReply(finalText: "a\(index)")
}
manyHistoryCard.beginFollowUp(question: "now")
check(NoteCardFollowUp.history(from: manyHistoryCard).count == NoteCardFollowUp.maximumHistoryMessages, "history is limited to the last few messages")

check(NoteCardFollowUp.displayText(fromModelReply: "It is **half**. [SAY: half]") == "It is **half**.", "a finished tag is removed")
check(NoteCardFollowUp.displayText(fromModelReply: "It is half. [POI") == "It is half.", "a half-written tag is hidden while streaming")
check(NoteCardFollowUp.displayText(fromModelReply: "Use the array [0] index") == "Use the array [0] index", "ordinary brackets are kept")
check(NoteCardFollowUp.displayText(fromModelReply: "  hello \n") == "hello", "surrounding space is trimmed")


// MARK: Source annotations and tear-off

check(built.sourceAnnotations.count == 3 && built.screenshotSizeInPixels == screenshotSize, "a card keeps the annotations and screenshot size it was built from")
check(built.originalQuestion == nil, "the original question starts unset")

let tearable = NoteCardBuilder.card(
    fromAnnotations: [
        circle(at: CGRect(x: 200, y: 200, width: 100, height: 40)),
        note("one", at: CGRect(x: 320, y: 210, width: 0, height: 0)),
        note("two", at: CGRect(x: 320, y: 250, width: 0, height: 0)),
        note("three", at: CGRect(x: 320, y: 290, width: 0, height: 0))
    ],
    screenshotSize: screenshotSize,
    displayFrameInAppKitPoints: display
)!
check(makeCard(stepCount: 1).tearingOffStep(at: 0) == nil, "a single-step card can't be torn")
check(tearable.tearingOffStep(at: 5) == nil && tearable.tearingOffStep(at: -1) == nil, "an out-of-range step can't be torn")

var tearSource = tearable
tearSource.activeStepIndex = 2
tearSource.originalQuestion = "solve it"
tearSource.beginFollowUp(question: "why?")
let torn = tearSource.tearingOffStep(at: 1)!
check(torn.remaining.steps.map(\.text) == ["one", "three"], "the torn step leaves the original card")
check(torn.torn.steps.map(\.text) == ["two"], "the new card holds just that step")
check(torn.remaining.activeStepIndex == 1, "tearing off a step before the active one keeps the same step active")
check(torn.torn.id != tearSource.id, "the torn card is a new card")
check(torn.remaining.id == tearSource.id, "the original card keeps its identity")
check(torn.remaining.hasBeenEngaged && torn.torn.hasBeenEngaged, "both cards count as engaged afterwards")
check(!torn.torn.isPinned, "the new card isn't pinned")
check(torn.torn.thread.isEmpty && torn.remaining.thread.count == 2, "the thread stays with the original card")
check(torn.torn.originalQuestion == "solve it", "the new card remembers the original question")
check(torn.torn.sourceAnnotations.filter { $0.style == .note }.map(\.label) == ["two"], "the new card keeps only its own note")
check(torn.torn.sourceAnnotations.contains { $0.style == .circle }, "the new card keeps the shapes")
check(torn.remaining.sourceAnnotations.filter { $0.style == .note }.map(\.label) == ["one", "three"], "the original keeps its remaining notes")
check(torn.torn.explainedAreaInOverlayPoints == torn.torn.steps[0].anchorRectInOverlayPoints, "the new card is placed by its own step")

var tearActive = tearable
tearActive.activeStepIndex = 1
check(tearActive.tearingOffStep(at: 1)!.remaining.activeStepIndex == 1, "tearing off the active step moves on to the next one")
var tearLastActive = tearable
tearLastActive.activeStepIndex = 2
check(tearLastActive.tearingOffStep(at: 2)!.remaining.activeStepIndex == 1, "tearing off the last active step falls back to the new last")

// MARK: Chips and clipboard text

check(NoteCardFollowUp.Chip.allCases.count == 3, "there are three chips")
check(NoteCardFollowUp.Chip.allCases.allSatisfy { !$0.title.isEmpty && $0.question.hasSuffix(".") }, "every chip has a title and a sentence to ask")

var clipboardCard = tearable
check(NoteCardFollowUp.clipboardText(for: clipboardCard) == "1. one\n2. two\n3. three", "several steps are copied numbered")
check(NoteCardFollowUp.clipboardText(for: makeCard()) == "step 0", "a single step is copied bare")
clipboardCard.beginFollowUp(question: "why?")
clipboardCard.finishReply(finalText: "because")
clipboardCard.beginFollowUp(question: "and?")
clipboardCard.failReply(message: "nope")
check(NoteCardFollowUp.clipboardText(for: clipboardCard) == "1. one\n2. two\n3. three\n\nQ: why?\nA: because\nQ: and?", "the conversation follows the steps, minus failed answers")


// MARK: Display changes and streaming markdown

let displayA = CGRect(x: 0, y: 0, width: 1440, height: 900)
let displayB = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
func cardOn(_ frame: CGRect, engaged: Bool = false, pinned: Bool = false) -> NoteCard {
    var card = NoteCardBuilder.card(fromAnnotations: [note("hi", at: .zero)], screenshotSize: frame.size, displayFrameInAppKitPoints: frame)!
    card.hasBeenEngaged = engaged
    card.isPinned = pinned
    return card
}
let onA = cardOn(displayA), onBUntouched = cardOn(displayB), onBEngaged = cardOn(displayB, engaged: true), onBPinned = cardOn(displayB, pinned: true)
let afterUnplug = NoteCardLifecycle.afterDisplaysChanged([onA, onBUntouched, onBEngaged, onBPinned], availableDisplayFrames: [displayA])
check(afterUnplug.map(\.id) == [onA.id, onBEngaged.id, onBPinned.id], "cards on a vanished display: untouched ones go, kept ones stay")
check(afterUnplug[0].isDetached == false && afterUnplug[1].isDetached && afterUnplug[2].isDetached, "kept cards on a vanished display detach; the others are untouched")
check(NoteCardLifecycle.afterDisplaysChanged([onA, onBUntouched], availableDisplayFrames: [displayA, displayB]).count == 2, "nothing changes while every display is still there")
let resized = CGRect(x: 0, y: 0, width: 1728, height: 1117)
check(NoteCardLifecycle.afterDisplaysChanged([onA], availableDisplayFrames: [resized]).isEmpty, "a resolution change counts as the display going (untouched card dropped)")

check(NoteCardFollowUp.balancingInlineMarkdown("away from **") == "away from", "a dangling bold marker is removed")
check(NoteCardFollowUp.balancingInlineMarkdown("a **b** c") == "a **b** c", "matched bold is kept")
check(NoteCardFollowUp.balancingInlineMarkdown("a **b** and **c") == "a **b** and c", "only the unmatched marker goes")
check(NoteCardFollowUp.balancingInlineMarkdown("use `x") == "use x", "a dangling code tick is removed")
check(NoteCardFollowUp.balancingInlineMarkdown("use `x` now") == "use `x` now", "matched code is kept")
check(NoteCardFollowUp.displayText(fromModelReply: "it is **half") == "it is half", "streamed text with an open bold shows without the marker")

check(NoteCardFollowUp.spokenText(fromMarkdown: "Start with **2x + 4 = 16** and `x`") == "Start with 2x + 4 = 16 and x", "spoken text drops bold and code markers")
check(NoteCardFollowUp.spokenText(fromMarkdown: "plain words") == "plain words", "spoken text leaves plain words alone")

print("\(checkCount) checks, \(failureCount) failures")
exit(failureCount == 0 ? 0 : 1)
