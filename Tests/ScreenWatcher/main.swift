//
//  Screen watcher suite: the spoken requests that start and stop a watch, the
//  whole-word OCR matching, and the evaluator fed successive screen readings.
//

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

func parsed(_ transcript: String) -> ScreenWatchRequest? {
    ScreenWatchRequestParser.request(from: transcript)
}

func expect(_ transcript: String, _ expectedRequest: ScreenWatchRequest?) {
    let actualRequest = parsed(transcript)
    check(actualRequest == expectedRequest, "\"\(transcript)\" → \(String(describing: actualRequest)), expected \(String(describing: expectedRequest))")
}

// MARK: Starting a "text appears" watch

expect("Tell me when it says Succeeded", .startWatching(.textAppears("Succeeded")))
expect("tell me when it says “Succeeded.”", .startWatching(.textAppears("Succeeded")))
expect("Watch this terminal and tell me when it says Succeeded.", .startWatching(.textAppears("Succeeded")))
expect("Can you let me know when the terminal shows build complete?", .startWatching(.textAppears("build complete")))
expect("let me know when xcode says Build Succeeded please", .startWatching(.textAppears("Build Succeeded")))
expect("tell me when it says that the tests passed", .startWatching(.textAppears("the tests passed")))
expect("tell me when the log prints DONE on the screen", .startWatching(.textAppears("DONE")))
expect("tell me when Build Succeeded appears", .startWatching(.textAppears("Build Succeeded")))
expect("tell me when the word ready shows up", .startWatching(.textAppears("ready")))
expect("hey wisp, notify me as soon as \"Export complete\" pops up", .startWatching(.textAppears("Export complete")))
expect("watch for \"Done\"", .startWatching(.textAppears("Done")))
expect("watch the screen for the word error", .startWatching(.textAppears("error")))
expect("keep an eye out for Upload complete to appear", .startWatching(.textAppears("Upload complete")))

// MARK: Starting a "text disappears" watch

expect("tell me when downloading goes away", .startWatching(.textDisappears("downloading")))
expect("let me know when the text Uploading disappears", .startWatching(.textDisappears("Uploading")))
expect("watch for \"Installing\" to go away", .startWatching(.textDisappears("Installing")))

// MARK: Starting a "settles" watch

expect("tell me when the build finishes", .startWatching(.screenTextSettles))
expect("Let me know when this download is done.", .startWatching(.screenTextSettles))
expect("tell me when it's done", .startWatching(.screenTextSettles))
expect("tell me when it's finished downloading", .startWatching(.screenTextSettles))
expect("ping me once the export completes", .startWatching(.screenTextSettles))
expect("tell me when the progress bar stops moving", .startWatching(.screenTextSettles))
expect("let me know when the video is done rendering", .startWatching(.screenTextSettles))
expect("wait for the export to finish and tell me", .startWatching(.screenTextSettles))
expect("could you tell me when my install is complete", .startWatching(.screenTextSettles))

// MARK: Stopping

expect("stop watching", .stopAllWatching)
expect("Stop watching the screen.", .stopAllWatching)
expect("ok stop watching that", .stopAllWatching)
expect("cancel the screen watch", .stopAllWatching)
expect("cancel all watchers", .stopAllWatching)
expect("you can stop watching now", nil) // "now" after — not a shape we take; falls through

// MARK: Declined (left to the model)

expect("tell me when you're done", nil)
expect("let me know when the meeting is over", nil)
expect("tell me when dinner is ready", nil)
expect("tell me when mom says she's home", nil)
expect("tell me when the dialog appears", nil)
expect("tell me when an error appears", nil)
expect("watch for new emails", nil)
expect("when does the build finish", nil)
expect("tell me a joke", nil)
expect("remind me when the build finishes", nil)
expect("tell me when the timer is done", nil)
expect("stop", nil)
expect("watch youtube", nil)
expect("tell me when it says " + String(repeating: "word ", count: 12), nil)
expect("what does the screen say", nil)
expect("tell me when it shows up", nil)

// MARK: Text matching

check(ScreenWatchTextMatching.normalizedText("** BUILD SUCCEEDED **") == "build succeeded", "normalised shouting")
check(ScreenWatchTextMatching.normalizedText("Café  —  déjà vu") == "cafe deja vu", "accents and dashes")
check(ScreenWatchTextMatching.screenLine("** BUILD SUCCEEDED **", containsTargetText: "Build Succeeded"), "case and punctuation")
check(ScreenWatchTextMatching.screenLine("Task done.", containsTargetText: "done"), "whole word at end")
check(!ScreenWatchTextMatching.screenLine("abandoned branch", containsTargetText: "done"), "no partial-word match")
check(!ScreenWatchTextMatching.screenLine("anything", containsTargetText: "  "), "empty target never matches")

// MARK: Evaluator — text appears

do {
    var evaluator = ScreenWatchEvaluator(condition: .textAppears("Succeeded"))
    check(evaluator.observe(screenLines: ["Compiling Foo.swift", "Linking"]) == .stillWaiting, "baseline")
    check(evaluator.observe(screenLines: ["Compiling Bar.swift"]) == .stillWaiting, "still working")
    check(evaluator.observe(screenLines: ["Compiling Bar.swift", "** BUILD SUCCEEDED **"]) == .conditionMet(matchedLineText: "** BUILD SUCCEEDED **"), "appears")
}

do {
    // The last build's "Succeeded" is already on screen when the watch starts.
    var evaluator = ScreenWatchEvaluator(condition: .textAppears("Succeeded"))
    check(evaluator.observe(screenLines: ["Build Succeeded", "$"]) == .stillWaiting, "already present at start")
    check(evaluator.observe(screenLines: ["Build Succeeded", "$ make"]) == .stillWaiting, "old one still there")
    check(evaluator.observe(screenLines: ["Build Succeeded", "$ make", "Build Succeeded"]) != .stillWaiting, "a second occurrence fires")
}

do {
    // The old occurrence scrolls away, then a new one arrives.
    var evaluator = ScreenWatchEvaluator(condition: .textAppears("Succeeded"))
    _ = evaluator.observe(screenLines: ["Build Succeeded"])
    check(evaluator.observe(screenLines: ["compiling"]) == .stillWaiting, "scrolled off (1)")
    check(evaluator.observe(screenLines: ["compiling more"]) == .stillWaiting, "scrolled off (2)")
    check(evaluator.observe(screenLines: ["Build Succeeded"]) != .stillWaiting, "new occurrence after scroll-off fires")
}

do {
    // One misread poll must not make the next correct reading look new.
    var evaluator = ScreenWatchEvaluator(condition: .textAppears("Succeeded"))
    _ = evaluator.observe(screenLines: ["Build Succeeded"])
    check(evaluator.observe(screenLines: ["Build Succeeoed"]) == .stillWaiting, "misread")
    check(evaluator.observe(screenLines: ["Build Succeeded"]) == .stillWaiting, "one misread doesn't fire")
}

// MARK: Evaluator — text disappears

do {
    var evaluator = ScreenWatchEvaluator(condition: .textDisappears("Downloading"))
    check(evaluator.observe(screenLines: ["Downloading… 12 MB of 80 MB"]) == .stillWaiting, "present")
    check(evaluator.observe(screenLines: ["Finder"]) == .stillWaiting, "gone once")
    check(evaluator.observe(screenLines: ["Downloading… 40 MB of 80 MB"]) == .stillWaiting, "back again resets")
    check(evaluator.observe(screenLines: ["Finder"]) == .stillWaiting, "gone once again")
    check(evaluator.observe(screenLines: ["Finder", "report.pdf"]) == .conditionMet(matchedLineText: nil), "gone twice fires")
}

do {
    var evaluator = ScreenWatchEvaluator(condition: .textDisappears("Downloading"))
    for _ in 0..<5 {
        check(evaluator.observe(screenLines: ["Finder"]) == .stillWaiting, "never seen: waits")
    }
}

// MARK: Evaluator — settles

do {
    var evaluator = ScreenWatchEvaluator(condition: .screenTextSettles)
    check(evaluator.observe(screenLines: ["Building 10%"]) == .stillWaiting, "baseline")
    check(evaluator.observe(screenLines: ["Building 40%"]) == .stillWaiting, "changing")
    check(evaluator.observe(screenLines: ["Building 90%"]) == .stillWaiting, "changing")
    check(evaluator.observe(screenLines: ["Done"]) == .stillWaiting, "changed to done")
    for pollIndex in 1..<ScreenWatchEvaluator.unchangedPollCountToSettle {
        check(evaluator.observe(screenLines: ["Done"]) == .stillWaiting, "settling poll \(pollIndex)")
    }
    check(evaluator.observe(screenLines: ["Done"]) == .conditionMet(matchedLineText: nil), "settled")
}

do {
    // A screen that never changes is still waiting for the work to start.
    var evaluator = ScreenWatchEvaluator(condition: .screenTextSettles)
    for _ in 0..<10 {
        check(evaluator.observe(screenLines: ["Idle"]) == .stillWaiting, "unchanged from the start never settles")
    }
}

do {
    // Same lines in a different order are not a change; a change resets the count.
    var evaluator = ScreenWatchEvaluator(condition: .screenTextSettles)
    _ = evaluator.observe(screenLines: ["a", "b"])
    _ = evaluator.observe(screenLines: ["a", "c"])
    _ = evaluator.observe(screenLines: ["c", "a"])
    _ = evaluator.observe(screenLines: ["a", "c"])
    _ = evaluator.observe(screenLines: ["a", "c", "d"])
    var settledPollNumber: Int?
    for pollNumber in 1...6 where settledPollNumber == nil {
        if evaluator.observe(screenLines: ["d", "c", "a"]) != .stillWaiting { settledPollNumber = pollNumber }
    }
    check(settledPollNumber == ScreenWatchEvaluator.unchangedPollCountToSettle, "reordering isn't change; reset on change (settled at \(String(describing: settledPollNumber)))")
}

// MARK: Summaries

check(ScreenWatchCondition.textAppears("Done").summaryText == "“Done” appears", "appears summary")
check(ScreenWatchCondition.screenTextSettles.summaryText == "the screen stops changing", "settles summary")

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
