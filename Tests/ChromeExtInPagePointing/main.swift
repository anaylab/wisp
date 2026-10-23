//
//  In-page pointing suite (Chrome extension phase 05): the decision to draw in
//  the page, the annotation → mark mapping, matching a target or walkthrough
//  step to one of the page's elements, and the walkthrough event rules.
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

// MARK: - Whether to try the page

func decide(front: BrowserControllerSelectionInputs.FrontmostApplication, connected: Bool, canRead: Bool) -> ChromeInPagePointingDecision {
    ChromeInPagePointingPolicy.decision(for: ChromeInPagePointingInputs(
        frontmostApplication: front, isExtensionConnected: connected, extensionCanReadPages: canRead
    ))
}

check(decide(front: .chromiumBrowser, connected: true, canRead: true) == .tryInPage, "Chrome in front, extension connected and reading → in-page")
if case .useOverlay = decide(front: .other, connected: true, canRead: true) {} else {
    check(false, "a non-browser app in front keeps the overlay (pointing elsewhere is unchanged)")
}
if case .useOverlay = decide(front: .safari, connected: true, canRead: true) {} else {
    check(false, "Safari in front keeps the overlay")
}
if case .useOverlay(let reason) = decide(front: .chromiumBrowser, connected: false, canRead: true) {
    check(reason.contains("isn't connected"), "a disconnected extension says so")
} else {
    check(false, "a disconnected extension keeps the overlay")
}
if case .useOverlay(let reason) = decide(front: .chromiumBrowser, connected: true, canRead: false) {
    check(reason.contains("can't read pages"), "no pages.read says so")
} else {
    check(false, "no pages.read keeps the overlay")
}

// MARK: - Which annotations go in the page

check(ChromeInPagePointingPolicy.markKind(for: .marker, label: "Settings", isWalkthroughStep: false) == .ring, "a point is a ring")
check(ChromeInPagePointingPolicy.markKind(for: .box, label: "Settings", isWalkthroughStep: false) == .box, "a box is a box")
check(ChromeInPagePointingPolicy.markKind(for: .highlight, label: "Plans", isWalkthroughStep: false) == .highlight, "a highlight is a band")
check(ChromeInPagePointingPolicy.markKind(for: .box, label: "Open settings", isWalkthroughStep: true) == .step, "a walkthrough step is a numbered step")
check(ChromeInPagePointingPolicy.markKind(for: .arrow, label: "here", isWalkthroughStep: false) == nil, "arrows stay on the overlay")
check(ChromeInPagePointingPolicy.markKind(for: .note, label: "x = 6", isWalkthroughStep: false) == nil, "notes stay on the overlay")
check(ChromeInPagePointingPolicy.markKind(for: .circle, label: "answer", isWalkthroughStep: false) == nil, "circles stay on the overlay")
check(ChromeInPagePointingPolicy.markKind(for: .marker, label: nil, isWalkthroughStep: false) == nil, "an unlabelled point has nothing to find it by")
check(ChromeInPagePointingPolicy.markKind(for: .marker, label: "  ", isWalkthroughStep: false) == nil, "a blank label neither")

let instructionLabel = ChromeInPagePointingPolicy.pointingRequest(forAnnotationLabel: "Click the Settings button")
check(instructionLabel?.targetText == "settings" && instructionLabel?.roleHint == "button", "a model's instruction-style label is read as its target and role")
check(ChromeInPagePointingPolicy.pointingRequest(forAnnotationLabel: "New repository")?.targetText == "new repository", "a plain label is kept whole")
check(ChromeInPagePointingPolicy.pointingRequest(forAnnotationLabel: "...") == nil, "punctuation alone isn't a target")

let chromeWindow = CGRect(x: 0, y: 25, width: 1400, height: 900)
check(ChromeInPagePointingPolicy.isPoint(CGPoint(x: 700, y: 400), insideBrowserWindow: chromeWindow), "a point in Chrome's window may go in the page")
check(!ChromeInPagePointingPolicy.isPoint(CGPoint(x: 1600, y: 400), insideBrowserWindow: chromeWindow), "a point in the app beside Chrome stays on the overlay")
check(!ChromeInPagePointingPolicy.isPoint(CGPoint(x: 700, y: 10), insideBrowserWindow: chromeWindow), "the menu bar stays on the overlay")
check(!ChromeInPagePointingPolicy.isPoint(CGPoint(x: 700, y: 400), insideBrowserWindow: nil), "no Chrome window found → overlay")

check(ChromeInPagePointingPolicy.cssColor(red: 0.2, green: 0.5, blue: 1.0) == "rgb(51, 128, 255)", "the marker colour goes over as rgb()")
check(ChromeInPagePointingPolicy.cssColor(red: -1, green: 2, blue: 0.5) == "rgb(0, 255, 128)", "out-of-range components are clamped")
check(ChromeInPagePointingPolicy.shortLabel("  Open   settings ") == "Open settings", "labels are one tidy line")
check(ChromeInPagePointingPolicy.shortLabel(String(repeating: "word ", count: 20)).count == ChromeInPagePointingPolicy.maximumLabelCharacters, "long labels are cut to the limit")

// MARK: - Step / target → element

func element(_ id: String, _ role: String, _ label: String) -> ChromeInPageElement {
    ChromeInPageElement(id: id, role: role, label: label)
}

let githubHeader = [
    element("e0", "link", "Skip to content"),
    element("e1", "button", "Open user navigation menu"),
    element("e2", "link", "Your profile"),
    element("e3", "link", "Settings"),
    element("e4", "link", "Settings and privacy"),
    element("e5", "textbox:search", "Search or jump to…"),
    element("e6", "link", "Repositories"),
    element("e7", "link", "Issues"),
]

func best(_ target: String, roleHint: String? = nil, among elements: [ChromeInPageElement] = githubHeader) -> [String] {
    ChromeInPageElementMatcher.bestElements(
        for: PointingRequest(targetText: target, roleHint: roleHint),
        among: elements
    ).map(\.id)
}

check(best("settings") == ["e3"], "the exact label wins over a longer one containing it")
check(best("issue") == ["e7"], "a plural on the page still matches")
check(best("search or jump", roleHint: "field") == ["e5"], "a search field matches with a spoken field hint")
check(best("billing") == [], "a target not on the page matches nothing (overlay fallback)")
check(best("privacy") == [], "one word of a long label isn't confident enough")
check(best("settings", among: [element("e9", "button", "(unlabelled)")]) == [], "unlabelled elements never match")

// The same label twice (header and footer) marks both; a column of them, none.
let twoSettings = githubHeader + [element("e40", "link", "Settings")]
check(best("settings", among: twoSettings) == ["e3", "e40"], "the same label twice marks both, in snapshot order")
let editColumn = (0..<5).map { element("e\(50 + $0)", "link", "Edit") }
check(best("edit", among: editColumn) == [], "a label everywhere isn't an answer")
check(
    ChromeInPageElementMatcher.bestElements(for: PointingRequest(targetText: "settings", roleHint: nil), among: twoSettings, maximumCount: 1).isEmpty,
    "a walkthrough asks for one, so a tie it can't break declines"
)

// The role hint breaks a tie between a link and a button of the same name.
let saveLinkAndButton = [element("e1", "link", "Save"), element("e2", "button", "Save")]
check(best("save", roleHint: "button", among: saveLinkAndButton) == ["e2"], "the role the user said breaks the tie")

// A walkthrough step's instruction, read the way the walkthrough reads it.
func stepElement(_ instruction: String, among elements: [ChromeInPageElement] = githubHeader) -> String? {
    ChromeInPageElementMatcher.bestElements(
        for: GuidedWalkthroughTargetText.pointingRequest(forInstruction: instruction),
        among: elements,
        maximumCount: 1
    ).first?.id
}

check(stepElement("Click your profile picture") == nil, "a step naming something not on the page finds nothing")
check(stepElement("Then click Settings in the menu") == "e3", "a step's location clause is dropped before matching")
check(stepElement("Open the user navigation menu") == "e1", "a step with a role word finds the control")
check(stepElement("Choose Repositories") == "e6", "a step's verb is dropped")

// MARK: - Walkthrough events

let stepID = UUID()
let otherStepID = UUID()
let markedTarget = ChromeInPageWalkthroughTarget(stepID: stepID, tabID: 7, elementID: "e3", elementLabel: "Settings")

check(
    ChromeInPageWalkthroughEventPolicy.clickCompletesStep(clickedTabID: 7, clickedElementID: "e3", currentTarget: markedTarget, currentStepID: stepID),
    "a real click on the marked element finishes the step"
)
check(
    !ChromeInPageWalkthroughEventPolicy.clickCompletesStep(clickedTabID: 7, clickedElementID: "e4", currentTarget: markedTarget, currentStepID: stepID),
    "a click on another element doesn't"
)
check(
    !ChromeInPageWalkthroughEventPolicy.clickCompletesStep(clickedTabID: 8, clickedElementID: "e3", currentTarget: markedTarget, currentStepID: stepID),
    "the same id in another tab doesn't"
)
check(
    !ChromeInPageWalkthroughEventPolicy.clickCompletesStep(clickedTabID: 7, clickedElementID: "e3", currentTarget: markedTarget, currentStepID: otherStepID),
    "a late click for a step already passed doesn't finish the next one"
)
check(
    !ChromeInPageWalkthroughEventPolicy.clickCompletesStep(clickedTabID: 7, clickedElementID: "e3", currentTarget: nil, currentStepID: stepID),
    "nothing marked in the page → clicks are the screen matcher's"
)

check(ChromeInPageWalkthroughEventPolicy.navigationRequiresRefind(navigatedTabID: 7, walkthroughTabID: 7), "a navigation in the walkthrough's tab re-finds the step")
check(!ChromeInPageWalkthroughEventPolicy.navigationRequiresRefind(navigatedTabID: 9, walkthroughTabID: 7), "another tab's navigation is ignored")
check(!ChromeInPageWalkthroughEventPolicy.navigationRequiresRefind(navigatedTabID: 7, walkthroughTabID: nil), "no walkthrough in Chrome → ignored")

let irreversibleWords: Set<String> = ["send", "delete", "pay", "remove"]
let namesIrreversible: (Set<String>) -> Bool = { !$0.isDisjoint(with: irreversibleWords) }
check(
    ChromeInPageWalkthroughEventPolicy.mayClickForUser(instruction: "Click Settings", elementLabel: "Settings", namesIrreversibleAction: namesIrreversible),
    "Wisp may click an ordinary step for the user"
)
check(
    !ChromeInPageWalkthroughEventPolicy.mayClickForUser(instruction: "Click the green button", elementLabel: "Delete repository", namesIrreversibleAction: namesIrreversible),
    "never an element whose label is irreversible"
)
check(
    !ChromeInPageWalkthroughEventPolicy.mayClickForUser(instruction: "Send the message", elementLabel: "Go", namesIrreversibleAction: namesIrreversible),
    "never a step whose instruction is irreversible"
)

// MARK: - Result

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
