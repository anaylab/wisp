//
//  WindowLayoutCommand.swift
//  leanring-buddy
//
//  The pure side of window management: turning "put Safari on the left and
//  Xcode on the right" into a list of (window, placement) assignments, and
//  turning a placement plus a display into the frame a window should take.
//  `WindowLayoutExecutor` does the Accessibility work; nothing here touches
//  another app, so all of it is tested by `Tests/WindowManagement`.
//
//  Like the other routers, the parser is biased hard toward *not* matching. A
//  miss costs the user one ordinary model turn; a false positive throws their
//  windows around in answer to a question. So a command must start with a
//  window verb, every clause must parse completely, every app name must be a
//  running app (unique match only — never a guess), and a bare "this"/"it"
//  only counts with a placement that can only mean a window ("left half", not
//  "left" — "move this to the left" may be about text in a document).
//

import CoreGraphics
import Foundation

// MARK: - Model

/// Where a window should go on its display.
nonisolated enum WindowPlacement: String, CaseIterable, Sendable, Equatable {
    case leftHalf = "left_half"
    case rightHalf = "right_half"
    case topHalf = "top_half"
    case bottomHalf = "bottom_half"
    case maximize = "maximize"
    case center = "center"
    case topLeftQuarter = "top_left"
    case topRightQuarter = "top_right"
    case bottomLeftQuarter = "bottom_left"
    case bottomRightQuarter = "bottom_right"
    case leftThird = "left_third"
    case centerThird = "center_third"
    case rightThird = "right_third"
    /// The same relative spot on the next display (wrapping round).
    case nextDisplay = "next_display"

    /// Short words for the notch reply: "Safari left, Xcode right".
    var shortReplyLabel: String {
        switch self {
        case .leftHalf: return "left"
        case .rightHalf: return "right"
        case .topHalf: return "top"
        case .bottomHalf: return "bottom"
        case .maximize: return "full screen"
        case .center: return "centered"
        case .topLeftQuarter: return "top left"
        case .topRightQuarter: return "top right"
        case .bottomLeftQuarter: return "bottom left"
        case .bottomRightQuarter: return "bottom right"
        case .leftThird: return "left third"
        case .centerThird: return "middle third"
        case .rightThird: return "right third"
        case .nextDisplay: return "on the other screen"
        }
    }

    /// Whether the placement changes the window's size, not just its position.
    /// A window that can't be resized can still be centered or sent to the
    /// other screen.
    var requiresResizing: Bool {
        switch self {
        case .center, .nextDisplay: return false
        default: return true
        }
    }
}

/// Which window a command is about.
nonisolated enum WindowLayoutTarget: Sendable, Equatable {
    /// "this", "it", "this window": the app the user was last in (not Wisp,
    /// which a typed question makes frontmost).
    case frontWindow
    /// A running app, by its exact localized name as macOS reports it.
    case application(named: String)
}

nonisolated struct WindowLayoutAssignment: Sendable, Equatable {
    let target: WindowLayoutTarget
    let placement: WindowPlacement
}

/// One recognised command: one or more windows to place, in the order said.
nonisolated struct WindowLayoutCommand: Sendable, Equatable {
    let assignments: [WindowLayoutAssignment]
}

// MARK: - App names

/// Resolves a spoken app name against the names of the running apps.
///
/// Exact (case- and punctuation-insensitive) first; otherwise a run of whole
/// words at the start or end of a multi-word name ("chrome" → "Google Chrome",
/// "outlook" → "Microsoft Outlook"). Either way the match must be unique — two
/// candidates is not a match, because guessing which window the user meant is
/// exactly the mistake this must not make.
nonisolated enum WindowLayoutApplicationNameMatcher {
    static func uniqueApplicationName(matching spokenName: String, among runningApplicationNames: [String]) -> String? {
        let spokenWords = comparableWords(spokenName)
        guard !spokenWords.isEmpty else { return nil }

        // Several processes can share a name; they are the same app for this.
        var distinctApplicationNames: [String] = []
        for applicationName in runningApplicationNames where !distinctApplicationNames.contains(applicationName) {
            distinctApplicationNames.append(applicationName)
        }

        let exactMatches = distinctApplicationNames.filter { applicationName in
            comparableWords(applicationName).joined() == spokenWords.joined()
        }
        if exactMatches.count == 1 { return exactMatches[0] }
        if exactMatches.count > 1 { return nil }

        let partialMatches = distinctApplicationNames.filter { applicationName in
            let applicationWords = comparableWords(applicationName)
            guard applicationWords.count > spokenWords.count else { return false }
            return Array(applicationWords.prefix(spokenWords.count)) == spokenWords
                || Array(applicationWords.suffix(spokenWords.count)) == spokenWords
        }
        return partialMatches.count == 1 ? partialMatches[0] : nil
    }

    /// Lowercased alphanumeric words: "Visual Studio Code" → visual, studio, code;
    /// "Notes." → notes.
    static func comparableWords(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}

// MARK: - Parser

nonisolated enum WindowLayoutCommandParser {
    /// Most windows one command may place. More than this is a paragraph,
    /// not a command.
    static let maximumAssignmentCount = 4

    /// Verbs that move a window to a named place: "put X on the left".
    private static let placingVerbs = ["put", "move", "snap", "place", "send", "throw", "drag", "push", "shove", "dock"]

    /// Words that, alone, mean the window the user is in.
    private static let bareFrontWindowPronouns: Set<String> = ["this", "it", "that"]

    /// Phrases that unambiguously mean the front window.
    private static let explicitFrontWindowPhrases: Set<String> = [
        "this window", "the window", "that window", "this app", "the app", "this application",
        "the current window", "current window", "the front window", "front window",
        "the frontmost window", "frontmost window", "the active window", "active window",
        "my window", "the focused window", "focused window",
    ]

    /// Recognises a window-layout command, or returns nil.
    ///
    /// - Parameter runningApplicationNames: The localized names of the apps
    ///   that are running, which are the only names a target may resolve to.
    static func command(from transcript: String, runningApplicationNames: [String]) -> WindowLayoutCommand? {
        let normalizedText = normalized(transcript)
        guard !normalizedText.isEmpty, normalizedText.count <= 160 else { return nil }

        if let tilingCommand = tilingCommand(from: normalizedText, runningApplicationNames: runningApplicationNames) {
            return tilingCommand
        }
        if let wholeWindowCommand = wholeWindowCommand(from: normalizedText, runningApplicationNames: runningApplicationNames) {
            return wholeWindowCommand
        }
        return placingCommand(from: normalizedText, runningApplicationNames: runningApplicationNames)
    }

    // MARK: Normalisation

    /// Lowercased, end punctuation and politeness stripped, hyphens and
    /// commas made into word gaps the clause splitter can see.
    static func normalized(_ transcript: String) -> String {
        var text = transcript.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ",", with: " , ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        text = text.split(separator: " ").joined(separator: " ")

        let leadingFillers = ["hey wisp , ", "hey wisp ", "wisp , ", "wisp ", "okay , ", "okay ", "ok , ", "ok ",
                              "please ", "can you ", "could you ", "would you ", "will you ", "go ahead and ", "just "]
        var didStripFiller = true
        while didStripFiller {
            didStripFiller = false
            for leadingFiller in leadingFillers where text.hasPrefix(leadingFiller) {
                text = String(text.dropFirst(leadingFiller.count))
                didStripFiller = true
            }
        }
        let trailingFillers = [" for me please", " for me", " please", " , please"]
        for trailingFiller in trailingFillers where text.hasSuffix(trailingFiller) {
            text = String(text.dropLast(trailingFiller.count))
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: "tile notes and mail"

    /// "tile notes and mail", "tile notes and mail side by side",
    /// "put notes and mail side by side", "split screen safari and xcode":
    /// the first app on the left half, the second on the right.
    private static func tilingCommand(from text: String, runningApplicationNames: [String]) -> WindowLayoutCommand? {
        var remainder: String
        if let tilingPrefix = ["tile ", "split screen ", "split "].first(where: { text.hasPrefix($0) }) {
            remainder = String(text.dropFirst(tilingPrefix.count))
            for optionalSuffix in [" side by side", " next to each other"] where remainder.hasSuffix(optionalSuffix) {
                remainder = String(remainder.dropLast(optionalSuffix.count))
            }
        } else if let placingVerb = placingVerbs.first(where: { text.hasPrefix($0 + " ") }),
                  text.hasSuffix(" side by side") || text.hasSuffix(" next to each other") {
            remainder = String(text.dropFirst(placingVerb.count + 1))
            for requiredSuffix in [" side by side", " next to each other"] where remainder.hasSuffix(requiredSuffix) {
                remainder = String(remainder.dropLast(requiredSuffix.count))
            }
        } else {
            return nil
        }

        let applicationPhrases = remainder.components(separatedBy: " and ")
        guard applicationPhrases.count == 2 else { return nil }
        // Pronouns are not tiled: "tile this and that" names nothing.
        guard let leftApplicationName = applicationName(fromTargetPhrase: applicationPhrases[0], runningApplicationNames: runningApplicationNames),
              let rightApplicationName = applicationName(fromTargetPhrase: applicationPhrases[1], runningApplicationNames: runningApplicationNames),
              leftApplicationName != rightApplicationName else { return nil }
        return WindowLayoutCommand(assignments: [
            WindowLayoutAssignment(target: .application(named: leftApplicationName), placement: .leftHalf),
            WindowLayoutAssignment(target: .application(named: rightApplicationName), placement: .rightHalf),
        ])
    }

    // MARK: "maximize this" / "make safari full screen" / "center this window"

    private static func wholeWindowCommand(from text: String, runningApplicationNames: [String]) -> WindowLayoutCommand? {
        // Verb first: "maximize safari", "center this window", "fill the screen with xcode" is not supported.
        let verbPlacements: [(verb: String, placement: WindowPlacement)] = [
            ("maximize ", .maximize), ("maximise ", .maximize),
            ("full screen ", .maximize), ("fullscreen ", .maximize),
            ("center ", .center), ("centre ", .center),
        ]
        for (verb, placement) in verbPlacements where text.hasPrefix(verb) {
            let targetPhrase = String(text.dropFirst(verb.count))
            // "center this" may be about text alignment, so a bare pronoun only
            // counts for maximize; "center this window" names the window.
            guard let target = target(
                fromTargetPhrase: targetPhrase,
                allowsBarePronoun: placement == .maximize,
                runningApplicationNames: runningApplicationNames
            ) else { return nil }
            return WindowLayoutCommand(assignments: [WindowLayoutAssignment(target: target, placement: placement)])
        }

        // "make X full screen", "make X fill the screen", "make X take up the whole screen".
        if text.hasPrefix("make ") {
            let afterMake = String(text.dropFirst("make ".count))
            let maximizingEndings = [" full screen", " fullscreen", " fill the screen", " fill the whole screen",
                                     " take up the whole screen", " take up the full screen", " maximized", " maximised",
                                     " as big as possible", " fill my screen", " fill the display"]
            for maximizingEnding in maximizingEndings where afterMake.hasSuffix(maximizingEnding) {
                let targetPhrase = String(afterMake.dropLast(maximizingEnding.count))
                guard let target = target(fromTargetPhrase: targetPhrase, allowsBarePronoun: true, runningApplicationNames: runningApplicationNames) else {
                    return nil
                }
                return WindowLayoutCommand(assignments: [WindowLayoutAssignment(target: target, placement: .maximize)])
            }
        }
        return nil
    }

    // MARK: "put safari on the left and xcode on the right"

    private static func placingCommand(from text: String, runningApplicationNames: [String]) -> WindowLayoutCommand? {
        guard let leadingVerb = placingVerbs.first(where: { text.hasPrefix($0 + " ") }) else { return nil }
        let afterVerb = String(text.dropFirst(leadingVerb.count + 1))

        // Clauses: "safari on the left and xcode on the right",
        // "safari on the left , xcode on the right".
        let clauseTexts = afterVerb
            .replacingOccurrences(of: " , and ", with: " | ")
            .replacingOccurrences(of: " and then ", with: " | ")
            .replacingOccurrences(of: " and ", with: " | ")
            .replacingOccurrences(of: " , ", with: " | ")
            .components(separatedBy: " | ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !clauseTexts.isEmpty, clauseTexts.count <= maximumAssignmentCount else { return nil }

        var assignments: [WindowLayoutAssignment] = []
        for (clauseIndex, clauseText) in clauseTexts.enumerated() {
            var clauseBody = clauseText
            // Later clauses may repeat a verb: "… and move xcode to the right".
            if clauseIndex > 0, let repeatedVerb = placingVerbs.first(where: { clauseBody.hasPrefix($0 + " ") }) {
                clauseBody = String(clauseBody.dropFirst(repeatedVerb.count + 1))
            }
            guard let assignment = assignment(fromClause: clauseBody, runningApplicationNames: runningApplicationNames) else {
                return nil
            }
            assignments.append(assignment)
        }

        // The same app twice is a contradiction, not a layout.
        let namedApplicationTargets = assignments.compactMap { assignment -> String? in
            if case .application(let applicationName) = assignment.target { return applicationName }
            return nil
        }
        guard Set(namedApplicationTargets).count == namedApplicationTargets.count else { return nil }
        let frontWindowTargetCount = assignments.filter { $0.target == .frontWindow }.count
        guard frontWindowTargetCount <= 1 else { return nil }
        return WindowLayoutCommand(assignments: assignments)
    }

    /// "safari on the left", "this window to the right half",
    /// "this to my other screen". Tries every connector position, so a target
    /// or placement containing "to"/"on" still splits correctly.
    private static func assignment(fromClause clauseText: String, runningApplicationNames: [String]) -> WindowLayoutAssignment? {
        let connectors = [" on ", " to ", " onto ", " into ", " in ", " over to ", " across to "]
        for connector in connectors {
            var searchRange = clauseText.startIndex..<clauseText.endIndex
            while let connectorRange = clauseText.range(of: connector, range: searchRange) {
                let targetPhrase = String(clauseText[clauseText.startIndex..<connectorRange.lowerBound])
                let placementPhrase = String(clauseText[connectorRange.upperBound...])
                if let placementReading = placement(fromPhrase: placementPhrase),
                   let target = target(
                       fromTargetPhrase: targetPhrase,
                       allowsBarePronoun: placementReading.isUnambiguouslyAboutWindows,
                       runningApplicationNames: runningApplicationNames
                   ) {
                    return WindowLayoutAssignment(target: target, placement: placementReading.placement)
                }
                searchRange = connectorRange.upperBound..<clauseText.endIndex
            }
        }
        return nil
    }

    // MARK: Targets

    private static func target(
        fromTargetPhrase rawTargetPhrase: String,
        allowsBarePronoun: Bool,
        runningApplicationNames: [String]
    ) -> WindowLayoutTarget? {
        let targetPhrase = rawTargetPhrase.trimmingCharacters(in: .whitespaces)
        if explicitFrontWindowPhrases.contains(targetPhrase) { return .frontWindow }
        if bareFrontWindowPronouns.contains(targetPhrase) {
            return allowsBarePronoun ? .frontWindow : nil
        }
        guard let resolvedApplicationName = applicationName(fromTargetPhrase: targetPhrase, runningApplicationNames: runningApplicationNames) else {
            return nil
        }
        return .application(named: resolvedApplicationName)
    }

    /// "the safari window", "my chrome", "xcode's window", "notes app" → the
    /// running app's name, or nil when it isn't exactly one running app.
    static func applicationName(fromTargetPhrase rawTargetPhrase: String, runningApplicationNames: [String]) -> String? {
        var targetPhrase = rawTargetPhrase.trimmingCharacters(in: .whitespaces)
        var hadLeadingArticle = false
        for leadingArticle in ["the ", "my ", "that ", "this "] where targetPhrase.hasPrefix(leadingArticle) {
            targetPhrase = String(targetPhrase.dropFirst(leadingArticle.count))
            hadLeadingArticle = true
        }
        var hadTrailingWindowNoun = false
        for trailingNoun in [" windows", " window", " app", " application"] where targetPhrase.hasSuffix(trailingNoun) {
            targetPhrase = String(targetPhrase.dropLast(trailingNoun.count))
            hadTrailingWindowNoun = true
        }
        // "the code", "my notes", "the music" are things, not apps — even with
        // Code, Notes or Music running. With an article, only "the safari
        // window" / "my notes app" names a window.
        guard !hadLeadingArticle || hadTrailingWindowNoun else { return nil }
        if targetPhrase.hasSuffix("'s") { targetPhrase = String(targetPhrase.dropLast(2)) }
        targetPhrase = targetPhrase.trimmingCharacters(in: .whitespaces)
        // An app name is a name, not a sentence.
        guard !targetPhrase.isEmpty, targetPhrase.split(separator: " ").count <= 4 else { return nil }
        guard !bareFrontWindowPronouns.contains(targetPhrase) else { return nil }
        return WindowLayoutApplicationNameMatcher.uniqueApplicationName(
            matching: targetPhrase,
            among: runningApplicationNames
        )
    }

    // MARK: Placements

    struct PlacementReading: Equatable {
        let placement: WindowPlacement
        /// True when the phrase can only be about a window ("left half",
        /// "top right corner", "other screen"), so a bare "this"/"it" may
        /// stand for the window. False for "left", "the middle".
        let isUnambiguouslyAboutWindows: Bool
    }

    /// Reads a placement phrase — what follows "on"/"to" — or returns nil.
    /// The whole phrase must be a placement: "the left shelf" is not one.
    static func placement(fromPhrase rawPlacementPhrase: String) -> PlacementReading? {
        var placementPhrase = " " + rawPlacementPhrase.trimmingCharacters(in: .whitespaces) + " "
        var mentionsTheScreen = false

        for screenSuffix in [" of the screen ", " of my screen ", " of the display ", " of my display ",
                             " of the monitor ", " of my monitor ", " of the desktop "]
            where placementPhrase.hasSuffix(screenSuffix) {
            placementPhrase = String(placementPhrase.dropLast(screenSuffix.count)) + " "
            mentionsTheScreen = true
        }
        for leadingArticle in [" the ", " my ", " a "] where placementPhrase.hasPrefix(leadingArticle) {
            placementPhrase = " " + String(placementPhrase.dropFirst(leadingArticle.count))
        }
        let phrase = placementPhrase.trimmingCharacters(in: .whitespaces)

        let nextDisplayPhrases: Set<String> = [
            "other screen", "other display", "other monitor", "next screen", "next display", "next monitor",
            "second screen", "second display", "second monitor", "external screen", "external display",
            "external monitor", "other desktop screen",
        ]
        if nextDisplayPhrases.contains(phrase) {
            return PlacementReading(placement: .nextDisplay, isUnambiguouslyAboutWindows: true)
        }

        let maximizePhrases: Set<String> = ["full screen", "fullscreen", "whole screen", "entire screen", "full display"]
        if maximizePhrases.contains(phrase) {
            return PlacementReading(placement: .maximize, isUnambiguouslyAboutWindows: true)
        }

        // Quarters and corners: "top left", "upper right corner", "bottom left quarter".
        let cornerPlacements: [(words: [String], placement: WindowPlacement)] = [
            (["top left", "upper left", "left top"], .topLeftQuarter),
            (["top right", "upper right", "right top"], .topRightQuarter),
            (["bottom left", "lower left", "left bottom"], .bottomLeftQuarter),
            (["bottom right", "lower right", "right bottom"], .bottomRightQuarter),
        ]
        for (cornerWords, cornerPlacement) in cornerPlacements {
            for cornerWord in cornerWords {
                if phrase == cornerWord {
                    return PlacementReading(placement: cornerPlacement, isUnambiguouslyAboutWindows: mentionsTheScreen)
                }
                if phrase == cornerWord + " corner" || phrase == cornerWord + " quarter" {
                    return PlacementReading(placement: cornerPlacement, isUnambiguouslyAboutWindows: true)
                }
            }
        }

        // Thirds: "left third", "middle third", "center third", "right third".
        let thirdPlacements: [(word: String, placement: WindowPlacement)] = [
            ("left third", .leftThird), ("right third", .rightThird),
            ("middle third", .centerThird), ("center third", .centerThird), ("centre third", .centerThird),
        ]
        for (thirdWord, thirdPlacement) in thirdPlacements where phrase == thirdWord {
            return PlacementReading(placement: thirdPlacement, isUnambiguouslyAboutWindows: true)
        }

        // Halves: "left", "left half", "left side", "left hand side".
        let halfPlacements: [(sideWords: [String], placement: WindowPlacement)] = [
            (["left"], .leftHalf), (["right"], .rightHalf),
            (["top", "upper"], .topHalf), (["bottom", "lower"], .bottomHalf),
        ]
        for (sideWords, halfPlacement) in halfPlacements {
            for sideWord in sideWords {
                if phrase == sideWord && sideWord != "upper" && sideWord != "lower" {
                    return PlacementReading(placement: halfPlacement, isUnambiguouslyAboutWindows: mentionsTheScreen)
                }
                if phrase == sideWord + " side" || phrase == sideWord + " hand side" {
                    return PlacementReading(placement: halfPlacement, isUnambiguouslyAboutWindows: mentionsTheScreen)
                }
                if phrase == sideWord + " half" {
                    return PlacementReading(placement: halfPlacement, isUnambiguouslyAboutWindows: true)
                }
            }
        }

        if phrase == "center" || phrase == "centre" || phrase == "middle" {
            return PlacementReading(placement: .center, isUnambiguouslyAboutWindows: mentionsTheScreen)
        }
        return nil
    }

    /// Reads an agent tool's `placement` argument: a raw value
    /// ("left_half"), or the same phrases the spoken parser accepts ("left",
    /// "top right corner", "other screen", "maximize").
    static func placement(fromToolArgument rawPlacementArgument: String) -> WindowPlacement? {
        let trimmedArgument = rawPlacementArgument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exactPlacement = WindowPlacement(rawValue: trimmedArgument.replacingOccurrences(of: " ", with: "_")) {
            return exactPlacement
        }
        let spacedArgument = trimmedArgument
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        switch spacedArgument {
        case "maximize", "maximise", "maximized", "fill", "fill screen", "full": return .maximize
        case "next display", "next screen", "other display", "other screen": return .nextDisplay
        default: return placement(fromPhrase: spacedArgument)?.placement
        }
    }
}

// MARK: - Replies

/// The notch reply for a finished command: "done — Safari left, Xcode right."
nonisolated enum WindowLayoutReplyText {
    struct AssignmentResult: Equatable {
        let applicationDisplayName: String
        let placement: WindowPlacement
        /// Nil when the window was placed; otherwise why not, phrased to
        /// follow the app name ("has no open window").
        let failureReason: String?
    }

    static func reply(for assignmentResults: [AssignmentResult]) -> String {
        let placedResults = assignmentResults.filter { $0.failureReason == nil }
        let failedResults = assignmentResults.filter { $0.failureReason != nil }

        let placedSummary = placedResults
            .map { "\($0.applicationDisplayName) \($0.placement.shortReplyLabel)" }
            .joined(separator: ", ")
        let failedSummary = failedResults
            .map { "\($0.applicationDisplayName) \($0.failureReason ?? "couldn't be moved")" }
            .joined(separator: "; ")

        if failedResults.isEmpty {
            return "done — \(placedSummary)."
        }
        if placedResults.isEmpty {
            return "i couldn't move that: \(failedSummary)."
        }
        return "done — \(placedSummary). but \(failedSummary)."
    }
}

// MARK: - Frames

/// Placement + display → the frame a window should take, in Accessibility's
/// top-left-origin global coordinates (what `kAXPositionAttribute` takes).
///
/// Displays come in AppKit's bottom-left-origin global space (`NSScreen`
/// frames), and the flip between the two uses the *primary* display's height
/// — the display at AppKit origin (0,0), `NSScreen.screens[0]` — not the
/// height of whichever display the window is on. Same convention as
/// `AccessibilityElementGeometry.appKitRect(fromAccessibilityRect:…)`.
nonisolated enum WindowFrameCalculator {
    /// AX rect → AppKit rect (and back: the flip is its own inverse).
    static func appKitRect(fromAccessibilityRect accessibilityRect: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
        CGRect(
            x: accessibilityRect.minX,
            y: primaryDisplayHeight - accessibilityRect.maxY,
            width: accessibilityRect.width,
            height: accessibilityRect.height
        )
    }

    static func accessibilityRect(fromAppKitRect appKitRect: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
        CGRect(
            x: appKitRect.minX,
            y: primaryDisplayHeight - appKitRect.maxY,
            width: appKitRect.width,
            height: appKitRect.height
        )
    }

    /// Index of the display a window is on: the one holding its centre, or
    /// failing that the one it overlaps most, or the first.
    static func displayIndex(
        forWindowAccessibilityFrame windowAccessibilityFrame: CGRect,
        displayVisibleFramesInAppKitCoordinates: [CGRect],
        primaryDisplayHeight: CGFloat
    ) -> Int {
        let windowAppKitFrame = appKitRect(fromAccessibilityRect: windowAccessibilityFrame, primaryDisplayHeight: primaryDisplayHeight)
        let windowCenter = CGPoint(x: windowAppKitFrame.midX, y: windowAppKitFrame.midY)
        if let containingIndex = displayVisibleFramesInAppKitCoordinates.firstIndex(where: { $0.contains(windowCenter) }) {
            return containingIndex
        }
        var bestIndex = 0
        var bestOverlapArea: CGFloat = 0
        for (displayIndex, displayFrame) in displayVisibleFramesInAppKitCoordinates.enumerated() {
            let overlap = displayFrame.intersection(windowAppKitFrame)
            let overlapArea = overlap.isNull ? 0 : overlap.width * overlap.height
            if overlapArea > bestOverlapArea {
                bestOverlapArea = overlapArea
                bestIndex = displayIndex
            }
        }
        return bestIndex
    }

    /// The target frame for `placement`, or nil when it can't be computed
    /// (no displays, or "next display" with only one).
    ///
    /// - Parameters:
    ///   - currentWindowAccessibilityFrame: Where the window is now (AX space).
    ///   - displayVisibleFramesInAppKitCoordinates: Each display's
    ///     `NSScreen.visibleFrame` (menu bar and Dock excluded), AppKit space.
    ///   - primaryDisplayHeight: `NSScreen.screens[0].frame.height`.
    static func targetAccessibilityFrame(
        for placement: WindowPlacement,
        currentWindowAccessibilityFrame: CGRect,
        displayVisibleFramesInAppKitCoordinates: [CGRect],
        primaryDisplayHeight: CGFloat
    ) -> CGRect? {
        guard !displayVisibleFramesInAppKitCoordinates.isEmpty else { return nil }
        let currentDisplayIndex = displayIndex(
            forWindowAccessibilityFrame: currentWindowAccessibilityFrame,
            displayVisibleFramesInAppKitCoordinates: displayVisibleFramesInAppKitCoordinates,
            primaryDisplayHeight: primaryDisplayHeight
        )
        let visibleFrame = displayVisibleFramesInAppKitCoordinates[currentDisplayIndex]

        let targetAppKitFrame: CGRect
        switch placement {
        case .nextDisplay:
            guard displayVisibleFramesInAppKitCoordinates.count > 1 else { return nil }
            let nextDisplayIndex = (currentDisplayIndex + 1) % displayVisibleFramesInAppKitCoordinates.count
            targetAppKitFrame = frameKeepingRelativePosition(
                windowAppKitFrame: appKitRect(fromAccessibilityRect: currentWindowAccessibilityFrame, primaryDisplayHeight: primaryDisplayHeight),
                fromVisibleFrame: visibleFrame,
                toVisibleFrame: displayVisibleFramesInAppKitCoordinates[nextDisplayIndex]
            )
        case .center:
            // Keep the size (clamped to fit), centre it on its display.
            let width = min(currentWindowAccessibilityFrame.width, visibleFrame.width)
            let height = min(currentWindowAccessibilityFrame.height, visibleFrame.height)
            targetAppKitFrame = CGRect(
                x: visibleFrame.midX - width / 2,
                y: visibleFrame.midY - height / 2,
                width: width,
                height: height
            )
        default:
            targetAppKitFrame = fractionalFrame(for: placement, in: visibleFrame)
        }
        // Whole points, rounding each *edge* rather than origin and size, so
        // two tiled halves share exactly the same edge (no gap, no overlap)
        // and a top half never pokes up under the menu bar.
        let roundedMinX = targetAppKitFrame.minX.rounded()
        let roundedMinY = targetAppKitFrame.minY.rounded()
        let roundedTargetAppKitFrame = CGRect(
            x: roundedMinX,
            y: roundedMinY,
            width: targetAppKitFrame.maxX.rounded() - roundedMinX,
            height: targetAppKitFrame.maxY.rounded() - roundedMinY
        )
        return accessibilityRect(fromAppKitRect: roundedTargetAppKitFrame, primaryDisplayHeight: primaryDisplayHeight)
    }

    /// The share of `visibleFrame` a sizing placement covers, in AppKit space
    /// (y grows upward, so "top" is the upper part: the higher y values).
    static func fractionalFrame(for placement: WindowPlacement, in visibleFrame: CGRect) -> CGRect {
        let halfWidth = visibleFrame.width / 2
        let halfHeight = visibleFrame.height / 2
        let thirdWidth = visibleFrame.width / 3
        switch placement {
        case .leftHalf:
            return CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: halfWidth, height: visibleFrame.height)
        case .rightHalf:
            return CGRect(x: visibleFrame.minX + halfWidth, y: visibleFrame.minY, width: halfWidth, height: visibleFrame.height)
        case .topHalf:
            return CGRect(x: visibleFrame.minX, y: visibleFrame.minY + halfHeight, width: visibleFrame.width, height: halfHeight)
        case .bottomHalf:
            return CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: visibleFrame.width, height: halfHeight)
        case .topLeftQuarter:
            return CGRect(x: visibleFrame.minX, y: visibleFrame.minY + halfHeight, width: halfWidth, height: halfHeight)
        case .topRightQuarter:
            return CGRect(x: visibleFrame.minX + halfWidth, y: visibleFrame.minY + halfHeight, width: halfWidth, height: halfHeight)
        case .bottomLeftQuarter:
            return CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: halfWidth, height: halfHeight)
        case .bottomRightQuarter:
            return CGRect(x: visibleFrame.minX + halfWidth, y: visibleFrame.minY, width: halfWidth, height: halfHeight)
        case .leftThird:
            return CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: thirdWidth, height: visibleFrame.height)
        case .centerThird:
            return CGRect(x: visibleFrame.minX + thirdWidth, y: visibleFrame.minY, width: thirdWidth, height: visibleFrame.height)
        case .rightThird:
            return CGRect(x: visibleFrame.minX + 2 * thirdWidth, y: visibleFrame.minY, width: thirdWidth, height: visibleFrame.height)
        case .maximize, .center, .nextDisplay:
            return visibleFrame
        }
    }

    /// Moves a window to another display at the same relative position and
    /// relative size, clamped so it fits there.
    static func frameKeepingRelativePosition(
        windowAppKitFrame: CGRect,
        fromVisibleFrame sourceVisibleFrame: CGRect,
        toVisibleFrame destinationVisibleFrame: CGRect
    ) -> CGRect {
        guard sourceVisibleFrame.width > 0, sourceVisibleFrame.height > 0 else {
            return destinationVisibleFrame
        }
        let horizontalScale = destinationVisibleFrame.width / sourceVisibleFrame.width
        let verticalScale = destinationVisibleFrame.height / sourceVisibleFrame.height
        let width = min(windowAppKitFrame.width * horizontalScale, destinationVisibleFrame.width)
        let height = min(windowAppKitFrame.height * verticalScale, destinationVisibleFrame.height)
        var originX = destinationVisibleFrame.minX + (windowAppKitFrame.minX - sourceVisibleFrame.minX) * horizontalScale
        var originY = destinationVisibleFrame.minY + (windowAppKitFrame.minY - sourceVisibleFrame.minY) * verticalScale
        originX = min(max(originX, destinationVisibleFrame.minX), destinationVisibleFrame.maxX - width)
        originY = min(max(originY, destinationVisibleFrame.minY), destinationVisibleFrame.maxY - height)
        return CGRect(x: originX, y: originY, width: width, height: height)
    }
}
