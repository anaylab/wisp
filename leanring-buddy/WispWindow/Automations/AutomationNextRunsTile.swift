//
//  AutomationNextRunsTile.swift
//  leanring-buddy
//
//  Today's "Next up" tile: the soonest scheduled automations and when each runs. Tapping it
//  opens the Automations page. It only reads the engine's published `nextRuns`; it computes
//  nothing itself.
//

import SwiftUI

struct AutomationNextRunsTile: View {
    @ObservedObject private var automationEngine = AutomationEngine.shared
    @ObservedObject private var buddyStore = BuddyStore.shared

    /// The tile is small; the page has the full list.
    private let maximumVisibleRuns = 3

    var body: some View {
        WispBentoTile(
            title: "Next up",
            symbolName: "clock",
            isLive: !automationEngine.runningAutomationIDs.isEmpty,
            action: { WispWindowNavigator.open(.automations) }
        ) {
            if automationEngine.nextRuns.isEmpty {
                emptyContent
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(automationEngine.nextRuns.prefix(maximumVisibleRuns)) { upcomingRun in
                        upcomingRunRow(upcomingRun)
                    }
                    let hiddenRunCount = automationEngine.nextRuns.count - maximumVisibleRuns
                    if hiddenRunCount > 0 {
                        Text("+\(hiddenRunCount) more")
                            .font(WispFont.caption)
                            .foregroundStyle(WispColor.textTertiary)
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
            Text("Add one from the Automations page.")
                .font(WispFont.callout)
                .foregroundStyle(WispColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func upcomingRunRow(_ upcomingRun: AutomationEngine.UpcomingRun) -> some View {
        HStack(spacing: 10) {
            ownerFace(for: upcomingRun)
            VStack(alignment: .leading, spacing: 1) {
                Text(upcomingRun.automationName)
                    .font(WispFont.bodyMedium)
                    .foregroundStyle(WispColor.textPrimary)
                    .lineLimit(1)
                Text(AutomationDisplayText.whenText(upcomingRun.date))
                    .font(WispFont.caption)
                    .foregroundStyle(WispColor.textSecondary)
            }
            Spacer(minLength: 0)
            if automationEngine.runningAutomationIDs.contains(upcomingRun.automationID) {
                ProgressView().controlSize(.mini)
            }
        }
    }

    @ViewBuilder
    private func ownerFace(for upcomingRun: AutomationEngine.UpcomingRun) -> some View {
        if let buddyID = upcomingRun.buddyID, let buddy = buddyStore.buddy(withID: buddyID) {
            BuddyAvatar(colorIndex: buddy.colorIndex, size: 24)
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WispColor.accentText)
                .frame(width: 24, height: 24)
        }
    }
}
