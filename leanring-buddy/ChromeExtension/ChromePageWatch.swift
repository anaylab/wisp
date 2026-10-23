//
//  ChromePageWatch.swift
//  leanring-buddy
//
//  The pure side of Chrome page watchers (phase 08): which kind of watch a
//  spoken "tell me when …" becomes (`ChromePageWatchRouter`), the condition
//  as the extension reads it (`ChromePageWatchWireCondition`), the extension's
//  replies and events, keeping Wisp's list in step with the extension's
//  (`ChromePageWatchReconciliation`), and what Wisp says when a watch ends.
//
//  Why page watches at all, when Wisp has screen watchers: a screen watch
//  reads pixels every 3 seconds and only sees what is on screen. "Tell me
//  when this tab says Deployed" usually means a tab the user is about to
//  leave — the page watcher runs inside the tab (content/page-watch.js),
//  sees the change the moment it happens, below the fold and in a background
//  tab. The conditions are the screen watcher's own (`ScreenWatchCondition`),
//  so a request means the same thing either way.
//
//  Running the watches (the bridge, notifications, the notch) lives in
//  `ChromePageWatchStore`; this file is Foundation only, so
//  `Tests/ChromeExtPageWatchers` compiles it with ScreenWatcher.swift alone.
//

import Foundation

// MARK: - Which watcher

nonisolated enum ChromePageWatchRoute: Equatable, Sendable {
    /// Watch the tab showing in Chrome. `reloadEveryMinutes` for a page that
    /// doesn't update by itself ("check this page every 10 minutes and …").
    case watchChromeTab(ScreenWatchCondition, reloadEveryMinutes: Int?)
    case watchScreen(ScreenWatchCondition)
    /// "Stop watching" stops both kinds.
    case stopAllWatching
}

/// Decides whether a spoken watch request recognised by
/// `ScreenWatchRequestParser` watches the Chrome tab or the screen.
/// Biased toward the screen watch, which works everywhere: a tab is watched
/// only when the user is in Chrome, the extension there is connected and may
/// read pages, and the words don't point at the screen itself.
nonisolated enum ChromePageWatchRouter {
    /// Words that say the user means the screen, or something that isn't a
    /// web page, even while Chrome is in front.
    private static let screenWords: Set<String> = [
        "screen", "terminal", "console", "xcode", "simulator", "desktop", "window", "monitor", "display",
    ]

    static func route(
        for request: ScreenWatchRequest,
        transcript: String,
        isChromeInFrontWithExtension: Bool,
        canReadPagesInChrome: Bool
    ) -> ChromePageWatchRoute {
        switch request {
        case .stopAllWatching:
            return .stopAllWatching
        case .startWatching(let condition):
            let transcriptWords = Set(ScreenWatchTextMatching.normalizedText(transcript).split(separator: " ").map(String.init))
            let namesTheScreen = !transcriptWords.isDisjoint(with: screenWords)
            guard isChromeInFrontWithExtension, canReadPagesInChrome, !namesTheScreen else {
                return .watchScreen(condition)
            }
            return .watchChromeTab(condition, reloadEveryMinutes: reloadEveryMinutes(in: transcript))
        }
    }

    /// Least reload interval the extension accepts: often enough to catch
    /// tickets coming back, gentle on the site.
    static let minimumReloadEveryMinutes = 5
    static let maximumReloadEveryMinutes = 24 * 60
    /// "Keep refreshing this page and tell me when …" with no interval.
    static let defaultReloadEveryMinutes = 15

    private static let reloadVerbPattern = #"\b(?:check|checking|reload|reloading|refresh|refreshing)\b"#
    private static let intervalPattern = #"\bevery\s+(?:(\d{1,4}|a|an|one|two|three|five|ten|fifteen|twenty|thirty|forty|forty[\s-]five|sixty)\s+)?(half\s+(?:an\s+)?hour|minutes?|mins?|hours?|hrs?)\b"#
    private static let numberWordValues: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "five": 5, "ten": 10, "fifteen": 15, "twenty": 20,
        "thirty": 30, "forty": 40, "forty five": 45, "forty-five": 45, "sixty": 60,
    ]

    /// The reload interval in a request, in minutes (at least 5), or nil for
    /// a page that updates by itself. Needs a reload verb ("check this page
    /// every 10 minutes", "refresh it every hour"); "every" alone could mean
    /// anything.
    static func reloadEveryMinutes(in transcript: String) -> Int? {
        let loweredTranscript = transcript.lowercased()
        guard loweredTranscript.range(of: reloadVerbPattern, options: .regularExpression) != nil else { return nil }

        guard let intervalExpression = try? NSRegularExpression(pattern: intervalPattern),
              let intervalMatch = intervalExpression.firstMatch(
                  in: loweredTranscript,
                  range: NSRange(loweredTranscript.startIndex..., in: loweredTranscript)
              ) else {
            // "keep refreshing this page" — only a reload verb aimed at the page.
            let isReloadingThePage = loweredTranscript.range(
                of: #"\b(?:reload|reloading|refresh|refreshing)\s+(?:this|the|that)\s+(?:page|tab|site)\b"#,
                options: .regularExpression
            ) != nil
            return isReloadingThePage ? defaultReloadEveryMinutes : nil
        }

        let countText = Range(intervalMatch.range(at: 1), in: loweredTranscript).map { String(loweredTranscript[$0]) }
        let unitText = Range(intervalMatch.range(at: 2), in: loweredTranscript).map { String(loweredTranscript[$0]) } ?? ""
        let count = countText.flatMap { Int($0) ?? numberWordValues[$0] } ?? 1

        let minutes: Int
        if unitText.hasPrefix("half") {
            minutes = 30
        } else if unitText.hasPrefix("h") {
            minutes = count * 60
        } else {
            minutes = count
        }
        return min(max(minutes, minimumReloadEveryMinutes), maximumReloadEveryMinutes)
    }
}

// MARK: - The wire shape

/// A watch condition as the extension reads it (contracts.md, phase 08).
nonisolated struct ChromePageWatchWireCondition: Codable, Equatable, Sendable {
    let kind: String
    var text: String?
    var nearText: String?
    var selector: String?
    var direction: String?
    var threshold: Double?

    init(kind: String, text: String? = nil, nearText: String? = nil, selector: String? = nil, direction: String? = nil, threshold: Double? = nil) {
        self.kind = kind
        self.text = text
        self.nearText = nearText
        self.selector = selector
        self.direction = direction
        self.threshold = threshold
    }

    init(_ condition: ScreenWatchCondition) {
        switch condition {
        case .textAppears(let targetText):
            self.init(kind: "textAppears", text: targetText)
        case .textDisappears(let targetText):
            self.init(kind: "textDisappears", text: targetText)
        case .screenTextSettles:
            self.init(kind: "pageSettlesAfterChange")
        case .numberCrosses(let numberThreshold):
            self.init(
                kind: "numberCrosses",
                nearText: numberThreshold.nearText,
                direction: numberThreshold.direction.rawValue,
                threshold: numberThreshold.threshold
            )
        }
    }

    /// Back to Wisp's condition, for a watch Wisp learns about from the
    /// extension's list (one started before Wisp was restarted). Nil for
    /// anything malformed.
    var screenWatchCondition: ScreenWatchCondition? {
        switch kind {
        case "textAppears":
            return text.map(ScreenWatchCondition.textAppears)
        case "textDisappears":
            return text.map(ScreenWatchCondition.textDisappears)
        case "pageSettlesAfterChange":
            return .screenTextSettles
        case "numberCrosses":
            guard let threshold, let direction = direction.flatMap(ScreenWatchNumberThreshold.Direction.init(rawValue:)) else { return nil }
            let label = nearText ?? selector ?? "the number"
            return .numberCrosses(ScreenWatchNumberThreshold(
                subjectText: label,
                nearText: label,
                direction: direction,
                threshold: threshold,
                thresholdText: Self.displayText(forThreshold: threshold)
            ))
        default:
            return nil
        }
    }

    /// "80", "79.99", "1299.5" — no trailing ".0".
    static func displayText(forThreshold threshold: Double) -> String {
        threshold.rounded() == threshold && abs(threshold) < 1e15
            ? String(Int64(threshold))
            : String(threshold)
    }
}

// MARK: - The extension's replies and events

/// One watch, as `startPageWatch` and `listPageWatches` return it.
nonisolated struct ChromePageWatchInfo: Decodable, Equatable, Sendable {
    let watchId: String
    let tabId: Int
    let windowId: Int?
    let url: String
    let title: String
    let label: String?
    let condition: ChromePageWatchWireCondition
    let reloadEveryMinutes: Int?
    let ownsTab: Bool
    /// Epoch milliseconds.
    let startedAt: Double
    let expiresAt: Double?
}

nonisolated struct ChromePageWatchEndedRecord: Decodable, Equatable, Sendable {
    let watchId: String
    let reason: String
    let matchedText: String?
    let endedAt: Double?
}

nonisolated struct ChromePageWatchList: Decodable, Equatable, Sendable {
    let watches: [ChromePageWatchInfo]
    let recentlyEnded: [ChromePageWatchEndedRecord]
}

nonisolated struct ChromePageWatchStopResult: Decodable, Equatable, Sendable {
    let stoppedCount: Int
}

/// `watch.matched`.
nonisolated struct ChromePageWatchMatchedPayload: Decodable, Equatable, Sendable {
    let watchId: String
    let matchedText: String?
    let tabId: Int?
    let url: String?
    let title: String?
}

/// `watch.ended`.
nonisolated struct ChromePageWatchEndedPayload: Decodable, Equatable, Sendable {
    let watchId: String
    let reason: String
}

// MARK: - Wisp's side of a watch

/// A page watch Wisp shows in the notch and can stop.
nonisolated struct ActiveChromePageWatch: Identifiable, Equatable, Sendable {
    /// The extension's watch id.
    let id: String
    let condition: ScreenWatchCondition
    let tabID: Int
    let tabTitle: String
    let pageURL: String
    let reloadEveryMinutes: Int?
    let startDate: Date

    init(id: String, condition: ScreenWatchCondition, tabID: Int, tabTitle: String, pageURL: String, reloadEveryMinutes: Int?, startDate: Date) {
        self.id = id
        self.condition = condition
        self.tabID = tabID
        self.tabTitle = tabTitle
        self.pageURL = pageURL
        self.reloadEveryMinutes = reloadEveryMinutes
        self.startDate = startDate
    }

    /// From the extension's description; nil when its condition is unreadable.
    init?(info: ChromePageWatchInfo, knownCondition: ScreenWatchCondition? = nil) {
        guard let condition = knownCondition ?? info.condition.screenWatchCondition else { return nil }
        self.init(
            id: info.watchId,
            condition: condition,
            tabID: info.tabId,
            tabTitle: info.title,
            pageURL: info.url,
            reloadEveryMinutes: info.reloadEveryMinutes,
            startDate: Date(timeIntervalSince1970: info.startedAt / 1000)
        )
    }

    /// "github.com" — how a tab is named when it has no title.
    var pageHost: String {
        URL(string: pageURL)?.host.map(ChromeSiteMatching.hostWithoutWWW) ?? ""
    }

    /// The tab as a short name for the notch and replies.
    var tabDisplayName: String {
        let trimmedTitle = tabTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty { return pageHost.isEmpty ? "the tab" : pageHost }
        return trimmedTitle.count > 60 ? String(trimmedTitle.prefix(59)) + "…" : trimmedTitle
    }
}

/// How a page watch ended without the user stopping it.
nonisolated enum ChromePageWatchEnding: Equatable, Sendable {
    case conditionMet(matchedText: String?)
    case timedOut
    case tabClosed
    case navigatedAway
    case pageUnavailable
    /// The extension no longer has it and didn't say why (Chrome was quit, or
    /// the extension reloaded).
    case lost

    init(extensionReason: String, matchedText: String?) {
        switch extensionReason {
        case "matched": self = .conditionMet(matchedText: matchedText)
        case "timedOut": self = .timedOut
        case "tabClosed": self = .tabClosed
        case "navigatedAway": self = .navigatedAway
        case "pageUnavailable": self = .pageUnavailable
        default: self = .lost
        }
    }

    var isConditionMet: Bool {
        if case .conditionMet = self { return true }
        return false
    }
}

nonisolated enum ChromePageWatchWording {
    /// What Wisp says, shows and notifies when a page watch ends.
    static func endingMessage(for watch: ActiveChromePageWatch, ending: ChromePageWatchEnding) -> String {
        let tabName = watch.tabDisplayName
        switch ending {
        case .conditionMet(let matchedText):
            switch watch.condition {
            case .textAppears(let targetText):
                if let matchedText,
                   ScreenWatchTextMatching.normalizedText(matchedText) != ScreenWatchTextMatching.normalizedText(targetText) {
                    return "“\(targetText)” is on \(tabName) now: \(matchedText)"
                }
                return "“\(targetText)” is on \(tabName) now."
            case .textDisappears(let targetText):
                return "“\(targetText)” is gone from \(tabName)."
            case .screenTextSettles:
                return "\(tabName) has stopped changing — looks like it's finished."
            case .numberCrosses(let numberThreshold):
                return numberThreshold.reachedMessage(matchedLineText: matchedText, place: "on \(tabName)")
            }
        case .timedOut:
            return "i stopped watching \(tabName) for \(watch.condition.summaryText) — it's been a day."
        case .tabClosed:
            return "i stopped watching for \(watch.condition.summaryText) — the tab was closed."
        case .navigatedAway:
            return "i stopped watching for \(watch.condition.summaryText) — that tab went to another site."
        case .pageUnavailable:
            return "i stopped watching \(tabName) — i couldn't read the page any more."
        case .lost:
            return "i stopped watching \(tabName) for \(watch.condition.summaryText) — chrome closed or the extension restarted."
        }
    }

    /// The reply when a tab watch starts.
    static func startedReply(for watch: ActiveChromePageWatch) -> String {
        if let reloadEveryMinutes = watch.reloadEveryMinutes {
            let intervalText = reloadEveryMinutes % 60 == 0
                ? (reloadEveryMinutes == 60 ? "hour" : "\(reloadEveryMinutes / 60) hours")
                : "\(reloadEveryMinutes) minutes"
            return "okay — i'll reload \(watch.tabDisplayName) in a background tab every \(intervalText) and tell you when \(watch.condition.summaryText)."
        }
        return "okay — watching this tab. i'll tell you when \(watch.condition.summaryText), even if you switch tabs."
    }
}

// MARK: - Keeping in step with the extension

/// Matches Wisp's list against the extension's after a (re)connect: the
/// extension is the source of truth for which watches exist.
nonisolated enum ChromePageWatchReconciliation {
    struct Outcome: Equatable, Sendable {
        /// Wisp's list from now on, in start order.
        let activeWatches: [ActiveChromePageWatch]
        /// Watches Wisp had that ended while it wasn't listening.
        let endedWatches: [(watch: ActiveChromePageWatch, ending: ChromePageWatchEnding)]

        static func == (lhs: Outcome, rhs: Outcome) -> Bool {
            lhs.activeWatches == rhs.activeWatches
                && lhs.endedWatches.map(\.watch) == rhs.endedWatches.map(\.watch)
                && lhs.endedWatches.map(\.ending) == rhs.endedWatches.map(\.ending)
        }
    }

    static func reconcile(knownWatches: [ActiveChromePageWatch], extensionList: ChromePageWatchList) -> Outcome {
        let knownByID = Dictionary(knownWatches.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let listedIDs = Set(extensionList.watches.map(\.watchId))

        // Listed watches, keeping Wisp's own condition (it has the user's
        // wording, like "$80") when Wisp started the watch.
        let activeWatches = extensionList.watches
            .compactMap { info in ActiveChromePageWatch(info: info, knownCondition: knownByID[info.watchId]?.condition) }
            .sorted { $0.startDate < $1.startDate }

        let endedRecordsByID = Dictionary(extensionList.recentlyEnded.map { ($0.watchId, $0) }, uniquingKeysWith: { _, last in last })
        let endedWatches = knownWatches
            .filter { !listedIDs.contains($0.id) }
            .map { knownWatch -> (watch: ActiveChromePageWatch, ending: ChromePageWatchEnding) in
                guard let endedRecord = endedRecordsByID[knownWatch.id] else { return (knownWatch, .lost) }
                return (knownWatch, ChromePageWatchEnding(extensionReason: endedRecord.reason, matchedText: endedRecord.matchedText))
            }
        return Outcome(activeWatches: activeWatches, endedWatches: endedWatches)
    }
}
