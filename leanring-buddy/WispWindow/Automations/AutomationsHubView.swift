//
//  AutomationsHubView.swift
//  leanring-buddy
//
//  Everything about automations in one embeddable view: a "Say it" box, anything that needs
//  the user, the list (pause switch, Run now, history, edit), and the ready-made gallery.
//  `AutomationsPage` is this view as a page; the Buddies section embeds it directly.
//
//  Three ways in, one card out. Saying it, picking a template and "Save as automation" on a
//  History answer all end in `AutomationDraftCardView`, so there is a single place where an
//  automation is looked over and saved. Other parts of the app ask for the card through
//  `WispWindowRouter` (`pendingAutomationDraft`, `isNewAutomationRequested`,
//  `automationIDToOpen`); this view takes each request and clears it.
//

import SwiftUI

/// One open draft card. A new session id makes the card rebuild its state when a different
/// draft replaces the current one.
private struct AutomationDraftSession: Identifiable {
    let id = UUID()
    let draft: AutomationDraft
    let existingAutomationID: UUID?
    let initiallyOpenField: AutomationDraftField?
}

struct AutomationsHubView: View {
    @ObservedObject private var automationStore = AutomationStore.shared
    @ObservedObject private var automationEngine = AutomationEngine.shared
    @ObservedObject private var buddyStore = BuddyStore.shared
    @ObservedObject private var router = WispWindowRouter.shared

    @State private var sayItText = ""
    @State private var sayItMessage: String?
    /// What the user typed when it didn't read as an automation, kept so "make it manual" can use it.
    @State private var unparsedSayItText: String?
    @State private var draftSession: AutomationDraftSession?
    @State private var expandedAutomationID: UUID?
    @State private var isGalleryExpanded: Bool?
    @State private var automationIDPendingDeletion: UUID?

    @FocusState private var isSayItFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                sayItBox
                if let draftSession {
                    AutomationDraftCardView(
                        draft: draftSession.draft,
                        onSave: { savedAutomation in finishDraft(saving: savedAutomation) },
                        onCancel: { closeDraft() },
                        existingAutomationID: draftSession.existingAutomationID,
                        initiallyOpenField: draftSession.initiallyOpenField
                    )
                    .id(draftSession.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                }
                needsYouSection
                listSection
                gallerySection
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(WispColor.windowBackground)
        .animation(WispMotion.island, value: draftSession?.id)
        .onChange(of: router.pendingAutomationDraft, initial: true) { _, pendingDraft in
            guard let pendingDraft else { return }
            beginDraft(pendingDraft)
            router.pendingAutomationDraft = nil
        }
        .onChange(of: router.isNewAutomationRequested, initial: true) { _, isRequested in
            guard isRequested else { return }
            beginDraft(AutomationDraftSaving.blankDraft())
            router.isNewAutomationRequested = false
            isSayItFocused = false
        }
        .onChange(of: router.automationIDToOpen, initial: true) { _, automationIDToOpen in
            guard let automationIDToOpen else { return }
            expandedAutomationID = automationIDToOpen
            router.automationIDToOpen = nil
        }
        .confirmationDialog(
            "Delete this automation?",
            isPresented: Binding(
                get: { automationIDPendingDeletion != nil },
                set: { if !$0 { automationIDPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let automationID = automationIDPendingDeletion {
                    delete(automationID: automationID)
                }
                automationIDPendingDeletion = nil
            }
            Button("Keep it", role: .cancel) { automationIDPendingDeletion = nil }
        } message: {
            Text("Its history goes with it. Anything it already wrote to Reminders or Calendar stays.")
        }
    }

    // MARK: - Say it

    private var sayItBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WispColor.accentText)
                TextField(
                    "Say it: “every weekday at 8, tell me what's due”",
                    text: $sayItText,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(WispFont.body)
                .lineLimit(1...3)
                .focused($isSayItFocused)
                .onSubmit { handleSayIt() }
                .onChange(of: sayItText) { _, _ in
                    sayItMessage = nil
                    unparsedSayItText = nil
                }

                Button {
                    handleSayIt()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(WispPillButtonStyle())
                .controlSize(.small)
                .disabled(sayItText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .pointerCursor(isEnabled: !sayItText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Make automation")

                Button {
                    beginDraft(AutomationDraftSaving.blankDraft())
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(WispPillButtonStyle(isProminent: false))
                .controlSize(.small)
                .pointerCursor()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .wispBentoSurface()

            if let sayItMessage {
                HStack(spacing: 10) {
                    Text(sayItMessage)
                        .font(WispFont.callout)
                        .foregroundStyle(WispColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let unparsedSayItText {
                        Button("Make it a manual one") {
                            beginDraft(manualDraft(from: unparsedSayItText))
                            sayItText = ""
                        }
                        .buttonStyle(WispPillButtonStyle(isProminent: false))
                        .controlSize(.small)
                        .pointerCursor()
                    }
                }
                .padding(.leading, 4)
                .transition(.opacity)
            }
        }
    }

    private func handleSayIt() {
        let spokenText = sayItText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spokenText.isEmpty else { return }

        let buddyReferences = buddyStore.buddies.map {
            AutomationBuddyReference(id: $0.id, name: $0.name, specialty: $0.specialty)
        }
        let parseResult = AutomationDraftParser.parse(spokenText, now: Date(), calendar: .current, buddies: buddyReferences)

        switch parseResult {
        case .draft(let parsedDraft):
            beginDraft(parsedDraft)
            sayItText = ""
        case .needsChoice(let parsedDraft, let field, let question):
            beginDraft(parsedDraft, initiallyOpenField: field)
            sayItText = ""
            sayItMessage = question
        case .unsure(let parsedDraft):
            beginDraft(parsedDraft)
            sayItText = ""
            sayItMessage = "I wasn't sure about this one. Check each part before saving."
        case .notAnAutomation:
            sayItMessage = "That reads like a question. Say when it should happen too."
            unparsedSayItText = spokenText
        }
    }

    private func manualDraft(from spokenText: String) -> AutomationDraft {
        AutomationDraft(
            originalText: spokenText,
            name: AutomationDraftNaming.name(fromInstruction: spokenText),
            trigger: .manual,
            action: .askBuddy(instruction: spokenText),
            outputs: [.notchCard],
            notify: .always
        )
    }

    // MARK: - Drafts

    private func beginDraft(_ draft: AutomationDraft, existingAutomationID: UUID? = nil, initiallyOpenField: AutomationDraftField? = nil) {
        withAnimation(WispMotion.island) {
            draftSession = AutomationDraftSession(
                draft: draft,
                existingAutomationID: existingAutomationID,
                initiallyOpenField: initiallyOpenField
            )
        }
    }

    private func closeDraft() {
        withAnimation(WispMotion.island) { draftSession = nil }
    }

    private func finishDraft(saving automation: Automation) {
        let savedAutomation = AutomationDraftSaving.save(automation)
        sayItMessage = nil
        withAnimation(WispMotion.island) {
            draftSession = nil
            expandedAutomationID = savedAutomation.id
        }
    }

    private func delete(automationID: UUID) {
        AutomationRunHistoryStore.shared.clear(forAutomationID: automationID)
        automationStore.delete(automationID: automationID)
        if expandedAutomationID == automationID { expandedAutomationID = nil }
    }

    // MARK: - Needs you

    @ViewBuilder
    private var needsYouSection: some View {
        if !automationEngine.needsYou.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                AutomationSectionTitle(title: "Needs you")
                ForEach(automationEngine.needsYou) { attentionItem in
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(WispColor.warningText)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(WispColor.warning.opacity(0.16)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(attentionItem.title)
                                .font(WispFont.bodyMedium)
                                .foregroundStyle(WispColor.textPrimary)
                                .lineLimit(1)
                            Text(attentionItem.detail)
                                .font(WispFont.callout)
                                .foregroundStyle(WispColor.textSecondary)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        Button("Open") {
                            withAnimation(WispMotion.smooth) { expandedAutomationID = attentionItem.automationID }
                        }
                        .buttonStyle(WispPillButtonStyle(isProminent: false))
                        .controlSize(.small)
                        .pointerCursor()
                        Button {
                            automationEngine.dismissAttentionItem(id: attentionItem.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(WispColor.textTertiary)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .accessibilityLabel("Dismiss")
                    }
                    .padding(12)
                    .wispBentoSurface()
                }
            }
        }
    }

    // MARK: - List

    @ViewBuilder
    private var listSection: some View {
        if !automationStore.automations.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                AutomationSectionTitle(
                    title: "Your automations",
                    detail: "\(automationStore.automations.count)"
                )
                ForEach(automationStore.automations) { automation in
                    AutomationListRow(
                        automation: automation,
                        isExpanded: expandedAutomationID == automation.id,
                        onToggleExpanded: {
                            withAnimation(WispMotion.smooth) {
                                expandedAutomationID = expandedAutomationID == automation.id ? nil : automation.id
                            }
                        },
                        onEdit: {
                            beginDraft(AutomationDraft(from: automation), existingAutomationID: automation.id)
                        },
                        onDelete: { automationIDPendingDeletion = automation.id }
                    )
                }
            }
        }
    }

    // MARK: - Gallery

    private var isGalleryOpen: Bool {
        isGalleryExpanded ?? automationStore.automations.isEmpty
    }

    private var gallerySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(WispMotion.smooth) { isGalleryExpanded = !isGalleryOpen }
            } label: {
                HStack(spacing: 6) {
                    AutomationSectionTitle(title: "Ready-made", detail: "pick one, then look it over")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(WispColor.textTertiary)
                        .rotationEffect(.degrees(isGalleryOpen ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("Ready-made automations")
            .accessibilityValue(isGalleryOpen ? "Expanded" : "Collapsed")

            if isGalleryOpen {
                AutomationTemplateGallery { pickedTemplate in
                    beginDraft(AutomationDraftSaving.draft(for: pickedTemplate))
                }
                .transition(.opacity)
            }
        }
    }
}

// MARK: - Page

/// `WispPage.automations`: the hub as a page.
struct AutomationsPage: View {
    init() {}

    var body: some View {
        AutomationsHubView()
    }
}

// MARK: - Row

/// One automation in the list: owner face, name, when, last result, pause switch and Run now.
/// Expanding it shows the history and the Edit / Delete buttons.
private struct AutomationListRow: View {
    let automation: Automation
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @ObservedObject private var automationEngine = AutomationEngine.shared
    @ObservedObject private var runHistoryStore = AutomationRunHistoryStore.shared
    @ObservedObject private var buddyStore = BuddyStore.shared

    private var isRunning: Bool {
        automationEngine.runningAutomationIDs.contains(automation.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Divider().opacity(0.5)
                    detailLine
                    AutomationRunHistoryView(automationID: automation.id)
                    HStack(spacing: 8) {
                        Button("Edit", action: onEdit)
                            .buttonStyle(WispPillButtonStyle(isProminent: false))
                            .controlSize(.small)
                            .pointerCursor()
                        Button("Delete", action: onDelete)
                            .buttonStyle(WispPillButtonStyle.destructive)
                            .controlSize(.small)
                            .pointerCursor()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .transition(.opacity)
            }
        }
        .wispBentoSurface(isInteractive: false, isLive: isRunning)
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Button(action: onToggleExpanded) {
                HStack(spacing: 10) {
                    ownerFace
                    VStack(alignment: .leading, spacing: 2) {
                        Text(automation.name)
                            .font(WispFont.bodyMedium)
                            .foregroundStyle(automation.isEnabled ? WispColor.textPrimary : WispColor.textTertiary)
                            .lineLimit(1)
                        Text(statusLine)
                            .font(WispFont.caption)
                            .foregroundStyle(statusLineIsProblem ? WispColor.warningText : WispColor.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(WispColor.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("\(automation.name). \(statusLine)")
            .accessibilityHint(isExpanded ? "Collapses the details." : "Shows history and options.")

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
            .controlSize(.small)
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
            .controlSize(.small)
            .pointerCursor()
            .accessibilityLabel("\(automation.name) enabled")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var ownerFace: some View {
        if let buddyID = automation.buddyID, let buddy = buddyStore.buddy(withID: buddyID) {
            BuddyAvatar(
                colorIndex: buddy.colorIndex,
                size: 30,
                isWorking: automationEngine.activeBuddyIDs.contains(buddy.id) && isRunning
            )
        } else {
            Image(systemName: automation.symbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(WispColor.accentText)
                .frame(width: 30, height: 30)
                .background(Circle().fill(WispColor.accentText.opacity(0.14)))
        }
    }

    private var latestOutcome: AutomationRunOutcome? {
        runHistoryStore.latestRecord(forAutomationID: automation.id)?.outcome
    }

    private var statusLineIsProblem: Bool {
        if !automation.isEnabled { return automation.pausedReason != nil }
        return latestOutcome?.needsAttention == true
    }

    /// Paused (with Wisp's reason, if it paused it), or the last problem, or when it runs next,
    /// or just the trigger in words.
    private var statusLine: String {
        if !automation.isEnabled {
            if let pausedReason = automation.pausedReason { return pausedReason }
            return "Paused · \(AutomationDisplayText.triggerSummary(automation.trigger))"
        }
        if isRunning { return "Running…" }
        if automationEngine.automationIDsWaitingForInternet.contains(automation.id) {
            return "Waiting for the internet · runs when it's back"
        }
        if statusLineIsProblem { return AutomationDisplayText.outcomeText(latestOutcome) }
        if case .schedule = automation.trigger, let nextRunAt = automation.nextRunAt {
            return "\(AutomationDisplayText.triggerSummary(automation.trigger)) · next \(AutomationDisplayText.whenText(nextRunAt))"
        }
        return AutomationDisplayText.triggerSummary(automation.trigger)
    }

    /// What it reads and where the answer goes, shown once expanded.
    private var detailLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            if case .askBuddy(let instruction) = automation.action {
                Text(instruction)
                    .font(WispFont.callout)
                    .foregroundStyle(WispColor.textSecondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("From \(AutomationDisplayText.sourceSummary(automation.source)) · to \(AutomationDisplayText.outputsSummary(automation.outputs)) · tell me: \(AutomationDisplayText.notifyTitle(automation.notify).lowercased())")
                .font(WispFont.caption)
                .foregroundStyle(WispColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
