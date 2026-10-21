//
//  BuddyAutomationsSection.swift
//  leanring-buddy
//
//  The buddy inspector's Automation tab: what this buddy does on its own, each with a pause
//  switch and Run now, and a menu to give it a new job. Editing and history live on the
//  Automations page; a row here opens the page at that automation.
//

import SwiftUI

struct BuddyAutomationsSection: View {
    let buddyID: UUID

    @ObservedObject private var automationStore = AutomationStore.shared
    @ObservedObject private var automationEngine = AutomationEngine.shared
    @ObservedObject private var runHistoryStore = AutomationRunHistoryStore.shared
    @ObservedObject private var router = WispWindowRouter.shared

    private var ownedAutomations: [Automation] {
        automationStore.automations(ownedByBuddyID: buddyID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Automations")
                    .font(WispFont.headline)
                    .foregroundStyle(WispColor.textPrimary)
                Spacer(minLength: 0)
                addMenu
            }

            if ownedAutomations.isEmpty {
                Text("Nothing runs on its own yet.")
                    .font(WispFont.callout)
                    .foregroundStyle(WispColor.textSecondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(ownedAutomations) { automation in
                        automationRow(automation)
                        if automation.id != ownedAutomations.last?.id {
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Add

    private var addMenu: some View {
        Menu {
            Button("Say it or build one…") {
                router.presentAutomationDraft(AutomationDraftSaving.blankDraft(buddyID: buddyID))
            }
            Divider()
            ForEach(AutomationTemplates.all) { template in
                Button(template.title) {
                    var draftFromTemplate = AutomationDraft(template: template, buddyID: buddyID)
                    draftFromTemplate.buddyID = buddyID
                    router.presentAutomationDraft(draftFromTemplate)
                }
            }
        } label: {
            Label("Add", systemImage: "plus")
                .font(WispFont.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .pointerCursor()
    }

    // MARK: - Rows

    private func automationRow(_ automation: Automation) -> some View {
        let isRunning = automationEngine.runningAutomationIDs.contains(automation.id)
        let latestOutcome = runHistoryStore.latestRecord(forAutomationID: automation.id)?.outcome
        let outcomeStyle = AutomationOutcomeStyle.style(for: latestOutcome)
        return HStack(spacing: 8) {
            Button {
                router.automationIDToOpen = automation.id
                WispWindowNavigator.open(.automations)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: automation.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(automation.isEnabled ? WispColor.accentText : WispColor.textTertiary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(automation.name)
                            .font(WispFont.bodyMedium)
                            .foregroundStyle(automation.isEnabled ? WispColor.textPrimary : WispColor.textTertiary)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            if latestOutcome?.needsAttention == true {
                                Image(systemName: outcomeStyle.symbolName)
                                    .font(.system(size: 9))
                                    .foregroundStyle(outcomeStyle.color)
                            }
                            Text(subtitle(for: automation))
                                .font(WispFont.caption)
                                .foregroundStyle(WispColor.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Button {
                Task { _ = await automationEngine.run(automationID: automation.id, reason: .manual, parameterValues: nil) }
            } label: {
                if isRunning {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                }
            }
            .buttonStyle(WispPillButtonStyle(isProminent: false))
            .controlSize(.mini)
            .disabled(isRunning)
            .pointerCursor(isEnabled: !isRunning)
            .help("Run now")
            .accessibilityLabel("Run \(automation.name) now")

            Toggle("", isOn: Binding(
                get: { automation.isEnabled },
                set: { isOn in automationEngine.setPaused(!isOn, forAutomationID: automation.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .pointerCursor()
            .accessibilityLabel("\(automation.name) enabled")
        }
        .padding(.vertical, 7)
    }

    private func subtitle(for automation: Automation) -> String {
        if !automation.isEnabled { return automation.pausedReason ?? "Paused" }
        if automationEngine.automationIDsWaitingForInternet.contains(automation.id) { return "Waiting for the internet" }
        if let failureText = failureText(for: automation) { return failureText }
        if case .schedule = automation.trigger, let nextRunAt = automation.nextRunAt {
            return "Next \(AutomationDisplayText.whenText(nextRunAt))"
        }
        return AutomationDisplayText.triggerSummary(automation.trigger)
    }

    private func failureText(for automation: Automation) -> String? {
        guard let outcome = runHistoryStore.latestRecord(forAutomationID: automation.id)?.outcome,
              outcome.needsAttention else { return nil }
        return AutomationDisplayText.outcomeText(outcome)
    }
}
