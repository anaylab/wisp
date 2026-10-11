//
//  BuddyInspectorView.swift
//  leanring-buddy
//
//  The panel beside a buddy's chat: everything about the buddy that isn't the
//  conversation, in five tabs — Automation (its schedule, next run, recent
//  runs), Files (its library), Memory (what it chose to remember), Tools (what
//  it may use) and About (name, specialty, colour, model, job). It edits the
//  same stores the rest of the app reads, so nothing here is a copy.
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
        case .automation: return "clock.arrow.2.circlepath"
        case .files: return "folder.fill"
        case .memory: return "brain.head.profile"
        case .tools: return "wrench.and.screwdriver.fill"
        case .about: return "person.crop.circle.fill"
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
    @State private var didLoadDrafts = false

    private var selectedTab: BuddyInspectorTab { BuddyInspectorTab(rawValue: selectedTabRawValue) ?? .automation }

    var body: some View {
        if let buddy = buddyStore.buddy(withID: buddyID) {
            VStack(spacing: 0) {
                tabBar(for: buddy)
                Divider().opacity(0.5)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
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
                    .transition(.opacity.combined(with: .offset(y: 6)))
                }
                .animation(WispMotion.smooth, value: selectedTab)
            }
            .background(WispColor.groupedCardBackground.opacity(0.55))
            .onAppear { loadDrafts(from: buddy) }
            .onChange(of: buddyID) { _, _ in
                if let newBuddy = buddyStore.buddy(withID: buddyID) { loadDrafts(from: newBuddy) }
            }
        }
    }

    private func loadDrafts(from buddy: WispBuddy) {
        editedName = buddy.name
        editedInstruction = buddy.instruction
        didLoadDrafts = true
    }

    // MARK: - Tabs

    private func tabBar(for buddy: WispBuddy) -> some View {
        HStack(spacing: 4) {
            ForEach(BuddyInspectorTab.allCases) { tab in
                let isSelected = tab == selectedTab
                Button {
                    selectedTabRawValue = tab.rawValue
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbolName).font(.system(size: 13, weight: .semibold))
                        Text(tab.title).font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(isSelected ? Color.white : WispColor.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(isSelected ? AnyShapeStyle(BuddyAppearance.accentGradient(forColorIndex: buddy.colorIndex)) : AnyShapeStyle(Color.clear))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityLabel(tab.title)
            }
        }
        .padding(10)
        .animation(WispMotion.quick, value: selectedTab)
    }

    private func sectionTitle(_ title: String, symbolName: String? = nil) -> some View {
        HStack(spacing: 5) {
            if let symbolName { Image(systemName: symbolName).font(.system(size: 10, weight: .bold)) }
            Text(title.uppercased())
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .tracking(1.1)
        }
        .foregroundStyle(WispColor.textTertiary)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(WispColor.surface2.opacity(0.8)))
    }

    // MARK: - Automation

    private func automationTab(for buddy: WispBuddy) -> some View {
        let isRunning = buddyStore.isRunning(buddy, in: taskRegistry)
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Next run", symbolName: "clock")
                Text(buddy.schedule.isRepeating ? BuddyFormatting.nextRunPhrase(for: buddy).capitalizedFirst : "When you ask")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex))
                Text(buddy.schedule.isRepeating ? "\(buddy.schedule.summary()) · while Wisp is running" : "Set a schedule and it works on its own.")
                    .font(.system(size: 11.5)).foregroundStyle(WispColor.textSecondary)
            }

            card {
                sectionTitle("Schedule")
                BuddyScheduleEditor(schedule: Binding(
                    get: { buddy.schedule },
                    set: { buddyStore.updateSchedule(ofBuddyWithID: buddy.id, to: $0) }
                ))
                Toggle(isOn: Binding(
                    get: { buddy.postsNotificationWhenFinished },
                    set: { buddyStore.setNotifiesWhenFinished(buddyWithID: buddy.id, notifiesWhenFinished: $0) }
                )) {
                    Text("Notify me when it finishes").font(.system(size: 12))
                }
                .toggleStyle(.switch).controlSize(.small).tint(BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex))
                .pointerCursor()
            }

            HStack(spacing: 8) {
                if isRunning {
                    Button { buddyStore.stopRun(ofBuddyWithID: buddy.id) } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(BuddyPillButtonStyle(colorIndex: buddy.colorIndex, isProminent: false)).pointerCursor()
                } else {
                    Button { buddyStore.runNow(buddyWithID: buddy.id) } label: { Label("Run now", systemImage: "play.fill") }
                        .buttonStyle(BuddyPillButtonStyle(colorIndex: buddy.colorIndex)).pointerCursor()
                }
            }

            let runRecords = buddyStore.runRecords(of: buddy, in: taskRegistry).suffix(6).reversed()
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Recent runs", symbolName: "list.bullet")
                if runRecords.isEmpty {
                    Text("No runs yet.").font(.system(size: 11.5)).foregroundStyle(WispColor.textTertiary)
                }
                ForEach(Array(runRecords), id: \.id) { record in
                    HStack(spacing: 9) {
                        Circle().fill(runColor(record.status, buddy: buddy)).frame(width: 8, height: 8)
                        Text(runLabel(record.status)).font(.system(size: 12, weight: .semibold, design: .rounded))
                        Spacer()
                        Text(BuddyFormatting.timeText(record.startedAt))
                            .font(.system(size: 11, design: .rounded).monospacedDigit())
                            .foregroundStyle(WispColor.textTertiary)
                    }
                }
            }
        }
    }

    private func runColor(_ status: AgentTaskRecord.Status, buddy: WispBuddy) -> Color {
        switch status {
        case .running, .waitingForApproval: return BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex)
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
        return VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Library", symbolName: "folder")
            Text("Files you send \(buddy.name) are kept here, so it can open them again in later runs without you attaching them twice.")
                .font(.system(size: 11.5)).foregroundStyle(WispColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                let openPanel = NSOpenPanel()
                openPanel.allowsMultipleSelection = true
                openPanel.canChooseDirectories = false
                guard openPanel.runModal() == .OK else { return }
                _ = fileLibrary.add(fileURLs: openPanel.urls, toBuddyWithID: buddy.id)
            } label: { Label("Add files", systemImage: "plus") }
                .buttonStyle(BuddyPillButtonStyle(colorIndex: buddy.colorIndex)).pointerCursor()

            if attachments.isEmpty {
                Text("Nothing yet. Drop a file on the chat, or add one here.")
                    .font(.system(size: 11.5)).foregroundStyle(WispColor.textTertiary)
            }
            ForEach(attachments) { attachment in
                HStack(spacing: 10) {
                    Image(systemName: attachment.kind == .image ? "photo.fill" : "doc.text.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex))
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(attachment.fileName).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        Text("\(BuddyFormatting.byteText(attachment.byteCount)) · \(BuddyFormatting.timeText(attachment.addedAt))")
                            .font(.system(size: 10.5)).foregroundStyle(WispColor.textTertiary)
                    }
                    Spacer(minLength: 4)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([fileLibrary.fileURL(of: attachment, buddyID: buddy.id)])
                    } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.plain).foregroundStyle(WispColor.textTertiary).pointerCursor().nativeTooltip("Show in Finder")
                    Button {
                        withAnimation(WispMotion.smooth) { fileLibrary.remove(attachment, fromBuddyWithID: buddy.id) }
                    } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(WispColor.textTertiary).pointerCursor().nativeTooltip("Remove")
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WispColor.surface2.opacity(0.8)))
            }
        }
    }

    // MARK: - Memory

    private func memoryTab(for buddy: WispBuddy) -> some View {
        let notes = memoryStore.facts(ofBuddyWithID: buddy.id)
        return VStack(alignment: .leading, spacing: 12) {
            sectionTitle("What \(buddy.name) remembers", symbolName: "brain.head.profile")
            Text("Short notes it saves for its own future runs — what it already reported, what to skip. Private to this buddy.")
                .font(.system(size: 11.5)).foregroundStyle(WispColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if notes.isEmpty {
                Text("Nothing saved yet.").font(.system(size: 11.5)).foregroundStyle(WispColor.textTertiary)
            }
            ForEach(notes, id: \.self) { note in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkle").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex)).padding(.top, 4)
                    Text(note).font(.system(size: 12.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button { withAnimation(WispMotion.smooth) { memoryStore.forgetExactFact(note, forBuddyWithID: buddy.id) } } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(WispColor.textTertiary).pointerCursor().nativeTooltip("Forget this")
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WispColor.surface2.opacity(0.8)))
            }
        }
    }

    // MARK: - Tools

    private func toolsTab(for buddy: WispBuddy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("What it can use", symbolName: "wrench.and.screwdriver")
            Text("A smaller toolbox helps the model choose well. \(buddy.specialty.map { "\($0.title) buddies start with a set that fits the job." } ?? "")")
                .font(.system(size: 11.5)).foregroundStyle(WispColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            BuddyToolAccessEditor(
                toolAccess: Binding(
                    get: { buddy.toolAccess },
                    set: { buddyStore.updateToolAccess(ofBuddyWithID: buddy.id, to: $0) }
                ),
                modelSendsDataOffThisMachine: BuddyModelChoice.sendsDataOffThisMachine(buddy.modelChoice)
            )
        }
    }

    // MARK: - About

    private func aboutTab(for buddy: WispBuddy) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            card {
                sectionTitle("Name")
                TextField("Name", text: $editedName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { buddyStore.rename(buddyWithID: buddy.id, to: editedName) }
                sectionTitle("Colour")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 8) {
                    ForEach(0..<BuddyAppearance.paletteCount, id: \.self) { colorIndex in
                        Button {
                            buddyStore.updateColor(ofBuddyWithID: buddy.id, to: colorIndex)
                        } label: {
                            Circle()
                                .fill(BuddyAppearance.gradient(forColorIndex: colorIndex))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(Color.white, lineWidth: buddy.colorIndex == colorIndex ? 2.5 : 0))
                                .shadow(color: BuddyAppearance.deepColor(forColorIndex: colorIndex).opacity(buddy.colorIndex == colorIndex ? 0.6 : 0), radius: 5)
                                .scaleEffect(buddy.colorIndex == colorIndex ? 1.12 : 1)
                        }
                        .buttonStyle(.plain).pointerCursor()
                    }
                }
                .animation(WispMotion.quick, value: buddy.colorIndex)
            }

            card {
                sectionTitle("Specialty")
                Picker("Specialty", selection: Binding(
                    get: { buddy.specialty ?? .general },
                    set: { newSpecialty in
                        buddyStore.updateSpecialty(ofBuddyWithID: buddy.id, to: newSpecialty, appliesToolLimits: true)
                    }
                )) {
                    ForEach(BuddySpecialty.allCases) { specialty in
                        Label(specialty.title, systemImage: specialty.symbolName).tag(specialty)
                    }
                }
                .labelsHidden().pickerStyle(.menu).pointerCursor()
                Text("Changing it re-sets the tools to that specialty's set.")
                    .font(.system(size: 10.5)).foregroundStyle(WispColor.textTertiary)
            }

            card {
                sectionTitle("Model")
                BuddyModelEditor(modelChoice: Binding(
                    get: { buddy.modelChoice },
                    set: { buddyStore.updateModelChoice(ofBuddyWithID: buddy.id, to: $0) }
                ))
            }

            card {
                sectionTitle("Mission")
                TextField("What should it do?", text: $editedInstruction, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...6)
                HStack {
                    Spacer()
                    Button("Save mission") { buddyStore.updateInstruction(ofBuddyWithID: buddy.id, to: editedInstruction) }
                        .buttonStyle(BuddyPillButtonStyle(colorIndex: buddy.colorIndex)).pointerCursor()
                        .disabled(editedInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editedInstruction == buddy.instruction)
                }
            }

            HStack(spacing: 8) {
                Button("Clear conversation…", action: onRequestClearConversation).buttonStyle(.bordered).pointerCursor()
                Button("Delete…", role: .destructive, action: onRequestDeletion).buttonStyle(.bordered).pointerCursor()
            }
            .controlSize(.small)
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
