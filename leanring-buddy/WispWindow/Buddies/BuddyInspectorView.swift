//
//  BuddyInspectorView.swift
//  leanring-buddy
//
//  The panel beside a buddy's chat: everything about the buddy that isn't the
//  conversation. Five icon tabs — Automation, Files, Memory, Tools, About — and
//  no explanatory prose; each tab is the controls and the data, nothing else.
//  It edits the same stores the rest of the app reads.
//

import AppKit
import SwiftUI

enum BuddyInspectorTab: String, CaseIterable, Identifiable {
    case automation
    case files
    case memory
    case tools
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automation: return "Automation"
        case .files: return "Files"
        case .memory: return "Memory"
        case .tools: return "Tools"
        case .about: return "About"
        }
    }

    var symbolName: String {
        switch self {
        case .automation: return "clock"
        case .files: return "folder"
        case .memory: return "brain"
        case .tools: return "wrench.and.screwdriver"
        case .about: return "person.crop.circle"
        }
    }
}

struct BuddyInspectorView: View {
    let buddyID: UUID
    var onRequestClearConversation: () -> Void
    var onRequestDeletion: () -> Void

    @ObservedObject private var buddyStore = BuddyStore.shared
    @ObservedObject private var taskRegistry = AgentTaskRegistry.shared
    @ObservedObject private var memoryStore = BuddyMemoryStore.shared
    @ObservedObject private var fileLibrary = BuddyFileLibrary.shared
    @AppStorage("BuddyInspectorSelectedTab") private var selectedTabRawValue = BuddyInspectorTab.automation.rawValue

    @State private var editedName = ""
    @State private var editedInstruction = ""

    private var selectedTab: BuddyInspectorTab { BuddyInspectorTab(rawValue: selectedTabRawValue) ?? .automation }

    var body: some View {
        if let buddy = buddyStore.buddy(withID: buddyID) {
            VStack(spacing: 0) {
                tabBar(for: buddy)
                Rectangle().fill(WispColor.cardSeparator.opacity(0.5)).frame(height: 0.5)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch selectedTab {
                        case .automation: automationTab(for: buddy)
                        case .files: filesTab(for: buddy)
                        case .memory: memoryTab(for: buddy)
                        case .tools: toolsTab(for: buddy)
                        case .about: aboutTab(for: buddy)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(selectedTab)
                    .transition(.opacity)
                }
                .animation(WispMotion.smooth, value: selectedTab)
            }
            .background(WispColor.groupedCardBackground.opacity(0.5))
            .onAppear { loadDrafts(from: buddy) }
            .onChange(of: buddyID) { _, _ in
                if let newBuddy = buddyStore.buddy(withID: buddyID) { loadDrafts(from: newBuddy) }
            }
        }
    }

    private func loadDrafts(from buddy: WispBuddy) {
        editedName = buddy.name
        editedInstruction = buddy.instruction
    }

    // MARK: - Pieces

    private func tabBar(for buddy: WispBuddy) -> some View {
        HStack(spacing: 2) {
            ForEach(BuddyInspectorTab.allCases) { tab in
                let isSelected = tab == selectedTab
                Button { selectedTabRawValue = tab.rawValue } label: {
                    Image(systemName: tab.symbolName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex) : WispColor.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background {
                            if isSelected {
                                Color.clear.buddyBevel(RoundedRectangle(cornerRadius: 8, style: .continuous), fill: WispColor.surface3)
                                    .transition(.opacity)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityLabel(tab.title)
                .nativeTooltip(tab.title)
            }
        }
        .padding(8)
        .animation(WispMotion.quick, value: selectedTab)
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
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                row("Next run", value: buddy.schedule.isRepeating ? BuddyFormatting.nextRunPhrase(for: buddy).capitalizedFirst : "On request")
                BuddyScheduleEditor(schedule: Binding(
                    get: { buddy.schedule },
                    set: { buddyStore.updateSchedule(ofBuddyWithID: buddy.id, to: $0) }
                ))
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
        return VStack(alignment: .leading, spacing: 10) {
            if notes.isEmpty {
                Text("Nothing saved yet.").font(.system(size: 12.5)).foregroundStyle(WispColor.textTertiary)
            }
            ForEach(notes, id: \.self) { note in
                HStack(alignment: .top, spacing: 8) {
                    Text(note).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    BuddyIconButton(symbolName: "xmark", label: "Forget this", size: 22) {
                        withAnimation(WispMotion.smooth) { memoryStore.forgetExactFact(note, forBuddyWithID: buddy.id) }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Tools

    private func toolsTab(for buddy: WispBuddy) -> some View {
        BuddyToolsView(
            toolAccess: Binding(
                get: { buddy.toolAccess },
                set: { buddyStore.updateToolAccess(ofBuddyWithID: buddy.id, to: $0) }
            ),
            modelSendsDataOffThisMachine: BuddyModelChoice.sendsDataOffThisMachine(buddy.modelChoice),
            colorIndex: buddy.colorIndex
        )
    }

    // MARK: - About

    private func aboutTab(for buddy: WispBuddy) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                header("Name")
                TextField("Name", text: $editedName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { buddyStore.rename(buddyWithID: buddy.id, to: editedName) }
            }

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
                header("Model")
                BuddyModelEditor(modelChoice: Binding(
                    get: { buddy.modelChoice },
                    set: { buddyStore.updateModelChoice(ofBuddyWithID: buddy.id, to: $0) }
                ))
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

            HStack(spacing: 8) {
                Button("Clear conversation…", action: onRequestClearConversation)
                    .buttonStyle(BuddyPillButtonStyle(colorIndex: buddy.colorIndex, isProminent: false)).pointerCursor()
                Button("Delete…", action: onRequestDeletion)
                    .buttonStyle(BuddyPillButtonStyle(colorIndex: buddy.colorIndex, isProminent: false))
                    .pointerCursor()
            }
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
