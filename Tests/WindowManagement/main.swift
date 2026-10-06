//
//  Window management suite: spoken layout commands, app-name resolution,
//  frames across displays (including the AppKit ↔ Accessibility flip), and
//  the notch reply.
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

let runningApplicationNames = [
    "Safari", "Xcode", "Google Chrome", "Notes", "Mail", "Finder", "Code", "Music",
    "Microsoft Word", "Microsoft Outlook", "Terminal", "Messages", "Slack", "System Settings",
    "Safari", // a second process with the same name is the same app
]

func command(_ transcript: String) -> WindowLayoutCommand? {
    WindowLayoutCommandParser.command(from: transcript, runningApplicationNames: runningApplicationNames)
}

func assignments(_ transcript: String) -> [WindowLayoutAssignment]? {
    command(transcript)?.assignments
}

func app(_ name: String, _ placement: WindowPlacement) -> WindowLayoutAssignment {
    WindowLayoutAssignment(target: .application(named: name), placement: placement)
}

func front(_ placement: WindowPlacement) -> WindowLayoutAssignment {
    WindowLayoutAssignment(target: .frontWindow, placement: placement)
}

// MARK: Recognised commands

check(assignments("Put Safari on the left and Xcode on the right") == [app("Safari", .leftHalf), app("Xcode", .rightHalf)],
      "two apps, left and right")
check(assignments("put safari on the left, xcode on the right.") == [app("Safari", .leftHalf), app("Xcode", .rightHalf)],
      "comma-separated clauses")
check(assignments("Hey Wisp, put Safari on the left and move Xcode to the right half") == [app("Safari", .leftHalf), app("Xcode", .rightHalf)],
      "greeting + repeated verb")
check(assignments("move Chrome to the right half") == [app("Google Chrome", .rightHalf)], "chrome → Google Chrome")
check(assignments("Make this window full screen") == [front(.maximize)], "make this window full screen")
check(assignments("make it full screen") == [front(.maximize)], "make it full screen")
check(assignments("maximize this") == [front(.maximize)], "maximize this")
check(assignments("Maximise Xcode") == [app("Xcode", .maximize)], "maximise xcode")
check(assignments("center this window") == [front(.center)], "center this window")
check(assignments("centre safari") == [app("Safari", .center)], "centre safari")
check(assignments("move this to my other screen") == [front(.nextDisplay)], "move this to my other screen")
check(assignments("send it to the external display") == [front(.nextDisplay)], "send it to the external display")
check(assignments("move notes to the next monitor") == [app("Notes", .nextDisplay)], "next monitor")
check(assignments("tile Notes and Mail") == [app("Notes", .leftHalf), app("Mail", .rightHalf)], "tile notes and mail")
check(assignments("tile mail and notes side by side") == [app("Mail", .leftHalf), app("Notes", .rightHalf)], "tile … side by side")
check(assignments("put safari and xcode side by side") == [app("Safari", .leftHalf), app("Xcode", .rightHalf)], "put … side by side")
check(assignments("snap terminal to the top-left corner") == [app("Terminal", .topLeftQuarter)], "top-left corner")
check(assignments("put messages in the bottom right") == [app("Messages", .bottomRightQuarter)], "bottom right")
check(assignments("move slack to the left third") == [app("Slack", .leftThird)], "left third")
check(assignments("put xcode in the middle third") == [app("Xcode", .centerThird)], "middle third")
check(assignments("move this window to the top half") == [front(.topHalf)], "this window top half")
check(assignments("move this to the left half of the screen") == [front(.leftHalf)], "this + left half of the screen")
check(assignments("put it on the left side of the screen") == [front(.leftHalf)], "it + left side of the screen")
check(assignments("put the safari window on the right") == [app("Safari", .rightHalf)], "the safari window")
check(assignments("move xcode's window to the bottom") == [app("Xcode", .bottomHalf)], "xcode's window")
check(assignments("could you put Code on the left please") == [app("Code", .leftHalf)], "politeness stripped")
check(assignments("put system settings in the center") == [app("System Settings", .center)], "two-word app, center")
check(assignments("put settings on the right") == [app("System Settings", .rightHalf)], "suffix word of a two-word name")
check(assignments("put outlook on the left") == [app("Microsoft Outlook", .leftHalf)], "vendor word dropped")
check(assignments("make chrome fill the screen") == [app("Google Chrome", .maximize)], "fill the screen")
check(assignments("put safari in full screen") == [app("Safari", .maximize)], "put … in full screen")

// MARK: Must NOT match

let mustNotMatch = [
    "what's on the left side of the screen",
    "move on to the next step",
    "put it on the left",                       // "it" + bare "left" may be text in a document
    "move this to the right",
    "center this",                              // text alignment
    "center the text",
    "put the milk on the left shelf",
    "move the code to the right",               // a thing, even with Code running
    "put my notes on the left",                 // ditto with Notes
    "move photoshop to the left",               // not running: fall through, don't guess
    "put microsoft on the left",                // Word and Outlook both match
    "send this to my mom",
    "how do i put safari on the left",
    "can you tell me how to tile windows",
    "split the bill and the tip",
    "tile this and that",
    "tile safari and safari",
    "put safari on the left and safari on the right",
    "put safari on the left and xcode somewhere",  // every clause must parse
    "move this to the other screen and that to the left half", // two front windows
    "move forward to the next page",
    "put a pin in it",
    "make it bigger",
    "make this better",
    "maximize my productivity",
    "where is the safari window",
    "open safari",
    "move the meeting to the right time",
    "throw it to the left",
    "",
]
for transcript in mustNotMatch {
    check(command(transcript) == nil, "must not match: \"\(transcript)\"")
}

// MARK: App names

func resolved(_ spoken: String, _ names: [String] = runningApplicationNames) -> String? {
    WindowLayoutApplicationNameMatcher.uniqueApplicationName(matching: spoken, among: names)
}
check(resolved("SAFARI") == "Safari", "case-insensitive")
check(resolved("x code") == "Xcode", "spaces ignored in exact match")
check(resolved("chrome") == "Google Chrome", "suffix word")
check(resolved("google") == "Google Chrome", "prefix word")
check(resolved("microsoft") == nil, "ambiguous prefix")
check(resolved("word") == "Microsoft Word", "word → Microsoft Word")
check(resolved("photoshop") == nil, "not running")
check(resolved("") == nil, "empty")
check(resolved("notes", ["Notes", "Sticky Notes"]) == "Notes", "an exact match beats a partial one")
check(resolved("studio", ["Visual Studio Code"]) == nil, "a middle word is not a match")

// MARK: Tool-argument placements

check(WindowLayoutCommandParser.placement(fromToolArgument: "left_half") == .leftHalf, "raw value")
check(WindowLayoutCommandParser.placement(fromToolArgument: "Left") == .leftHalf, "bare side")
check(WindowLayoutCommandParser.placement(fromToolArgument: "maximize") == .maximize, "maximize")
check(WindowLayoutCommandParser.placement(fromToolArgument: "top right corner") == .topRightQuarter, "phrase")
check(WindowLayoutCommandParser.placement(fromToolArgument: "next-display") == .nextDisplay, "hyphenated")
check(WindowLayoutCommandParser.placement(fromToolArgument: "diagonal") == nil, "unknown placement")

// MARK: Frames

// Primary: a 1512×982 laptop panel at the AppKit origin, menu bar 33pt, Dock hidden.
let primaryDisplayHeight: CGFloat = 982
let primaryVisibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 949)
// Secondary: 1920×1080 to the right and 200pt higher (AppKit y grows up), its own menu bar 25pt.
let secondaryVisibleFrame = CGRect(x: 1512, y: 200, width: 1920, height: 1055)
let bothDisplays = [primaryVisibleFrame, secondaryVisibleFrame]

func frame(_ placement: WindowPlacement, window: CGRect, displays: [CGRect] = bothDisplays) -> CGRect? {
    WindowFrameCalculator.targetAccessibilityFrame(
        for: placement,
        currentWindowAccessibilityFrame: window,
        displayVisibleFramesInAppKitCoordinates: displays,
        primaryDisplayHeight: primaryDisplayHeight
    )
}

let windowOnPrimary = CGRect(x: 100, y: 100, width: 800, height: 600)    // AX, top-left origin
let windowOnSecondary = CGRect(x: 1700, y: -200, width: 800, height: 600) // AX: above the primary's top edge

check(WindowFrameCalculator.appKitRect(fromAccessibilityRect: windowOnPrimary, primaryDisplayHeight: primaryDisplayHeight)
      == CGRect(x: 100, y: 282, width: 800, height: 600), "AX → AppKit flip uses the primary height")
check(WindowFrameCalculator.accessibilityRect(
        fromAppKitRect: WindowFrameCalculator.appKitRect(fromAccessibilityRect: windowOnSecondary, primaryDisplayHeight: primaryDisplayHeight),
        primaryDisplayHeight: primaryDisplayHeight) == windowOnSecondary, "flip round-trips")

check(WindowFrameCalculator.displayIndex(forWindowAccessibilityFrame: windowOnPrimary,
                                         displayVisibleFramesInAppKitCoordinates: bothDisplays,
                                         primaryDisplayHeight: primaryDisplayHeight) == 0, "window on primary")
check(WindowFrameCalculator.displayIndex(forWindowAccessibilityFrame: windowOnSecondary,
                                         displayVisibleFramesInAppKitCoordinates: bothDisplays,
                                         primaryDisplayHeight: primaryDisplayHeight) == 1, "window on secondary")

check(frame(.leftHalf, window: windowOnPrimary) == CGRect(x: 0, y: 33, width: 756, height: 949), "primary left half sits under the menu bar")
check(frame(.rightHalf, window: windowOnPrimary) == CGRect(x: 756, y: 33, width: 756, height: 949), "primary right half")
check(frame(.maximize, window: windowOnPrimary) == CGRect(x: 0, y: 33, width: 1512, height: 949), "primary maximize")
check(frame(.topHalf, window: windowOnPrimary) == CGRect(x: 0, y: 33, width: 1512, height: 474), "primary top half is the upper part")
check(frame(.bottomHalf, window: windowOnPrimary) == CGRect(x: 0, y: 507, width: 1512, height: 475), "primary bottom half")
check(frame(.topLeftQuarter, window: windowOnPrimary) == CGRect(x: 0, y: 33, width: 756, height: 474), "primary top-left quarter")
check(frame(.bottomRightQuarter, window: windowOnPrimary) == CGRect(x: 756, y: 507, width: 756, height: 475), "primary bottom-right quarter")
check(frame(.leftThird, window: windowOnPrimary) == CGRect(x: 0, y: 33, width: 504, height: 949), "left third")
check(frame(.centerThird, window: windowOnPrimary) == CGRect(x: 504, y: 33, width: 504, height: 949), "center third")
check(frame(.rightThird, window: windowOnPrimary) == CGRect(x: 1008, y: 33, width: 504, height: 949), "right third")
check(frame(.center, window: windowOnPrimary) == CGRect(x: 356, y: 207, width: 800, height: 600), "center keeps the size")
check(frame(.center, window: CGRect(x: 0, y: 0, width: 3000, height: 2000)) == CGRect(x: 0, y: 33, width: 1512, height: 949),
      "center clamps an oversized window")

// The secondary display's top edge is at AppKit y 1255 → AX y 982 − 1255 = −273.
check(frame(.rightHalf, window: windowOnSecondary) == CGRect(x: 2472, y: -273, width: 960, height: 1055), "secondary right half")
check(frame(.topHalf, window: windowOnSecondary) == CGRect(x: 1512, y: -273, width: 1920, height: 527), "secondary top half")
check(frame(.maximize, window: windowOnSecondary) == CGRect(x: 1512, y: -273, width: 1920, height: 1055), "secondary maximize")

// Next display: same relative spot and size, wrapping round.
let primaryLeftHalf = CGRect(x: 0, y: 33, width: 756, height: 949)
check(frame(.nextDisplay, window: primaryLeftHalf) == CGRect(x: 1512, y: -273, width: 960, height: 1055), "left half → secondary's left half")
check(frame(.nextDisplay, window: CGRect(x: 2472, y: -273, width: 960, height: 1055)) == CGRect(x: 756, y: 33, width: 756, height: 949),
      "secondary right half wraps to primary right half")
check(frame(.nextDisplay, window: windowOnPrimary, displays: [primaryVisibleFrame]) == nil, "next display with one display")
check(frame(.leftHalf, window: windowOnPrimary, displays: []) == nil, "no displays")

// A window mostly off every display goes by overlap.
let windowHangingOffTheRight = CGRect(x: 3300, y: -100, width: 800, height: 400)
check(WindowFrameCalculator.displayIndex(forWindowAccessibilityFrame: windowHangingOffTheRight,
                                         displayVisibleFramesInAppKitCoordinates: bothDisplays,
                                         primaryDisplayHeight: primaryDisplayHeight) == 1, "off-screen centre → most overlap")

// MARK: Replies

typealias Result = WindowLayoutReplyText.AssignmentResult
check(WindowLayoutReplyText.reply(for: [
    Result(applicationDisplayName: "Safari", placement: .leftHalf, failureReason: nil),
    Result(applicationDisplayName: "Xcode", placement: .rightHalf, failureReason: nil),
]) == "done — Safari left, Xcode right.", "all placed")
check(WindowLayoutReplyText.reply(for: [
    Result(applicationDisplayName: "Safari", placement: .maximize, failureReason: nil),
]) == "done — Safari full screen.", "maximize reply")
check(WindowLayoutReplyText.reply(for: [
    Result(applicationDisplayName: "Safari", placement: .leftHalf, failureReason: nil),
    Result(applicationDisplayName: "Xcode", placement: .rightHalf, failureReason: "has no open window"),
]) == "done — Safari left. but Xcode has no open window.", "partial")
check(WindowLayoutReplyText.reply(for: [
    Result(applicationDisplayName: "Notes", placement: .nextDisplay, failureReason: "can't move: there's only one display"),
]) == "i couldn't move that: Notes can't move: there's only one display.", "all failed")

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
