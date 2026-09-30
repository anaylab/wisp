//
//  Fast pointing suite. The screen below is real: the OCR lines Vision read
//  from a Claude window sidebar during the measurement that motivated fast
//  pointing, where the vision model missed 4 of 5 "where is X" questions.
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

func ocrLine(_ lineID: String, _ left: Int, _ top: Int, _ right: Int, _ bottom: Int, _ text: String) -> PointingCandidate {
    PointingCandidate(
        elementID: lineID,
        text: text,
        accessibilityRoleName: nil,
        regionInScreenshotPixels: CGRect(x: left, y: top, width: right - left, height: bottom - top),
        screenNumber: 1
    )
}

let sidebarScreen: [PointingCandidate] = [
    ocrLine("t1", 12, 67, 54, 77, "+ New"),
    ocrLine("t2", 9, 88, 43, 98, "Pinned"),
    ocrLine("t3", 11, 107, 56, 120, "• Wisp"),
    ocrLine("t4", 10, 143, 122, 153, "Notch & Glance Cards >"),
    ocrLine("t6", 10, 169, 82, 179, "Voice & Models"),
    ocrLine("t7", 12, 189, 210, 201, "• Wisp voice/silent modes and multi-so!"),
    ocrLine("t10", 12, 255, 174, 267, "• Qwen loading and RAM usage"),
    ocrLine("t12", 9, 304, 99, 314, "Agent, Skills & Tools"),
    ocrLine("t16", 10, 371, 92, 383, "Setup & Research"),
    ocrLine("t18", 11, 416, 121, 426, "• Sentient OS review"),
    ocrLine("t24", 9, 512, 63, 522, "Ungrouped"),
    ocrLine("t25", 12, 531, 166, 543, "• Wisp feature enhancements"),
]

// MARK: Request recognition

func target(_ transcript: String) -> String? { PointingRequestParser.request(from: transcript)?.targetText }

check(target("Where is the New button?") == "new", "where is the New button")
check(PointingRequestParser.request(from: "Where is the New button?")?.roleHint == "button", "role hint kept")
check(target("Where's the Setup and Research section?") == "setup and research", "where's … section")
check(target("point at Voice & Models") == "voice & models", "point at")
check(target("where is the Sentient OS review chat") == "sentient os review chat", "where is … chat")
check(target("Hey Wisp, can you show me where the export option is?") == "export", "show me where … is")
check(target("where do I click to save") == "save", "where do I click to")
check(target("find the share button") == "share", "find with a role word")
check(target("highlight the search field on my screen") == "search", "highlight … on my screen")
check(target("where are my downloads located") == "downloads", "where are … located")

check(target("find coffee near me") == nil, "find without a role word is a places question")
check(target("show me the weather") == nil, "show me … is a card, not pointing")
check(target("where is it") == nil, "bare pronoun")
check(target("what is on my screen") == nil, "not a pointing request")
check(target("where is the button that saves and then closes the window") == nil, "a question, not a label")
check(target("how do I export this") == nil, "how-to stays with the model")

// MARK: Matching (the five measured questions)

func matchedID(_ transcript: String, _ candidates: [PointingCandidate] = sidebarScreen) -> String? {
    guard let request = PointingRequestParser.request(from: transcript) else { return nil }
    return PointingTargetMatcher.bestMatch(for: request, among: candidates)?.candidate.elementID
}

check(matchedID("Where is the New button?") == "t1", "New → t1")
check(matchedID("Where's the Setup and Research section?") == "t16", "Setup & Research → t16")
check(matchedID("point at Voice & Models") == "t6", "Voice & Models → t6")
check(matchedID("where is the Sentient OS review") == "t18", "Sentient OS review → t18")
check(matchedID("show me where Ungrouped is") == "t24", "Ungrouped → t24")
check(matchedID("where is the Setup and Reserch section") == "t16", "one-letter misspelling tolerated")

check(matchedID("where is wisp") == "t3", "a line that is just the word beats sentences mentioning it")
check(matchedID("where is the wisp voice") == nil, "a target only inside a long sentence is too weak")
check(matchedID("where is the export button") == nil, "absent target declines")
check(matchedID("where is the sentient os review chat") == nil, "an extra word the screen doesn't have declines")

// Two "Save" buttons in different places: decline rather than guess.
let twoSaveButtons = [
    PointingCandidate(elementID: "a1", text: "Save", accessibilityRoleName: "button",
                      regionInScreenshotPixels: CGRect(x: 10, y: 10, width: 40, height: 20), screenNumber: 1),
    PointingCandidate(elementID: "a2", text: "Save", accessibilityRoleName: "button",
                      regionInScreenshotPixels: CGRect(x: 400, y: 300, width: 40, height: 20), screenNumber: 1),
]
check(matchedID("where is the save button", twoSaveButtons) == nil, "two equal matches elsewhere decline")

// The Accessibility element and the OCR line of its own label are one place.
let saveButtonAndItsLabel = [
    PointingCandidate(elementID: "t4", text: "Save", accessibilityRoleName: nil,
                      regionInScreenshotPixels: CGRect(x: 14, y: 12, width: 30, height: 14), screenNumber: 1),
    PointingCandidate(elementID: "a1", text: "Save", accessibilityRoleName: "button",
                      regionInScreenshotPixels: CGRect(x: 10, y: 10, width: 40, height: 20), screenNumber: 1),
]
check(matchedID("where is the save button", saveButtonAndItsLabel) == "a1", "same place: the control wins")

// "Save" vs "Save As…": the exact label wins.
let saveAndSaveAs = [
    PointingCandidate(elementID: "a1", text: "Save", accessibilityRoleName: "menuitem",
                      regionInScreenshotPixels: CGRect(x: 10, y: 10, width: 60, height: 20), screenNumber: 1),
    PointingCandidate(elementID: "a2", text: "Save As…", accessibilityRoleName: "menuitem",
                      regionInScreenshotPixels: CGRect(x: 10, y: 40, width: 60, height: 20), screenNumber: 1),
]
check(matchedID("where is save", saveAndSaveAs) == "a1", "exact label beats a longer one")

// Same label in two places (Finder's sidebar and its file list): mark both.
let documentsTwice = [
    PointingCandidate(elementID: "a8", text: "Documents", accessibilityRoleName: "text",
                      regionInScreenshotPixels: CGRect(x: 20, y: 300, width: 70, height: 16), screenNumber: 1),
    PointingCandidate(elementID: "t9", text: "Documents", accessibilityRoleName: nil,
                      regionInScreenshotPixels: CGRect(x: 22, y: 301, width: 66, height: 14), screenNumber: 1),
    PointingCandidate(elementID: "t30", text: "Documents", accessibilityRoleName: nil,
                      regionInScreenshotPixels: CGRect(x: 260, y: 350, width: 70, height: 14), screenNumber: 1),
    PointingCandidate(elementID: "t31", text: "Folder", accessibilityRoleName: nil,
                      regionInScreenshotPixels: CGRect(x: 600, y: 350, width: 40, height: 14), screenNumber: 1),
]
let documentsPlaces = PointingTargetMatcher.bestPlaces(
    for: PointingRequestParser.request(from: "point at Documents")!, among: documentsTwice
).map(\.candidate.elementID)
check(documentsPlaces == ["a8", "t30"], "two places marked, element preferred over its own label: \(documentsPlaces)")
check(target("where is the Movies folder") == "movies", "folder is a kind word")

// Measured live in Finder: the sidebar row is a text element plus an icon
// element beside it, and OCR reads the list row's folder icon as a letter.
let finderDocuments = [
    PointingCandidate(elementID: "a28", text: "Documents", accessibilityRoleName: "text",
                      regionInScreenshotPixels: CGRect(x: 177.8, y: 371.0, width: 45.6, height: 10.6), screenNumber: 1),
    PointingCandidate(elementID: "a29", text: "document", accessibilityRoleName: "image",
                      regionInScreenshotPixels: CGRect(x: 162.4, y: 373.3, width: 11.9, height: 6.5), screenNumber: 1),
    PointingCandidate(elementID: "a79", text: "Java document", accessibilityRoleName: "text",
                      regionInScreenshotPixels: CGRect(x: 617.5, y: 327.8, width: 56.3, height: 10.6), screenNumber: 1),
    PointingCandidate(elementID: "t40", text: "I Documents", accessibilityRoleName: nil,
                      regionInScreenshotPixels: CGRect(x: 256.0, y: 353.4, width: 48.0, height: 10.0), screenNumber: 1),
    PointingCandidate(elementID: "t46", text: "D Documents", accessibilityRoleName: nil,
                      regionInScreenshotPixels: CGRect(x: 164.0, y: 371.3, width: 56.0, height: 12.1), screenNumber: 1),
]
let finderDocumentsPlaces = PointingTargetMatcher.bestPlaces(
    for: PointingRequestParser.request(from: "point at Documents")!, among: finderDocuments
).map(\.candidate.elementID)
check(finderDocumentsPlaces == ["a28", "t40"], "sidebar row once (its text, not its icon) + the list row: \(finderDocumentsPlaces)")

let columnOfFolders = (1...6).map { rowIndex in
    PointingCandidate(elementID: "t\(rowIndex)", text: "Folder", accessibilityRoleName: nil,
                      regionInScreenshotPixels: CGRect(x: 600, y: 20 * rowIndex, width: 40, height: 14), screenNumber: 1)
}
check(PointingTargetMatcher.bestPlaces(for: PointingRequest(targetText: "folder", roleHint: nil), among: columnOfFolders).isEmpty,
      "a label everywhere is not an answer")

let shortlist = PointingTargetMatcher.shortlist(targetText: "sentient review chat", among: sidebarScreen).map(\.elementID)
check(shortlist.first == "t18", "shortlist ranks the line sharing most words first: \(shortlist)")
check(!shortlist.contains("t1"), "shortlist leaves out unrelated lines")

// Measured live: "share" also matched Finder's "Shared" sidebar row.
let shareAndShared = [
    PointingCandidate(elementID: "a11", text: "Shared", accessibilityRoleName: "text",
                      regionInScreenshotPixels: CGRect(x: 40, y: 140, width: 50, height: 12), screenNumber: 1),
    PointingCandidate(elementID: "a23", text: "Share", accessibilityRoleName: "button",
                      regionInScreenshotPixels: CGRect(x: 700, y: 60, width: 24, height: 24), screenNumber: 1),
]
let sharePlaces = PointingTargetMatcher.bestPlaces(
    for: PointingRequestParser.request(from: "where is the share button")!, among: shareAndShared
).map(\.candidate.elementID)
check(sharePlaces == ["a23"], "exact word beats a tolerated one: \(sharePlaces)")

// Measured live: "privacy and security" (scrolled out of view) shortlisted
// and then accepted "AutoFill & Passwords" for sharing only "and".
let autofill = PointingCandidate(elementID: "a17", text: "AutoFill & Passwords", accessibilityRoleName: "button",
                                 regionInScreenshotPixels: CGRect(x: 300, y: 300, width: 100, height: 14), screenNumber: 1)
check(PointingTargetMatcher.shortlist(targetText: "privacy and security", among: [autofill]).isEmpty,
      "a connector word alone doesn't shortlist")
check(!PointingTargetMatcher.sharesContentWord(targetText: "privacy and security", candidate: autofill),
      "a connector word alone isn't a shared word")

// MARK: Reading the text-only model's reply (real replies from the measurement)

func replyID(_ reply: String) -> String? {
    PointingModelFallback.elementID(fromReply: reply, candidates: sidebarScreen)
}

check(replyID(#"[POINT:id="t1"]"#) == "t1", "id=\"t1\"")
check(replyID("[POINT:id:16]") == "t16", "bare number with one id kind")
check(replyID("[POINT:id:t6]") == "t6", "id:t6")
check(replyID("[POINT:id:18]") == "t18", "bare 18")
check(replyID("[POINT:id:Ungrouped]") == "t24", "label instead of id")
check(replyID("[POINT:t6:voice and models]") == "t6", "the requested form")
check(replyID("[POINT:none]") == nil, "none")
check(replyID("[POINT:t99:ghost]") == nil, "unknown id")

let mixedCandidates = sidebarScreen + [
    PointingCandidate(elementID: "a16", text: "Close", accessibilityRoleName: "button",
                      regionInScreenshotPixels: CGRect(x: 800, y: 5, width: 20, height: 20), screenNumber: 1),
]
check(PointingModelFallback.elementID(fromReply: "[POINT:id:16]", candidates: mixedCandidates) == nil,
      "bare number is ambiguous with both id kinds")

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
