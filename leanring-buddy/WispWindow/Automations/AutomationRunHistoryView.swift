//
//  AutomationRunHistoryView.swift
//  leanring-buddy
//
//  One automation's recent life: whether it is on, a Run now / Test run pair, the last result,
//  and a list of past runs with the plain-words reason when one failed. "Run now" is an
//  attended run (the normal confirmation rules apply); "Test run" reads for real and writes
//  nothing. History holds a capped result text for 30 days, never a prompt or a link.
//

import SwiftUI

struct AutomationRunHistoryView: View {
    let automationID: UUID

    @ObservedObject private var automationStore = AutomationStore.shared
    @ObservedObject private var runHistoryStore = AutomationRunHistoryStore.shared
    @ObservedObject private var automationEngine = AutomationEngine.shared

    @State private var testResult: AutomationTestResult?
    @State private var isTesting = false
    @State private var isShowingFullLastResult = false

    /// The list shows the latest handful; the store keeps up to 30.
    private let maximumVisibleRecords = 8
    private let collapsedResultCharacterLimit = 360

    var body: some View {
        if let automation = automationStore.automation(withID: automationID) {
            VStack(alignment: .leading, spacing: 14) {
                controlsRow(for: automation)
                if let testResult {
                    testResultBlock(testResult)
                }
                lastResultBlock
                recordsList
            }
        } else {
            Text("This automation is gone.")
                .font(WispFont.callout)
                .foregroundStyle(WispColor.textSecondary)
        }
    }

    // MARK: - Controls

    private func controlsRow(for automation: Automation) -> some View {
        let isRunning = automationEngine.runningAutomationIDs.contains(automationID)
        return HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { automation.isEnabled },
                set: { isOn in automationEngine.setPaused(!isOn, forAutomationID: automationID) }
            )) {
                Text(automation.isEnabled ? "On" : "Paused")
                    .font(WispFont.bodyMedium)
                    .foregroundStyle(WispColor.textPrimary)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .pointerCursor()

            Spacer(minLength: 0)

            Button {
                runTest()
            } label: {
                HStack(spacing: 5) {
                    if isTesting { ProgressView().controlSize(.mini) } else { Image(systemName: "flask") }
                    Text("Test run")
                }
            }
            .buttonStyle(WispPillButtonStyle(isProminent: false))
            .controlSize(.small)
            .disabled(isTesting)
            .pointerCursor(isEnabled: !isTesting)

            Button {
                Task { _ = await automationEngine.run(automationID: automationID, reason: .manual, parameterValues: nil) }
            } label: {
                HStack(spacing: 5) {
                    if isRunning { ProgressView().controlSize(.mini) } else { Image(systemName: "play.fill") }
                    Text(isRunning ? "Running" : "Run now")
                }
            }
            .buttonStyle(WispPillButtonStyle())
            .controlSize(.small)
            .disabled(isRunning)
            .pointerCursor(isEnabled: !isRunning)
        }
    }

    private func runTest() {
        isTesting = true
        Task {
            let result = await automationEngine.testRun(automationID: automationID)
            testResult = result
            isTesting = false
        }
    }

    @ViewBuilder
    private func testResultBlock(_ result: AutomationTestResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Test run · nothing was written")
                    .font(WispFont.caption)
                    .foregroundStyle(WispColor.textTertiary)
                Spacer(minLength: 0)
                Button("Dismiss") { testResult = nil }
                    .buttonStyle(.plain)
                    .font(WispFont.caption)
                    .foregroundStyle(WispColor.accentText)
                    .pointerCursor()
            }
            if let problem = result.problem {
                Text(problem)
                    .font(WispFont.callout)
                    .foregroundStyle(WispColor.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(result.previewText)
                    .font(WispFont.body)
                    .foregroundStyle(WispColor.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(result.wouldWrite, id: \.self) { writeDescription in
                    Text("• \(writeDescription)")
                        .font(WispFont.callout)
                        .foregroundStyle(WispColor.textSecondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WispColor.surface3.opacity(0.5)))
    }

    // MARK: - Last result

    private var visibleRecords: [AutomationRunRecord] {
        Array(runHistoryStore.records(forAutomationID: automationID).filter { !$0.isTestRun }.prefix(maximumVisibleRecords))
    }

    @ViewBuilder
    private var lastResultBlock: some View {
        if let latestRecord = visibleRecords.first {
            let outcomeStyle = AutomationOutcomeStyle.style(for: latestRecord.outcome)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: outcomeStyle.symbolName)
                        .foregroundStyle(outcomeStyle.color)
                    Text("Last run · \(AutomationDisplayText.agoText(latestRecord.finishedAt ?? latestRecord.startedAt))")
                        .font(WispFont.bodyMedium)
                        .foregroundStyle(WispColor.textPrimary)
                }
                if let resultText = latestRecord.resultText, !resultText.isEmpty {
                    let needsTruncation = resultText.count > collapsedResultCharacterLimit
                    Text(isShowingFullLastResult || !needsTruncation
                         ? resultText
                         : String(resultText.prefix(collapsedResultCharacterLimit)) + "…")
                        .font(WispFont.callout)
                        .foregroundStyle(WispColor.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if needsTruncation {
                        Button(isShowingFullLastResult ? "Show less" : "Show more") {
                            withAnimation(WispMotion.smooth) { isShowingFullLastResult.toggle() }
                        }
                        .buttonStyle(.plain)
                        .font(WispFont.caption)
                        .foregroundStyle(WispColor.accentText)
                        .pointerCursor()
                    }
                } else {
                    Text(AutomationDisplayText.outcomeText(latestRecord.outcome))
                        .font(WispFont.callout)
                        .foregroundStyle(latestRecord.outcome?.needsAttention == true ? WispColor.warningText : WispColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            Text("It hasn't run yet.")
                .font(WispFont.callout)
                .foregroundStyle(WispColor.textSecondary)
        }
    }

    // MARK: - Past runs

    @ViewBuilder
    private var recordsList: some View {
        let records = visibleRecords
        if records.count > 1 || (records.count == 1 && records[0].outcome?.needsAttention == true) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("History")
                        .font(WispFont.caption)
                        .foregroundStyle(WispColor.textTertiary)
                    Spacer(minLength: 0)
                    Button("Clear") {
                        runHistoryStore.clear(forAutomationID: automationID)
                    }
                    .buttonStyle(.plain)
                    .font(WispFont.caption)
                    .foregroundStyle(WispColor.accentText)
                    .pointerCursor()
                }
                .padding(.bottom, 4)
                ForEach(records) { record in
                    recordRow(record)
                    if record.id != records.last?.id {
                        Divider().opacity(0.5)
                    }
                }
            }
        }
    }

    private func recordRow(_ record: AutomationRunRecord) -> some View {
        let outcomeStyle = AutomationOutcomeStyle.style(for: record.outcome)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: outcomeStyle.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(outcomeStyle.color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(AutomationDisplayText.reasonTitle(record.reason)) · \(AutomationDisplayText.agoText(record.startedAt))")
                    .font(WispFont.caption)
                    .foregroundStyle(WispColor.textTertiary)
                Text(AutomationDisplayText.outcomeText(record.outcome))
                    .font(WispFont.callout)
                    .foregroundStyle(record.outcome?.needsAttention == true ? WispColor.warningText : WispColor.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if record.backgroundTaskID != nil {
                Button("History") { WispWindowNavigator.open(.timeline) }
                    .buttonStyle(.plain)
                    .font(WispFont.caption)
                    .foregroundStyle(WispColor.accentText)
                    .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }
}
