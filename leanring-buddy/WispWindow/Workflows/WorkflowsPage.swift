//
//  WorkflowsPage.swift
//  leanring-buddy
//
//  The Workflows page: a title (with a switcher) over the canvas, as OpenBot's Workflows tab has.
//

import SwiftUI

struct WorkflowsPage: View {
    @ObservedObject private var store = WorkflowStore.shared
    @ObservedObject private var engine = WorkflowRunEngine.shared
    @AppStorage("WispLastWorkflowID") private var lastWorkflowIDText = ""
    @State private var selectedID: UUID?
    @State private var titleText = ""
    @State private var isConfirmingDeletion = false
    @FocusState private var isTitleFocused: Bool

    private var selectedWorkflow: Workflow? { selectedID.flatMap(store.workflow(withID:)) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(WispColor.cardSeparator.opacity(0.5)).frame(height: 0.5)
            if let selectedWorkflow {
                WorkflowEditorHost(workflowID: selectedWorkflow.id)
                    .id(selectedWorkflow.id)
            } else {
                emptyState
            }
        }
        .onAppear(perform: chooseInitialWorkflow)
        .confirmationDialog("Delete \(selectedWorkflow?.title ?? "this workflow")?", isPresented: $isConfirmingDeletion) {
            Button("Delete Workflow", role: .destructive) {
                if let selectedID { store.delete(selectedID) }
                selectedID = store.ordered.first?.id
                titleText = selectedWorkflow?.title ?? ""
            }
        } message: {
            Text("The canvas and everything on it is removed.")
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(store.ordered) { workflow in
                    Button(workflow.title) { select(workflow.id) }
                }
                if !store.workflows.isEmpty { Divider() }
                Button("New workflow", systemImage: "plus") { createWorkflow() }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(WispColor.textSecondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().pointerCursor()
            .accessibilityLabel("Switch workflow")

            TextField("Untitled workflow", text: $titleText)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(WispColor.textPrimary)
                .focused($isTitleFocused)
                .onSubmit(commitTitle)
                .onChange(of: isTitleFocused) { _, isFocused in if !isFocused { commitTitle() } }
                .frame(maxWidth: 320)
                .disabled(selectedWorkflow == nil)

            if let selectedWorkflow {
                Text("\(selectedWorkflow.stepCount) \(selectedWorkflow.stepCount == 1 ? "step" : "steps")")
                    .font(.system(size: 11.5)).foregroundStyle(WispColor.textTertiary)
            }

            if let selectedWorkflow { runControls(for: selectedWorkflow) }
            Spacer()
            BuddyIconButton(symbolName: "plus", label: "New workflow", size: 28) { createWorkflow() }
            if selectedWorkflow != nil {
                BuddyIconButton(symbolName: "trash", label: "Delete workflow", size: 28) { isConfirmingDeletion = true }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    /// Run (or Stop while it runs), what the latest run did, and the schedule switch.
    @ViewBuilder
    private func runControls(for workflow: Workflow) -> some View {
        let run = engine.runs[workflow.id]
        let isRunning = run?.status == .running
        HStack(spacing: 10) {
            if isRunning {
                Button { engine.stop(workflowID: workflow.id) } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(WispPillButtonStyle(isProminent: false)).controlSize(.small).pointerCursor()
            } else {
                Button { engine.start(workflowID: workflow.id) } label: { Label("Run", systemImage: "play.fill") }
                    .buttonStyle(WispPillButtonStyle()).controlSize(.small).pointerCursor()
                    .disabled(workflow.graph.nodes.isEmpty)
            }
            if let run { Text(runSummary(run)).font(.system(size: 11.5)).foregroundStyle(runColor(run)).lineLimit(1) }
            if workflow.graph.nodes.contains(where: { $0.kind == .trigger && $0.text("trigger") == WorkflowTriggerType.schedule.rawValue }) {
                Toggle("On schedule", isOn: Binding(
                    get: { workflow.isScheduled == true },
                    set: { store.setScheduled(workflow.id, $0) }
                ))
                .toggleStyle(.switch).controlSize(.small).font(.system(size: 11.5)).pointerCursor()
                .nativeTooltip("Starts its schedule triggers at their time while Wisp is running")
            }
        }
    }

    private func runSummary(_ run: WorkflowRunEngine.Run) -> String {
        switch run.status {
        case .running: return "Running…"
        case .done: return "Done"
        case .failed(let message): return message
        case .stopped(let message): return message
        }
    }

    private func runColor(_ run: WorkflowRunEngine.Run) -> Color {
        if case .failed = run.status { return DS.Colors.destructiveText }
        return WispColor.textSecondary
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("No workflows yet").font(.system(size: 14, weight: .semibold)).foregroundStyle(WispColor.textPrimary)
            Text("A workflow chains triggers, buddies and outputs on a canvas.")
                .font(.system(size: 12.5)).foregroundStyle(WispColor.textSecondary)
            Button { createWorkflow() } label: { Label("New workflow", systemImage: "plus") }
                .buttonStyle(WispPillButtonStyle()).pointerCursor()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chooseInitialWorkflow() {
        guard selectedID == nil else { return }
        let remembered = UUID(uuidString: lastWorkflowIDText).flatMap(store.workflow(withID:))
        select((remembered ?? store.ordered.first)?.id)
    }

    private func select(_ id: UUID?) {
        selectedID = id
        titleText = selectedWorkflow?.title ?? ""
        if let id { lastWorkflowIDText = id.uuidString }
    }

    private func createWorkflow() {
        select(store.create().id)
        isTitleFocused = true
    }

    private func commitTitle() {
        guard let selectedID else { return }
        let trimmed = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { titleText = selectedWorkflow?.title ?? "" } else { store.rename(selectedID, to: trimmed) }
    }
}

/// Owns the editor model of one workflow (the page gives it a new identity per workflow).
private struct WorkflowEditorHost: View {
    @StateObject private var model: WorkflowEditorModel

    init(workflowID: UUID) {
        _model = StateObject(wrappedValue: WorkflowEditorModel(workflowID: workflowID))
    }

    var body: some View { WorkflowCanvasView(model: model) }
}
