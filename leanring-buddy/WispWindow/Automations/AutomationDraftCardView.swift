//
//  AutomationDraftCardView.swift
//  leanring-buddy
//
//  The one editable card every setup path ends on: "say it", a template, "save as automation"
//  on a History answer, or editing an existing automation. Five chips (when, from, to, who,
//  tell me) each open a small editor; anything the parser had to guess is drawn in the
//  warning tint with its reason underneath, and clears the moment the user looks at it and
//  changes it. Test run shows what a run would produce and writes nothing. Nothing is saved
//  or switched on until Save.
//

import SwiftUI

struct AutomationDraftCardView: View {
    let onSave: (Automation) -> Void
    let onCancel: () -> Void
    /// Set when editing, so Save updates the same automation instead of adding a copy.
    let existingAutomationID: UUID?

    @State private var draft: AutomationDraft
    @State private var openChipField: AutomationDraftField?
    @State private var testResult: AutomationTestResult?
    @State private var isTesting = false

    @ObservedObject private var buddyStore = BuddyStore.shared

    init(
        draft: AutomationDraft,
        onSave: @escaping (Automation) -> Void,
        onCancel: @escaping () -> Void,
        existingAutomationID: UUID? = nil,
        initiallyOpenField: AutomationDraftField? = nil
    ) {
        _draft = State(initialValue: draft)
        _openChipField = State(initialValue: initiallyOpenField)
        self.onSave = onSave
        self.onCancel = onCancel
        self.existingAutomationID = existingAutomationID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            nameAndInstruction
            chipRow
            notesBlock
            cloudDataBlock
            if let testResult {
                testResultBlock(testResult)
            }
            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wispBentoSurface()
        .animation(WispMotion.smooth, value: testResult)
        .animation(WispMotion.smooth, value: draft.uncertainFields)
    }

    // MARK: - Name and instruction

    private var nameAndInstruction: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: draft.symbolName ?? AutomationSymbolPolicy.symbolName(
                    source: draft.source, action: draft.action, outputs: draft.outputs
                ))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(WispColor.accentText)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(WispColor.accentText.opacity(0.14)))

                TextField("Name it", text: nameBinding)
                    .textFieldStyle(.plain)
                    .font(WispFont.headline)
                    .foregroundStyle(WispColor.textPrimary)
            }

            if case .askBuddy(let instruction) = draft.action {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: instructionBinding(currentInstruction: instruction))
                        .font(WispFont.body)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 64, maxHeight: 120)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(WispColor.surface3.opacity(0.5)))
                    if instruction.isEmpty {
                        Text("What should it do? Use {blank|default} for a value you fill in when you run it.")
                            .font(WispFont.body)
                            .foregroundStyle(WispColor.textTertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }
            } else {
                Text(actionDescription)
                    .font(WispFont.callout)
                    .foregroundStyle(WispColor.textSecondary)
            }

            if case .startChromeFocus(let topic, let minutes) = draft.action {
                chromeFocusFields(topic: topic, minutes: minutes)
            }
            if draft.action == .proposeStudyBlocks {
                Toggle("Also focus Chrome during each block", isOn: Binding(
                    get: { draft.focusesChromeDuringStudyBlocks == true },
                    set: { draft.focusesChromeDuringStudyBlocks = $0; testResult = nil }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(WispFont.callout)
                .pointerCursor()
                .help("Collapses and mutes off-topic tabs while an approved study block runs, then puts them back.")
            }
        }
    }

    /// Topic and length for a Chrome focus automation. The topic decides which tabs stay in view.
    private func chromeFocusFields(topic: String, minutes: Int) -> some View {
        HStack(spacing: 10) {
            TextField("Topic (e.g. essay)", text: Binding(
                get: { topic },
                set: { draft.action = .startChromeFocus(topic: $0, minutes: minutes); testResult = nil }
            ))
            .textFieldStyle(.plain)
            .font(WispFont.body)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(WispColor.surface3.opacity(0.5)))

            Stepper(value: Binding(
                get: { minutes },
                set: { draft.action = .startChromeFocus(topic: topic, minutes: $0); testResult = nil }
            ), in: AutomationAction.chromeFocusMinutesRange, step: 5) {
                Text("\(minutes) min")
                    .font(WispFont.callout.monospacedDigit())
                    .foregroundStyle(WispColor.textSecondary)
            }
            .controlSize(.small)
            .pointerCursor()
        }
    }

    private var actionDescription: String {
        switch draft.action {
        case .syncCanvas: return "Checks your Canvas feed and keeps the Wisp calendar in step. No model involved."
        case .buildDailyChecklist: return "Builds today's tick-off list in Reminders. No model involved."
        case .proposeStudyBlocks: return "Finds free time for study blocks and asks before booking any."
        case .startChromeFocus: return "Collapses and mutes off-topic Chrome tabs for a while, then puts them back. Nothing is closed."
        case .askBuddy: return ""
        }
    }

    // MARK: - Chips

    private var chipRow: some View {
        AutomationChipFlowLayout {
            AutomationChipButton(
                fieldTitle: "When",
                valueText: AutomationDisplayText.triggerSummary(draft.trigger),
                symbolName: AutomationTriggerKind(trigger: draft.trigger).symbolName,
                isUncertain: draft.uncertainFields.contains(.trigger),
                isEditorOpen: openBinding(for: .trigger)
            ) {
                AutomationTriggerEditor(trigger: triggerBinding, isTimingManagedElsewhere: draft.action.isManagedByJobsEngine)
            }

            if case .askBuddy = draft.action {
                AutomationChipButton(
                    fieldTitle: "From",
                    valueText: AutomationDisplayText.sourceSummary(draft.source),
                    symbolName: AutomationDisplayText.sourceSymbolName(draft.source),
                    isUncertain: draft.uncertainFields.contains(.source),
                    isEditorOpen: openBinding(for: .source)
                ) {
                    AutomationSourceEditor(source: sourceBinding)
                }
            }

            AutomationChipButton(
                fieldTitle: "To",
                valueText: AutomationDisplayText.outputsSummary(draft.outputs),
                symbolName: "tray.and.arrow.down",
                isUncertain: draft.uncertainFields.contains(.output),
                isEditorOpen: openBinding(for: .output)
            ) {
                AutomationOutputEditor(outputs: outputsBinding)
            }

            AutomationChipButton(
                fieldTitle: "Who",
                valueText: ownerName,
                symbolName: "person.crop.circle",
                isUncertain: draft.uncertainFields.contains(.buddy),
                isEditorOpen: openBinding(for: .buddy)
            ) {
                AutomationBuddyEditor(buddyID: buddyBinding)
            }

            AutomationChipButton(
                fieldTitle: "Tell me",
                valueText: AutomationDisplayText.notifyTitle(draft.notify),
                symbolName: "bell",
                isUncertain: draft.uncertainFields.contains(.notify),
                isEditorOpen: openBinding(for: .notify)
            ) {
                AutomationNotifyEditor(notifyPolicy: notifyBinding)
            }
        }
    }

    private var ownerName: String {
        guard let buddyID = draft.buddyID, let buddy = buddyStore.buddy(withID: buddyID) else { return "Choose for me" }
        return buddy.name
    }

    // MARK: - Notes (why a chip is highlighted)

    @ViewBuilder
    private var notesBlock: some View {
        let highlightedNotes = AutomationDraftField.allCases.compactMap { field -> (AutomationDraftField, String)? in
            guard draft.uncertainFields.contains(field), let note = draft.notes[field] else { return nil }
            return (field, note)
        }
        if !highlightedNotes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(highlightedNotes, id: \.0) { _, note in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(WispColor.warningText)
                        Text(note)
                            .font(WispFont.callout)
                            .foregroundStyle(WispColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .transition(.opacity)
        }
    }

    // MARK: - "This leaves your Mac"

    /// Whether a private source would be read by a model that runs off this Mac. The engine
    /// refuses that unless the user said yes here, so the card asks plainly.
    private var sourceWouldLeaveThisMac: Bool {
        guard AutomationCloudPrivacy.readsPrivateDataForModel(source: draft.source, trigger: draft.trigger, action: draft.action) else { return false }
        let ownerBuddy = draft.buddyID.flatMap { buddyStore.buddy(withID: $0) }
        let ownerSendsDataOffMachine = ownerBuddy?.modelChoice?.sendsDataOffThisMachine
            ?? BuddyChatProviderSelection.current.sendsScreenshotsOffThisMachine
        return ownerSendsDataOffMachine
    }

    @ViewBuilder
    private var cloudDataBlock: some View {
        if sourceWouldLeaveThisMac {
            VStack(alignment: .leading, spacing: 6) {
                Label("This leaves your Mac", systemImage: "icloud.and.arrow.up")
                    .font(WispFont.bodyMedium)
                    .foregroundStyle(WispColor.warningText)
                Text("\(draft.source.isSensitiveForCloudModels ? AutomationDisplayText.sourceSummary(draft.source) : "What starts it, or the clipboard") would be sent to \(ownerName)'s cloud model each run.")
                    .font(WispFont.callout)
                    .foregroundStyle(WispColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Allow this", isOn: Binding(
                    get: { draft.acknowledgedSourceLeavesMac == true },
                    set: { draft.acknowledgedSourceLeavesMac = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .pointerCursor()
                if draft.acknowledgedSourceLeavesMac != true {
                    Text("Until you allow it, runs skip this source.")
                        .font(WispFont.caption)
                        .foregroundStyle(WispColor.textTertiary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WispColor.warning.opacity(0.10)))
        }
    }

    // MARK: - Test run

    @ViewBuilder
    private func testResultBlock(_ result: AutomationTestResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "flask")
                    .font(.system(size: 10, weight: .semibold))
                Text("Test run · nothing was written")
                    .font(WispFont.caption)
            }
            .foregroundStyle(WispColor.textTertiary)

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
                if !result.wouldWrite.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("A real run would also")
                            .font(WispFont.caption)
                            .foregroundStyle(WispColor.textTertiary)
                        ForEach(result.wouldWrite, id: \.self) { writeDescription in
                            Text("• \(writeDescription)")
                                .font(WispFont.callout)
                                .foregroundStyle(WispColor.textSecondary)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WispColor.surface3.opacity(0.5)))
        .transition(.opacity)
    }

    private func runTest() {
        let draftToTest = draft
        isTesting = true
        Task {
            let result = await AutomationEngine.shared.testRun(draftToTest)
            testResult = result
            isTesting = false
        }
    }

    // MARK: - Footer

    private var blockingProblems: [String] {
        var problems = draft.problemsBlockingSave()
        let hasUnresolvedGuess = draft.uncertainFields.contains(.trigger) || draft.uncertainFields.contains(.output)
        if problems.isEmpty && hasUnresolvedGuess {
            problems.append("Check the highlighted part first.")
        }
        return problems
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !blockingProblems.isEmpty {
                Text(blockingProblems.joined(separator: " "))
                    .font(WispFont.caption)
                    .foregroundStyle(WispColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button {
                    runTest()
                } label: {
                    HStack(spacing: 5) {
                        if isTesting {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "flask")
                        }
                        Text("Test run")
                    }
                }
                .buttonStyle(WispPillButtonStyle(isProminent: false))
                .controlSize(.small)
                .disabled(isTesting || !draft.problemsBlockingSave().isEmpty)
                .pointerCursor(isEnabled: !isTesting)

                Spacer(minLength: 0)

                Button("Cancel", action: onCancel)
                    .buttonStyle(WispPillButtonStyle(isProminent: false))
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                    .pointerCursor()

                Button(existingAutomationID == nil ? "Save" : "Save changes") {
                    onSave(draft.makeAutomation(id: existingAutomationID ?? UUID(), now: Date()))
                }
                .buttonStyle(WispPillButtonStyle())
                .controlSize(.small)
                .disabled(!draft.isReadyToSave)
                .pointerCursor(isEnabled: draft.isReadyToSave)
            }
        }
    }

    // MARK: - Bindings

    /// An edit means the user looked at the part, so it stops being a guess.
    private func markResolved(_ field: AutomationDraftField) {
        draft.uncertainFields.remove(field)
        draft.notes[field] = nil
        testResult = nil
    }

    private func openBinding(for field: AutomationDraftField) -> Binding<Bool> {
        Binding(
            get: { openChipField == field },
            set: { isOpen in openChipField = isOpen ? field : (openChipField == field ? nil : openChipField) }
        )
    }

    private var nameBinding: Binding<String> {
        Binding(get: { draft.name }, set: { draft.name = $0; markResolved(.name) })
    }

    private func instructionBinding(currentInstruction: String) -> Binding<String> {
        Binding(get: { currentInstruction }, set: { draft.action = .askBuddy(instruction: $0); testResult = nil })
    }

    private var triggerBinding: Binding<AutomationTrigger> {
        Binding(get: { draft.trigger }, set: { draft.trigger = $0; markResolved(.trigger) })
    }

    private var sourceBinding: Binding<AutomationSource> {
        Binding(get: { draft.source }, set: { draft.source = $0; markResolved(.source) })
    }

    private var outputsBinding: Binding<[AutomationOutput]> {
        Binding(get: { draft.outputs }, set: { draft.outputs = $0; markResolved(.output) })
    }

    private var buddyBinding: Binding<UUID?> {
        Binding(get: { draft.buddyID }, set: { draft.buddyID = $0; markResolved(.buddy) })
    }

    private var notifyBinding: Binding<AutomationNotifyPolicy> {
        Binding(get: { draft.notify }, set: { draft.notify = $0; markResolved(.notify) })
    }
}

extension AutomationAction {
    /// Canvas sync and the daily checklist keep their own timers in JobsEngine.
    var isManagedByJobsEngine: Bool {
        switch self {
        case .syncCanvas, .buildDailyChecklist: return true
        case .askBuddy, .proposeStudyBlocks, .startChromeFocus: return false
        }
    }
}
