//
//  Chrome extension DOM controller suite: choosing the extension or AppleScript
//  for a browser task, decoding the snapshot JSON (the shared fixture the
//  extension's own tests also check) into the exact page text Wisp's planners
//  and prompts read, and what the extension's action replies mean.
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

// MARK: - Choosing a controller

func choose(connected: Bool, canRead: Bool, front: BrowserControllerSelectionInputs.FrontmostApplication) -> BrowserControllerKind {
    BrowserControllerSelector.choose(BrowserControllerSelectionInputs(
        isExtensionConnected: connected, extensionCanReadPages: canRead, frontmostApplication: front
    )).kind
}

check(choose(connected: true, canRead: true, front: .chromiumBrowser) == .chromeExtension, "connected + pages.read + Chrome in front → extension")
check(choose(connected: true, canRead: true, front: .other) == .chromeExtension, "connected + pages.read, no browser in front (a typed question) → extension")
check(choose(connected: true, canRead: true, front: .safari) == .appleScript, "Safari in front → AppleScript")
check(choose(connected: true, canRead: false, front: .chromiumBrowser) == .appleScript, "no pages.read (removed mid-session) → AppleScript")
check(choose(connected: false, canRead: true, front: .chromiumBrowser) == .appleScript, "extension not connected → AppleScript")
check(choose(connected: false, canRead: false, front: .safari) == .appleScript, "nothing → AppleScript")
check(
    !BrowserControllerSelector.choose(BrowserControllerSelectionInputs(
        isExtensionConnected: true, extensionCanReadPages: false, frontmostApplication: .chromiumBrowser
    )).reason.isEmpty,
    "every choice carries a reason for the log"
)

typealias Frontmost = BrowserControllerSelectionInputs.FrontmostApplication
check(Frontmost(bundleIdentifier: "com.apple.Safari") == .safari, "Safari")
check(Frontmost(bundleIdentifier: "com.apple.SafariTechnologyPreview") == .safari, "Safari Technology Preview")
check(Frontmost(bundleIdentifier: "com.google.Chrome") == .chromiumBrowser, "Chrome")
check(Frontmost(bundleIdentifier: "com.google.Chrome.canary") == .chromiumBrowser, "Chrome Canary")
check(Frontmost(bundleIdentifier: "com.microsoft.edgemac") == .chromiumBrowser, "Edge")
check(Frontmost(bundleIdentifier: "com.apple.dt.Xcode") == .other, "Xcode isn't a browser")
check(Frontmost(bundleIdentifier: nil) == .other, "no frontmost app")

// MARK: - Snapshot decoding (the shared fixture)

let fixturePath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/ChromeExtDOMController/snapshot-fixture.json"
guard let fixtureData = FileManager.default.contents(atPath: fixturePath),
      let fixtureSnapshot = BrowserPageSnapshotDecoding.snapshot(fromJSONData: fixtureData) else {
    print("FAIL: couldn't read \(fixturePath)")
    exit(1)
}

let expectedPromptText = """
PAGE: Checkout
URL: https://shop.example/checkout
HEADINGS: Checkout
INTERACTIVE ELEMENTS (refer to these by id):
  e0 [button] Not now
  e1 [button] Save {disabled}
  e2 [textbox:email] Email (value: ada@example.com) {required}
  e3 [textbox:password] Password {sensitive — user only}
  e4 [select] Shipping (value: Express)
  e5 [checkbox] Accept terms {checked}
  e6 [link] Back to cart
TEXT:
(a dialog is open: Save card? — its elements are listed first)
(scrolled 0% down the page)
Not now Save
"""
check(fixtureSnapshot.promptRepresentation() == expectedPromptText, "the fixture decodes to the exact page text the prompts expect")
if fixtureSnapshot.promptRepresentation() != expectedPromptText {
    print("--- got:\n\(fixtureSnapshot.promptRepresentation())\n---")
}
check(fixtureSnapshot.elements.first(where: { $0.id == "e3" })?.isSensitiveInput == true, "the password field is sensitive")
check(fixtureSnapshot.elements.first(where: { $0.id == "e3" })?.value == nil, "the password field has no value")
check(fixtureSnapshot.elements.first(where: { $0.id == "e6" })?.href == "https://shop.example/cart", "links keep their href")
check(fixtureSnapshot.elements.first(where: { $0.id == "e0" })?.state == nil, "no state flags reads as nil")

// Lenient, like the decoding it replaced.
let lenientJSON = #"""
{"url":"https://a.example/","title":"A","elements":[
  {"id":"e0","role":"button","label":"Kept","state":""},
  {"id":"e1","role":"button"},
  {"role":"link","label":"No id"},
  {"id":"f4e2","role":"textbox","label":"From a frame","value":42}
],"text":"Body","scroll":"","dialog":""}
"""#
let lenientSnapshot = BrowserPageSnapshotDecoding.snapshot(fromJSONData: Data(lenientJSON.utf8))
check(lenientSnapshot?.elements.map(\.id) == ["e0", "f4e2"], "elements missing an id, role or label are dropped; frame ids are kept")
check(lenientSnapshot?.elements.first?.state == nil, "an empty state reads as none")
check(lenientSnapshot?.elements.last?.value == nil, "a value of the wrong type is ignored")
check(lenientSnapshot?.text == "Body", "no scroll or dialog line when they are empty")
check(lenientSnapshot?.headings == [], "missing headings read as none")
check(BrowserPageSnapshotDecoding.snapshot(fromJSONData: Data("[1,2]".utf8)) == nil, "a reply that isn't an object is unreadable")
check(
    BrowserPageSnapshotDecoding.elements(fromJSONData: Data(#"{"elements":[{"id":"e3","role":"link","label":"Cart"}]}"#.utf8)).map(\.id) == ["e3"],
    "findElements replies decode the same way"
)

// MARK: - Action replies

func errorText(_ status: String, _ action: ExtensionElementAction, _ elementID: String = "e4") -> String? {
    ExtensionBrowserReplies.error(forActionStatus: status, action: action, elementID: elementID)?.errorDescription
}

check(errorText("OK", .click) == nil, "OK is success")
check(errorText("MISSING", .click) == "No element e4 on the page any more.", "missing element, worded as AppleScript does")
check(errorText("DISABLED", .click) == "e4 is disabled right now.", "disabled, worded as AppleScript does")
check(errorText("SENSITIVE", .typeText) == "e4 is a password or payment field — only you can fill that in.", "sensitive, worded as AppleScript does")
check(errorText("NOTSELECT", .selectOption(optionLabel: "Express")) == "e4 isn't a dropdown — click it to open it instead.", "not a select")
check(errorText("NOOPTION", .selectOption(optionLabel: "Overnight")) == "No option matching \"Overnight\".", "no matching option")
check(errorText("NO_RESULT", .click) == "Couldn't click e4.", "an unknown status is a plain failure")
check(errorText("NO_RESULT", .scroll, "") == "Couldn't scroll.", "scroll failure")
check(errorText("IGNORED", .click)?.contains("private") == true, "a data-wisp-ignore region is explained")

check(ExtensionBrowserReplies.sanitizedElementID(" e12 ") == "e12", "ids are trimmed")
check(ExtensionBrowserReplies.sanitizedElementID("f1234e56") == "f1234e56", "frame-prefixed ids pass")
check(ExtensionBrowserReplies.sanitizedElementID("e1'); alert(1)") == nil, "an id can't carry script")
check(ExtensionBrowserReplies.sanitizedElementID("") == nil, "an empty id is refused")
check(ExtensionBrowserReplies.sanitizedElementID(String(repeating: "e", count: 25)) == nil, "an overlong id is refused")
check(ExtensionBrowserReplies.sanitizedElementID("é1") == nil, "non-ASCII letters are refused")

check(ExtensionBrowserReplies.isMissingTabErrorMessage("No tab with id: 812."), "Chrome's missing-tab wording is recognised")
check(!ExtensionBrowserReplies.isMissingTabErrorMessage("couldn't read the page"), "other errors aren't a closed tab")

check(
    ExtensionBrowserReplies.appKitPoint(fromTopLeftScreenPoint: CGPoint(x: 220, y: 360), primaryDisplayHeight: 1117) == CGPoint(x: 220, y: 757),
    "screen points flip y about the primary display"
)

let shortWait = ExtensionBrowserReplies.settleRequestTimeouts(forWaitSeconds: 4)
check(shortWait.waitSeconds == 4 && shortWait.requestTimeoutSeconds == 7, "Wisp waits a little longer than the extension does")
let longWait = ExtensionBrowserReplies.settleRequestTimeouts(forWaitSeconds: 60)
check(longWait.requestTimeoutSeconds <= 30 && longWait.waitSeconds < longWait.requestTimeoutSeconds, "never past the bridge's 30s cap")

// MARK: - Result

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
