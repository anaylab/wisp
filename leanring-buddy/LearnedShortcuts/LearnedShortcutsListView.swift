//
//  LearnedShortcutsListView.swift
//  leanring-buddy
//
//  Settings → Agent → Learned shortcuts: each saved shortcut with its phrase, an on/off switch,
//  how often it has run, why it was turned off, the exact steps (folded away until asked for)
//  and Delete. Delete is confirmed inline: this tab can also be shown in the notch, which can't
//  host a sheet.
//

import SwiftUI

struct LearnedShortcutsListView: View {
    @ObservedObject var learnedShortcutStore: LearnedShortcutStore

    @State private var expandedShortcutID: UUID?
    @State private var shortcutIDPendingDelete: UUID?
    @State private var shortcutIDBeingPromoted: UUID?
    @State private var promotionRunsDaily = false
    @State private var promotionTime = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var promotionMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(LearnedShortcutDisplay.listOrder(learnedShortcutStore.shortcuts)) { shortcut in
                shortcutRow(shortcut)
                if shortcut.id != LearnedShortcutDisplay.listOrder(learnedShortcutStore.shortcuts).last?.id {
                    Divider().padding(.vertical, 8)
                }
            }
        }
    }

    private func shortcutRow(_ shortcut: LearnedShortcut) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(shortcut.phraseTemplate)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(shortcut.isEnabled ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TimelineView(.everyMinute) { timeline in
                        Text(LearnedShortcutDisplay.runSummary(for: shortcut, now: timeline.date))
                            .font(.system(size: 11))
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                    if let attentionLine = LearnedShortcutDisplay.attentionLine(for: shortcut) {
                        Text(attentionLine)
                            .font(.system(size: 11))
                            .foregroundStyle(DS.Colors.warningText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(
                    get: { shortcut.isEnabled },
                    set: { learnedShortcutStore.setEnabled($0, shortcutID: shortcut.id) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .pointerCursor()
                .accessibilityLabel("Use shortcut \(shortcut.phraseTemplate)")
            }

            if expandedShortcutID == shortcut.id {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(LearnedShortcutDisplay.stepLines(for: shortcut).enumerated()), id: \.offset) { _, stepLine in
                        Text(stepLine)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 2)
            }

            if shortcutIDBeingPromoted == shortcut.id {
                promotionControls(for: shortcut)
            } else if shortcutIDPendingDelete == shortcut.id {
                deleteConfirmation(for: shortcut)
            } else {
                HStack(spacing: 14) {
                    Button(expandedShortcutID == shortcut.id ? "Hide steps" : "Show steps") {
                        expandedShortcutID = expandedShortcutID == shortcut.id ? nil : shortcut.id
                    }
                    Button("Make automation…") {
                        promotionMessage = nil
                        promotionRunsDaily = false
                        shortcutIDBeingPromoted = shortcut.id
                    }
                    Button("Delete") { shortcutIDPendingDelete = shortcut.id }
                        .foregroundStyle(DS.Colors.destructiveText)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.Colors.textSecondary)
                .pointerCursor()
            }
        }
    }

    private func deleteConfirmation(for shortcut: LearnedShortcut) -> some View {
        HStack(spacing: 10) {
            Text("Delete this shortcut?")
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.textPrimary)
            Button("Delete") {
                learnedShortcutStore.delete(shortcutID: shortcut.id)
                shortcutIDPendingDelete = nil
                if expandedShortcutID == shortcut.id { expandedShortcutID = nil }
            }
            .foregroundStyle(DS.Colors.destructiveText)
            Button("Keep") { shortcutIDPendingDelete = nil }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .pointerCursor()
    }

    // MARK: - Make automation

    private func promotionTrigger() -> AutomationTrigger {
        guard promotionRunsDaily else { return .manual }
        let timeComponents = Calendar.current.dateComponents([.hour, .minute], from: promotionTime)
        return .schedule(AutomationSchedule(recurrence: .daily, hour: timeComponents.hour ?? 8, minute: timeComponents.minute ?? 0))
    }

    /// A scheduled or event automation runs with nobody there, so a shortcut with a step that asks
    /// for your OK can only become a button; the reason is shown instead of a disabled control.
    private func promotionControls(for shortcut: LearnedShortcut) -> some View {
        let promotionVerdict = LearnedShortcutPromotion.verdict(
            for: shortcut,
            trigger: promotionTrigger(),
            toolRequiresConfirmation: { LearnedShortcutToolLookup.requiresConfirmationIfRegistered($0) }
        )
        return VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $promotionRunsDaily) {
                Text("Button").tag(false)
                Text("Every day").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 200)

            if promotionRunsDaily {
                DatePicker("", selection: $promotionTime, displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
            Text("Runs with the values it was saved with.")
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.textSecondary)
            if case .refused(let reason) = promotionVerdict {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let promotionMessage {
                Text(promotionMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textPrimary)
            }

            HStack(spacing: 14) {
                Button("Create") { createAutomation(from: shortcut) }
                    .disabled(promotionVerdict != .allowed)
                Button("Cancel") { shortcutIDBeingPromoted = nil }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .pointerCursor()
        }
    }

    private func createAutomation(from shortcut: LearnedShortcut) {
        let trigger = promotionTrigger()
        guard LearnedShortcutPromotion.verdict(
            for: shortcut,
            trigger: trigger,
            toolRequiresConfirmation: { LearnedShortcutToolLookup.requiresConfirmationIfRegistered($0) }
        ) == .allowed else { return }

        let automation = LearnedShortcutPromotion.automation(from: shortcut, trigger: trigger, now: Date())
        guard automation.isValid else {
            promotionMessage = automation.validationProblems().joined(separator: " ")
            return
        }
        AutomationStore.shared.add(automation)
        shortcutIDBeingPromoted = nil
        WispWindowNavigator.open(.automations)
    }
}
