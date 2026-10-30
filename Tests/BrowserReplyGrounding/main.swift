//
//  Browser reply grounding suite: the closing message after a browser task
//  must describe the page the task ended on, not the screen from before it ran.
//  Covers the load-readiness rule (the outgoing document also reads
//  "complete") and the explicit STATUS line in the task result.
//

import Foundation

// BrowserController.swift reads two limits from the real controller, which
// drags in AppleScript and AppKit; the suite only needs the names to resolve.
enum AppleScriptBrowserController {
    static let defaultTextCharacterLimit = 1000
    static let defaultElementLimit = 40
}

var failureCount = 0
var checkCount = 0

func check(_ condition: Bool, _ description: String) {
    checkCount += 1
    if !condition {
        failureCount += 1
        print("FAIL: \(description)")
    }
}

func isLoaded(
    readyState: String?, outgoingStillShowing: Bool, expectsNavigation: Bool,
    waited: TimeInterval, maximumWait: TimeInterval
) -> Bool {
    BrowserLoadReadiness.isLoaded(
        readyState: readyState,
        outgoingDocumentStillShowing: outgoingStillShowing,
        expectsNavigation: expectsNavigation,
        secondsWaitedForReplacement: waited,
        maximumWaitForReplacementSeconds: maximumWait
    )
}

// The bug: right after navigate, the old page says "complete" and must not count.
check(!isLoaded(readyState: "complete", outgoingStillShowing: true, expectsNavigation: true, waited: 0.1, maximumWait: .infinity),
      "outgoing document reading complete is not the new page")
check(!isLoaded(readyState: "complete", outgoingStillShowing: true, expectsNavigation: true, waited: 9, maximumWait: .infinity),
      "a direct navigation keeps waiting for the replacement until the caller's timeout")
check(isLoaded(readyState: "complete", outgoingStillShowing: false, expectsNavigation: true, waited: 0.3, maximumWait: .infinity),
      "the replacement document, complete, is loaded")
check(!isLoaded(readyState: "loading", outgoingStillShowing: false, expectsNavigation: true, waited: 0.3, maximumWait: .infinity),
      "a replacement still loading is not ready")
check(!isLoaded(readyState: nil, outgoingStillShowing: false, expectsNavigation: true, waited: 0.3, maximumWait: .infinity),
      "an unscriptable page is not ready")

// Clicks that never navigate must not hang the task.
check(!isLoaded(readyState: "complete", outgoingStillShowing: true, expectsNavigation: true, waited: 0.5, maximumWait: 2),
      "a click gets a short window to navigate")
check(isLoaded(readyState: "complete", outgoingStillShowing: true, expectsNavigation: true, waited: 2.1, maximumWait: 2),
      "a click that never navigated is treated as a same-page update")

// No navigation expected: old behaviour.
check(isLoaded(readyState: "complete", outgoingStillShowing: true, expectsNavigation: false, waited: 0, maximumWait: 0),
      "without a pending navigation, complete means loaded")

// The task result tells the model which view of the world to believe.
let enigmaSnapshot = BrowserPageSnapshot(
    url: "https://en.wikipedia.org/wiki/Enigma_machine",
    title: "Enigma machine - Wikipedia",
    headings: [], elements: [], text: ""
)
let successfulResult = BrowserTaskResult(
    goal: "open wikipedia and search for the Enigma machine",
    stepLog: ["open wikipedia — 800ms"],
    finalSnapshot: enigmaSnapshot, totalDuration: 3, browserOperationCount: 3,
    didSucceed: true, failureReason: nil
)
let successText = successfulResult.promptRepresentation()
check(successText.contains("STATUS: completed"), "a successful task says it completed")
check(successText.contains("Enigma machine - Wikipedia") && successText.contains("wikipedia.org/wiki/Enigma_machine"),
      "the status names the final title and URL")
check(successText.contains("out of date"), "the status says earlier screenshots are out of date")

let failedResult = BrowserTaskResult(
    goal: "x", stepLog: [], finalSnapshot: enigmaSnapshot, totalDuration: 1,
    browserOperationCount: 0, didSucceed: false, failureReason: "no such field"
)
check(!failedResult.promptRepresentation().contains("STATUS: completed"), "a failed task never claims completion")
check(failedResult.promptRepresentation().contains("STOPPED: no such field"), "a failed task still reports why")

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
