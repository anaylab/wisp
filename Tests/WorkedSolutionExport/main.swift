//
//  "Save a worked solution" suite: what is worth saving, which display wins,
//  file names and the Markdown text.
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

func annotation(_ style: ScreenAnnotation.Style, label: String? = nil) -> ScreenAnnotation {
    ScreenAnnotation(style: style, regionInScreenshotPixels: CGRect(x: 10, y: 10, width: 40, height: 20), label: label, screenNumber: nil)
}

let utc = TimeZone(identifier: "UTC")!
let sampleDate = Date(timeIntervalSince1970: 1_792_247_525) // 2026-10-17 14:32:05 UTC

// Worth saving: a note or a circle, not a lone marker/box/arrow.
check(!WorkedSolutionExport.isWorthSaving([]), "nothing drawn is not worth saving")
check(!WorkedSolutionExport.isWorthSaving([annotation(.marker), annotation(.box), annotation(.arrow), annotation(.highlight)]), "markers and boxes alone are not worth saving")
check(WorkedSolutionExport.isWorthSaving([annotation(.box), annotation(.note, label: "x = 3")]), "a note makes it worth saving")
check(WorkedSolutionExport.isWorthSaving([annotation(.circle)]), "a circle makes it worth saving")

// Which display.
let leftDisplay = CGRect(x: 0, y: 0, width: 1440, height: 900)
let rightDisplay = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
check(WorkedSolutionExport.displayFrameToSave(annotationsByDisplayFrame: [:]) == nil, "no drawings: no display")
check(WorkedSolutionExport.displayFrameToSave(annotationsByDisplayFrame: [leftDisplay: [annotation(.marker)]]) == nil, "only a marker: no display")
let busyRight: [CGRect: [ScreenAnnotation]] = [
    leftDisplay: [annotation(.note, label: "a")],
    rightDisplay: [annotation(.note, label: "a"), annotation(.note, label: "b")],
]
check(WorkedSolutionExport.displayFrameToSave(annotationsByDisplayFrame: busyRight) == rightDisplay, "the display with more notes wins")
let tied: [CGRect: [ScreenAnnotation]] = [
    rightDisplay: [annotation(.note, label: "a")],
    leftDisplay: [annotation(.note, label: "a")],
]
check(WorkedSolutionExport.displayFrameToSave(annotationsByDisplayFrame: tied) == leftDisplay, "a tie goes to the leftmost display")
let circlesDecide: [CGRect: [ScreenAnnotation]] = [
    leftDisplay: [annotation(.note, label: "a"), annotation(.box)],
    rightDisplay: [annotation(.note, label: "a"), annotation(.circle)],
]
check(WorkedSolutionExport.displayFrameToSave(annotationsByDisplayFrame: circlesDecide) == rightDisplay, "equal notes: more circles wins")

// Note texts keep order, drop blanks, flatten line breaks.
let noteTexts = WorkedSolutionExport.noteTexts(in: [
    annotation(.note, label: "2x + 3 = 11"),
    annotation(.circle),
    annotation(.note, label: "   "),
    annotation(.note, label: nil),
    annotation(.note, label: "  2x = 8\n so  x = 4 "),
])
check(noteTexts == ["2x + 3 = 11", "2x = 8 so x = 4"], "notes in order, blanks dropped, whitespace collapsed")

// File names.
check(WorkedSolutionExport.defaultImageFileName(date: sampleDate, timeZone: utc) == "Worked solution 2026-10-17 14.32.05.png", "default name has date and time with no colons")
check(WorkedSolutionExport.markdownFileName(forImageFileName: "Algebra.png") == "Algebra.md", "markdown name follows the renamed image")
check(WorkedSolutionExport.markdownFileName(forImageFileName: "Worked solution 1.png") == "Worked solution 1.md", "spaces are kept")
check(WorkedSolutionExport.markdownFileName(forImageFileName: "noextension") == "noextension.md", "no extension still works")
check(WorkedSolutionExport.markdownFileName(forImageFileName: ".png") == "Worked solution.md", "an empty base name falls back")

// Markdown.
let markdown = WorkedSolutionExport.markdown(
    noteTexts: noteTexts,
    question: "How do I solve\n2x + 3 = 11?",
    date: sampleDate,
    imageFileName: "Algebra (1).png",
    timeZone: utc
)
check(markdown.contains("Date: 2026-10-17 14:32"), "markdown has the date")
check(markdown.contains("Question: How do I solve 2x + 3 = 11?"), "markdown has the question on one line")
check(markdown.contains("1. 2x + 3 = 11\n2. 2x = 8 so x = 4"), "notes are a numbered list")
check(markdown.contains("![Worked solution](Algebra%20%281%29.png)"), "image link is percent-encoded")
check(markdown.hasSuffix("\n"), "markdown ends with a newline")

let noQuestion = WorkedSolutionExport.markdown(noteTexts: ["a"], question: "  \n ", date: sampleDate, imageFileName: "a.png", timeZone: utc)
check(!noQuestion.contains("Question:"), "a blank question is omitted")
let noNotes = WorkedSolutionExport.markdown(noteTexts: [], question: nil, date: sampleDate, imageFileName: "a.png", timeZone: utc)
check(noNotes.contains("no written notes"), "circles-only drawing says so")

let longQuestion = String(repeating: "word ", count: 300)
let clipped = WorkedSolutionExport.clippedQuestion(longQuestion)!
check(clipped.count <= WorkedSolutionExport.maximumQuestionCharacters + 1 && clipped.hasSuffix("…"), "a long question is clipped")
check(WorkedSolutionExport.clippedQuestion(nil) == nil, "no question stays nil")

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
