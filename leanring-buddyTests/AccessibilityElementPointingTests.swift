//
//  AccessibilityElementPointingTests.swift
//  leanring-buddyTests
//
//  Proves the pure parts of Accessibility-tree pointing: the compact element
//  list the model is shown, the id tag forms ([POINT:a12:label],
//  [BOX:a12:label]…) and their fallback to coordinates, and the conversion
//  from an Accessibility frame to a region in the right display's screenshot.
//

import XCTest
@testable import Wisp

@MainActor
final class AccessibilityElementPointingTests: XCTestCase {

    // MARK: - Fixtures

    private func makeEntry(
        _ elementID: String,
        _ shortRoleName: String,
        _ labelText: String,
        valueText: String? = nil,
        frame: CGRect = CGRect(x: 100, y: 100, width: 80, height: 24)
    ) -> AccessibilityElementSnapshotEntry {
        AccessibilityElementSnapshotEntry(
            elementID: elementID,
            shortRoleName: shortRoleName,
            labelText: labelText,
            valueText: valueText,
            frameInAccessibilityCoordinates: frame
        )
    }

    // MARK: - Prompt rendering

    func testPromptTextListsOneShortLinePerElementAndTeachesTheIdTag() {
        let snapshot = AccessibilityElementSnapshot(
            applicationName: "Finder",
            windowTitle: "Downloads",
            elements: [
                makeEntry("a1", "menu", "File"),
                makeEntry("a2", "button", "Back"),
                makeEntry("a3", "searchfield", "Search", valueText: "report"),
            ]
        )

        let promptLines = snapshot.promptText().components(separatedBy: "\n")

        XCTAssertEqual(promptLines.first, "on-screen elements in \"Finder\" (window \"Downloads\"), from the accessibility tree:")
        XCTAssertEqual(promptLines[1], "a1 menu \"File\"")
        XCTAssertEqual(promptLines[2], "a2 button \"Back\"")
        XCTAssertEqual(promptLines[3], "a3 searchfield \"Search\" = \"report\"")
        XCTAssertTrue(promptLines.last?.contains("[POINT:a2:save button]") ?? false)
        XCTAssertEqual(promptLines.count, 5)
    }

    func testEmptySnapshotRendersNothing() {
        let snapshot = AccessibilityElementSnapshot(applicationName: "Finder", windowTitle: nil, elements: [])
        XCTAssertEqual(snapshot.promptText(), "")
    }

    func testPromptLineOmitsEmptyLabelAndValueEqualToLabel() {
        XCTAssertEqual(
            AccessibilityElementSnapshot.promptLine(for: makeEntry("a4", "textfield", "")),
            "a4 textfield"
        )
        XCTAssertEqual(
            AccessibilityElementSnapshot.promptLine(for: makeEntry("a5", "popup", "Size", valueText: "Size")),
            "a5 popup \"Size\""
        )
    }

    func testSanitizingCollapsesWhitespaceSwapsTagCharactersAndTruncates() {
        XCTAssertEqual(
            AccessibilityElementSnapshot.sanitizedForPrompt("  Save\n  as  \"PDF\" [beta] "),
            "Save as 'PDF' (beta)"
        )

        let longLabel = String(repeating: "x", count: 100)
        let sanitizedLongLabel = AccessibilityElementSnapshot.sanitizedForPrompt(longLabel)
        XCTAssertEqual(sanitizedLongLabel.count, AccessibilityElementSnapshot.maximumRenderedTextLength)
        XCTAssertTrue(sanitizedLongLabel.hasSuffix("…"))
    }

    func testRoleNamesPreferSubroleAndSkipContainers() {
        XCTAssertEqual(AccessibilityElementSnapshot.shortRoleName(forAccessibilityRole: "AXButton", subrole: nil), "button")
        XCTAssertEqual(AccessibilityElementSnapshot.shortRoleName(forAccessibilityRole: "AXTextField", subrole: "AXSearchField"), "searchfield")
        XCTAssertEqual(AccessibilityElementSnapshot.shortRoleName(forAccessibilityRole: "AXRadioButton", subrole: "AXTabButton"), "tab")
        XCTAssertNil(AccessibilityElementSnapshot.shortRoleName(forAccessibilityRole: "AXGroup", subrole: nil))
        XCTAssertNil(AccessibilityElementSnapshot.shortRoleName(forAccessibilityRole: "AXScrollArea", subrole: nil))
    }

    func testElementLookupIsCaseInsensitive() {
        let snapshot = AccessibilityElementSnapshot(
            applicationName: "Notes",
            windowTitle: nil,
            elements: [makeEntry("a12", "button", "New Note")]
        )
        XCTAssertEqual(snapshot.element(withID: "A12")?.labelText, "New Note")
        XCTAssertNil(snapshot.element(withID: "a13"))
    }

    // MARK: - [POINT:] id parsing

    func testPointTagWithIdParsesIdAndLabel() {
        let parseResult = CompanionManager.parsePointingCoordinates(
            from: "click the new note button up top. [POINT:a12:new note]"
        )
        XCTAssertEqual(parseResult.spokenText, "click the new note button up top.")
        XCTAssertEqual(parseResult.accessibilityElementID, "a12")
        XCTAssertEqual(parseResult.elementLabel, "new note")
        XCTAssertNil(parseResult.coordinate)
        XCTAssertNil(parseResult.screenNumber)
    }

    func testPointTagWithIdToleratesUppercaseSpacesAndNoLabel() {
        let spacedParseResult = CompanionManager.parsePointingCoordinates(from: "there. [POINT: A7 save]")
        XCTAssertEqual(spacedParseResult.accessibilityElementID, "a7")
        XCTAssertEqual(spacedParseResult.elementLabel, "save")

        let unlabelledParseResult = CompanionManager.parsePointingCoordinates(from: "there. [POINT:a3]")
        XCTAssertEqual(unlabelledParseResult.accessibilityElementID, "a3")
        XCTAssertNil(unlabelledParseResult.elementLabel)
        XCTAssertEqual(unlabelledParseResult.spokenText, "there.")
    }

    func testCoordinatePointTagStillWorksAsFallback() {
        let parseResult = CompanionManager.parsePointingCoordinates(
            from: "that's the terminal. [POINT:400,300:terminal:screen2]"
        )
        XCTAssertNil(parseResult.accessibilityElementID)
        XCTAssertEqual(parseResult.coordinate, CGPoint(x: 400, y: 300))
        XCTAssertEqual(parseResult.elementLabel, "terminal")
        XCTAssertEqual(parseResult.screenNumber, 2)

        let noneParseResult = CompanionManager.parsePointingCoordinates(from: "html is markup. [POINT:none]")
        XCTAssertNil(noneParseResult.accessibilityElementID)
        XCTAssertNil(noneParseResult.coordinate)
        XCTAssertEqual(noneParseResult.spokenText, "html is markup.")
    }

    // MARK: - [BOX:] / [HIGHLIGHT:] / [ARROW:] id parsing

    func testIdAnnotationTagsResolveThroughTheResolver() {
        let resolvedSaveButtonRegion = AccessibilityElementResolvedRegion(
            regionInScreenshotPixels: CGRect(x: 100, y: 40, width: 60, height: 20),
            screenNumber: 2
        )
        let parseResult = ScreenAnnotationParser.parse(
            "first click save [BOX:a4:save], then look here [ARROW:a4:here] and there [HIGHLIGHT:a9:unknown]",
            accessibilityElementRegionResolver: { elementID in
                elementID == "a4" ? resolvedSaveButtonRegion : nil
            }
        )

        // Every id tag is stripped from the speech, resolved or not.
        XCTAssertEqual(parseResult.spokenText, "first click save , then look here  and there")

        // The unknown id draws nothing.
        XCTAssertEqual(parseResult.annotations.count, 2)

        let boxAnnotation = parseResult.annotations[0]
        XCTAssertEqual(boxAnnotation.style, .box)
        XCTAssertEqual(boxAnnotation.regionInScreenshotPixels, resolvedSaveButtonRegion.regionInScreenshotPixels)
        XCTAssertEqual(boxAnnotation.label, "save")
        XCTAssertEqual(boxAnnotation.screenNumber, 2)
        XCTAssertEqual(boxAnnotation.stepNumber, 1)

        let arrowAnnotation = parseResult.annotations[1]
        XCTAssertEqual(arrowAnnotation.style, .arrow)
        XCTAssertEqual(arrowAnnotation.regionInScreenshotPixels, CGRect(x: 130, y: 50, width: 0, height: 0))
        XCTAssertEqual(arrowAnnotation.stepNumber, 2)
    }

    func testIdAnnotationTagsWithoutResolverDrawNothingButAreStripped() {
        let parseResult = ScreenAnnotationParser.parse("look here [BOX:a4:save]")
        XCTAssertEqual(parseResult.spokenText, "look here")
        XCTAssertTrue(parseResult.annotations.isEmpty)
    }

    func testIdAndCoordinateAnnotationsKeepDocumentOrder() {
        let parseResult = ScreenAnnotationParser.parse(
            "[BOX:10,10,50,50:first] [BOX:a1:second]",
            accessibilityElementRegionResolver: { _ in
                AccessibilityElementResolvedRegion(
                    regionInScreenshotPixels: CGRect(x: 200, y: 200, width: 20, height: 20),
                    screenNumber: 1
                )
            }
        )
        XCTAssertEqual(parseResult.annotations.map(\.label), ["first", "second"])
    }

    /// Regression: the coordinate patterns used to be written with a `[:\s]`
    /// class, which ICU reads as the start of a POSIX class, so they failed to
    /// compile and no coordinate box or arrow was ever drawn.
    func testCoordinateBoxAndArrowTagsStillParse() {
        let parseResult = ScreenAnnotationParser.parse("here [BOX:10,20,110,60:panel] and [ARROW:5,6:tip:screen2]")
        XCTAssertEqual(parseResult.spokenText, "here  and")
        XCTAssertEqual(parseResult.annotations.count, 2)
        XCTAssertEqual(parseResult.annotations[0].regionInScreenshotPixels, CGRect(x: 10, y: 20, width: 100, height: 40))
        XCTAssertEqual(parseResult.annotations[1].style, .arrow)
        XCTAssertEqual(parseResult.annotations[1].screenNumber, 2)
    }

    // MARK: - Coordinate conversion

    func testAccessibilityRectFlipsToAppKitAgainstThePrimaryDisplay() {
        let appKitRect = AccessibilityElementGeometry.appKitRect(
            fromAccessibilityRect: CGRect(x: 100, y: 50, width: 40, height: 20),
            primaryDisplayHeight: 1000
        )
        XCTAssertEqual(appKitRect, CGRect(x: 100, y: 930, width: 40, height: 20))
    }

    func testRegionOnPrimaryDisplayScalesToScreenshotPixels() {
        // A 1600×1000-point display captured as an 800×500 screenshot: half scale.
        let primaryDisplay = AccessibilityElementGeometry.CapturedDisplayGeometry(
            displayFrameInAppKitCoordinates: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            screenshotSizeInPixels: CGSize(width: 800, height: 500)
        )

        let resolvedRegion = AccessibilityElementGeometry.screenshotRegion(
            forAccessibilityFrame: CGRect(x: 200, y: 100, width: 80, height: 40),
            primaryDisplayHeight: 1000,
            capturedDisplays: [primaryDisplay]
        )

        XCTAssertEqual(resolvedRegion?.screenNumber, 1)
        XCTAssertEqual(resolvedRegion?.regionInScreenshotPixels, CGRect(x: 100, y: 50, width: 40, height: 20))
        XCTAssertEqual(resolvedRegion?.centerPointRegionInScreenshotPixels, CGRect(x: 120, y: 60, width: 0, height: 0))
    }

    func testRegionOnSecondaryDisplayAboveThePrimaryUsesThatDisplay() {
        let primaryDisplay = AccessibilityElementGeometry.CapturedDisplayGeometry(
            displayFrameInAppKitCoordinates: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            screenshotSizeInPixels: CGSize(width: 800, height: 500)
        )
        // Sits directly above the primary in AppKit space (y up), so in
        // Accessibility space (y down) its top edge is at y = -1200.
        let secondaryDisplay = AccessibilityElementGeometry.CapturedDisplayGeometry(
            displayFrameInAppKitCoordinates: CGRect(x: 0, y: 1000, width: 1920, height: 1200),
            screenshotSizeInPixels: CGSize(width: 960, height: 600)
        )

        let resolvedRegion = AccessibilityElementGeometry.screenshotRegion(
            forAccessibilityFrame: CGRect(x: 400, y: -1100, width: 100, height: 50),
            primaryDisplayHeight: 1000,
            capturedDisplays: [primaryDisplay, secondaryDisplay]
        )

        XCTAssertEqual(resolvedRegion?.screenNumber, 2)
        // 100pt below the secondary's top edge and 400pt in, at half scale.
        XCTAssertEqual(resolvedRegion?.regionInScreenshotPixels, CGRect(x: 200, y: 50, width: 50, height: 25))
    }

    func testRegionOffEveryDisplayResolvesToNil() {
        let primaryDisplay = AccessibilityElementGeometry.CapturedDisplayGeometry(
            displayFrameInAppKitCoordinates: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            screenshotSizeInPixels: CGSize(width: 800, height: 500)
        )
        let resolvedRegion = AccessibilityElementGeometry.screenshotRegion(
            forAccessibilityFrame: CGRect(x: 5000, y: 5000, width: 10, height: 10),
            primaryDisplayHeight: 1000,
            capturedDisplays: [primaryDisplay]
        )
        XCTAssertNil(resolvedRegion)
    }
}
