//
//  BuddyInspectorView.swift
//  leanring-buddy
//
//  The panel beside a buddy's chat, laid out like OpenBot's agent settings: an
//  overview with who the buddy is (name, role, mission), then grouped link rows
//  with a one-line summary each (Brain, Rules, Library) that open a page and
//  back again. Each page is the controls and the data, nothing else. It edits
//  the same stores the rest of the app reads.
//

import AppKit
import SwiftUI

enum BuddyInspectorPage: String, CaseIterable, Identifiable {
    case identity
    case automation
    case tools
    case memory
    case files
    case usage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .identity: return "Look & personality"
        case .automation: return "Automation"
        case .tools: return "Tools"
        case .memory: return "Memory"
        case .files: return "Files"
        case .usage: return "Usage"
        }
    }

    var symbolName: String {
        switch self {
        case .identity: return "paintpalette"
        case .automation: return "clock"
        case .tools: return "wrench.and.screwdriver"
        case .memory: return "brain"
        case .files: return "folder"
        case .usage: return "chart.bar"
        }
    }
}

struct BuddyInspectorView: View {
    let buddyID: UUID
    var onRequestClearConversation: () -> Void
    var onRequestDeletion: () -> Void

    @ObservedObject private var buddyStore = BuddyStore.shared
    @ObservedObject private var advancedFeatures = WispAdvancedFeaturesPreference.shared
    @ObservedObject private var taskRegistry = AgentTaskRegistry.shared
    @ObservedObject private var memoryStore = BuddyMemoryStore.shared
    @ObservedObject private var fileLibrary = BuddyFileLibrary.shared
    @ObservedObject private var usageLog = UsageLogStore.shared

    /// Nil is the overview; a page replaces it with a Back button above.
    @State private var openPage: BuddyInspectorPage?
    @State private var editedName = ""
    @State private var editedInstruction = ""
    @State private var justSavedTemplate = false
    @State private var isAddingMemory = false
    @State private var newMemoryText = ""

    var body: some View {
        if let buddy = buddyStore.buddy(withID: buddyID) {
            VStack(spacing: 0) {
                if let openPage {
                    pageBar(for: openPage, buddy: buddy)
                    Rectangle().fill(WispColor.cardSeparator.opacity(0.5)).frame(height: 0.5)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let openPage {
                            pageContent(openPage, for: buddy)
                        } else {
                            overview(for: buddy)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(openPage?.rawValue ?? "overview")
                    .transition(.opacity)
                }
                .animation(WispMotion.smooth, value: openPage)
            }
            .background(WispColor.groupedCardBackground.opacity(0.5))
            .onAppear { loadDrafts(from: buddy) }
            .onChange(of: buddyID) { _, _ in
                openPage = nil
                justSavedTemplate = false
                if let newBuddy = buddyStore.buddy(withID: buddyID) { loadDrafts(from: newBuddy) }
            }
        }
    }

    private func loadDrafts(from buddy: WispBuddy) {
        editedName = buddy.name
        editedInstruction = buddy.instruction
    }

    // MARK: - Overview

    private func overview(for buddy: WispBuddy) -> some View {
        let mood = buddyStore.mood(of: buddy, in: taskRegistry)
        let roleTitle = (buddy.specialty ?? .general).title
        let usageTotals = thirtyDayUsage(for: buddy)
        let runCount = buddyStore.runRecords(of: buddy, in: taskRegistry).count
        return VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                BuddyCharacter(colorIndex: buddy.colorIndex, size: 46, mood: mood, liveliness: .working, bounceTrigger: 0, looksAtPointer: true)
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Name", text: $editedName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .semibold))
                        .onSubmit { buddyStore.rename(buddyWithID: buddy.id, to: editedName) }
                    Text(roleTitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(WispColor.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule(style: .continuous).fill(WispColor.surface3.opacity(0.8)))
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                header("Mission")
                TextField("What should it do?", text: $editedInstruction, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...6)
                if editedInstruction != buddy.instruction && !editedInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Save") { buddyStore.updateInstruction(ofBuddyWithID: buddy.id, to: editedInstruction) }
                        .buttonStyle(BuddyPillButtonStyle(colorIndex: buddy.colorIndex)).pointerCursor()
                        .transition(.opacity)
                }
            }
            .animation(WispMotion.quick, value: editedInstruction == buddy.instruction)

            linkGroup("Brain") {
                linkRow(.identity, value: "\((buddy.personality ?? .coach).title) · \(roleTitle)")
                if advancedFeatures.isEnabled {
                    modelRow(for: buddy)
                }
            }

            linkGroup("Knows") {
                linkRow(.memory, value: countText(memoryStore.facts(ofBuddyWithID: buddy.id).count, "note"))
                linkRow(.files, value: countText(fileLibrary.attachments(ofBuddyWithID: buddy.id).count, "file"))
                linkRow(.tools, value: BuddyToolAccessPolicy.summary(of: buddy.toolAccess))
            }

            linkGroup("Does") {
                linkRow(.automation, value: buddy.schedule.isRepeating
                    ? BuddyFormatting.nextRunPhrase(for: buddy).capitalizedFirst : "On request")
                linkRow(.usage, value: usageTotals.turnCount == 0
                    ? "\(runCount == 0 ? "No runs yet" : "No usage logged")" : usageSummaryText(usageTotals))
                BuddyInspectorLinkRow(
                    symbolName: justSavedTemplate ? "checkmark" : "square.on.square.dashed",
                    title: justSavedTemplate ? "Saved as template" : "Save as template",
                    value: ""
                ) {
                    BuddyTemplateStore.shared.save(buddy: buddy)
                    withAnimation(WispMotion.quick) { justSavedTemplate = true }
                }
                .nativeTooltip("Keeps its job, role, tone, schedule and limits — not its conversation, notes or files — in New buddy → Templates")
            }

            linkGroup("Rules") {
                BuddyInspectorToggleRow(
                    symbolName: "bell",
                    title: "Notify me",
                    isOn: Binding(
                        get: { buddy.postsNotificationWhenFinished },
                        set: { buddyStore.setNotifiesWhenFinished(buddyWithID: buddy.id, notifiesWhenFinished: $0) }
                    ),
                    tint: BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex)
                )
            }

            // Stacked, not side by side: the panel is narrow and a wrapped label looks broken.
            VStack(alignment: .leading, spacing: 8) {
                if advancedFeatures.isEnabled {
                    Button { WispShareImporter.exportBuddy(buddy) } label: {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(BuddyPillButtonStyle(colorIndex: buddy.colorIndex, isProminent: false)).pointerCursor().fixedSize()
                    .nativeTooltip("Saves its job, model and tool limits as a file — not its conversation, notes or files")
                }
                Button("Clear conversation…", action: onRequestClearConversation)
                    .buttonStyle(BuddyPillButtonStyle(colorIndex: buddy.colorIndex, isProminent: false)).pointerCursor().fixedSize()
                Button("Delete…", action: onRequestDeletion)
                    .buttonStyle(BuddyPillButtonStyle(colorIndex: buddy.colorIndex, isProminent: false)).pointerCursor().fixedSize()
            }
        }
    }

    private func linkGroup<Rows: View>(_ title: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header(title)
            VStack(spacing: 0) { rows() }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WispColor.surface3.opacity(0.55)))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    /// One row that opens a page: its icon and name, a one-line summary, a chevron.
    private func linkRow(_ page: BuddyInspectorPage, value: String) -> some View {
        BuddyInspectorLinkRow(symbolName: page.symbolName, title: page.title, value: value) {
            withAnimation(WispMotion.smooth) { openPage = page }
        }
    }

    /// The model is chosen on the Look & personality page, so this row only reads it.
    private func modelRow(for buddy: WispBuddy) -> some View {
        BuddyInspectorLinkRow(symbolName: "cpu", title: "Model", value: buddy.runsOnLabel ?? "Follows Wisp") {
            withAnimation(WispMotion.smooth) { openPage = .identity }
        }
    }

    private func countText(_ count: Int, _ noun: String) -> String {
        count == 0 ? "None" : "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    // MARK: - Usage

    private func thirtyDayUsage(for buddy: WispBuddy) -> UsageTotals {
        let summary = UsageAggregator.summary(
            of: UsageAggregator.records(usageLog.records, ofBuddyWithID: buddy.id), now: Date())
        return summary.lastThirtyDays
    }

    private func usageSummaryText(_ totals: UsageTotals) -> String {
        let tokens = UsageAggregator.formattedTokenCount(totals.totalTokens)
        return totals.estimatedCostUSD > 0
            ? "\(tokens) tokens · ≈ " + String(format: "$%.2f", totals.estimatedCostUSD)
            : "\(tokens) tokens"
    }

    private func usagePage(for buddy: WispBuddy) -> some View {
        let summary = UsageAggregator.summary(
            of: UsageAggregator.records(usageLog.records, ofBuddyWithID: buddy.id), now: Date())
        let periods: [(String, UsageTotals)] = [
            ("Today", summary.today), ("Last 7 days", summary.lastSevenDays), ("Last 30 days", summary.lastThirtyDays),
        ]
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(periods, id: \.0) { period in
                VStack(alignment: .leading, spacing: 6) {
                    header(period.0)
                    row("Runs", value: "\(period.1.turnCount)")
                    row("Tokens", value: UsageAggregator.formattedTokenCount(period.1.totalTokens))
                    row("Estimated cost", value: period.1.estimatedCostUSD > 0
                        ? String(format: "≈ $%.2f", period.1.estimatedCostUSD) : "—")
                }
            }
            Text("Estimates from the model's price list; a local model costs nothing.")
                .font(.system(size: 11.5)).foregroundStyle(WispColor.textTertiary)
        }
    }

    // MARK: - Pages

    private func pageBar(for page: BuddyInspectorPage, buddy: WispBuddy) -> some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(WispMotion.smooth) { openPage = nil }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("Settings").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(WispColor.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("Back to settings")
            Spacer()
            Text(page.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex))
            Spacer()
            // Balances the Back button so the title stays centred.
            Color.clear.frame(width: 64, height: 1)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    @ViewBuilder
    private func pageContent(_ page: BuddyInspectorPage, for buddy: WispBuddy) -> some View {
        switch page {
        case .identity: identityPage(for: buddy)
        case .automation: automationTab(for: buddy)
        case .tools: toolsTab(for: buddy)
        case .memory: memoryTab(for: buddy)
        case .files: filesTab(for: buddy)
        case .usage: usagePage(for: buddy)
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(WispColor.textSecondary)
    }

    private func row(_ title: String, value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 13)).foregroundStyle(WispColor.textSecondary)
            Spacer()
            Text(value).font(.system(size: 13, weight: .medium)).foregroundStyle(WispColor.textPrimary)
        }
    }

    // MARK: - Automation

    private func automationTab(for buddy: WispBuddy) -> some View {
        let isRunning = buddyStore.isRunning(buddy, in: taskRegistry)
        let runRecords = Array(buddyStore.runRecords(of: buddy, in: taskRegistry).suffix(6).reversed())
        // Once an Automation owns this buddy's job, the old schedule editor would edit a
        // schedule nothing reads any more, so it gives way to the automations list.
        let scheduleIsOwnedByAutomations = buddyStore.buddyIDsWhoseSchedulesAreOwnedByAutomations.contains(buddy.id)
        return VStack(alignment: .leading, spacing: 18) {
            BuddyAutomationsSection(buddyID: buddy.id)

            VStack(alignment: .leading, spacing: 10) {
                if !scheduleIsOwnedByAutomations {
                    row("Next run", value: buddy.schedule.isRepeating ? BuddyFormatting.nextRunPhrase(for: buddy).capitalizedFirst : "On request")
                    BuddyScheduleEditor(schedule: Binding(
                        get: { buddy.schedule },
                        set: { buddyStore.updateSchedule(ofBuddyWithID: buddy.id, to: $0) }
                    ))
                }
                Toggle(isOn: Binding(
                    get: { buddy.postsNotificationWhenFinished },
                    set: { buddyStore.setNotifiesWhenFinished(buddyWithID: buddy.id, notifiesWhenFinished: $0) }
                )) {
                    Text("Notify when finished").font(.system(size: 13))
                }
                .toggleStyle(.switch).controlSize(.small).tint(BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex))
                .pointerCursor()
            }

            if isRunning {
                Button { buddyStore.stopRun(ofBuddyWithID: buddy.id) } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(BuddyPillButtonStyle(colorIndex: buddy.colorIndex, isProminent: false)).pointerCursor()
            } else {
                Button { buddyStore.runNow(buddyWithID: buddy.id) } label: { Label("Run now", systemImage: "play.fill") }
                    .buttonStyle(BuddyPillButtonStyle(colorIndex: buddy.colorIndex)).pointerCursor()
            }

            if !runRecords.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    header("Recent runs")
                    ForEach(runRecords, id: \.id) { record in
                        HStack(spacing: 8) {
                            Circle().fill(runColor(record.status)).frame(width: 6, height: 6)
                            Text(runLabel(record.status)).font(.system(size: 12.5))
                            Spacer()
                            Text(BuddyFormatting.timeText(record.startedAt))
                                .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(WispColor.textTertiary)
                        }
                    }
                }
            }
        }
    }

    private func runColor(_ status: AgentTaskRecord.Status) -> Color {
        switch status {
        case .running, .waitingForApproval: return DS.Colors.warning
        case .succeeded: return DS.Colors.success
        case .failed: return DS.Colors.destructive
        case .cancelled, .interrupted: return WispColor.textTertiary
        }
    }

    private func runLabel(_ status: AgentTaskRecord.Status) -> String {
        switch status {
        case .running: return "Working"
        case .waitingForApproval: return "Needs your ok"
        case .succeeded: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Stopped"
        case .interrupted: return "Interrupted"
        }
    }

    // MARK: - Files

    private func filesTab(for buddy: WispBuddy) -> some View {
        let attachments = fileLibrary.attachments(ofBuddyWithID: buddy.id)
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                let openPanel = NSOpenPanel()
                openPanel.allowsMultipleSelection = true
                openPanel.canChooseDirectories = false
                guard openPanel.runModal() == .OK else { return }
                _ = fileLibrary.add(fileURLs: openPanel.urls, toBuddyWithID: buddy.id)
            } label: { Label("Add files", systemImage: "plus") }
                .buttonStyle(BuddyPillButtonStyle(colorIndex: buddy.colorIndex)).pointerCursor()

            if attachments.isEmpty {
                Text("Files you send in chat are kept here.")
                    .font(.system(size: 12.5)).foregroundStyle(WispColor.textTertiary)
            }
            ForEach(attachments) { attachment in
                HStack(spacing: 10) {
                    Image(systemName: attachment.kind == .image ? "photo" : "doc.text")
                        .font(.system(size: 15)).foregroundStyle(WispColor.textSecondary).frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(attachment.fileName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(BuddyFormatting.byteText(attachment.byteCount))
                            .font(.system(size: 11)).foregroundStyle(WispColor.textTertiary)
                    }
                    Spacer(minLength: 4)
                    BuddyIconButton(symbolName: "magnifyingglass", label: "Show in Finder", size: 24) {
                        NSWorkspace.shared.activateFileViewerSelecting([fileLibrary.fileURL(of: attachment, buddyID: buddy.id)])
                    }
                    BuddyIconButton(symbolName: "trash", label: "Remove", size: 24) {
                        withAnimation(WispMotion.smooth) { fileLibrary.remove(attachment, fromBuddyWithID: buddy.id) }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Memory

    private func memoryTab(for buddy: WispBuddy) -> some View {
        let notes = memoryStore.facts(ofBuddyWithID: buddy.id)
        return VStack(alignment: .leading, spacing: 12) {
            if notes.isEmpty && !isAddingMemory {
                // OpenBot's empty state: say what memory is for, and offer to add one.
                VStack(spacing: 6) {
                    Text("Tell it once.").font(.system(size: 17, weight: .semibold)).foregroundStyle(WispColor.textSecondary)
                    Text("It will remember.").font(.system(size: 17, weight: .semibold)).foregroundStyle(WispColor.textPrimary)
                    Text("\(buddy.name) saves what it learns in your chats. You can also add a memory yourself.")
                        .font(.system(size: 12)).foregroundStyle(WispColor.textTertiary).multilineTextAlignment(.center)
                        .padding(.top, 4)
                    Button("Add memory") { withAnimation(WispMotion.quick) { isAddingMemory = true } }
                        .buttonStyle(BuddyPillButtonStyle(colorIndex: buddy.colorIndex)).pointerCursor().padding(.top, 8)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                HStack {
                    header("\(notes.count) saved")
                    Spacer()
                    BuddyIconButton(symbolName: "plus", label: "Add memory", size: 24) {
                        withAnimation(WispMotion.quick) { isAddingMemory = true }
                    }
                }
                if isAddingMemory {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Something it should always remember", text: $newMemoryText, axis: .vertical)
                            .textFieldStyle(.roundedBorder).lineLimit(1...4)
                            .onSubmit { saveNewMemory(for: buddy) }
                        HStack(spacing: 8) {
                            Button("Save") { saveNewMemory(for: buddy) }
                                .buttonStyle(BuddyPillButtonStyle(colorIndex: buddy.colorIndex)).pointerCursor()
                                .disabled(newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("Cancel") { withAnimation(WispMotion.quick) { isAddingMemory = false; newMemoryText = "" } }
                                .buttonStyle(BuddyPillButtonStyle(colorIndex: buddy.colorIndex, isProminent: false)).pointerCursor()
                        }
                    }
                }
                ForEach(notes, id: \.self) { note in
                    HStack(alignment: .top, spacing: 8) {
                        Text(note).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        BuddyIconButton(symbolName: "trash", label: "Forget this", size: 22) {
                            withAnimation(WispMotion.smooth) { memoryStore.forgetExactFact(note, forBuddyWithID: buddy.id) }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func saveNewMemory(for buddy: WispBuddy) {
        let trimmed = newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = memoryStore.remember(trimmed, forBuddyWithID: buddy.id)
        withAnimation(WispMotion.quick) { isAddingMemory = false; newMemoryText = "" }
    }

    // MARK: - Tools

    private func toolsTab(for buddy: WispBuddy) -> some View {
        BuddyToolsView(
            toolAccess: Binding(
                get: { buddy.toolAccess },
                set: { buddyStore.updateToolAccess(ofBuddyWithID: buddy.id, to: $0) }
            ),
            modelSendsDataOffThisMachine: buddy.sendsDataOffThisMachine,
            colorIndex: buddy.colorIndex
        )
    }

    // MARK: - Look & personality

    private func identityPage(for buddy: WispBuddy) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                header("Colour")
                HStack(spacing: 9) {
                    ForEach(0..<BuddyAppearance.paletteCount, id: \.self) { colorIndex in
                        Button { buddyStore.updateColor(ofBuddyWithID: buddy.id, to: colorIndex) } label: {
                            Circle()
                                .fill(BuddyAppearance.lightColor(forColorIndex: colorIndex))
                                .frame(width: 20, height: 20)
                                .overlay(Circle().strokeBorder(WispColor.textPrimary.opacity(buddy.colorIndex == colorIndex ? 0.85 : 0), lineWidth: 1.5).padding(-3))
                        }
                        .buttonStyle(.plain).pointerCursor().accessibilityLabel("Colour \(colorIndex + 1)")
                    }
                }
                .animation(WispMotion.quick, value: buddy.colorIndex)
            }

            VStack(alignment: .leading, spacing: 8) {
                header("Specialty")
                Picker("Specialty", selection: Binding(
                    get: { buddy.specialty ?? .general },
                    set: { buddyStore.updateSpecialty(ofBuddyWithID: buddy.id, to: $0, appliesToolLimits: true) }
                )) {
                    ForEach(BuddySpecialty.allCases) { specialty in
                        Label(specialty.title, systemImage: specialty.symbolName).tag(specialty)
                    }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize().pointerCursor()
            }

            VStack(alignment: .leading, spacing: 8) {
                header("How it works")
                BuddyPersonalityPicker(selection: Binding(
                    get: { buddy.personality ?? .coach },
                    set: { buddyStore.updatePersonality(ofBuddyWithID: buddy.id, to: $0) }
                ))
            }

            VStack(alignment: .leading, spacing: 8) {
                header("Messages while it's busy")
                Picker("Messages while it's busy", selection: Binding(
                    get: { buddy.busyMode },
                    set: { buddyStore.updateBusyMessageMode(ofBuddyWithID: buddy.id, to: $0) }
                )) {
                    ForEach(BuddyBusyMessageMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize().pointerCursor()
                if buddy.busyMode == .steer {
                    Text("A message you send while it works is taken in at its next step. If it's already writing its answer, the message runs next instead.")
                        .font(.system(size: 11))
                        .foregroundStyle(WispColor.textTertiary)
                        .frame(minWidth: 280, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if advancedFeatures.isEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    header("Model")
                    BuddyModelEditor(modelChoice: Binding(
                        get: { buddy.modelChoice },
                        set: { buddyStore.updateModelChoice(ofBuddyWithID: buddy.id, to: $0) }
                    ))
                    BuddyRuntimeEditor(buddy: buddy)
                }
            }
        }
    }
}

/// A row in the settings overview with a switch.
private struct BuddyInspectorToggleRow: View {
    let symbolName: String
    let title: String
    @Binding var isOn: Bool
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbolName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(WispColor.textSecondary)
                .frame(width: 20)
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(WispColor.textPrimary)
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(tint)
                .pointerCursor()
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .accessibilityElement(children: .combine)
    }
}

/// A row in the settings overview that opens a page.
private struct BuddyInspectorLinkRow: View {
    let symbolName: String
    let title: String
    let value: String
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbolName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WispColor.textSecondary)
                    .frame(width: 20)
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(WispColor.textPrimary)
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 12))
                    .foregroundStyle(WispColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(WispColor.textTertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(WispColor.surface3.opacity(isHovering ? 0.6 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering = $0 }
        .animation(WispMotion.hover, value: isHovering)
        .accessibilityLabel("\(title), \(value)")
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
