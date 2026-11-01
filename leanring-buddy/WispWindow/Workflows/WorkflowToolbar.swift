//
//  WorkflowToolbar.swift
//  leanring-buddy
//
//  The bar along the bottom of the canvas (tools, add a node, undo and redo) and the zoom control
//  at its bottom-left, after OpenBot's: round, quiet, a hairline instead of a shadow.
//

import SwiftUI

struct WorkflowToolbar: View {
    @ObservedObject var model: WorkflowEditorModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(WorkflowTool.allCases) { tool in
                toolButton(tool)
            }
            divider
            iconButton("arrow.uturn.backward", "Undo  ⌘Z", isEnabled: model.canUndo) { model.undo() }
            iconButton("arrow.uturn.forward", "Redo  ⇧⌘Z", isEnabled: model.canRedo) { model.redo() }
            divider
            Menu {
                ForEach(WorkflowNodeKind.stepKinds) { kind in
                    Button(kind.title, systemImage: kind.symbolName) { model.addNode(kind) }
                }
            } label: {
                Label("Add node", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(WispColor.windowBackground)
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(Capsule().fill(WispColor.textPrimary))
                    .contentShape(Capsule())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().pointerCursor()
        }
        .padding(5)
        .background(Capsule().fill(WispColor.surface2))
        .overlay(Capsule().strokeBorder(WispColor.cardSeparator, lineWidth: 0.75))
    }

    private var divider: some View {
        Rectangle().fill(WispColor.cardSeparator).frame(width: 0.5, height: 18).padding(.horizontal, 3)
    }

    private func toolButton(_ tool: WorkflowTool) -> some View {
        let isSelected = model.tool == tool
        return Button { model.tool = tool } label: {
            Image(systemName: tool.symbolName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? WispColor.textPrimary : WispColor.textSecondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(isSelected ? WispColor.surface4 : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain).pointerCursor()
        .accessibilityLabel(tool.title)
        .nativeTooltip(tool.title)
    }

    private func iconButton(_ symbol: String, _ label: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isEnabled ? WispColor.textSecondary : WispColor.textTertiary.opacity(0.5))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain).disabled(!isEnabled).pointerCursor()
        .accessibilityLabel(label)
        .nativeTooltip(label)
    }
}

/// "− 100% +", and fit, at the canvas's bottom-left.
struct WorkflowZoomControl: View {
    @ObservedObject var model: WorkflowEditorModel

    var body: some View {
        HStack(spacing: 2) {
            button("minus", "Zoom out  ⌘−") { model.zoomOut() }
            Menu {
                Button("Zoom to fit  ⌘0") { model.fit() }
                Button("Zoom to 100%") { model.resetZoom() }
                Button("Zoom in  ⌘+") { model.zoomIn() }
                Button("Zoom out  ⌘−") { model.zoomOut() }
            } label: {
                Text(model.camera.percentText)
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(WispColor.textSecondary)
                    .frame(width: 46, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().pointerCursor()
            button("plus", "Zoom in  ⌘+") { model.zoomIn() }
            button("arrow.up.left.and.down.right.magnifyingglass", "Zoom to fit  ⌘0") { model.fit() }
        }
        .padding(3)
        .background(Capsule().fill(WispColor.surface2))
        .overlay(Capsule().strokeBorder(WispColor.cardSeparator, lineWidth: 0.75))
    }

    private func button(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(WispColor.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain).pointerCursor()
        .accessibilityLabel(label)
        .nativeTooltip(label)
    }
}
