//
//  RoutinesTab.swift
//  leanring-buddy
//
//  The dashboard's Routines tab: create and edit routines — a name, the
//  instruction Wisp runs, an icon, an optional ⌃⌥ + digit shortcut, the apps the
//  notch should suggest it in, and whether it's always in the notch. Edits save
//  as they are made (to `RoutineStore`), like the other settings tabs.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RoutinesTab: View {
    @ObservedObject private var routineStore = RoutineStore.shared
    let companionManager: CompanionManager

    @State private var selectedRoutineID: UUID?
    /// The routine being edited. Kept as a local copy so text fields don't fight
    /// the store's republishing; every change is written straight back.
    @State private var editedRoutine: WispRoutine?
    @State private var isConfirmingDelete = false

    var body: some View {
        HStack(spacing: 0) {
            routineList
                .frame(width: 230)
            Divider().background(DS.Colors.borderSubtle)
            editorPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(WispColor.windowBackground)
        .onAppear {
            if !openRoutineHandedOverByAnotherScreen() && selectedRoutineID == nil {
                selectRoutine(routineStore.routines.first?.id)
            }
        }
        .onChange(of: routineStore.routineIDToOpenInEditor) { _, _ in
            _ = openRoutineHandedOverByAnotherScreen()
        }
    }

    // MARK: - List

    private var routineList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Saved instructions Wisp runs from the notch or a shortcut.")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                let newRoutine = routineStore.addRoutine(
                    WispRoutine(name: "New routine", instruction: "")
                )
                selectRoutine(newRoutine.id)
            } label: {
                Label("New routine", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(WispGlassButtonStyle())
            .pointerCursor()

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(routineStore.routines) { routine in
                        routineListRow(routine)
                    }
                }
            }
        }
        .padding(12)
    }

    private func routineListRow(_ routine: WispRoutine) -> some View {
        let isSelected = routine.id == selectedRoutineID
        return Button {
            selectRoutine(routine.id)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: routine.symbolName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Colors.accentText)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(routine.name.isEmpty ? "Untitled" : routine.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(routineSubtitle(routine))
                        .font(.system(size: 10.5))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(isSelected ? DS.Colors.surface3 : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    /// "⌃⌥1 · Chrome, Safari +4" — how the routine is reached, at a glance.
    private func routineSubtitle(_ routine: WispRoutine) -> String {
        var parts: [String] = []
        if let shortcutDigit = routine.shortcutDigit {
            parts.append(RoutineStore.shortcutLabel(forDigit: shortcutDigit))
        }
        if !routine.suggestedAppNames.isEmpty {
            let shownAppNames = routine.suggestedAppNames.prefix(2).joined(separator: ", ")
            let hiddenAppCount = routine.suggestedAppNames.count - 2
            parts.append(hiddenAppCount > 0 ? "\(shownAppNames) +\(hiddenAppCount)" : shownAppNames)
        }
        if routine.isPinnedInNotch {
            parts.append("In the notch")
        }
        return parts.isEmpty ? "Run from the dashboard" : parts.joined(separator: " · ")
    }

    /// Selects a routine another screen created for editing (History's "Save as
    /// routine") and clears the handover. Returns whether there was one.
    private func openRoutineHandedOverByAnotherScreen() -> Bool {
        guard let handedOverRoutineID = routineStore.routineIDToOpenInEditor else { return false }
        routineStore.routineIDToOpenInEditor = nil
        selectRoutine(handedOverRoutineID)
        return true
    }

    private func selectRoutine(_ routineID: UUID?) {
        selectedRoutineID = routineID
        editedRoutine = routineID.flatMap { routineStore.routine(withID: $0) }
    }

    // MARK: - Editor

    @ViewBuilder
    private var editorPane: some View {
        if let editedRoutine {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    editorHeader(editedRoutine)
                    instructionCard
                    triggersCard(editedRoutine)
                    suggestedAppsCard(editedRoutine)
                    if let lastRunAt = editedRoutine.lastRunAt {
                        Text("Last run \(lastRunAt.formatted(.relative(presentation: .named)))")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.Colors.textTertiary)
                    }
                }
                .padding(16)
            }
            .confirmationDialog(
                "Delete “\(editedRoutine.name)”?",
                isPresented: $isConfirmingDelete
            ) {
                Button("Delete", role: .destructive) {
                    routineStore.deleteRoutine(withID: editedRoutine.id)
                    selectRoutine(routineStore.routines.first?.id)
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "bolt")
                    .font(.system(size: 22))
                    .foregroundStyle(DS.Colors.textTertiary)
                Text("No routine selected")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A binding into one field of the routine being edited that writes each
    /// change straight to the store.
    private func editedRoutineBinding<Value>(_ keyPath: WritableKeyPath<WispRoutine, Value>) -> Binding<Value>? {
        guard let editedRoutine else { return nil }
        return Binding(
            get: { self.editedRoutine?[keyPath: keyPath] ?? editedRoutine[keyPath: keyPath] },
            set: { newValue in
                guard var updatedRoutine = latestEditedRoutine() else { return }
                updatedRoutine[keyPath: keyPath] = newValue
                self.editedRoutine = updatedRoutine
                routineStore.updateRoutine(updatedRoutine)
            }
        )
    }

    /// The routine being edited as the store has it now. Edits start from this
    /// rather than the local copy, which can be stale: running the routine from
    /// the notch updates its last-run time, and another routine taking its
    /// shortcut clears its digit — saving the old copy would undo either.
    private func latestEditedRoutine() -> WispRoutine? {
        guard let editedRoutine else { return nil }
        return routineStore.routine(withID: editedRoutine.id) ?? editedRoutine
    }

    private func editorHeader(_ routine: WispRoutine) -> some View {
        HStack(spacing: 10) {
            symbolMenu(routine)
            if let nameBinding = editedRoutineBinding(\.name) {
                TextField("Routine name", text: nameBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(DS.Colors.textPrimary)
            }
            Spacer(minLength: 8)
            Button {
                runRoutineOnCurrentWork(routine.id)
            } label: {
                Label("Run now", systemImage: "play.fill")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(WispGlassButtonStyle(prominence: .prominent))
            .disabled(routine.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .pointerCursor()
            .nativeTooltip("Close the dashboard and run this on what's behind it")

            Button {
                isConfirmingDelete = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Colors.destructiveText)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .nativeTooltip("Delete this routine")
        }
    }

    private func symbolMenu(_ routine: WispRoutine) -> some View {
        Menu {
            ForEach(RoutineStore.availableSymbolNames, id: \.self) { symbolName in
                Button {
                    editedRoutineBinding(\.symbolName)?.wrappedValue = symbolName
                } label: {
                    Label(symbolName, systemImage: symbolName)
                }
            }
        } label: {
            Image(systemName: routine.symbolName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(DS.Colors.accentText)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.accentSubtle)
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointerCursor()
        .nativeTooltip("Change icon")
    }

    private var instructionCard: some View {
        DashboardCard(title: "What should Wisp do?") {
            VStack(alignment: .leading, spacing: 6) {
                if let instructionBinding = editedRoutineBinding(\.instruction) {
                    TextEditor(text: instructionBinding)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 70)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(DS.Colors.surface2)
                        )
                }
                Text("Sent with a screenshot of your screen and the name of the app you're in, like a question you typed.")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func triggersCard(_ routine: WispRoutine) -> some View {
        DashboardCard(title: "Run it with") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Keyboard shortcut")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DS.Colors.textPrimary)
                        Text("Hold your talk chord and press the number.")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                    Spacer(minLength: 0)
                    shortcutMenu(routine)
                }
                if let pinnedBinding = editedRoutineBinding(\.isPinnedInNotch) {
                    Toggle(isOn: pinnedBinding) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Always show in the notch")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(DS.Colors.textPrimary)
                            Text("Otherwise it only appears in the apps below.")
                                .font(.system(size: 11))
                                .foregroundStyle(DS.Colors.textSecondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .tint(DS.Colors.accent)
                    .pointerCursor()
                }
            }
        }
    }

    private func shortcutMenu(_ routine: WispRoutine) -> some View {
        Menu {
            Button("None") {
                editedRoutineBinding(\.shortcutDigit)?.wrappedValue = nil
            }
            Divider()
            ForEach(1...9, id: \.self) { shortcutDigit in
                Button {
                    editedRoutineBinding(\.shortcutDigit)?.wrappedValue = shortcutDigit
                } label: {
                    Text(shortcutMenuItemTitle(digit: shortcutDigit, forRoutineID: routine.id))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(routine.shortcutDigit.map { RoutineStore.shortcutLabel(forDigit: $0) } ?? "None")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(DS.Colors.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointerCursor()
    }

    /// "⌃⌥2 — used by Explain this error", so picking a taken digit (which moves
    /// it to this routine) is never a surprise.
    private func shortcutMenuItemTitle(digit shortcutDigit: Int, forRoutineID routineID: UUID) -> String {
        let baseTitle = RoutineStore.shortcutLabel(forDigit: shortcutDigit)
        if let owningRoutine = routineStore.routine(forShortcutDigit: shortcutDigit),
           owningRoutine.id != routineID {
            return "\(baseTitle) — used by \(owningRoutine.name)"
        }
        return baseTitle
    }

    // MARK: Suggested apps

    private func suggestedAppsCard(_ routine: WispRoutine) -> some View {
        DashboardCard(title: "Suggest it in") {
            VStack(alignment: .leading, spacing: 10) {
                Text("When one of these apps is in front, the notch offers this routine.")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textSecondary)

                if !routine.suggestedAppNames.isEmpty {
                    FlowingWordChips(
                        words: routine.suggestedAppNames,
                        onRemove: { appName in removeSuggestedApp(named: appName) }
                    )
                }

                addAppMenu(routine)
            }
        }
    }

    private func addAppMenu(_ routine: WispRoutine) -> some View {
        Menu {
            let runningApplications = runningAppsNotYetSuggested(for: routine)
            if !runningApplications.isEmpty {
                Section("Open now") {
                    ForEach(runningApplications, id: \.bundleIdentifier) { application in
                        Button(application.displayName) {
                            addSuggestedApp(bundleIdentifier: application.bundleIdentifier, displayName: application.displayName)
                        }
                    }
                }
            }
            Button("Choose from Applications…") {
                chooseSuggestedAppFromApplicationsFolder()
            }
        } label: {
            Label("Add app", systemImage: "plus")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.Colors.accentText)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointerCursor()
    }

    private func runningAppsNotYetSuggested(for routine: WispRoutine) -> [FrontmostAppTracker.TrackedApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { runningApplication -> FrontmostAppTracker.TrackedApplication? in
                guard let bundleIdentifier = runningApplication.bundleIdentifier,
                      !routine.suggestedAppBundleIdentifiers.contains(bundleIdentifier) else { return nil }
                return FrontmostAppTracker.TrackedApplication(
                    bundleIdentifier: bundleIdentifier,
                    displayName: runningApplication.localizedName ?? bundleIdentifier
                )
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func chooseSuggestedAppFromApplicationsFolder() {
        let openPanel = NSOpenPanel()
        openPanel.directoryURL = URL(fileURLWithPath: "/Applications")
        openPanel.allowedContentTypes = [.application]
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Add"
        guard openPanel.runModal() == .OK,
              let applicationURL = openPanel.url,
              let applicationBundle = Bundle(url: applicationURL),
              let bundleIdentifier = applicationBundle.bundleIdentifier else { return }
        let displayName = FileManager.default.displayName(atPath: applicationURL.path)
            .replacingOccurrences(of: ".app", with: "")
        addSuggestedApp(bundleIdentifier: bundleIdentifier, displayName: displayName)
    }

    private func addSuggestedApp(bundleIdentifier: String, displayName: String) {
        guard var updatedRoutine = latestEditedRoutine(),
              !updatedRoutine.suggestedAppBundleIdentifiers.contains(bundleIdentifier) else { return }
        updatedRoutine.suggestedAppBundleIdentifiers.append(bundleIdentifier)
        updatedRoutine.suggestedAppNames.append(displayName)
        editedRoutine = updatedRoutine
        routineStore.updateRoutine(updatedRoutine)
    }

    private func removeSuggestedApp(named appName: String) {
        guard var updatedRoutine = latestEditedRoutine(),
              let appIndex = updatedRoutine.suggestedAppNames.firstIndex(of: appName) else { return }
        updatedRoutine.suggestedAppNames.remove(at: appIndex)
        if appIndex < updatedRoutine.suggestedAppBundleIdentifiers.count {
            updatedRoutine.suggestedAppBundleIdentifiers.remove(at: appIndex)
        }
        editedRoutine = updatedRoutine
        routineStore.updateRoutine(updatedRoutine)
    }

    // MARK: - Running

    /// Closes the dashboard so the routine sees the user's work rather than this
    /// window, then runs it once the previous app is back in front.
    private func runRoutineOnCurrentWork(_ routineID: UUID) {
        NSApp.keyWindow?.performClose(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            companionManager.runRoutine(withID: routineID)
        }
    }
}
