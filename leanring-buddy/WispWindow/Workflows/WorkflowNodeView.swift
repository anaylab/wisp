//
//  WorkflowNodeView.swift
//  leanring-buddy
//
//  One node on the canvas: its card, its fields, and its ports. A step's card has a header you drag
//  and a body of fields; a note is a sticky; text is just text. Ports appear on the card's edges;
//  drag out of an output port to connect. After OpenBot's `Workflow*Node` cards.
//

import SwiftUI

private let canvasSpace = "workflow-canvas"

struct WorkflowNodeView: View {
    @ObservedObject var model: WorkflowEditorModel
    let node: WorkflowNode

    @ObservedObject private var buddyStore = BuddyStore.shared
    @ObservedObject private var engine = WorkflowRunEngine.shared
    @State private var isHovering = false

    /// What the latest run did at this node, for its badge and its output chip.
    private var stepState: WorkflowRunEngine.StepState? { engine.runs[model.workflowID]?.steps[node.id] }

    private var isSelected: Bool { model.selection.contains(node.id) }
    private var isLocked: Bool { node.locked == true }

    var body: some View {
        ZStack(alignment: .topLeading) {
            card
            ports
            outputChip
        }
        .onHover { isHovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture {
            model.select(node.id, extending: NSEvent.modifierFlags.contains(.shift))
        }
        .contextMenu {
            Button(isLocked ? "Unlock" : "Lock", systemImage: isLocked ? "lock.open" : "lock") {
                model.selection = [node.id]; model.toggleLockOnSelection()
            }
            if node.kind.isStep {
                Button("Run from here", systemImage: "play") {
                    WorkflowRunEngine.shared.start(workflowID: model.workflowID, fromNodeIDs: [node.id])
                }
            }
            Button("Duplicate", systemImage: "plus.square.on.square") { model.selection = [node.id]; model.duplicateSelection() }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { model.selection = [node.id]; model.removeSelection() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(node.kind.title) node")
    }

    // MARK: Card

    @ViewBuilder
    private var card: some View {
        switch node.kind {
        case .note: noteCard
        case .text: textCard
        default: stepCard
        }
    }

    private var stepCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            fields
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(WispColor.surface2))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isSelected ? WispColor.textPrimary.opacity(0.85) : WispColor.cardSeparator, lineWidth: isSelected ? 1.5 : 0.75)
        )
    }

    /// The title row. Dragging it moves the node (the fields below take their own clicks).
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: node.kind.symbolName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(WispColor.textSecondary)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(WispColor.surface3))
            Text(headerTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(WispColor.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let stepState { statusBadge(stepState) }
            if isLocked {
                Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(WispColor.textTertiary)
            }
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .gesture(moveGesture)
    }

    /// Running, waiting for you, done, failed or stopped — one small mark in the header.
    @ViewBuilder
    private func statusBadge(_ state: WorkflowRunEngine.StepState) -> some View {
        switch state.status {
        case .running:
            ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16, height: 16)
        case .waitingForApproval:
            Image(systemName: "checkmark.shield").font(.system(size: 12)).foregroundStyle(WispColor.warningText)
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(WispColor.success)
        case .failed:
            Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(DS.Colors.destructiveText)
        case .stopped:
            Image(systemName: "stop.circle").font(.system(size: 13)).foregroundStyle(WispColor.textTertiary)
        }
    }

    /// Under the card: what the step produced, or why it failed, in a quiet chip.
    @ViewBuilder
    private var outputChip: some View {
        if let stepState, stepState.status == .done || stepState.status == .failed {
            let text = stepState.status == .failed
                ? (stepState.error ?? "Failed")
                : WorkflowPromptBuilder.preview(of: stepState.output ?? "", limit: 160)
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(stepState.status == .failed ? DS.Colors.destructiveText : WispColor.textSecondary)
                    .lineLimit(3)
                    .padding(8)
                    .frame(width: WorkflowLayout.size(of: node).width, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(WispColor.surface1))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(WispColor.cardSeparator, lineWidth: 0.5))
                    .offset(y: WorkflowLayout.size(of: node).height + 8)
                    .allowsHitTesting(false)
            }
        }
    }

    private var headerTitle: String {
        if node.kind == .buddy, let buddy = selectedBuddy { return buddy.name }
        return node.kind.title
    }

    private var selectedBuddy: WispBuddy? {
        UUID(uuidString: node.text("buddyID")).flatMap { buddyStore.buddy(withID: $0) }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: WorkflowLayout.dragThreshold, coordinateSpace: .named(canvasSpace))
            .onChanged { value in
                if !isSelected { model.select(node.id, extending: false) }
                if value.translation == .zero { return }
                if !model.isDragging { model.beginDrag() }
                model.drag(byScreenTranslation: value.translation)
            }
            .onEnded { _ in model.endDrag() }
    }

    private var noteCard: some View {
        TextField("Write a note", text: binding("text"), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(WispColor.textPrimary)
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(WispColor.warning.opacity(0.22)))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? WispColor.textPrimary.opacity(0.85) : WispColor.warning.opacity(0.35), lineWidth: isSelected ? 1.5 : 0.75)
            )
            .overlay(alignment: .top) {
                Color.clear.frame(height: 14).contentShape(Rectangle()).gesture(moveGesture)
            }
    }

    private var textCard: some View {
        TextField("Text", text: binding("text"), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(WispColor.textPrimary)
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected || isHovering ? WispColor.textPrimary.opacity(isSelected ? 0.85 : 0.25) : .clear, lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                Color.clear.frame(width: 18, height: 18).contentShape(Rectangle()).gesture(moveGesture)
            }
    }

    // MARK: Fields

    @ViewBuilder
    private var fields: some View {
        switch node.kind {
        case .trigger:
            Picker("", selection: Binding(
                get: { node.text("trigger").isEmpty ? WorkflowTriggerType.manual.rawValue : node.text("trigger") },
                set: { model.setField(node.id, "trigger", to: $0) }
            )) {
                Text("Run by hand").tag(WorkflowTriggerType.manual.rawValue)
                Text("On a schedule").tag(WorkflowTriggerType.schedule.rawValue)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            if node.text("trigger") == WorkflowTriggerType.schedule.rawValue {
                labeled("Every day at", TextField("09:00", text: binding("time")).textFieldStyle(.plain))
            }
        case .prompt:
            fieldBox(TextField("Text to start from", text: binding("text"), axis: .vertical).lineLimit(3...6))
        case .buddy:
            buddyMenu
            fieldBox(TextField("What should it do?", text: binding("task"), axis: .vertical).lineLimit(2...4))
        case .condition:
            fieldBox(TextField("Is the answer positive?", text: binding("rule"), axis: .vertical).lineLimit(2...3))
        case .approval:
            fieldBox(TextField("What should you approve?", text: binding("question"), axis: .vertical).lineLimit(2...3))
        case .output:
            Picker("", selection: Binding(
                get: { node.text("target").isEmpty ? WorkflowOutputTarget.notify.rawValue : node.text("target") },
                set: { model.setField(node.id, "target", to: $0) }
            )) {
                Text("Notify me").tag(WorkflowOutputTarget.notify.rawValue)
                Text("Save to a file").tag(WorkflowOutputTarget.file.rawValue)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
        case .text, .note:
            EmptyView()
        }
    }

    private var buddyMenu: some View {
        Menu {
            ForEach(buddyStore.buddies) { buddy in
                Button(buddy.name) { model.setField(node.id, "buddyID", to: buddy.id.uuidString) }
            }
            if buddyStore.buddies.isEmpty { Text("No buddies yet") }
        } label: {
            HStack(spacing: 6) {
                if let buddy = selectedBuddy {
                    BuddyCharacter(colorIndex: buddy.colorIndex, size: 18, mood: .idle, liveliness: .still)
                        .frame(width: 20, height: 20)
                    Text(buddy.name)
                } else {
                    Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 12))
                    Text("Choose a buddy")
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(WispColor.textPrimary)
            .padding(.horizontal, 8).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(WispColor.surface3))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).pointerCursor()
    }

    private func fieldBox<Content: View>(_ content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(WispColor.textPrimary)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(WispColor.surface3.opacity(0.7)))
    }

    private func labeled<Content: View>(_ title: String, _ content: Content) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12)).foregroundStyle(WispColor.textSecondary)
            content
                .font(.system(size: 12.5).monospacedDigit())
                .foregroundStyle(WispColor.textPrimary)
                .padding(.horizontal, 8).frame(width: 70, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(WispColor.surface3.opacity(0.7)))
        }
    }

    private func binding(_ field: String) -> Binding<String> {
        Binding(get: { node.text(field) }, set: { model.setField(node.id, field, to: $0, typing: true) })
    }

    // MARK: Ports

    @ViewBuilder
    private var ports: some View {
        if node.kind.isStep {
            if !WorkflowPorts.incoming(node.kind).isEmpty {
                portCircle(isOutput: false, branch: nil)
                    .offset(x: -WorkflowLayout.portSize / 2, y: 36 - WorkflowLayout.portSize / 2)
            }
            if !WorkflowPorts.outgoing(node.kind).isEmpty {
                if node.kind == .condition {
                    ForEach([WorkflowBranch.yes, .no], id: \.self) { branch in
                        let point = WorkflowLayout.portPoint(of: node, isOutput: true, branch: branch)
                        portCircle(isOutput: true, branch: branch)
                            .offset(x: WorkflowLayout.size(of: node).width - WorkflowLayout.portSize / 2,
                                    y: point.y - node.at.y - WorkflowLayout.portSize / 2)
                        Text(branch == .yes ? "Yes" : "No")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(WispColor.textSecondary)
                            .offset(x: WorkflowLayout.size(of: node).width - 40, y: point.y - node.at.y - 8)
                    }
                } else {
                    portCircle(isOutput: true, branch: nil)
                        .offset(x: WorkflowLayout.size(of: node).width - WorkflowLayout.portSize / 2,
                                y: 36 - WorkflowLayout.portSize / 2)
                }
            }
        }
    }

    private func portCircle(isOutput: Bool, branch: WorkflowBranch?) -> some View {
        let isActive = isHovering || isSelected || model.pending != nil
        return Circle()
            .fill(WispColor.surface3)
            .frame(width: WorkflowLayout.portSize, height: WorkflowLayout.portSize)
            .overlay(Circle().strokeBorder(WispColor.textSecondary.opacity(0.7), lineWidth: 1))
            .overlay(Circle().fill(WispColor.textSecondary).frame(width: 4, height: 4))
            .opacity(isActive ? 1 : 0.35)
            .contentShape(Circle().inset(by: -6))
            .gesture(isOutput ? connectGesture(branch: branch) : nil)
            .pointerCursor()
    }

    private func connectGesture(branch: WorkflowBranch?) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(canvasSpace))
            .onChanged { value in
                let world = model.camera.worldPoint(WorkflowPoint(x: value.location.x, y: value.location.y))
                if model.pending == nil {
                    model.beginConnection(from: node.id, branch: branch, pointerWorld: world)
                } else {
                    model.updateConnection(pointerWorld: world)
                }
            }
            .onEnded { _ in model.finishConnection() }
    }
}
