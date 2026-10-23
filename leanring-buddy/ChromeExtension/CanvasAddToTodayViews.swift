//
//  CanvasAddToTodayViews.swift
//  leanring-buddy
//
//  The Canvas page helper's two views (phase 10): the one-line "Add to today?"
//  chip in the notch when an assignment that isn't on today's checklist opens in
//  Chrome, and its switch in Settings → Agent → Chrome Tabs.
//
//  The chip sits on the island, so it uses `WispColor.Island` and the island
//  button style; the Settings row uses the window's tokens.
//

import SwiftUI

/// Draws nothing without an offer or a result, so the notch can place it unconditionally.
struct CanvasAddToTodayNotchChip: View {
    @ObservedObject private var canvasPageHelper = CanvasPageHelper.shared

    var body: some View {
        if let offer = canvasPageHelper.addToTodayOffer {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(WispColor.Island.accent)
                Text("Add “\(offer.canvasItem.title)” to today?")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(WispColor.Island.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Button("Add") {
                    canvasPageHelper.acceptOffer()
                }
                .font(.system(size: 11, weight: .semibold))
                .wispIslandButtonStyle(prominence: .prominent)
                .pointerCursor()
                .nativeTooltip("Put this assignment on today's checklist")
                Button("Not now") {
                    canvasPageHelper.dismissOffer()
                    NotificationCenter.default.post(name: .wispDismissPanel, object: nil)
                }
                .font(.system(size: 11, weight: .medium))
                .wispIslandButtonStyle(prominence: .subtle)
                .pointerCursor()
                .nativeTooltip("Wisp won't offer this assignment again")
            }
        } else if let resultText = canvasPageHelper.offerResultText {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(WispColor.Island.accent)
                Text(resultText)
                    .font(.system(size: 12))
                    .foregroundColor(WispColor.Island.textPrimary)
                    .lineLimit(2)
            }
        }
    }
}

/// The switch for the chip, one row in the Chrome Tabs card.
struct CanvasAddToTodaySettingsRow: View {
    @ObservedObject private var canvasPageHelper = CanvasPageHelper.shared
    @ObservedObject private var chromeExtensionBridge = ChromeExtensionBridge.shared

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Offer to add Canvas assignments to today")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Colors.textPrimary)
                Text(chromeExtensionBridge.hasCapability(.pagesRead)
                     ? "Once per assignment, when one opens that isn't on today's checklist."
                     : "Needs Read pages allowed in Chrome.")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $canvasPageHelper.offersAddToToday)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .pointerCursor()
                .accessibilityLabel("Offer to add Canvas assignments to today")
        }
    }
}
