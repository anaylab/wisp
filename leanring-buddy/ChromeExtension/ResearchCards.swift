//
//  ResearchCards.swift
//  leanring-buddy
//
//  Research mode's tool names and its one confirmation card (phase 11): "close
//  the research tabs you used too?". Kept apart from the main-actor session
//  code because `ToolCallSafety` and `ToolConfirmationCardBuilder` name them,
//  and the standalone suites that compile those (`Tests/EditableConfirmation`,
//  `Tests/MCPStructuredContent`) compile this file too.
//

import Foundation

nonisolated enum ResearchToolNames {
    static let researchTopic = "chrome_research_topic"
    /// Not an agent tool: the name the "close tabs you used" card is asked under.
    /// On `ToolCallSafety.alwaysAskBareToolNames`: session auto-approve must not
    /// close a tab the user was reading.
    static let closeResearchTabs = "chrome_close_research_tabs"
}

enum ResearchCards {

    /// Nil for any other tool, so `ToolConfirmationCardBuilder` carries on.
    static func confirmationCard(forBareToolName bareToolName: String, toolInput: JSONValue) -> GlanceCard? {
        guard bareToolName == ResearchToolNames.closeResearchTabs else { return nil }
        let usedTabCount = numberValue("used_tab_count", in: toolInput) ?? 0
        let untouchedTabCount = numberValue("untouched_tab_count", in: toolInput) ?? 0
        let usedTabsText = usedTabCount == 1 ? "1 tab you used" : "\(usedTabCount) tabs you used"
        return GlanceCard(blocks: [
            .header(title: "Close research tabs", iconName: "xmark.circle", trailingText: nil),
            .keyValue(pairs: [
                GlanceKeyValuePair(key: "Also close", value: usedTabsText, tone: .neutral),
                GlanceKeyValuePair(key: "Closing anyway", value: "\(untouchedTabCount) untouched", tone: .neutral),
            ]),
            .list(rows: [
                GlanceListRow(text: "Cancel keeps the tabs you used open.", iconName: "info.circle", tone: .neutral),
            ]),
        ])
    }

    private static func numberValue(_ key: String, in toolInput: JSONValue) -> Int? {
        guard case .object(let fields) = toolInput, case .number(let numericValue)? = fields[key] else { return nil }
        return Int(exactly: numericValue)
    }
}
