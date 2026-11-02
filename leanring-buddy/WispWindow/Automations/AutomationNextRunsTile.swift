//
//  AutomationNextRunsTile.swift
//  leanring-buddy
//
//  Today's "Next up" tile: everything Wisp will do on its own later and when each runs --
//  automations, buddies that still keep their own schedule, and scheduled workflows -- merged by
//  `WispScheduledPolicy` into one soonest-first list. Shows the next three; "Show all" opens the
//  rest grouped Today / Tomorrow / Later. Tapping the tile opens the Automations page.
//

import SwiftUI

struct AutomationNextRunsTile: View {
    @ObservedObject private var automationEngine = AutomationEngine.shared
    @ObservedObject private var buddyStore = BuddyStore.shared
    @ObservedObject private var workflowStore = WorkflowStore.shared

    /// The tile is small; "Show all" expands it.
    private let maximumVisibleRuns = 3
    @State private var isShowingAll = false

    private var scheduledItems: [WispScheduledItem] {
        let now = Date()
        let automationItems = automationEngine.nextRuns.map { upcomingRun in
            WispScheduledItem(
                id: "automation-\(upcomingRun.automationID.uuidString)",
                source: .automation,
                title: upcomingRun.automationName,
                buddyID: upcomingRun.buddyID,
                nextRun: upcomingRun.date
            )
        }
        let buddyItems: [WispScheduledItem] = buddyStore.buddies.compactMap { buddy in
            guard buddy.schedule.isRepeating, let nextRun = buddy.nextScheduledRunAt else { return nil }
            return WispScheduledItem(
                id: "buddy-\(buddy.id.uuidString)", source: .buddy, title: buddy.name, buddyID: buddy.id, nextRun: nextRun
            )
        }
        let workflowItems: [WispScheduledItem] = workflowStore.workflows.compactMap { workflow in
            guard workflow.isScheduled == true else { return nil }
            let nextRun = workflow.graph.nodes
                .filter { $0.kind == .trigger && $0.text("trigger") == WorkflowTriggerType.schedule.rawValue }
                .compactMap { WispScheduledPolicy.nextDailyRun(timeText: $0.text("time"), after: now) }
                .min()
            guard let nextRun else { return nil }
            return WispScheduledItem(
                id: "workflow-\(workflow.id.uuidString)", source: .workflow, title: workflow.title, buddyID: nil, nextRun: nextRun
            )
        }
        return WispScheduledPolicy.merged(
            automationItems: automationItems,
            buddyItems: buddyItems,
            workflowItems: workflowItems,
            buddyIDsOwnedByAutomations: buddyStore.buddyIDsWhoseSchedulesAreOwnedByAutomations
        )
    }

    var body: some View {
        WispBentoTile(
            title: "Next up",
            symbolName: "clock",
            isLive: !automationEngine.runningAutomationIDs.isEmpty,
            action: { WispWindowNavigator.open(.automations) }
        ) {
            let items = scheduledItems
            if items.isEmpty {
                emptyContent
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if isShowingAll {
                        ForEach(WispScheduledPolicy.grouped(items, now: Date()), id: \.day) { group in
                            Text(group.day.title)
                                .font(WispFont.caption)
                                .foregroundStyle(WispColor.textTertiary)
                            ForEach(group.items) { scheduledRow($0) }
                        }
                    } else {
                        ForEach(items.prefix(maximumVisibleRuns)) { scheduledRow($0) }
                    }
                    if items.count > maximumVisibleRuns {
                        Button(isShowingAll ? "Show less" : "Show all \(items.count)") {
                            withAnimation(WispMotion.island) { isShowingAll.toggle() }
                        }
                        .buttonStyle(.plain)
                        .font(WispFont.caption)
                        .foregroundStyle(WispColor.accentText)
                        .pointerCursor()
                    }
                }
            }
        }
    }

    private var emptyContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nothing scheduled")
                .font(WispFont.bodyMedium)
                .foregroundStyle(WispColor.textPrimary)
            Text("Add one from Automations.")
                .font(WispFont.callout)
                .foregroundStyle(WispColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func scheduledRow(_ scheduledItem: WispScheduledItem) -> some View {
        HStack(spacing: 10) {
            ownerFace(for: scheduledItem)
            VStack(alignment: .leading, spacing: 1) {
                Text(scheduledItem.title)
                    .font(WispFont.bodyMedium)
                    .foregroundStyle(WispColor.textPrimary)
                    .lineLimit(1)
                Text(AutomationDisplayText.whenText(scheduledItem.nextRun))
                    .font(WispFont.caption)
                    .foregroundStyle(WispColor.textSecondary)
            }
            Spacer(minLength: 0)
            if scheduledItem.source == .automation,
               let automationID = UUID(uuidString: scheduledItem.id.replacingOccurrences(of: "automation-", with: "")),
               automationEngine.runningAutomationIDs.contains(automationID) {
                ProgressView().controlSize(.mini)
            }
        }
    }

    @ViewBuilder
    private func ownerFace(for scheduledItem: WispScheduledItem) -> some View {
        if let buddyID = scheduledItem.buddyID, let buddy = buddyStore.buddy(withID: buddyID) {
            BuddyAvatar(colorIndex: buddy.colorIndex, size: 24)
        } else {
            Image(systemName: scheduledItem.source == .workflow ? "point.3.connected.trianglepath.dotted" : "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WispColor.accentText)
                .frame(width: 24, height: 24)
        }
    }
}
