//
//  ScreenTextRecognitionTests.swift
//  leanring-buddyTests
//
//  Proves the pure parts of on-device OCR: reading order, confidence
//  filtering, the prompt-size caps, the compact rendering the model is shown,
//  the `t7` id tag forms and their resolution to a line's box, the Vision
//  coordinate flip, and the byte-keyed recognition cache. None of it runs
//  Vision, so none of it depends on what is on the test machine's screen.
//

import Vision
import XCTest
@testable import Wisp

@MainActor
final class ScreenTextRecognitionTests: XCTestCase {

    // MARK: - Fixtures

    private func makeLine(
        _ text: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat = 80,
        height: CGFloat = 12,
        confidence: Float = 1.0
    ) -> RecognizedScreenTextLine {
        RecognizedScreenTextLine(
            text: text,
            confidence: confidence,
            boundingBoxInScreenshotPixels: CGRect(x: x, y: y, width: width, height: height)
        )
    }

    private func makeResult(_ lines: [RecognizedScreenTextLine]) -> ScreenTextRecognitionResult {
        ScreenTextRecognitionResult(lines: lines, recognitionDurationSeconds: 0.1)
    }

    // MARK: - Reading order

    func testLinesAreOrderedTopToBottomThenLeftToRightWithinARow() {
        let orderedLines = ScreenTextSnapshot.linesInReadingOrder([
            makeLine("second paragraph", x: 10, y: 100),
            // Same visual row as "File", a pixel lower — must still sort by x.
            makeLine("Edit", x: 60, y: 11),
            makeLine("File", x: 10, y: 10),
            makeLine("View", x: 110, y: 9),
            makeLine("first paragraph", x: 10, y: 50),
        ])

        XCTAssertEqual(orderedLines.map(\.text), ["File", "Edit", "View", "first paragraph", "second paragraph"])
    }

    // MARK: - Building: filtering, ids, caps

    func testBuildDropsLowConfidenceAndSymbolOnlyLinesAndAssignsSequentialIds() {
        let snapshot = ScreenTextSnapshot.build(fromPerScreenResults: [
            makeResult([
                makeLine("Save", x: 10, y: 10),
                makeLine("blurry", x: 10, y: 30, confidence: 0.3),
                makeLine("•  ›", x: 10, y: 50),
                makeLine("Cancel   now", x: 10, y: 70),
            ])
        ])

        XCTAssertEqual(snapshot.entries.map(\.lineID), ["t1", "t2"])
        XCTAssertEqual(snapshot.entries.map(\.text), ["Save", "Cancel now"])
        XCTAssertEqual(snapshot.contributingScreenCount, 1)
    }

    func testBuildCapsLineCountInReadingOrder() {
        let manyLines = (0..<100).map { lineIndex in
            makeLine("line \(lineIndex)", x: 10, y: CGFloat(lineIndex) * 20)
        }
        let snapshot = ScreenTextSnapshot.build(fromPerScreenResults: [makeResult(manyLines.reversed())])

        XCTAssertEqual(snapshot.entries.count, ScreenTextSnapshot.maximumPromptLineCount)
        XCTAssertEqual(snapshot.entries.first?.text, "line 0")
        XCTAssertEqual(snapshot.entries.last?.lineID, "t\(ScreenTextSnapshot.maximumPromptLineCount)")
    }

    func testBuildCapsTotalCharactersAndTruncatesLongLines() {
        let longText = String(repeating: "x", count: 500)
        let snapshot = ScreenTextSnapshot.build(
            fromPerScreenResults: [makeResult([
                makeLine(longText, x: 10, y: 10),
                makeLine("short", x: 10, y: 40),
                makeLine("dropped", x: 10, y: 70),
            ])],
            maximumLineCount: 10,
            maximumCharacterCount: ScreenTextSnapshot.maximumLineCharacterCount + 5
        )

        XCTAssertEqual(snapshot.entries.count, 2)
        XCTAssertEqual(snapshot.entries[0].text.count, ScreenTextSnapshot.maximumLineCharacterCount)
        XCTAssertTrue(snapshot.entries[0].text.hasSuffix("…"))
        XCTAssertEqual(snapshot.entries[1].text, "short")
    }

    func testBuildNumbersScreensByPositionAndSkipsUnfinishedOnes() {
        let snapshot = ScreenTextSnapshot.build(fromPerScreenResults: [
            makeResult([makeLine("cursor screen", x: 10, y: 10)]),
            nil,
            makeResult([makeLine("third screen", x: 10, y: 10)]),
        ])

        XCTAssertEqual(snapshot.entries.map(\.screenNumber), [1, 3])
        XCTAssertEqual(snapshot.entries.map(\.lineID), ["t1", "t2"])
        XCTAssertEqual(snapshot.contributingScreenCount, 2)
    }

    // MARK: - Rendering

    func testPromptTextListsIdBoxAndSanitizedTextAndTeachesTheIdTag() {
        let snapshot = ScreenTextSnapshot.build(fromPerScreenResults: [
            makeResult([
                makeLine("Error: file \"a.txt\" [missing]", x: 12.4, y: 40, width: 197.8, height: 18)
            ])
        ])

        let promptLines = snapshot.promptText().components(separatedBy: "\n")

        XCTAssertEqual(promptLines.count, 3)
        XCTAssertTrue(promptLines[0].hasPrefix("text on screen, read by on-device OCR"))
        XCTAssertEqual(promptLines[1], "t1 12,40,210,58 \"Error: file 'a.txt' (missing)\"")
        XCTAssertTrue(promptLines[2].contains("[POINT:t3:label]"))
    }

    func testPromptTextAddsScreenHeadersOnlyWithSeveralScreens() {
        let singleScreenSnapshot = ScreenTextSnapshot.build(fromPerScreenResults: [
            makeResult([makeLine("only", x: 0, y: 0)])
        ])
        XCTAssertFalse(singleScreenSnapshot.promptText().contains("screen 1:"))

        let twoScreenSnapshot = ScreenTextSnapshot.build(fromPerScreenResults: [
            makeResult([makeLine("left", x: 0, y: 0)]),
            makeResult([makeLine("right", x: 0, y: 0)]),
        ])
        let twoScreenPromptText = twoScreenSnapshot.promptText()
        XCTAssertTrue(twoScreenPromptText.contains("screen 1:\nt1 "))
        XCTAssertTrue(twoScreenPromptText.contains("screen 2:\nt2 "))
        XCTAssertEqual(twoScreenSnapshot.plainText(), "— screen 1 —\nleft\n\n— screen 2 —\nright")
    }

    func testEmptySnapshotRendersNothingAndContextFallsBackToAccessibilityText() {
        let emptySnapshot = ScreenTextSnapshot.build(fromPerScreenResults: [makeResult([])])
        XCTAssertEqual(emptySnapshot.promptText(), "")

        XCTAssertEqual(
            ScreenTextSnapshot.screenContextPromptText(accessibilityElementPromptText: "ax list", screenTextSnapshot: nil),
            "ax list"
        )
        XCTAssertEqual(
            ScreenTextSnapshot.screenContextPromptText(accessibilityElementPromptText: "", screenTextSnapshot: emptySnapshot),
            ""
        )

        let snapshot = ScreenTextSnapshot.build(fromPerScreenResults: [makeResult([makeLine("hi", x: 0, y: 0)])])
        let combinedText = ScreenTextSnapshot.screenContextPromptText(
            accessibilityElementPromptText: "ax list",
            screenTextSnapshot: snapshot
        )
        XCTAssertTrue(combinedText.hasPrefix("ax list\n\ntext on screen"))
    }

    // MARK: - Geometry

    func testVisionLowerLeftNormalizedRectBecomesTopLeftScreenshotPixels() {
        let screenshotRect = ScreenTextSnapshot.screenshotRect(
            fromNormalizedLowerLeftOriginRect: CGRect(x: 0.25, y: 0.75, width: 0.5, height: 0.125),
            screenshotSizeInPixels: CGSize(width: 800, height: 400)
        )
        XCTAssertEqual(screenshotRect, CGRect(x: 200, y: 50, width: 400, height: 50))
    }

    func testMinimumTextHeightFractionNeverExceedsVisionDefault() {
        XCTAssertEqual(ScreenTextRecognizer.minimumTextHeightFraction(forImageHeightInPixels: 500), 0.01, accuracy: 0.0001)
        XCTAssertEqual(ScreenTextRecognizer.minimumTextHeightFraction(forImageHeightInPixels: 50), 1.0 / 32.0, accuracy: 0.0001)
        XCTAssertEqual(ScreenTextRecognizer.recognitionLevel(forImagePixelCount: 896 * 582), .accurate)
        XCTAssertEqual(ScreenTextRecognizer.recognitionLevel(forImagePixelCount: 3024 * 1964), .fast)
    }

    // MARK: - [POINT:t7] parsing and resolution

    func testPointTagWithOcrLineIdParsesThroughTheIdPath() {
        let parseResult = CompanionManager.parsePointingCoordinates(from: "that's the error. [POINT:T7:error line]")
        XCTAssertEqual(parseResult.spokenText, "that's the error.")
        XCTAssertEqual(parseResult.accessibilityElementID, "t7")
        XCTAssertEqual(parseResult.elementLabel, "error line")
        XCTAssertNil(parseResult.coordinate)
    }

    func testOcrLineIdsResolveToTheLineBoxAndScreen() {
        let snapshot = ScreenTextSnapshot.build(fromPerScreenResults: [
            makeResult([makeLine("first", x: 0, y: 0)]),
            makeResult([makeLine("Build failed", x: 100, y: 200, width: 60, height: 20)]),
        ])

        let resolvedRegion = CompanionManager.resolveScreenElementRegion(
            elementID: "T2",
            accessibilityElementSnapshot: nil,
            screenTextSnapshot: snapshot,
            screenCaptures: []
        )
        XCTAssertEqual(resolvedRegion?.regionInScreenshotPixels, CGRect(x: 100, y: 200, width: 60, height: 20))
        XCTAssertEqual(resolvedRegion?.screenNumber, 2)
        XCTAssertEqual(resolvedRegion?.centerPointRegionInScreenshotPixels, CGRect(x: 130, y: 210, width: 0, height: 0))

        XCTAssertNil(CompanionManager.resolveScreenElementRegion(
            elementID: "t9",
            accessibilityElementSnapshot: nil,
            screenTextSnapshot: snapshot,
            screenCaptures: []
        ))
        XCTAssertNil(CompanionManager.resolveScreenElementRegion(
            elementID: "t1",
            accessibilityElementSnapshot: nil,
            screenTextSnapshot: nil,
            screenCaptures: []
        ))
    }

    func testOcrIdAnnotationTagsResolveThroughTheSharedResolver() {
        let snapshot = ScreenTextSnapshot.build(fromPerScreenResults: [
            makeResult([makeLine("Save changes", x: 40, y: 60, width: 100, height: 20)])
        ])
        let parseResult = ScreenAnnotationParser.parse(
            "here [BOX:t1:save] and [ARROW:t1:save]",
            accessibilityElementRegionResolver: { elementID in
                snapshot.resolvedRegion(forLineID: elementID)
            }
        )

        XCTAssertEqual(parseResult.spokenText, "here  and")
        XCTAssertEqual(parseResult.annotations.count, 2)
        XCTAssertEqual(parseResult.annotations[0].style, .box)
        XCTAssertEqual(parseResult.annotations[0].regionInScreenshotPixels, CGRect(x: 40, y: 60, width: 100, height: 20))
        XCTAssertEqual(parseResult.annotations[1].style, .arrow)
        XCTAssertEqual(parseResult.annotations[1].regionInScreenshotPixels, CGRect(x: 90, y: 70, width: 0, height: 0))
    }

    // MARK: - Cache keying

    func testCacheHitsOnlyForTheSameDisplayAndExactBytes() {
        var cache = ScreenTextRecognitionCache<String>()
        let firstFrameData = Data([1, 2, 3])
        let changedFrameData = Data([1, 2, 4])

        cache.store("first frame text", forDisplay: 1, imageData: firstFrameData)

        // The reuse cache hands back identical bytes for an unchanged screen.
        XCTAssertEqual(cache.cachedValue(forDisplay: 1, imageData: Data([1, 2, 3])), "first frame text")
        XCTAssertNil(cache.cachedValue(forDisplay: 1, imageData: changedFrameData))
        XCTAssertNil(cache.cachedValue(forDisplay: 2, imageData: firstFrameData))
        XCTAssertEqual(cache.cachedValue(matchingImageData: firstFrameData), "first frame text")

        // A new frame replaces the display's entry.
        cache.store("changed frame text", forDisplay: 1, imageData: changedFrameData)
        XCTAssertNil(cache.cachedValue(forDisplay: 1, imageData: firstFrameData))
        XCTAssertNil(cache.cachedValue(matchingImageData: firstFrameData))
        XCTAssertEqual(cache.cachedValue(matchingImageData: changedFrameData), "changed frame text")

        cache.removeAll()
        XCTAssertNil(cache.cachedValue(matchingImageData: changedFrameData))
    }

    // MARK: - Waiting with a deadline

    func testWaitingReturnsNilAtTheDeadlineAndTheValueWhenReady() async {
        let slowTask = Task<Int, Never>.detached {
            try? await Task.sleep(for: .seconds(2))
            return 1
        }
        let timedOutValue = await ScreenTextRecognizer.value(of: slowTask, waitingAtMost: 0.05)
        XCTAssertNil(timedOutValue)
        slowTask.cancel()

        let readyTask = Task<Int, Never>.detached { 42 }
        let readyValue = await ScreenTextRecognizer.value(of: readyTask, waitingAtMost: 1)
        XCTAssertEqual(readyValue, 42)
    }
}
