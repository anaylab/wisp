//
//  BrainActivityExclusions.swift
//  leanring-buddy
//
//  What the activity feed must never record, and how a URL is cleaned before
//  it is stored. Pure, so the whole privacy policy is testable.
//
//  The feed records things the user never asked Wisp about, so the defaults
//  lean hard toward not recording: password managers, the lock screen and
//  System Settings are skipped by app, and banking/finance/health/adult sites
//  by domain. A skipped sample is dropped entirely — not recorded as "some
//  app" — because even the window title of a banking tab says too much.
//  The user's own lists (`BrainPreferences.activityExcludedBundleIdentifiers`
//  / `activityExcludedDomains`) extend the built-in ones.
//

import Foundation

/// One observation of what the user was working in.
nonisolated struct BrainActivitySample: Equatable, Sendable {
    var date: Date
    var applicationName: String
    var bundleIdentifier: String
    /// The focused window's title (Accessibility). Nil when unreadable.
    var windowTitle: String?
    /// Browser front tab URL with query string and fragment removed.
    var url: String?
    /// Lowercased host of `url`, without a leading "www.".
    var domain: String?
    /// A little on-screen text, only when text capture is on (≤300 chars).
    var screenText: String?
}

nonisolated enum BrainActivityExclusionPolicy {
    /// Apps never recorded. Wisp itself is added at runtime by bundle id too.
    static let builtInExcludedBundleIdentifiers: Set<String> = [
        // Password managers.
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "com.agilebits.onepassword4",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.lastpass.LastPass",
        "com.lastpass.lastpassmacdesktop",
        "com.dashlane.Dashlane",
        "com.dashlane.dashlanephonefinal",
        "in.sinew.Enpass-Desktop",
        "com.keepassxc.keepassxc",
        "org.keepassxc.keepassxc",
        "com.nordpass.macos.NordPass",
        "me.proton.pass.electron",
        // The lock screen and screen saver: whatever they show is not work.
        "com.apple.loginwindow",
        "com.apple.ScreenSaver.Engine",
        "com.apple.screensaver",
        // System Settings shows account, network and security details.
        "com.apple.systempreferences",
        "com.apple.Settings",
        // Wisp's own bundle id (the running one is also checked at runtime).
        "com.gluepixel.wisp",
    ]

    /// Words in an app's bundle id that mark it as a password manager even
    /// when it isn't in the list above (a new version, a different vendor id).
    static let excludedBundleIdentifierWords: [String] = ["1password", "onepassword", "bitwarden", "lastpass", "dashlane", "keepass", "passwords"]

    /// Sites never recorded. Subdomains match too (`secure.chase.com`).
    static let builtInExcludedDomains: Set<String> = [
        // Banking and cards.
        "chase.com", "bankofamerica.com", "wellsfargo.com", "citi.com", "citibank.com",
        "capitalone.com", "usbank.com", "pnc.com", "tdbank.com", "ally.com", "discover.com",
        "americanexpress.com", "barclays.co.uk", "barclaycard.co.uk", "hsbc.com", "hsbc.co.uk",
        "lloydsbank.co.uk", "natwest.com", "santander.com", "santander.co.uk", "monzo.com",
        "revolut.com", "n26.com", "wise.com", "sofi.com", "chime.com", "schwab.com",
        "icicibank.com", "hdfcbank.com", "sbi.co.in", "axisbank.com", "kotak.com",
        // Payments and money transfer.
        "paypal.com", "venmo.com", "cash.app", "zellepay.com", "stripe.com", "klarna.com",
        "affirm.com", "paytm.com", "phonepe.com",
        // Investing, brokerage, crypto and tax.
        "fidelity.com", "vanguard.com", "robinhood.com", "etrade.com", "interactivebrokers.com",
        "coinbase.com", "binance.com", "kraken.com", "crypto.com", "wealthfront.com",
        "betterment.com", "zerodha.com", "groww.in", "turbotax.intuit.com", "irs.gov",
        "hmrc.gov.uk", "creditkarma.com", "experian.com", "equifax.com", "transunion.com",
        "mint.intuit.com", "ynab.com",
        // Health.
        "mychart.org", "mychart.com", "patient.info", "zocdoc.com", "teladoc.com",
        "kp.org", "healthcare.gov", "nhs.uk", "goodrx.com", "23andme.com", "betterhelp.com",
        "talkspace.com", "webmd.com", "onemedical.com",
        // Adult.
        "pornhub.com", "xvideos.com", "xnxx.com", "xhamster.com", "onlyfans.com",
        "redtube.com", "youporn.com", "chaturbate.com", "stripchat.com",
        // Account and password pages.
        "accounts.google.com", "appleid.apple.com", "account.apple.com", "login.microsoftonline.com",
        "login.live.com", "my.1password.com", "vault.bitwarden.com",
    ]

    /// Words that exclude a host when they appear inside one of its labels
    /// ("mybank.example", "firstcreditunion.org", "xxxvideos.net"). A cheap
    /// net for the long tail of local banks and adult sites the list can't name.
    static let excludedHostLabelWords: [String] = ["bank", "creditunion", "porn", "xxx", "onlyfans"]

    /// Browsers whose front tab Wisp can't read. Their window title is a
    /// page title that can't be checked against the site exclusions (or for
    /// private browsing), so only the app name is recorded for them.
    static let browserBundleIdentifiersWithoutURLReading: Set<String> = [
        "company.thebrowser.Browser", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
        "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
        "com.google.Chrome.beta", "com.google.Chrome.canary", "com.google.Chrome.dev", "org.chromium.Chromium",
        "com.kagi.kagimacOS", "app.zen-browser.zen",
    ]

    // MARK: Apps

    static func isApplicationExcluded(
        bundleIdentifier: String,
        ownBundleIdentifier: String?,
        userExcludedBundleIdentifiers: [String]
    ) -> Bool {
        let comparableBundleIdentifier = bundleIdentifier.lowercased()
        if let ownBundleIdentifier, comparableBundleIdentifier == ownBundleIdentifier.lowercased() { return true }
        let builtInLowercased = Set(builtInExcludedBundleIdentifiers.map { $0.lowercased() })
        if builtInLowercased.contains(comparableBundleIdentifier) { return true }
        if excludedBundleIdentifierWords.contains(where: { comparableBundleIdentifier.contains($0) }) { return true }
        let userExcludedLowercased = userExcludedBundleIdentifiers.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return userExcludedLowercased.contains(comparableBundleIdentifier)
    }

    // MARK: Sites

    /// Normalises a user-typed domain ("https://www.Chase.com/login" →
    /// "chase.com") so the list works however it was entered.
    static func normalizedDomain(_ typedDomain: String) -> String {
        var domain = typedDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let schemeRange = domain.range(of: "://") {
            domain = String(domain[schemeRange.upperBound...])
        }
        if let pathStart = domain.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            domain = String(domain[..<pathStart])
        }
        if let portStart = domain.firstIndex(of: ":") {
            domain = String(domain[..<portStart])
        }
        if domain.hasPrefix("*.") { domain.removeFirst(2) }
        if domain.hasPrefix("www.") { domain.removeFirst(4) }
        while domain.hasSuffix(".") { domain.removeLast() }
        return domain
    }

    /// Whether `host` is an excluded domain or a subdomain of one.
    static func isDomainExcluded(host: String, userExcludedDomains: [String]) -> Bool {
        let comparableHost = normalizedDomain(host)
        guard !comparableHost.isEmpty else { return false }
        let allExcludedDomains = builtInExcludedDomains.union(userExcludedDomains.map(normalizedDomain)).filter { !$0.isEmpty }
        for excludedDomain in allExcludedDomains {
            if comparableHost == excludedDomain || comparableHost.hasSuffix("." + excludedDomain) {
                return true
            }
        }
        let hostLabels = comparableHost.split(separator: ".").map(String.init)
        return hostLabels.contains { hostLabel in
            excludedHostLabelWords.contains { hostLabel.contains($0) }
        }
    }

    // MARK: URLs

    /// A URL cleaned for storage: http(s) only, no credentials, no query
    /// string, no fragment (tokens, session ids and search terms live there).
    /// Returns nil for anything else (file:, chrome://, about:blank…).
    static func sanitizedURL(_ rawURLString: String) -> (url: String, domain: String)? {
        let trimmedURLString = rawURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmedURLString),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return nil }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        components.scheme = scheme
        components.host = host.lowercased()
        guard let cleanedURLString = components.string else { return nil }
        return (cleanedURLString, normalizedDomain(host))
    }

    // MARK: Screen text

    /// Longest screen-text excerpt kept with a sample.
    static let maximumScreenTextCharacters = 300

    /// Collapses whitespace and caps the excerpt.
    static func cappedScreenText(_ screenText: String) -> String? {
        let collapsedText = screenText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsedText.isEmpty else { return nil }
        if collapsedText.count <= maximumScreenTextCharacters { return collapsedText }
        return String(collapsedText.prefix(maximumScreenTextCharacters - 1)) + "…"
    }
}
