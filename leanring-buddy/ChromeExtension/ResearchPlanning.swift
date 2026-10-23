//
//  ResearchPlanning.swift
//  leanring-buddy
//
//  The deterministic half of research mode (phase 11): what the user asked
//  for, which search results become sources, and how much of each the model
//  gets. None of it involves a model, so nothing a web page says can change
//  which pages are opened or how many.
//
//  * `ResearchRequestParser` — "research the best budget mechanical keyboards",
//    "do some research on how mrna vaccines work for my bio essay and save it
//    to my brain". Biased toward not matching, like every router here.
//  * `ResearchSessionCommandParser` — "done" / "close the research tabs".
//  * `ResearchSourcePicker` — result links on the search page → up to 5 (local
//    model) or 8 (cloud) distinct pages: the search engine's own pages, video
//    and social sites skipped, Google's `/url?q=` redirects unwrapped, one page
//    per site, duplicates by host + path dropped.
//  * `ResearchBudget` — the per-model caps.
//
//  Pure (Foundation only), tested by `Tests/ChromeExtResearch`.
//

import Foundation

// MARK: - What was asked

nonisolated struct ResearchRequest: Equatable, Sendable {
    /// The question as the user put it, purpose included ("how mrna vaccines
    /// work for my bio essay"): the model writes for it.
    let topic: String
    /// What goes in the search box: the topic without the purpose.
    let searchQuery: String
    /// Save the result as Brain pages when done.
    let savesToBrain: Bool
}

nonisolated enum ResearchRequestParser {

    private static let leadingPhrases = [
        "do some research on ", "do some research about ", "do some research into ",
        "do research on ", "do research about ", "research about ", "research on ",
        "research into ", "research ",
    ]

    private static let saveToBrainSuffixes = [
        " and save it to my brain", " and save it in my brain", " and add it to my brain",
        " and put it in my brain", " and save that to my brain", " and add that to my brain",
        " and save to my brain", " and add to my brain", " and save it to the brain",
        " and add it to the brain",
    ]

    /// Words that put the request on the Mac or in a feature, not on the web.
    private static let nonWebTopicWords: Set<String> = [
        "mode", "file", "files", "folder", "folders", "desktop", "downloads", "document",
        "documents", "email", "emails", "inbox", "screen", "tab", "tabs", "notes", "settings",
    ]

    /// Topics that are only pronouns name something on screen, not a subject.
    private static let pronounTopics: Set<String> = ["this", "that", "it", "this page", "this tab", "these", "them"]

    /// "for my bio essay": a purpose the model should write for, kept out of
    /// the search box.
    private static let purposePattern = #"\s+for (?:my|a|our|the) (?:[a-z0-9-]+ ){0,3}(?:essay|paper|class|course|homework|project|report|assignment|presentation|thesis|exam|test|lab)$"#

    static func request(from transcript: String) -> ResearchRequest? {
        var text = normalized(transcript)
        text = strippedPoliteFiller(text)
        guard let leadingPhrase = leadingPhrases.first(where: { text.hasPrefix($0) }) else { return nil }
        var topic = String(text.dropFirst(leadingPhrase.count)).trimmingCharacters(in: .whitespaces)

        var savesToBrain = false
        for suffix in saveToBrainSuffixes where topic.hasSuffix(suffix) {
            topic = String(topic.dropLast(suffix.count))
            savesToBrain = true
            break
        }
        for trailing in [" for me please", " please", " for me", " online", " on the web", " on the internet"]
        where topic.hasSuffix(trailing) {
            topic = String(topic.dropLast(trailing.count))
        }
        topic = topic.trimmingCharacters(in: .whitespaces)

        let topicWords = topic.split(separator: " ").map(String.init)
        guard topic.count >= 3, topicWords.count <= 20 else { return nil }
        guard !pronounTopics.contains(topic) else { return nil }
        // "research mode", "research the file on my desktop", "research tabs".
        guard !topicWords.contains(where: nonWebTopicWords.contains) else { return nil }
        // A question about research ("research is hard, right?") isn't a request.
        guard !topic.hasSuffix("?"), !["is ", "was ", "says ", "shows ", "suggests "].contains(where: { topic.hasPrefix($0) }) else {
            return nil
        }

        var searchQuery = topic.replacingOccurrences(of: purposePattern, with: "", options: .regularExpression)
        for leadingArticle in ["the ", "a "] where searchQuery.hasPrefix(leadingArticle) && searchQuery.count > leadingArticle.count + 3 {
            searchQuery = String(searchQuery.dropFirst(leadingArticle.count))
        }
        return ResearchRequest(topic: topic, searchQuery: searchQuery, savesToBrain: savesToBrain)
    }

    static func normalized(_ transcript: String) -> String {
        transcript
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: ",", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
    }

    static func strippedPoliteFiller(_ text: String) -> String {
        var command = text
        let leadingFillers = [
            "hey wisp ", "wisp ", "hey ", "okay ", "ok ", "so ", "um ", "uh ",
            "can you please ", "could you please ", "can you ", "could you ", "would you ",
            "please ", "i want you to ", "i'd like you to ", "i need you to ", "go ahead and ", "just ",
        ]
        var didStrip = true
        while didStrip {
            didStrip = false
            for filler in leadingFillers where command.hasPrefix(filler) {
                command = String(command.dropFirst(filler.count))
                didStrip = true
            }
        }
        return command.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - "done"

nonisolated enum ResearchSessionCommandParser {
    /// Whole utterances only. A bare "done" closes research tabs only while
    /// there are some (`hasOpenResearchTabs`); otherwise it is someone else's
    /// "done" and goes on as an ordinary turn.
    static func isFinishCommand(_ transcript: String, hasOpenResearchTabs: Bool) -> Bool {
        let command = ResearchRequestParser.strippedPoliteFiller(ResearchRequestParser.normalized(transcript))
        let alwaysFinishPhrases: Set<String> = [
            "close the research tabs", "close research tabs", "close my research tabs",
            "close the research", "close the tabs you opened for research",
        ]
        if alwaysFinishPhrases.contains(command) { return true }
        let finishWhileResearchingPhrases: Set<String> = [
            "done", "i'm done", "im done", "all done", "we're done", "done researching",
            "i'm done researching", "done with the research", "i'm done with the research",
            "i'm done with that research", "done with research", "that's enough research",
        ]
        return hasOpenResearchTabs && finishWhileResearchingPhrases.contains(command)
    }
}

// MARK: - Budgets

nonisolated enum ResearchBudget {
    static let maximumSourcesForLocalModel = 5
    static let maximumSourcesForCloudModel = 8
    /// Page characters one local map call reads: with its instructions this
    /// stays well inside the small model's context.
    static let localMapCharactersPerSource = 3_500
    static let maximumFindingsPerSource = 3
    /// A cloud model reads every source in one combine call.
    static let cloudCharactersPerSource = 6_000
    /// Pages with fewer words read as an app, a paywall or a cookie wall.
    static let minimumSourceWords = 80
    /// Idle research tabs are closed after this long.
    static let idleCloseSeconds: TimeInterval = 30 * 60

    static func maximumSources(isLocalModel: Bool) -> Int {
        isLocalModel ? maximumSourcesForLocalModel : maximumSourcesForCloudModel
    }
}

// MARK: - Searching and picking sources

nonisolated enum ResearchSearch {
    /// The search page Wisp's browser tasks already treat as the default
    /// ("search for x" → Google, `BrowserCommandRouter`). Reading Chrome's own
    /// default engine needs the `search` permission, which the manifest
    /// (phase 01's) doesn't ask for.
    static func searchURL(for searchQuery: String) -> URL? {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: searchQuery)]
        return components?.url
    }
}

/// A result link on the search page.
nonisolated struct ResearchSearchResultLink: Equatable, Sendable {
    let href: String
    let label: String
}

nonisolated struct ResearchSourceCandidate: Equatable, Sendable {
    let url: String
    let title: String
}

nonisolated enum ResearchSourceKey {
    /// Host without `www.` plus path without a trailing slash: the same page
    /// reached with tracking parameters or a fragment is one source.
    static func key(forURLString urlString: String) -> String? {
        guard let components = URLComponents(string: urlString),
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        var path = components.percentEncodedPath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty { path = "/" }
        return bareHost + path
    }

    static func site(forURLString urlString: String) -> String? {
        key(forURLString: urlString)?.split(separator: "/", maxSplits: 1).first.map(String.init)
    }
}

nonisolated enum ResearchSourcePicker {

    /// Sites whose pages aren't readable articles (video, social, login walls)
    /// or are the search engine itself.
    private static let skippedSiteSuffixes = [
        "google.com", "googleusercontent.com", "gstatic.com", "bing.com", "duckduckgo.com",
        "youtube.com", "youtu.be", "facebook.com", "instagram.com", "tiktok.com", "x.com",
        "twitter.com", "pinterest.com", "linkedin.com", "accounts.google.com",
    ]

    static func pickedSources(fromSearchResultLinks links: [ResearchSearchResultLink], maximumCount: Int) -> [ResearchSourceCandidate] {
        var pickedCandidates: [ResearchSourceCandidate] = []
        var seenKeys = Set<String>()
        var seenSites = Set<String>()
        for link in links {
            guard pickedCandidates.count < maximumCount else { break }
            guard let resultURLString = unwrappedResultURL(link.href),
                  let key = ResearchSourceKey.key(forURLString: resultURLString),
                  let site = ResearchSourceKey.site(forURLString: resultURLString) else { continue }
            guard !isSkippedSite(site) else { continue }
            let title = link.label.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            // "Cached", "More results", a bare arrow: not a result title.
            guard title.split(separator: " ").count >= 2 else { continue }
            guard !seenKeys.contains(key), !seenSites.contains(site) else { continue }
            seenKeys.insert(key)
            seenSites.insert(site)
            pickedCandidates.append(ResearchSourceCandidate(url: resultURLString, title: String(title.prefix(160))))
        }
        return pickedCandidates
    }

    /// The page a result link leads to: Google's `/url?q=` redirect unwrapped,
    /// anything that isn't http(s) refused.
    static func unwrappedResultURL(_ href: String) -> String? {
        guard let components = URLComponents(string: href),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased() else { return nil }
        if (host == "google.com" || host.hasSuffix(".google.com")) && components.path == "/url" {
            let wrappedAddress = components.queryItems?.first(where: { $0.name == "q" || $0.name == "url" })?.value
            guard let wrappedAddress, wrappedAddress != href else { return nil }
            return unwrappedResultURL(wrappedAddress)
        }
        return href
    }

    private static func isSkippedSite(_ site: String) -> Bool {
        skippedSiteSuffixes.contains { site == $0 || site.hasSuffix("." + $0) }
            || site.hasPrefix("google.") || site.contains(".google.")
    }
}
