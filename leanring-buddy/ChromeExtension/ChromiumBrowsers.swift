//
//  ChromiumBrowsers.swift
//  leanring-buddy
//
//  Which Chromium browsers the Wisp extension can run in, what to call each
//  one, and which connected browser Wisp talks to right now.
//
//  Arc, Brave, Edge, Vivaldi, Opera and Chrome's Beta/Dev/Canary channels load
//  the same unpacked extension with the same ID (the manifest `key`), so every
//  one of them can dial into Wisp's bridge at once. The bridge keeps one
//  connection per browser and sends each request to one of them, the *active
//  browser*, chosen here:
//
//  1. While work Wisp started in a browser is still going (a task tab, research
//     tabs, focus mode, page watches), that browser stays active. Chrome's tab
//     ids are per browser, so a request carrying a tab id from Chrome must not
//     reach Edge, where the same number is some other tab.
//  2. Otherwise the browser the user is in (the last app in front that isn't
//     Wisp), when it's one of the connected ones.
//  3. Otherwise whichever was active before, so going from Edge to Xcode and
//     asking "organize my tabs" still means Edge's tabs.
//  4. Otherwise Google Chrome, then whichever connected first.
//
//  A browser is known by the bundle identifier of the app that owns the
//  socket (`ChromeExtensionPeerProcess` finds it), because the extension can't
//  tell Chrome from Chrome Canary or from Arc: they report the same brand.
//  When that lookup fails, the extension's own `hello.browserName` stands in.
//
//  Pure (Foundation only) so `Tests/ChromeExtBrowsers` can compile it.
//

import Foundation

nonisolated struct ChromiumBrowserDescription: Equatable, Sendable {
    let bundleIdentifier: String
    let displayName: String
    /// Words the extension's `hello.browserName` (a `navigator.userAgentData`
    /// brand) contains for this browser, lowercased. Empty when the browser
    /// reports no brand of its own (Arc, Vivaldi), so a name alone can't
    /// identify it.
    let helloBrandWords: [String]
}

nonisolated enum ChromiumBrowserCatalog {
    static let googleChromeBundleIdentifier = "com.google.Chrome"

    /// Every Chromium browser Wisp names. Exact bundle identifiers: the
    /// channels share a prefix ("com.google.Chrome.canary" starts with
    /// "com.google.Chrome") but are different apps with different tabs.
    static let knownBrowsers: [ChromiumBrowserDescription] = [
        ChromiumBrowserDescription(bundleIdentifier: "com.google.Chrome", displayName: "Google Chrome", helloBrandWords: ["google chrome"]),
        ChromiumBrowserDescription(bundleIdentifier: "com.google.Chrome.beta", displayName: "Chrome Beta", helloBrandWords: ["google chrome"]),
        ChromiumBrowserDescription(bundleIdentifier: "com.google.Chrome.dev", displayName: "Chrome Dev", helloBrandWords: ["google chrome"]),
        ChromiumBrowserDescription(bundleIdentifier: "com.google.Chrome.canary", displayName: "Chrome Canary", helloBrandWords: ["google chrome"]),
        ChromiumBrowserDescription(bundleIdentifier: "org.chromium.Chromium", displayName: "Chromium", helloBrandWords: ["chromium"]),
        ChromiumBrowserDescription(bundleIdentifier: "com.microsoft.edgemac", displayName: "Microsoft Edge", helloBrandWords: ["microsoft edge"]),
        ChromiumBrowserDescription(bundleIdentifier: "com.microsoft.edgemac.Beta", displayName: "Edge Beta", helloBrandWords: ["microsoft edge"]),
        ChromiumBrowserDescription(bundleIdentifier: "com.microsoft.edgemac.Dev", displayName: "Edge Dev", helloBrandWords: ["microsoft edge"]),
        ChromiumBrowserDescription(bundleIdentifier: "com.microsoft.edgemac.Canary", displayName: "Edge Canary", helloBrandWords: ["microsoft edge"]),
        ChromiumBrowserDescription(bundleIdentifier: "com.brave.Browser", displayName: "Brave", helloBrandWords: ["brave"]),
        ChromiumBrowserDescription(bundleIdentifier: "com.brave.Browser.beta", displayName: "Brave Beta", helloBrandWords: ["brave"]),
        ChromiumBrowserDescription(bundleIdentifier: "com.brave.Browser.nightly", displayName: "Brave Nightly", helloBrandWords: ["brave"]),
        ChromiumBrowserDescription(bundleIdentifier: "company.thebrowser.Browser", displayName: "Arc", helloBrandWords: []),
        ChromiumBrowserDescription(bundleIdentifier: "com.vivaldi.Vivaldi", displayName: "Vivaldi", helloBrandWords: []),
        ChromiumBrowserDescription(bundleIdentifier: "com.operasoftware.Opera", displayName: "Opera", helloBrandWords: ["opera"]),
    ]

    /// Prefixes for channels the table above doesn't list by name, so a new
    /// Edge or Brave channel still counts as a Chromium browser.
    private static let chromiumBundleIdentifierPrefixes = [
        "com.google.Chrome", "org.chromium.Chromium", "com.microsoft.edgemac",
        "com.brave.Browser", "company.thebrowser.", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    static func description(forBundleIdentifier bundleIdentifier: String) -> ChromiumBrowserDescription? {
        knownBrowsers.first { $0.bundleIdentifier == bundleIdentifier }
    }

    static func isChromiumBrowser(bundleIdentifier: String) -> Bool {
        chromiumBundleIdentifierPrefixes.contains { bundleIdentifier.hasPrefix($0) }
    }

    /// The name to show for a connected browser: the catalog's, else the app's
    /// own name, else what the extension said, else "Chrome".
    static func displayName(bundleIdentifier: String?, applicationName: String?, helloBrowserName: String) -> String {
        if let bundleIdentifier, let knownBrowser = description(forBundleIdentifier: bundleIdentifier) {
            return knownBrowser.displayName
        }
        if let applicationName, !applicationName.trimmingCharacters(in: .whitespaces).isEmpty {
            return applicationName
        }
        let trimmedHelloName = helloBrowserName.trimmingCharacters(in: .whitespaces)
        return trimmedHelloName.isEmpty ? "Chrome" : trimmedHelloName
    }

    /// The key one connection per browser profile is kept under: the bundle
    /// identifier when the socket's owner was found, else the extension's
    /// brand name, plus the extension's per-profile instance id when it sent
    /// one (two Chrome profiles each run their own copy of the extension; with
    /// one key they'd replace each other every 30 seconds).
    static func browserID(bundleIdentifier: String?, helloBrowserName: String, instanceID: String?) -> String {
        let browserPart: String
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            browserPart = bundleIdentifier
        } else {
            browserPart = "name:" + helloBrowserName.trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard let instanceID, !instanceID.isEmpty else { return browserPart }
        return browserPart + "#" + instanceID
    }

    /// Whether a connection whose owner is unknown is plausibly the app with
    /// this bundle identifier, judged by the extension's brand name alone.
    /// Conservative: Arc and Vivaldi report no brand, so they never match by
    /// name, and Chrome's channels all say "Google Chrome", so only the stable
    /// channel is assumed.
    static func helloBrowserName(_ helloBrowserName: String, plausiblyBelongsTo bundleIdentifier: String) -> Bool {
        guard let knownBrowser = description(forBundleIdentifier: bundleIdentifier),
              !knownBrowser.helloBrandWords.isEmpty else { return false }
        let lowercasedHelloName = helloBrowserName.lowercased()
        guard knownBrowser.helloBrandWords.contains(where: { lowercasedHelloName.contains($0) }) else { return false }
        // Every channel shares its stable channel's brand; pick the stable one.
        let firstBrowserWithTheseWords = knownBrowsers.first { $0.helloBrandWords == knownBrowser.helloBrandWords }
        return firstBrowserWithTheseWords?.bundleIdentifier == bundleIdentifier
    }
}

/// One connected browser, as the routing rule sees it.
nonisolated struct ChromiumBrowserConnectionSummary: Equatable, Sendable {
    let browserID: String
    /// The app that owns the socket, when it was found.
    let bundleIdentifier: String?
    let helloBrowserName: String
    /// Order of connection; lower connected earlier.
    let connectionOrder: Int

    /// Whether this connection is the app with `bundleIdentifier`.
    func isBrowser(withBundleIdentifier frontmostBundleIdentifier: String) -> Bool {
        if let bundleIdentifier { return bundleIdentifier == frontmostBundleIdentifier }
        return ChromiumBrowserCatalog.helloBrowserName(helloBrowserName, plausiblyBelongsTo: frontmostBundleIdentifier)
    }

    var isGoogleChrome: Bool {
        isBrowser(withBundleIdentifier: ChromiumBrowserCatalog.googleChromeBundleIdentifier)
    }
}

nonisolated struct ChromiumBrowserRoutingInputs: Equatable, Sendable {
    let connectedBrowsers: [ChromiumBrowserConnectionSummary]
    /// The last app in front that isn't Wisp (a typed question brings Wisp
    /// forward, and the user still means the browser they came from).
    let frontmostBundleIdentifier: String?
    let currentActiveBrowserID: String?
    /// True while work Wisp started in the active browser is still going.
    let isActiveBrowserHeld: Bool
}

nonisolated enum ChromiumBrowserRouting {
    /// The browser requests go to, or nil when none is connected. See the file
    /// comment for the order of the rules and why.
    static func activeBrowserID(_ inputs: ChromiumBrowserRoutingInputs) -> String? {
        let connectedBrowsers = inputs.connectedBrowsers
        guard !connectedBrowsers.isEmpty else { return nil }
        if connectedBrowsers.count == 1 { return connectedBrowsers[0].browserID }

        let currentActiveBrowser = connectedBrowsers.first { $0.browserID == inputs.currentActiveBrowserID }
        if inputs.isActiveBrowserHeld, let currentActiveBrowser {
            return currentActiveBrowser.browserID
        }
        if let frontmostBundleIdentifier = inputs.frontmostBundleIdentifier {
            // Two profiles of the browser in front can't be told apart from
            // here, so the one already active wins, then the earliest.
            if let currentActiveBrowser, currentActiveBrowser.isBrowser(withBundleIdentifier: frontmostBundleIdentifier) {
                return currentActiveBrowser.browserID
            }
            if let frontmostConnectedBrowser = connectedBrowsers
                .filter({ $0.isBrowser(withBundleIdentifier: frontmostBundleIdentifier) })
                .min(by: { $0.connectionOrder < $1.connectionOrder }) {
                return frontmostConnectedBrowser.browserID
            }
        }
        if let currentActiveBrowser {
            return currentActiveBrowser.browserID
        }
        if let googleChrome = connectedBrowsers.first(where: \.isGoogleChrome) {
            return googleChrome.browserID
        }
        return connectedBrowsers.min { $0.connectionOrder < $1.connectionOrder }?.browserID
    }
}
