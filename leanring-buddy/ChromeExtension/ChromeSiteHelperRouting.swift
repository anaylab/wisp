//
//  ChromeSiteHelperRouting.swift
//  leanring-buddy
//
//  Which spoken phrases the site helpers (phase 10) answer without the model's
//  tool choice, and the little that Wisp keeps track of to know when they apply:
//  which Chrome tab is showing, which tabs are Canvas assignments, which are calls.
//
//  Like every deterministic router here it is biased toward not matching. "Plan
//  this" only means the Canvas assignment when one is the tab the user is looking
//  at in Chrome; "what did I miss" only means the call when a call is open. Any
//  other time the words go to the model as an ordinary turn.
//
//  The tab state is built from the extension's tab events (contracts.md §1) and
//  seeded from `getTabs` when the extension connects. Tab ids and addresses stay
//  in memory only, as the contracts require.
//
//  Pure (Foundation only), tested by `Tests/ChromeExtSiteHelpers`.
//

import Foundation

nonisolated enum ChromeSiteHelperCommand: Equatable, Sendable {
    /// "Is this on my checklist?"
    case canvasStatus
    /// "Add this to my checklist" / "add this to today".
    case canvasAddToToday
    /// "Plan this": study blocks for just this assignment, behind the approval card.
    case canvasPlan
    /// "What did I miss", "summarize the last 5 minutes".
    case meetingCaptions(MeetingCaptionsRequest)
}

/// What the router may assume right now. Computed on the main actor, read by the
/// (nonisolated) router through a lock.
nonisolated struct ChromeSiteHelperAvailability: Equatable, Sendable {
    /// The Chrome tab the user is looking at is a Canvas assignment on a trusted
    /// host, and Chrome is the app they're in.
    var isShowingCanvasAssignment = false
    /// A Meet or Zoom web call is open in Chrome.
    var hasMeetingTab = false

    static let nothing = ChromeSiteHelperAvailability()
}

nonisolated enum ChromeSiteHelperCommandParser {

    private static let maximumCanvasCommandWordCount = 10

    // "this" always refers to the page; "it" only with the assignment open.
    private static let thisWords = ["this", "this assignment", "it", "this one", "this homework"]
    private static let checklistPlaces = [
        "my checklist", "the checklist", "todays checklist", "my list", "today", "my day", "my to do list", "my to dos", "todays list", "my list for today", "the list",
    ]
    private static let planPhrases = [
        "plan this", "plan this assignment", "plan it", "plan this for me", "plan it for me",
        "plan this one", "make a study plan for this", "make me a study plan for this",
        "schedule study time for this", "schedule time for this", "plan study time for this",
        "find time to work on this", "find time for this", "block out time for this",
        "plan study time for this assignment", "schedule study time for this assignment",
        "add a study block for this", "add study blocks for this",
    ]
    private static let statusPhrases = [
        "is this on my checklist", "is this on my calendar", "is this on todays checklist",
        "is this assignment on my checklist", "is this assignment on my calendar", "is this on my list",
        "is this on my to do list", "did i add this", "have i added this", "is this assignment on my list",
        "is it on my checklist", "is this on my checklist already", "is this already on my checklist",
    ]

    static func command(for transcript: String, availability: ChromeSiteHelperAvailability) -> ChromeSiteHelperCommand? {
        if availability.hasMeetingTab, let meetingRequest = MeetingCaptionsRequestParser.request(from: transcript) {
            return .meetingCaptions(meetingRequest)
        }
        guard availability.isShowingCanvasAssignment else { return nil }

        let text = normalized(transcript)
        let wordCount = text.split(separator: " ").count
        guard wordCount > 0, wordCount <= maximumCanvasCommandWordCount else { return nil }
        let politeText = strippedPoliteness(text)

        if statusPhrases.contains(politeText) { return .canvasStatus }
        if planPhrases.contains(politeText) { return .canvasPlan }
        for verb in ["add", "put"] {
            for thisWord in thisWords {
                for place in checklistPlaces {
                    for preposition in verb == "add" ? ["to", "onto"] : ["on", "onto"] {
                        if politeText == "\(verb) \(thisWord) \(preposition) \(place)" { return .canvasAddToToday }
                    }
                }
            }
        }
        if politeText == "add to today" || politeText == "add to my checklist" { return .canvasAddToToday }
        return nil
    }

    /// "can you please add this to today" → "add this to today".
    private static func strippedPoliteness(_ text: String) -> String {
        var workingText = text
        for prefix in ["hey wisp ", "wisp ", "can you ", "could you ", "would you ", "please ", "go ahead and ", "ok ", "okay "] {
            if workingText.hasPrefix(prefix) { workingText = String(workingText.dropFirst(prefix.count)) }
        }
        for suffix in [" please", " for me please", " thanks", " thank you"] where workingText.hasSuffix(suffix) {
            workingText = String(workingText.dropLast(suffix.count))
        }
        return workingText
    }

    private static func normalized(_ transcript: String) -> String {
        let lowered = transcript.lowercased()
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "todo", with: "to do")
        let kept = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }
}

// MARK: - Tab state

/// Which tab shows in each window, which window is in front, and the addresses of
/// the tabs that matter to the site helpers.
nonisolated struct ChromeSiteHelperTabState: Equatable, Sendable {
    private(set) var activeTabIDByWindowID: [Int: Int] = [:]
    private(set) var focusedWindowID: Int?
    /// Only Canvas-assignment-shaped and call addresses, by tab id.
    private(set) var helperURLByTabID: [Int: String] = [:]

    var showingTabID: Int? {
        guard let focusedWindowID else { return nil }
        return activeTabIDByWindowID[focusedWindowID]
    }

    var meetingTabIDs: [Int] {
        helperURLByTabID.compactMap { tabID, urlString in
            MeetingCaptionsPageMatcher.site(forURLString: urlString) == nil ? nil : tabID
        }.sorted()
    }

    /// The Canvas assignment the user is looking at, on a trusted host.
    func showingCanvasAssignment(savedCanvasFeedHost: String?) -> (tabID: Int, reference: CanvasAssignmentPageReference)? {
        guard let showingTabID, let urlString = helperURLByTabID[showingTabID],
              let reference = CanvasAssignmentPageMatcher.reference(forPageURLString: urlString, savedCanvasFeedHost: savedCanvasFeedHost)
        else { return nil }
        return (showingTabID, reference)
    }

    func urlString(forTabID tabID: Int) -> String? { helperURLByTabID[tabID] }

    /// Replaces everything with what `getTabs` reports.
    mutating func reset(tabs: [(id: Int, windowID: Int, url: String, isActive: Bool)], focusedWindowID: Int?) {
        activeTabIDByWindowID = [:]
        helperURLByTabID = [:]
        for tab in tabs {
            if tab.isActive { activeTabIDByWindowID[tab.windowID] = tab.id }
            rememberURL(tab.url, forTabID: tab.id)
        }
        self.focusedWindowID = focusedWindowID ?? tabs.first(where: \.isActive)?.windowID
    }

    mutating func tabActivated(tabID: Int, windowID: Int, url: String?) {
        activeTabIDByWindowID[windowID] = tabID
        if let url { rememberURL(url, forTabID: tabID) }
    }

    /// `tab.created` / `tab.updated`.
    mutating func tabChanged(tabID: Int, windowID: Int, url: String?, isActive: Bool?) {
        if let url { rememberURL(url, forTabID: tabID) }
        if isActive == true { activeTabIDByWindowID[windowID] = tabID }
    }

    mutating func tabRemoved(tabID: Int) {
        helperURLByTabID[tabID] = nil
        for (windowID, activeTabID) in activeTabIDByWindowID where activeTabID == tabID {
            activeTabIDByWindowID[windowID] = nil
        }
    }

    /// `window.focused`. A nil id (Chrome lost focus) keeps the last window, which
    /// is still the one the user means when they come back with "plan this".
    mutating func windowFocused(windowID: Int?) {
        guard let windowID, windowID >= 0 else { return }
        focusedWindowID = windowID
    }

    mutating func clear() {
        self = ChromeSiteHelperTabState()
    }

    private mutating func rememberURL(_ urlString: String, forTabID tabID: Int) {
        let isHelperPage = CanvasAssignmentPageMatcher.hasAssignmentPath(urlString)
            || MeetingCaptionsPageMatcher.site(forURLString: urlString) != nil
        helperURLByTabID[tabID] = isHelperPage ? urlString : nil
    }
}
