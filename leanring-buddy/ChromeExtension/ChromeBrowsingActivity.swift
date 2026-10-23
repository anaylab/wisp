//
//  ChromeBrowsingActivity.swift
//  leanring-buddy
//
//  The pure side of the browser automation triggers (phase 08): "when I open
//  youtube …" and "if I'm on reddit for 30 minutes …". Which site a spoken
//  name means and whether a tab's address is on it (`ChromeSiteMatching`), and
//  how long the user has been on a site in the current visit
//  (`ChromeTimeOnSiteAccumulator`).
//
//  Time on a site only counts while the user is actually there: that site is
//  the showing tab of the focused Chrome window, Chrome is the frontmost app,
//  and the Mac isn't idle. Anything else pauses the count; it doesn't reset
//  it, so glancing at Slack for a minute doesn't excuse half an hour of
//  Reddit. A visit does end after a long break (15 minutes away), so this
//  evening's YouTube isn't added to this morning's.
//
//  Foundation only, so `Tests/ChromeExtPageWatchers` and the automation suites
//  compile it alone. The live feed (tab events, the frontmost app, idle time)
//  is `ChromeBrowsingActivityMonitor`.
//

import Foundation

// MARK: - Sites

nonisolated enum ChromeSiteMatching {
    /// Spoken names of common sites → the host the automation stores. A name
    /// not here is accepted only as an address ("example.com").
    static let knownSiteHostsBySpokenName: [String: String] = [
        "youtube": "youtube.com",
        "you tube": "youtube.com",
        "reddit": "reddit.com",
        "twitter": "x.com",
        "x": "x.com",
        "instagram": "instagram.com",
        "insta": "instagram.com",
        "tiktok": "tiktok.com",
        "tik tok": "tiktok.com",
        "facebook": "facebook.com",
        "netflix": "netflix.com",
        "twitch": "twitch.tv",
        "linkedin": "linkedin.com",
        "github": "github.com",
        "gmail": "mail.google.com",
        "amazon": "amazon.com",
        "wikipedia": "wikipedia.org",
        "hacker news": "news.ycombinator.com",
        "canvas": "instructure.com",
        "pinterest": "pinterest.com",
        "tumblr": "tumblr.com",
        "discord": "discord.com",
        "spotify": "open.spotify.com",
        "chatgpt": "chatgpt.com",
    ]

    /// Hosts that are the same site under another name.
    private static let equivalentSiteHosts: [String: Set<String>] = [
        "x.com": ["x.com", "twitter.com"],
        "twitter.com": ["x.com", "twitter.com"],
        "youtube.com": ["youtube.com", "youtu.be"],
    ]

    static func hostWithoutWWW(_ host: String) -> String {
        let loweredHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return loweredHost.hasPrefix("www.") ? String(loweredHost.dropFirst(4)) : loweredHost
    }

    /// The host of an address, without "www."; nil for anything that isn't a
    /// web page (chrome://, about:blank).
    static func host(ofURL urlText: String) -> String? {
        guard let pageURL = URL(string: urlText),
              let scheme = pageURL.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = pageURL.host, !host.isEmpty else { return nil }
        return hostWithoutWWW(host)
    }

    /// The site host a spoken name means: a known site ("youtube" →
    /// "youtube.com"), or an address as said ("example.com", "www.bbc.co.uk"
    /// → "bbc.co.uk"). Nil for anything else, so "when I open my notes" is not
    /// mistaken for a site.
    static func siteHost(fromSpokenName spokenName: String) -> String? {
        let cleanedName = spokenName
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?\"'"))
        if let knownHost = knownSiteHostsBySpokenName[cleanedName] { return knownHost }
        // "youtube.com", "news.ycombinator.com", "https://example.org/x".
        let addressText = cleanedName.contains("://") ? cleanedName : "https://\(cleanedName)"
        guard !cleanedName.contains(" "),
              cleanedName.contains("."),
              let host = host(ofURL: addressText),
              host.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$"#, options: .regularExpression) != nil else { return nil }
        return host
    }

    /// Whether a tab's host is on a site: the same host, a subdomain of it
    /// ("m.youtube.com" is YouTube), or an equivalent host ("twitter.com" is X).
    static func host(_ tabHost: String, isOnSite siteHost: String) -> Bool {
        let normalizedTabHost = hostWithoutWWW(tabHost)
        let normalizedSiteHost = hostWithoutWWW(siteHost)
        guard !normalizedTabHost.isEmpty, !normalizedSiteHost.isEmpty else { return false }
        let siteHosts = equivalentSiteHosts[normalizedSiteHost] ?? [normalizedSiteHost]
        return siteHosts.contains { candidateHost in
            normalizedTabHost == candidateHost || normalizedTabHost.hasSuffix("." + candidateHost)
        }
    }

    /// "youtube.com" → "YouTube"-ish display: the known spoken name if any,
    /// else the host.
    static func displayName(forSiteHost siteHost: String) -> String {
        let displayNamesByHost: [String: String] = [
            "youtube.com": "YouTube", "reddit.com": "Reddit", "x.com": "X", "instagram.com": "Instagram",
            "tiktok.com": "TikTok", "facebook.com": "Facebook", "netflix.com": "Netflix", "twitch.tv": "Twitch",
            "linkedin.com": "LinkedIn", "github.com": "GitHub", "mail.google.com": "Gmail", "amazon.com": "Amazon",
            "wikipedia.org": "Wikipedia", "news.ycombinator.com": "Hacker News", "instructure.com": "Canvas",
        ]
        return displayNamesByHost[hostWithoutWWW(siteHost)] ?? hostWithoutWWW(siteHost)
    }
}

// MARK: - Time on a site

/// What the user is doing in Chrome at one moment.
nonisolated struct ChromeBrowsingSample: Equatable, Sendable {
    /// The host of the showing tab in the focused Chrome window; nil when
    /// that tab isn't a web page or no Chrome window has focus.
    let activeHost: String?
    let isChromeFrontmost: Bool
    let isUserIdle: Bool

    /// Whether this moment counts as time on `activeHost`.
    var countsAsTimeOnSite: Bool {
        activeHost != nil && isChromeFrontmost && !isUserIdle
    }
}

/// One stretch of time on a site.
nonisolated struct ChromeSiteVisit: Equatable, Sendable {
    let startedAt: Date
    var secondsOnSite: TimeInterval
    var lastCountedAt: Date
}

nonisolated struct ChromeTimeOnSiteAccumulator: Sendable {
    /// The most one gap between samples can add. Samples come every ~15s and
    /// on every tab change; a longer gap means the Mac slept or Wisp was busy,
    /// and that is not time on a site.
    static let maximumCreditedGapSeconds: TimeInterval = 90
    /// Away from a site this long and the next time is a new visit.
    static let visitResetGapSeconds: TimeInterval = 15 * 60

    private(set) var visitsByHost: [String: ChromeSiteVisit] = [:]
    private var lastSample: ChromeBrowsingSample?
    private var lastSampleDate: Date?

    init() {}

    /// Takes the state at `date`. The time since the previous sample is
    /// credited to the previous sample's site, if it was counting.
    mutating func record(_ sample: ChromeBrowsingSample, at date: Date) {
        creditTimeSinceLastSample(until: date)
        lastSample = sample
        lastSampleDate = date
        pruneStaleVisits(now: date)
    }

    /// The current visit to a site (any of its hosts) at `now`, counting time
    /// since the last sample. Nil when the user hasn't been there lately.
    func currentVisit(toSite siteHost: String, now: Date) -> ChromeSiteVisit? {
        var accumulatorAtNow = self
        accumulatorAtNow.creditTimeSinceLastSample(until: now)
        return accumulatorAtNow.visitsByHost
            .filter { ChromeSiteMatching.host($0.key, isOnSite: siteHost) }
            .map(\.value)
            .filter { now.timeIntervalSince($0.lastCountedAt) < Self.visitResetGapSeconds }
            .max { $0.secondsOnSite < $1.secondsOnSite }
    }

    private mutating func creditTimeSinceLastSample(until date: Date) {
        guard let lastSample, let lastSampleDate, lastSample.countsAsTimeOnSite, let activeHost = lastSample.activeHost else { return }
        let creditedSeconds = min(max(0, date.timeIntervalSince(lastSampleDate)), Self.maximumCreditedGapSeconds)
        guard creditedSeconds > 0 else { return }

        let hostKey = ChromeSiteMatching.hostWithoutWWW(activeHost)
        var visit = visitsByHost[hostKey]
        if let existingVisit = visit,
           lastSampleDate.timeIntervalSince(existingVisit.lastCountedAt) >= Self.visitResetGapSeconds {
            visit = nil
        }
        var updatedVisit = visit ?? ChromeSiteVisit(startedAt: lastSampleDate, secondsOnSite: 0, lastCountedAt: lastSampleDate)
        updatedVisit.secondsOnSite += creditedSeconds
        updatedVisit.lastCountedAt = lastSampleDate.addingTimeInterval(creditedSeconds)
        visitsByHost[hostKey] = updatedVisit
        self.lastSampleDate = lastSampleDate.addingTimeInterval(creditedSeconds)
    }

    private mutating func pruneStaleVisits(now: Date) {
        visitsByHost = visitsByHost.filter { now.timeIntervalSince($0.value.lastCountedAt) < Self.visitResetGapSeconds }
    }
}
