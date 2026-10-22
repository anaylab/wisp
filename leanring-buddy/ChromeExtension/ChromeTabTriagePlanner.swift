//
//  ChromeTabTriagePlanner.swift
//  leanring-buddy
//
//  Pure plan behind "triage my tabs" (phase 04): duplicates to close, stale
//  tabs to close (saved as a session first), and groups to make from what's
//  left — one ordered plan the user approves once, on one card.
//
//  Built from the existing planners rather than new rules:
//  `ChromeDuplicateTabFinder` for duplicates, `ChromeStaleTabFinder` for old
//  tabs, and `ChromeTabGroupingPlanner` for the groups (topic groups from the
//  existing model call when there are any, otherwise by site). The grouping is
//  planned over the tabs that will still be open, so a tab is never both closed
//  and grouped, and the numbers on the card are what happens.
//

import Foundation

nonisolated struct ChromeTabTriagePlan: Equatable, Sendable {

    /// The card's lines, in the order they run.
    enum Step: Equatable, Sendable {
        case closeDuplicates(tabCount: Int)
        case closeStaleTabs(tabCount: Int, minimumDaysUnused: Int)
        case makeGroups(groupTitles: [String], tabCount: Int)
    }

    let duplicateTabs: [ChromeTab]
    let staleTabs: [ChromeTab]
    let groupingPlan: ChromeTabGroupingPlan
    let staleRules: ChromeStaleTabRules

    var closedTabCount: Int { duplicateTabs.count + staleTabs.count }
    var groupedTabCount: Int { groupingPlan.groupedTabCount }
    var isEmpty: Bool { closedTabCount == 0 && groupingPlan.plannedGroups.isEmpty }

    /// Titles of the groups to make, once each (a topic in two windows is two
    /// Chrome groups with one name).
    var uniqueGroupTitles: [String] {
        var titles: [String] = []
        for plannedGroup in groupingPlan.plannedGroups where !titles.contains(plannedGroup.title) {
            titles.append(plannedGroup.title)
        }
        return titles
    }

    var steps: [Step] {
        var orderedSteps: [Step] = []
        if !duplicateTabs.isEmpty { orderedSteps.append(.closeDuplicates(tabCount: duplicateTabs.count)) }
        if !staleTabs.isEmpty {
            orderedSteps.append(.closeStaleTabs(tabCount: staleTabs.count, minimumDaysUnused: staleRules.minimumDaysUnused))
        }
        if !groupingPlan.plannedGroups.isEmpty {
            orderedSteps.append(.makeGroups(groupTitles: uniqueGroupTitles, tabCount: groupingPlan.groupedTabCount))
        }
        return orderedSteps
    }
}

nonisolated enum ChromeTabTriagePlanner {

    /// Duplicates first (keeping one copy), then stale tabs that aren't
    /// already going as duplicates.
    static func tabsToClose(
        in snapshot: ChromeTabsSnapshot,
        nowMilliseconds: Double,
        staleRules: ChromeStaleTabRules
    ) -> (duplicateTabs: [ChromeTab], staleTabs: [ChromeTab]) {
        let duplicateTabIDs = Set(ChromeDuplicateTabFinder.tabIDsToClose(in: snapshot))
        let duplicateTabs = snapshot.tabs.filter { duplicateTabIDs.contains($0.id) }
        let staleTabs = ChromeStaleTabFinder.staleTabs(in: snapshot, nowMilliseconds: nowMilliseconds, rules: staleRules)
            .filter { !duplicateTabIDs.contains($0.id) }
        return (duplicateTabs, staleTabs)
    }

    /// The snapshot as it will be once `tabIDs` are closed — what grouping is
    /// planned over, and what the topic prompt lists.
    static func snapshot(_ snapshot: ChromeTabsSnapshot, removingTabIDs tabIDs: Set<Int>) -> ChromeTabsSnapshot {
        ChromeTabsSnapshot(
            tabs: snapshot.tabs.filter { !tabIDs.contains($0.id) },
            groups: snapshot.groups,
            focusedWindowId: snapshot.focusedWindowId
        )
    }

    /// The whole plan. `topicGroups` is the existing topic model call's answer
    /// for the remaining tabs; empty (no model, or nothing usable) groups by site.
    static func plan(
        for snapshot: ChromeTabsSnapshot,
        nowMilliseconds: Double,
        staleRules: ChromeStaleTabRules,
        topicGroups: [(title: String, tabIDs: [Int])]
    ) -> ChromeTabTriagePlan {
        let (duplicateTabs, staleTabs) = tabsToClose(in: snapshot, nowMilliseconds: nowMilliseconds, staleRules: staleRules)
        let closingTabIDs = Set((duplicateTabs + staleTabs).map(\.id))
        let remainingSnapshot = self.snapshot(snapshot, removingTabIDs: closingTabIDs)

        var groupingPlan = ChromeTabGroupingPlanner.plan(topicGroups, in: remainingSnapshot)
        if groupingPlan.plannedGroups.isEmpty {
            groupingPlan = ChromeTabGroupingPlanner.planSiteGroups(for: remainingSnapshot)
        }
        return ChromeTabTriagePlan(
            duplicateTabs: duplicateTabs,
            staleTabs: staleTabs,
            groupingPlan: groupingPlan,
            staleRules: staleRules
        )
    }

    /// The approved plan cut down to tabs still open when it runs — the card
    /// can be up for 45 seconds, and Chrome refuses a whole close or group
    /// request when one id in it is gone.
    static func restricted(_ plan: ChromeTabTriagePlan, toOpenTabIDs openTabIDs: Set<Int>) -> ChromeTabTriagePlan {
        let stillPlannedGroups = plan.groupingPlan.plannedGroups.compactMap { plannedGroup -> ChromeTabGroupingPlan.PlannedGroup? in
            let openGroupTabIDs = plannedGroup.tabIDs.filter { openTabIDs.contains($0) }
            let minimumTabCount = plannedGroup.existingGroupID == nil ? ChromeTabGroupingPlanner.minimumTabsForNewGroup : 1
            guard openGroupTabIDs.count >= minimumTabCount else { return nil }
            return ChromeTabGroupingPlan.PlannedGroup(
                windowID: plannedGroup.windowID,
                title: plannedGroup.title,
                color: plannedGroup.color,
                tabIDs: openGroupTabIDs,
                existingGroupID: plannedGroup.existingGroupID
            )
        }
        return ChromeTabTriagePlan(
            duplicateTabs: plan.duplicateTabs.filter { openTabIDs.contains($0.id) },
            staleTabs: plan.staleTabs.filter { openTabIDs.contains($0.id) },
            groupingPlan: ChromeTabGroupingPlan(plannedGroups: stillPlannedGroups),
            staleRules: plan.staleRules
        )
    }

    /// "closed 3 duplicates and 12 old tabs (saved as "Cleanup Oct 21"), and
    /// grouped 9 tabs into 3 groups."
    static func resultText(for appliedPlan: ChromeTabTriagePlan, savedSessionName: String?) -> String {
        var parts: [String] = []
        if !appliedPlan.duplicateTabs.isEmpty {
            parts.append("closed \(appliedPlan.duplicateTabs.count) duplicate\(appliedPlan.duplicateTabs.count == 1 ? "" : "s")")
        }
        if !appliedPlan.staleTabs.isEmpty {
            let savedText = savedSessionName.map { " (saved as \"\($0)\")" } ?? ""
            let verb = parts.isEmpty ? "closed " : ""
            parts.append("\(verb)\(ChromeTabSessionDescriptions.tabCountText(appliedPlan.staleTabs.count)) you hadn't used\(savedText)")
        }
        let groupCount = appliedPlan.uniqueGroupTitles.count
        if groupCount > 0 {
            parts.append("grouped \(ChromeTabSessionDescriptions.tabCountText(appliedPlan.groupedTabCount)) into \(groupCount) group\(groupCount == 1 ? "" : "s")")
        }
        guard !parts.isEmpty else { return "your tabs are already tidy — nothing to triage." }
        let joinedParts: String
        if parts.count == 1 {
            joinedParts = parts[0]
        } else {
            joinedParts = parts.dropLast().joined(separator: ", ") + " and " + (parts.last ?? "")
        }
        return joinedParts + "."
    }
}
