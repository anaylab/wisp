//
//  ChromeStaleTabFinder.swift
//  leanring-buddy
//
//  Pure rules for "clean up old tabs" (phase 04): which tabs the user hasn't
//  looked at in a while and can lose without noticing.
//
//  Biased hard toward keeping a tab. The sweep is recoverable (the tabs are
//  saved as a session first, and the card asks), but a tab the user is using
//  should never even be on the list. So a tab is left alone when it is pinned,
//  playing sound, showing in its window, or in any tab group (groups are the
//  user's own filing, or "organize my tabs" filing they kept), and when Chrome
//  hasn't said when it was last used.
//

import Foundation

nonisolated struct ChromeStaleTabRules: Equatable, Sendable {
    static let defaultMinimumDaysUnused = 14
    /// Anything shorter isn't "old": yesterday's tab is still in use.
    static let smallestMinimumDaysUnused = 1
    static let largestMinimumDaysUnused = 365

    let minimumDaysUnused: Int
    /// chrome:// pages (settings, history) are only swept when the user says
    /// "including chrome pages": they're cheap to keep and often open on purpose.
    let includesChromePages: Bool

    init(minimumDaysUnused: Int = Self.defaultMinimumDaysUnused, includesChromePages: Bool = false) {
        self.minimumDaysUnused = min(max(minimumDaysUnused, Self.smallestMinimumDaysUnused), Self.largestMinimumDaysUnused)
        self.includesChromePages = includesChromePages
    }

    static let standard = ChromeStaleTabRules()
}

nonisolated enum ChromeStaleTabFinder {

    static let millisecondsPerDay: Double = 24 * 60 * 60 * 1000

    /// Whether the tab's page is a kind the sweep may close at all.
    static func isSweepablePage(_ urlString: String, includesChromePages: Bool) -> Bool {
        guard let scheme = URLComponents(string: urlString)?.scheme?.lowercased() else { return false }
        switch scheme {
        case "http", "https": return true
        case "chrome": return includesChromePages
        // file:, extension pages, devtools, blank pages: never.
        default: return false
        }
    }

    /// Whole days since the tab was last looked at, or nil when Chrome didn't say.
    static func daysUnused(_ tab: ChromeTab, nowMilliseconds: Double) -> Int? {
        guard tab.lastAccessed > 0, nowMilliseconds >= tab.lastAccessed else { return nil }
        return Int((nowMilliseconds - tab.lastAccessed) / millisecondsPerDay)
    }

    /// The stale tabs, least recently used first.
    static func staleTabs(in snapshot: ChromeTabsSnapshot, nowMilliseconds: Double, rules: ChromeStaleTabRules) -> [ChromeTab] {
        snapshot.tabs
            .filter { candidateTab in
                guard !candidateTab.pinned, !candidateTab.audible, !candidateTab.active, !candidateTab.isInGroup else { return false }
                guard isSweepablePage(candidateTab.url, includesChromePages: rules.includesChromePages) else { return false }
                guard let unusedDays = daysUnused(candidateTab, nowMilliseconds: nowMilliseconds) else { return false }
                return unusedDays >= rules.minimumDaysUnused
            }
            .sorted { lhs, rhs in
                if lhs.lastAccessed != rhs.lastAccessed { return lhs.lastAccessed < rhs.lastAccessed }
                if lhs.windowId != rhs.windowId { return lhs.windowId < rhs.windowId }
                return lhs.index < rhs.index
            }
    }

    /// "no tab has gone unused for 14 days." — said instead of showing a card.
    static func nothingStaleText(rules: ChromeStaleTabRules) -> String {
        let dayText = rules.minimumDaysUnused == 1 ? "a day" : "\(rules.minimumDaysUnused) days"
        return "no old tabs to clean up — nothing loose has gone unused for \(dayText)."
    }
}
