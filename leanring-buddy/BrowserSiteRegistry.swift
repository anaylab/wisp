//
//  BrowserSiteRegistry.swift
//  leanring-buddy
//
//  The sites the deterministic planner knows, as data rather than control flow.
//
//  Every request answered from here costs no planning call at all — measured at
//  roughly two seconds saved each time, since planning generation dominates that
//  path. So the value of this file is proportional to how much of it there is,
//  which is exactly why it must not be a growing thicket of if-statements.
//  Adding a site is adding a row.
//
//  The bar for inclusion is deliberately high: a site belongs here only when the
//  workflow is genuinely predictable without reasoning. "Search Wikipedia for X"
//  has one shape. "Find my open issues" does not — it depends on who is logged
//  in and what that account contains — and putting it here would produce a
//  confident search for the literal phrase, which is worse than admitting the
//  planner does not know.
//

import Foundation

/// What can be done with a site without thinking about it.
struct BrowserSiteDefinition: Sendable {
    let name: String
    /// Canonical host, used for navigation.
    let homeURL: String
    /// What people call it out loud, lowercased. The name itself is implied.
    let aliases: [String]
    /// Query goes where `{query}` is, percent-encoded.
    ///
    /// Nil for sites worth navigating to but with no stable public search that
    /// can be addressed by URL — pretending otherwise produces plans that land
    /// somewhere unhelpful.
    let searchURLTemplate: String?

    /// Every name this site answers to.
    var allNames: [String] { [name] + aliases }

    func searchURL(for query: String) -> URL? {
        guard let template = searchURLTemplate,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }
        return URL(string: template.replacingOccurrences(of: "{query}", with: encoded))
    }

    var homeURLValue: URL? { URL(string: homeURL) }
}

enum BrowserSiteRegistry {
    /// Ordered longest-name-first at lookup time so "stack overflow" is not
    /// shadowed by a site whose alias happens to be a prefix.
    static let sites: [BrowserSiteDefinition] = [
        BrowserSiteDefinition(
            name: "google", homeURL: "https://www.google.com",
            aliases: [], searchURLTemplate: "https://www.google.com/search?q={query}"
        ),
        BrowserSiteDefinition(
            name: "bing", homeURL: "https://www.bing.com",
            aliases: [], searchURLTemplate: "https://www.bing.com/search?q={query}"
        ),
        BrowserSiteDefinition(
            name: "duckduckgo", homeURL: "https://duckduckgo.com",
            aliases: ["duck duck go", "ddg"], searchURLTemplate: "https://duckduckgo.com/?q={query}"
        ),
        BrowserSiteDefinition(
            name: "wikipedia", homeURL: "https://en.wikipedia.org",
            aliases: ["wiki"], searchURLTemplate: "https://en.wikipedia.org/w/index.php?search={query}"
        ),
        BrowserSiteDefinition(
            name: "youtube", homeURL: "https://www.youtube.com",
            aliases: ["you tube"], searchURLTemplate: "https://www.youtube.com/results?search_query={query}"
        ),
        BrowserSiteDefinition(
            name: "reddit", homeURL: "https://www.reddit.com",
            aliases: [], searchURLTemplate: "https://www.reddit.com/search/?q={query}"
        ),
        BrowserSiteDefinition(
            name: "github", homeURL: "https://github.com",
            aliases: ["git hub"], searchURLTemplate: "https://github.com/search?q={query}"
        ),
        BrowserSiteDefinition(
            name: "stack overflow", homeURL: "https://stackoverflow.com",
            aliases: ["stackoverflow"], searchURLTemplate: "https://stackoverflow.com/search?q={query}"
        ),
        BrowserSiteDefinition(
            name: "amazon", homeURL: "https://www.amazon.com",
            aliases: [], searchURLTemplate: "https://www.amazon.com/s?k={query}"
        ),
        BrowserSiteDefinition(
            name: "hacker news", homeURL: "https://news.ycombinator.com",
            aliases: ["hackernews", "hn"],
            searchURLTemplate: "https://hn.algolia.com/?q={query}"
        ),
    ]

    /// Finds the site a request names, longest name first.
    ///
    /// Longest-first matters: "stack overflow" contains no other site's name,
    /// but a shorter alias appearing inside a longer one would otherwise win by
    /// position and send the request somewhere else entirely.
    static func site(namedIn text: String) -> BrowserSiteDefinition? {
        let lowercased = text.lowercased()
        let candidates = sites.flatMap { site in site.allNames.map { (name: $0, site: site) } }
        return candidates
            .filter { lowercased.contains($0.name) }
            .max { $0.name.count < $1.name.count }?
            .site
    }
}
