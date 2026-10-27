//
//  FirstRunSetupFlow.swift
//  leanring-buddy
//
//  Four short steps, one screen each, every one skippable: pick a look, pick the Planner's work
//  style, optionally link Canvas, and switch on up to three ready-made automations. Shown once
//  over Today and reopenable from Settings -> General. Nothing runs and nothing is switched on
//  until the user taps; Skip leaves the step exactly as it was.
//

import SwiftUI

struct FirstRunSetupFlow: View {
    let onFinished: () -> Void

    init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
    }

    private enum SetupStep: Int, CaseIterable {
        case theme, personality, canvas, automations

        var title: String {
            switch self {
            case .theme: return "Pick a look"
            case .personality: return "How should your Planner work?"
            case .canvas: return "Connect Canvas"
            case .automations: return "Switch on a few automations"
            }
        }
    }

    /// The templates offered in the last step, in the order shown.
    private static let suggestedTemplateIDs: [AutomationTemplateID] = [.morningBrief, .dailyChecklist, .canvasDeadlines]

    @ObservedObject private var buddyStore = BuddyStore.shared
    @ObservedObject private var automationStore = AutomationStore.shared

    @State private var currentStep: SetupStep = .theme
    @State private var plannerPersonality: BuddyPersonality = .coach
    @State private var canvasFeedLinkText = ""
    @State private var canvasProblemMessage: String?
    @State private var isCanvasConnected = JobsEngine.shared.hasCanvasFeed
    @State private var templateIDsToSwitchOn: Set<AutomationTemplateID> = [.morningBrief, .dailyChecklist]
    @State private var hasPreparedCanvasSuggestion = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            progressDots

            Text(currentStep.title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(WispColor.textPrimary)

            stepContent
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
            footerButtons
        }
        .padding(28)
        .frame(width: 560, height: 520)
        .background(WispColor.windowBackground)
        .onAppear(perform: prepareFlow)
    }

    // MARK: - Steps

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .theme:
            ScrollView { WispThemePicker() }
        case .personality:
            VStack(alignment: .leading, spacing: 12) {
                BuddyPersonalityPicker(selection: $plannerPersonality)
            }
        case .canvas:
            canvasStepContent
        case .automations:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Self.suggestedTemplateIDs, id: \.self) { templateID in
                    templateRow(AutomationTemplates.template(withID: templateID))
                }
            }
        }
    }

    private var canvasStepContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isCanvasConnected {
                Label("Canvas is connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(WispColor.success)
            } else {
                Text("Paste your Canvas calendar feed link. It stays in your Keychain.")
                    .font(.callout)
                    .foregroundStyle(WispColor.textSecondary)
                // A secure field: the link is a secret, so it is never shown back on screen.
                SecureField("Calendar feed link", text: $canvasFeedLinkText)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background {
                        Color.clear.wispBevel(RoundedRectangle(cornerRadius: 10, style: .continuous), fill: WispColor.surface2)
                    }
                    .onSubmit(connectCanvas)
                if let canvasProblemMessage {
                    Text(canvasProblemMessage)
                        .font(.callout)
                        .foregroundStyle(WispColor.warningText)
                }
                Button("Connect", action: connectCanvas)
                    .buttonStyle(WispPillButtonStyle())
                    .disabled(canvasFeedLinkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .pointerCursor()
            }
        }
    }

    private func templateRow(_ template: AutomationTemplate) -> some View {
        let needsCanvas = template.id == .canvasDeadlines && !isCanvasConnected
        let isAlreadyThere = existingAutomation(matching: template) != nil
        return HStack(spacing: 12) {
            Image(systemName: template.symbolName)
                .frame(width: 22)
                .foregroundStyle(WispColor.accentText)
            VStack(alignment: .leading, spacing: 2) {
                Text(template.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(WispColor.textPrimary)
                Text(needsCanvas ? "Needs Canvas from the last step." : template.summary)
                    .font(.callout)
                    .foregroundStyle(WispColor.textSecondary)
            }
            Spacer(minLength: 0)
            Toggle(template.title, isOn: switchBinding(for: template.id))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(needsCanvas)
                .pointerCursor()
        }
        .padding(12)
        .background {
            Color.clear.wispBevel(RoundedRectangle(cornerRadius: 12, style: .continuous), fill: WispColor.surface2)
        }
        .opacity(isAlreadyThere ? 0.9 : 1)
    }

    private func switchBinding(for templateID: AutomationTemplateID) -> Binding<Bool> {
        Binding(
            get: { templateIDsToSwitchOn.contains(templateID) },
            set: { isOn in
                if isOn { templateIDsToSwitchOn.insert(templateID) } else { templateIDsToSwitchOn.remove(templateID) }
            }
        )
    }

    // MARK: - Chrome

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(SetupStep.allCases, id: \.rawValue) { setupStep in
                Capsule()
                    .fill(setupStep.rawValue <= currentStep.rawValue ? WispColor.accent : WispColor.surface3)
                    .frame(width: setupStep == currentStep ? 22 : 8, height: 6)
            }
        }
        .animation(WispMotion.quick, value: currentStep)
        .accessibilityLabel("Step \(currentStep.rawValue + 1) of \(SetupStep.allCases.count)")
    }

    private var footerButtons: some View {
        HStack {
            Button("Skip", action: skipCurrentStep)
                .buttonStyle(WispPillButtonStyle(isProminent: false))
                .pointerCursor()
            Spacer()
            Button(isLastStep ? "Finish" : "Continue", action: continueFromCurrentStep)
                .buttonStyle(WispPillButtonStyle())
                .keyboardShortcut(.defaultAction)
                .pointerCursor()
        }
    }

    private var isLastStep: Bool { currentStep == SetupStep.allCases.last }

    // MARK: - Actions

    private func prepareFlow() {
        // The starters are the owners of everything in steps 2 and 4, so they exist first.
        buddyStore.ensureStarterBuddies()
        if let plannerBuddy = buddyStore.buddy(withID: StarterBuddyDefinition.plannerBuddyID),
           let existingPersonality = plannerBuddy.personality {
            plannerPersonality = existingPersonality
        }
    }

    private func connectCanvas() {
        switch JobsEngine.shared.saveCanvasFeed(urlText: canvasFeedLinkText) {
        case .success:
            canvasFeedLinkText = ""
            canvasProblemMessage = nil
            isCanvasConnected = true
            if !hasPreparedCanvasSuggestion {
                templateIDsToSwitchOn.insert(.canvasDeadlines)
                hasPreparedCanvasSuggestion = true
            }
        case .failure(let validationError):
            // The error text never contains the link itself.
            canvasProblemMessage = validationError.errorDescription
        }
    }

    private func skipCurrentStep() {
        // Skipping the last step switches nothing on.
        if isLastStep {
            finishFlow(switchingOnTemplates: false)
        } else {
            advance()
        }
    }

    private func continueFromCurrentStep() {
        switch currentStep {
        case .personality:
            buddyStore.updatePersonality(ofBuddyWithID: StarterBuddyDefinition.plannerBuddyID, to: plannerPersonality)
            advance()
        case .canvas:
            if !canvasFeedLinkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isCanvasConnected {
                connectCanvas()
                // A bad link stays on this step so the message can be read.
                guard isCanvasConnected else { return }
            }
            advance()
        case .automations:
            finishFlow(switchingOnTemplates: true)
        case .theme:
            advance()
        }
    }

    private func advance() {
        guard let nextStep = SetupStep(rawValue: currentStep.rawValue + 1) else { return }
        withAnimation(WispMotion.smooth) { currentStep = nextStep }
    }

    private func finishFlow(switchingOnTemplates: Bool) {
        if switchingOnTemplates {
            for templateID in Self.suggestedTemplateIDs where templateIDsToSwitchOn.contains(templateID) {
                let template = AutomationTemplates.template(withID: templateID)
                if templateID == .canvasDeadlines && !isCanvasConnected { continue }
                switchOn(template)
            }
        }
        WispFirstRunState.shared.markCompleted()
        WispWindowRouter.shared.isFirstRunSetupRequested = false
        onFinished()
    }

    /// The existing automation that already does this template's job, if any. The Canvas sync and
    /// the daily checklist are driven by JobsEngine and migration may have created them already, so
    /// they are matched by action; the rest by name.
    private func existingAutomation(matching template: AutomationTemplate) -> Automation? {
        automationStore.automations.first { existingAutomation in
            switch template.action {
            case .syncCanvas, .buildDailyChecklist:
                return existingAutomation.action == template.action
            default:
                return existingAutomation.name == template.title
            }
        }
    }

    private func switchOn(_ template: AutomationTemplate) {
        if let alreadyThere = existingAutomation(matching: template) {
            automationStore.setEnabled(true, forAutomationID: alreadyThere.id)
            return
        }
        let starterBuddyID = StarterBuddyDefinition.definition(for: template.suggestedStarterBuddy).id
        let ownerBuddyID = buddyStore.buddy(withID: starterBuddyID) != nil ? starterBuddyID : nil
        var draftFromTemplate = AutomationDraft(template: template, buddyID: ownerBuddyID)
        // The Jobs-driven pair keep their old origin so the migration never makes a second copy.
        switch template.action {
        case .syncCanvas: draftFromTemplate.legacyOrigin = .jobsCanvas
        case .buildDailyChecklist: draftFromTemplate.legacyOrigin = .jobsDailyChecklist
        default: break
        }
        draftFromTemplate.isEnabled = true
        automationStore.add(draftFromTemplate.makeAutomation(id: UUID(), now: Date()))
    }
}

/// The Settings -> General row that reopens the setup.
struct FirstRunSetupAgainRow: View {
    var body: some View {
        SettingRow(title: "Setup", detail: "Look, work style, Canvas and first automations.") {
            Button("Run setup again") {
                WispFirstRunState.shared.reset()
            }
            .buttonStyle(WispPillButtonStyle(isProminent: false))
            .pointerCursor()
        }
    }
}
