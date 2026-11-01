//
//  StudyBlocklist.swift
//  leanring-buddy
//
//  What Study mode holds back during a focus phase: ready-made categories plus
//  anything the user adds. Pure: matching a URL's host or an app's bundle id.
//

import Foundation

struct StudyBlockCategory: Identifiable, Equatable {
    let id: String
    let title: String
    let symbolName: String
    let domains: [String]
    let appBundleIdentifiers: [String]
}

struct StudyBlockedApp: Codable, Equatable, Identifiable {
    let bundleIdentifier: String
    let name: String
    var id: String { bundleIdentifier }
}

struct StudyBlocklist: Codable, Equatable {
    var enabledCategoryIDs: Set<String> = ["social", "video"]
    var customDomains: [String] = []
    var customApps: [StudyBlockedApp] = []
    var blocksWebsites = true
    var blocksApps = true

    static let categories: [StudyBlockCategory] = [
        StudyBlockCategory(
            id: "social", title: "Social media", symbolName: "bubble.left.and.bubble.right",
            domains: ["instagram.com", "tiktok.com", "x.com", "twitter.com", "facebook.com",
                      "snapchat.com", "reddit.com", "threads.net", "linkedin.com"],
            appBundleIdentifiers: ["com.burbn.instagram", "com.zhiliaoapp.musically"]),
        StudyBlockCategory(
            id: "video", title: "Video & streaming", symbolName: "play.rectangle",
            domains: ["youtube.com", "netflix.com", "twitch.tv", "hulu.com", "disneyplus.com",
                      "primevideo.com", "max.com"],
            appBundleIdentifiers: ["com.apple.TV", "com.netflix.Netflix", "tv.twitch.studio"]),
        StudyBlockCategory(
            id: "games", title: "Games", symbolName: "gamecontroller",
            domains: ["steampowered.com", "epicgames.com", "roblox.com", "chess.com", "miniclip.com"],
            appBundleIdentifiers: ["com.valvesoftware.steam", "com.epicgames.EpicGamesLauncher",
                                   "com.roblox.RobloxPlayer", "com.mojang.minecraftlauncher"]),
        StudyBlockCategory(
            id: "chat", title: "Chat apps", symbolName: "message",
            domains: ["discord.com", "web.whatsapp.com", "messenger.com", "telegram.org"],
            appBundleIdentifiers: ["com.hnc.Discord", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram",
                                   "com.apple.MobileSMS"]),
        StudyBlockCategory(
            id: "news", title: "News & shopping", symbolName: "newspaper",
            domains: ["cnn.com", "nytimes.com", "bbc.com", "news.ycombinator.com", "amazon.com", "ebay.com"],
            appBundleIdentifiers: []),
    ]

    /// Apps that are never blocked, so a session can't lock the user out of their Mac.
    static let protectedBundleIdentifiers: Set<String> = [
        "com.apple.finder", "com.apple.systempreferences", "com.apple.loginwindow",
        "com.apple.dock", "com.apple.SecurityAgent", "com.apple.ActivityMonitor",
    ]

    var isEmpty: Bool {
        allDomains.isEmpty && allAppBundleIdentifiers.isEmpty
    }

    var allDomains: [String] {
        guard blocksWebsites else { return [] }
        let categoryDomains = Self.categories
            .filter { enabledCategoryIDs.contains($0.id) }
            .flatMap(\.domains)
        return Array(Set(categoryDomains + customDomains)).sorted()
    }

    var allAppBundleIdentifiers: Set<String> {
        guard blocksApps else { return [] }
        let categoryApps = Self.categories
            .filter { enabledCategoryIDs.contains($0.id) }
            .flatMap(\.appBundleIdentifiers)
        return Set(categoryApps).union(customApps.map(\.bundleIdentifier))
    }

    func blocksApp(bundleIdentifier: String, ownBundleIdentifier: String?) -> Bool {
        if bundleIdentifier == ownBundleIdentifier { return false }
        if Self.protectedBundleIdentifiers.contains(bundleIdentifier) { return false }
        return allAppBundleIdentifiers.contains(bundleIdentifier)
    }

    /// The blocked domain a page's URL falls under ("www.youtube.com/watch?v=…" → "youtube.com"), if any.
    func blockedDomain(forURLString urlString: String) -> String? {
        guard let host = Self.host(fromURLString: urlString) else { return nil }
        return allDomains.first { host == $0 || host.hasSuffix("." + $0) }
    }

    // MARK: - Parsing what the user types

    /// "https://www.Reddit.com/r/all" → "reddit.com". Nil when it doesn't look like a site.
    static func normalizedDomain(fromUserText text: String) -> String? {
        guard let host = host(fromURLString: text) else { return nil }
        let withoutWWW = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard withoutWWW.contains("."),
              !withoutWWW.hasPrefix("."), !withoutWWW.hasSuffix("."),
              withoutWWW.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }) else {
            return nil
        }
        return withoutWWW
    }

    static func host(fromURLString urlString: String) -> String? {
        var trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let host = URLComponents(string: trimmed)?.host, !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
