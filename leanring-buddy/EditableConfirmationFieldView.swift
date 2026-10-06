//
//  EditableConfirmationFieldView.swift
//  leanring-buddy
//
//  One editable field on the tool-confirmation card — a subject, a message
//  body, an event title — drawn to read like the card's own text until the
//  pointer finds it: hover brings up a faint fill, a pencil and the I-beam;
//  focus adds a border. A changed field carries a small "edited" mark, so it
//  is obvious at a glance that what will run is not what the model wrote.
//
//  Which fields exist, and the rule that edits can only touch them, live in
//  `EditableConfirmationFields`; the typed text lives in
//  `ToolConfirmationCoordinator` (so a spoken "yes" approves it too). This
//  view only shows and reports.
//
//  Keys: Return in a single-line field does nothing (no default button sits
//  behind it, so it can't approve by accident); a multi-line body takes
//  Return as a new line; Cmd-Return is Allow, bound on the button.
//

import AppKit
import SwiftUI

struct EditableConfirmationFieldView: View {
    let editableField: EditableConfirmationField
    /// The text now in the field: the user's edit, or the original.
    let currentText: String
    let onTextChange: (String) -> Void
    /// Focusing the field counts as working on it, so the prompt's timeout
    /// is pushed out before the first keystroke, not after.
    let onEditingActivity: () -> Void

    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    private var isEdited: Bool { currentText != editableField.originalText }

    private var textBinding: Binding<String> {
        Binding(get: { currentText }, set: { onTextChange($0) })
    }

    var body: some View {
        let fieldShape = RoundedRectangle(cornerRadius: WispRadius.medium, style: .continuous)

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: WispSpacing.xs) {
                Text(editableField.label)
                    .font(WispFont.caption)
                    .foregroundColor(WispColor.OnGlass.textSecondary)
                if isEdited {
                    EditedConfirmationFieldMark()
                        .transition(.opacity)
                }
                Spacer(minLength: WispSpacing.xs)
                // The affordance: invisible at rest so the card still reads
                // as a card, there the moment the pointer or focus arrives.
                Image(systemName: "pencil")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(WispColor.OnGlass.textTertiary)
                    .opacity(isHovered || isFocused ? 1 : 0)
            }
            textEditor
        }
        .padding(.horizontal, WispSpacing.sm)
        .padding(.vertical, WispSpacing.xs + 2)
        .background(
            fieldShape.fill(isFocused || isHovered ? WispColor.OnGlass.chipFill : Color.clear)
        )
        .overlay(
            fieldShape.strokeBorder(
                isFocused ? WispColor.OnGlass.borderStrong : Color.clear,
                lineWidth: 0.75
            )
        )
        .contentShape(fieldShape)
        // A click anywhere on the row (the label, the padding) goes to the field.
        .onTapGesture { isFocused = true }
        .onHover { hovering in
            isHovered = hovering
            if hovering { NSCursor.iBeam.push() } else { NSCursor.pop() }
        }
        .onChange(of: isFocused) { _, isNowFocused in
            if isNowFocused { onEditingActivity() }
        }
        .animation(WispMotion.quick, value: isHovered)
        .animation(WispMotion.quick, value: isFocused)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(editableField.label), editable")
    }

    @ViewBuilder
    private var textEditor: some View {
        if editableField.isMultiline {
            TextEditor(text: textBinding)
                .font(WispFont.callout)
                .foregroundColor(WispColor.OnGlass.textPrimary)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .focused($isFocused)
                // TextEditor's own inset, removed so the text lines up with
                // the label and with the card's text above it.
                .padding(.horizontal, -5)
                .frame(minHeight: 36, maxHeight: 96)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            TextField("", text: textBinding)
                .textFieldStyle(.plain)
                .font(WispFont.bodyMedium)
                .foregroundColor(WispColor.OnGlass.textPrimary)
                .focused($isFocused)
                .lineLimit(1)
        }
    }
}

/// The small "edited" capsule on a changed field — here, and beside the
/// message bubble on the Siri-style send panel.
struct EditedConfirmationFieldMark: View {
    var body: some View {
        Text("edited")
            .font(WispFont.overline)
            .foregroundColor(WispColor.Brand.lavender)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(WispColor.Brand.lavender.opacity(0.16)))
    }
}
