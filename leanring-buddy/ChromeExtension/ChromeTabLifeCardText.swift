//
//  ChromeTabLifeCardText.swift
//  leanring-buddy
//
//  Pure wording of the tab-life confirmation cards (phase 04): closing stale
//  tabs, the triage plan, and restoring a big session. `ChromeTabLifeCards`
//  turns this into a `GlanceCard`; keeping the words here lets
//  `Tests/ChromeExtTabLife` check that the card says what will happen.
//
//  Tab titles are page content. They are only ever shown, never followed, and
//  each is cut to one short line.
//

import Foundation

nonisolated struct ChromeTabLifeCardText: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        let key: String
        let value: String
    }

    let headline: String
    let headlineTrailingText: String?
    /// Key/value lines: the plan's steps for triage, otherwise tab titles with their site.
    let rows: [Row]
    /// "and 15 more", when rows were left off.
    let moreText: String?
    /// The reassurance line under the rows.
    let footnote: String

    static let maximumRows = 8
    static let maximumTitleLength = 60

    /// One tab as the card lists it.
    struct ListedTab: Equatable, Sendable {
        let title: String
        let url: String
    }

    static func rows(for listedTabs: [ListedTab]) -> [Row] {
        listedTabs.prefix(maximumRows).map { listedTab in
            Row(key: shortTitle(listedTab.title), value: siteText(forURL: listedTab.url))
        }
    }

    static func moreText(totalCount: Int, shownCount: Int) -> String? {
        totalCount > shownCount ? "and \(totalCount - shownCount) more" : nil
    }

    /// "Close 23 tabs · saved as 'Cleanup Oct 21' first".
    static func closeStaleTabs(sessionName: String, minimumDaysUnused: Int, closingTabs: [ListedTab]) -> ChromeTabLifeCardText {
        let shownRows = rows(for: closingTabs)
        let dayText = minimumDaysUnused == 1 ? "a day" : "\(minimumDaysUnused) days"
        return ChromeTabLifeCardText(
            headline: "Close \(tabCountText(closingTabs.count)) · saved as '\(sessionName)' first",
            headlineTrailingText: nil,
            rows: shownRows,
            moreText: moreText(totalCount: closingTabs.count, shownCount: shownRows.count),
            footnote: "Unused for \(dayText) or more. Say \"restore \(sessionName)\" to bring them back."
        )
    }

    /// One card for the whole triage: the steps with their counts, then the
    /// tabs that will close.
    static func triage(
        duplicateTabs: [ListedTab],
        staleTabs: [ListedTab],
        sessionName: String?,
        minimumDaysUnused: Int,
        groupTitles: [String],
        groupedTabCount: Int
    ) -> ChromeTabLifeCardText {
        var stepRows: [Row] = []
        if !duplicateTabs.isEmpty {
            stepRows.append(Row(key: "Close duplicates", value: tabCountText(duplicateTabs.count)))
        }
        if !staleTabs.isEmpty {
            let savedText = sessionName.map { " · saved as '\($0)' first" } ?? ""
            stepRows.append(Row(
                key: "Close unused \(minimumDaysUnused)+ days",
                value: tabCountText(staleTabs.count) + savedText
            ))
        }
        if !groupTitles.isEmpty {
            let shownTitles = groupTitles.prefix(4).joined(separator: ", ") + (groupTitles.count > 4 ? "…" : "")
            stepRows.append(Row(
                key: "Make \(groupTitles.count) group\(groupTitles.count == 1 ? "" : "s")",
                value: "\(tabCountText(groupedTabCount)): \(shownTitles)"
            ))
        }

        let closingTabs = duplicateTabs + staleTabs
        let titleRowBudget = max(0, maximumRows - stepRows.count)
        let closingTitleRows = rows(for: Array(closingTabs.prefix(titleRowBudget)))
        let closedCount = closingTabs.count
        let headline: String
        if closedCount > 0 && groupedTabCount > 0 {
            headline = "Close \(tabCountText(closedCount)), group \(groupedTabCount)"
        } else if closedCount > 0 {
            headline = "Close \(tabCountText(closedCount))"
        } else {
            headline = "Group \(tabCountText(groupedTabCount))"
        }
        return ChromeTabLifeCardText(
            headline: "Triage · " + headline,
            headlineTrailingText: nil,
            rows: stepRows + closingTitleRows,
            moreText: moreText(totalCount: closedCount, shownCount: closingTitleRows.count),
            footnote: sessionName == nil
                ? "Pinned tabs, tabs playing sound and your groups stay put."
                : "Pinned tabs, tabs playing sound and your groups stay put. Unused tabs are saved first."
        )
    }

    /// "Open 14 tabs · 'Thesis research'".
    static func restoreSession(sessionName: String, windowCount: Int, groupCount: Int, restoringTabs: [ListedTab]) -> ChromeTabLifeCardText {
        let shownRows = rows(for: restoringTabs)
        let windowText = windowCount == 1 ? "a new window" : "\(windowCount) new windows"
        let groupText = groupCount == 0 ? "" : ", with its \(groupCount) group\(groupCount == 1 ? "" : "s")"
        return ChromeTabLifeCardText(
            headline: "Open \(tabCountText(restoringTabs.count)) · '\(sessionName)'",
            headlineTrailingText: nil,
            rows: shownRows,
            moreText: moreText(totalCount: restoringTabs.count, shownCount: shownRows.count),
            footnote: "Opens in \(windowText)\(groupText). Pages load as you visit them."
        )
    }

    static func tabCountText(_ tabCount: Int) -> String {
        tabCount == 1 ? "1 tab" : "\(tabCount) tabs"
    }

    static func shortTitle(_ rawTitle: String) -> String {
        let singleLineTitle = rawTitle
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !singleLineTitle.isEmpty else { return "(untitled)" }
        guard singleLineTitle.count > maximumTitleLength else { return singleLineTitle }
        return String(singleLineTitle.prefix(maximumTitleLength - 1)) + "…"
    }

    /// "github.com" for a web page, "chrome://settings" for Chrome's own.
    static func siteText(forURL urlString: String) -> String {
        guard let urlComponents = URLComponents(string: urlString), let host = urlComponents.host, !host.isEmpty else { return "" }
        if urlComponents.scheme?.lowercased() == "chrome" { return "chrome://\(host)" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
