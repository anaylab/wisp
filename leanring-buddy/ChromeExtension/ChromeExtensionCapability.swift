//
//  ChromeExtensionCapability.swift
//  leanring-buddy
//
//  What the user has let the Wisp Tabs extension do in Chrome
//  (docs/chrome-extension/contracts.md §3). Tabs are always there; the rest
//  are optional Chrome permissions the user grants on the extension's options
//  page, because Chrome only shows a permission prompt after a click inside an
//  extension page. The extension reports the list in `hello` and again in a
//  `capabilities` message whenever it changes.
//
//  Pure (Foundation only) so the frame parser's test suite can compile it.
//

import Foundation

nonisolated enum ChromeExtensionCapability: String, CaseIterable, Sendable, Codable, Hashable {
    /// Today's tab tools and the tab events. Always granted.
    case tabs
    /// `scripting` + `<all_urls>`: reading page text, the DOM controller,
    /// in-page pointing, page watchers.
    case pagesRead = "pages.read"
    /// `downloads`: download events and filing.
    case downloads

    /// The short name the Settings card shows.
    var displayName: String {
        switch self {
        case .tabs:
            return "Tabs"
        case .pagesRead:
            return "Read pages"
        case .downloads:
            return "Downloads"
        }
    }

    /// One line on what the capability lets Wisp do.
    var whatItAllows: String {
        switch self {
        case .tabs:
            return "See, group, mute and close tabs."
        case .pagesRead:
            return "Read, point at and work in pages you ask about."
        case .downloads:
            return "Offer to file finished downloads."
        }
    }

    /// Reads the wire list, keeping only names this build knows (a newer
    /// extension may report capabilities Wisp can't use yet).
    static func capabilities(fromWireNames wireNames: [String]) -> Set<ChromeExtensionCapability> {
        Set(wireNames.compactMap(ChromeExtensionCapability.init(rawValue:)))
    }
}
