//
//  ChromeTabLifeCards.swift
//  leanring-buddy
//
//  The tab-life tool names and confirmation cards (phase 04). Kept apart from
//  the main-actor code in `ChromeTabLife.swift` because `ToolCallSafety` and
//  `ToolConfirmationCardBuilder` name them, and the standalone suites that
//  compile those (`Tests/EditableConfirmation`, `Tests/MCPStructuredContent`)
//  compile this file too.
//
//  A card is drawn from the call's prepared input (never the model's words):
//  `{"session_name", "minimum_days", "tabs"|"duplicates"|"stale": [{id?, title, url}], …}`.
//  Wording lives in `ChromeTabLifeCardText`.
//

import Foundation

nonisolated enum ChromeTabLifeToolNames {
    static let saveTabSession = "chrome_save_tab_session"
    static let restoreTabSession = "chrome_restore_tab_session"
    static let listTabSessions = "chrome_list_tab_sessions"
    static let closeStaleTabs = "chrome_close_stale_tabs"
    /// Not an agent tool: the name the triage plan's approval card is asked under.
    static let applyTabTriage = "chrome_apply_tab_triage"

    /// The ones `ToolCallSafety` keeps asking about under session auto-approve.
    static func mustAlwaysAsk(bareToolName: String) -> Bool {
        [closeStaleTabs, applyTabTriage, restoreTabSession].contains(bareToolName)
    }
}

/// The tab-life confirmation cards, from the call's input (never the model's
/// words). Wording lives in `ChromeTabLifeCardText`.
enum ChromeTabLifeCards {

    /// Nil for any other tool, so `ToolConfirmationCardBuilder` carries on.
    static func confirmationCard(forBareToolName bareToolName: String, toolInput: JSONValue) -> GlanceCard? {
        func cardTabs(_ key: String) -> [ChromeTabLifeCardText.ListedTab] {
            listedTabs(in: toolInput, key: key).map { ChromeTabLifeCardText.ListedTab(title: $0.title, url: $0.url) }
        }
        let sessionName = ToolCallInspection.stringValue(forAnyOf: ["session_name"], in: toolInput)
        let minimumDays = numberValue("minimum_days", in: toolInput) ?? 14

        let cardText: ChromeTabLifeCardText
        let iconName: String
        switch bareToolName {
        case ChromeTabLifeToolNames.closeStaleTabs:
            cardText = ChromeTabLifeCardText.closeStaleTabs(
                sessionName: sessionName ?? "Cleanup", minimumDaysUnused: minimumDays, closingTabs: cardTabs("tabs")
            )
            iconName = "xmark.circle"
        case ChromeTabLifeToolNames.applyTabTriage:
            var groupTitles: [String] = []
            if case .object(let fields) = toolInput, case .array(let titleValues)? = fields["group_titles"] {
                groupTitles = titleValues.compactMap { titleValue in
                    if case .string(let groupTitle) = titleValue { return groupTitle }
                    return nil
                }
            }
            cardText = ChromeTabLifeCardText.triage(
                duplicateTabs: cardTabs("duplicates"),
                staleTabs: cardTabs("stale"),
                sessionName: sessionName,
                minimumDaysUnused: minimumDays,
                groupTitles: groupTitles,
                groupedTabCount: numberValue("grouped_tab_count", in: toolInput) ?? 0
            )
            iconName = "square.stack.3d.up"
        case ChromeTabLifeToolNames.restoreTabSession:
            cardText = ChromeTabLifeCardText.restoreSession(
                sessionName: sessionName ?? "tab session",
                windowCount: numberValue("window_count", in: toolInput) ?? 1,
                groupCount: numberValue("group_count", in: toolInput) ?? 0,
                restoringTabs: cardTabs("tabs")
            )
            iconName = "macwindow"
        default:
            return nil
        }

        var blocks: [GlanceBlock] = [
            .header(title: cardText.headline, iconName: iconName, trailingText: cardText.headlineTrailingText)
        ]
        if !cardText.rows.isEmpty {
            blocks.append(.keyValue(pairs: cardText.rows.map { GlanceKeyValuePair(key: $0.key, value: $0.value, tone: .neutral) }))
        }
        var footerRows: [GlanceListRow] = []
        if let moreText = cardText.moreText { footerRows.append(GlanceListRow(text: moreText, iconName: nil, tone: .neutral)) }
        footerRows.append(GlanceListRow(text: cardText.footnote, iconName: "info.circle", tone: .neutral))
        blocks.append(.list(rows: footerRows))
        return GlanceCard(blocks: blocks)
    }

    // MARK: - The input the cards are drawn from

    /// One tab in a card's input. `tabID` is set for tabs that will close, so
    /// the run can check each is still open at the same address.
    struct ListedTabValue: Equatable {
        let title: String
        let url: String
        let tabID: Int?
    }

    static func listedTabValue(title: String, url: String, tabID: Int?) -> JSONValue {
        var fields: [String: JSONValue] = [
            "title": .string(ChromeTabLifeCardText.shortTitle(title)),
            "url": .string(url),
        ]
        if let tabID { fields["id"] = .number(Double(tabID)) }
        return .object(fields)
    }

    static func listedTabs(in toolInput: JSONValue, key: String) -> [ListedTabValue] {
        guard case .object(let fields) = toolInput, case .array(let tabValues)? = fields[key] else { return [] }
        return tabValues.compactMap { tabValue in
            guard case .object(let tabFields) = tabValue else { return nil }
            var tabID: Int?
            if case .number(let numericTabID)? = tabFields["id"] { tabID = Int(exactly: numericTabID) }
            var title = ""
            if case .string(let titleText)? = tabFields["title"] { title = titleText }
            guard case .string(let url)? = tabFields["url"] else { return nil }
            return ListedTabValue(title: title, url: url, tabID: tabID)
        }
    }

    static func numberValue(_ key: String, in toolInput: JSONValue) -> Int? {
        guard case .object(let fields) = toolInput, case .number(let numericValue)? = fields[key] else { return nil }
        return Int(exactly: numericValue)
    }
}
