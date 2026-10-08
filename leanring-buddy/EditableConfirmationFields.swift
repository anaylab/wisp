//
//  EditableConfirmationFields.swift
//  leanring-buddy
//
//  Which fields of a pending tool call the user may edit on the confirmation
//  card before allowing it, and how those edits are applied to the call's
//  arguments. Pure and deterministic, so the whole rule is testable without
//  a panel, a model or a user (`Tests/EditableConfirmation`).
//
//  Why only some fields: the card is a consent step. Fixing the wording of a
//  subject line, a message or an event title changes *what is said*, which is
//  the user's to decide. Changing *who* it goes to or *where* it lands — a
//  recipient, a handle, a path, a URL, a command — would change what the
//  consent and `ToolCallSafety`'s destructive-action floor were judged
//  against, so those stay read-only. That is enforced here, not in the view:
//  `applyingEdits` re-derives the editable set from the very input that was
//  asked about and ignores any edit to a key outside it, so nothing upstream
//  (a view bug, a stale edit, a key from another call) can rewrite a field
//  the user was not shown as editable. The tool name is never touched.
//
//  Only top-level string arguments are ever editable. Composio's gateway
//  wraps the real calls in nested arguments; its batches stay read-only.
//

import Foundation

/// One field the confirmation card offers as an editable text box.
struct EditableConfirmationField: Identifiable, Equatable {
    /// The key exactly as spelled in the tool input (`Subject`, `message`),
    /// found leniently but written back verbatim.
    let argumentKey: String
    /// What the card calls it: "Subject", "Message", "Title".
    let label: String
    /// The value the model wrote, untouched.
    let originalText: String
    /// Bodies and messages get a multi-line box; titles a single line.
    let isMultiline: Bool
    /// The label of the card's key/value row that shows this field, so the
    /// panel can draw the field in its place rather than twice. Nil for a
    /// body, which the card shows as a preview line rather than a row.
    let replacedCardRowLabel: String?

    var id: String { argumentKey }
}

/// One field the user actually changed, as it will run.
struct EditedConfirmationField: Equatable {
    let argumentKey: String
    let label: String
    let editedText: String
}

/// A tool input after the user's edits, and which fields those edits changed.
struct AppliedConfirmationEdits: Equatable {
    /// The input to run. Identical to the input asked about when nothing changed.
    let toolInput: JSONValue
    /// Empty when nothing changed.
    let editedFields: [EditedConfirmationField]

    var hasEdits: Bool { !editedFields.isEmpty }
}

enum EditableConfirmationFields {

    /// `create_reminder` is registered by name in `AgentToolRegistry` with
    /// no shared constant; its title is the one human-text field it has.
    static let createReminderToolName = "create_reminder"

    /// How much of an edited value is quoted back to the model in the tool
    /// result. Enough for the model to know what was actually sent.
    static let maximumEditedTextCharactersInToolResult = 300

    // MARK: - Which fields

    /// The fields of this call the card may offer for editing — empty for
    /// every call that has none (reads, file writes, deletions, Composio
    /// batches, unrecognised shapes).
    static func editableFields(forToolNamed toolName: String, toolInput: JSONValue) -> [EditableConfirmationField] {
        guard case .object = toolInput else { return [] }
        let bareToolName = ToolCallInspection.bareToolName(toolName)

        // Composio's gateway carries the real calls nested inside its own
        // arguments; nothing in them is offered for editing.
        if ToolCallInspection.isComposioMetaTool(bareToolName: bareToolName) { return [] }

        let candidateFields: [CandidateField]
        switch bareToolName {
        // Matched by bare name, as `ToolConfirmationCardBuilder` matches them.
        case MessagingToolNames.sendIMessage:
            candidateFields = [CandidateField(label: "Message", candidateKeys: ["message"], isMultiline: true, replacedCardRowLabel: nil)]
        case ShortcutsToolRouting.runShortcutToolName:
            candidateFields = [CandidateField(label: "Input", candidateKeys: ["input"], isMultiline: true, replacedCardRowLabel: "Input")]
        case createReminderToolName:
            candidateFields = [CandidateField(label: "Title", candidateKeys: ["title"], isMultiline: false, replacedCardRowLabel: "Title")]
        default:
            candidateFields = candidateFieldsForCardShape(toolName: toolName, toolInput: toolInput)
        }

        var editableFields: [EditableConfirmationField] = []
        for candidateField in candidateFields {
            guard let argumentKey = ToolCallInspection.matchingFieldKey(forAnyOf: candidateField.candidateKeys, in: toolInput),
                  // One key is one field, even if two labels could claim it.
                  !editableFields.contains(where: { $0.argumentKey == argumentKey }),
                  case .object(let argumentFields) = toolInput,
                  // Only a plain string is human text. A number, a list of
                  // people or a nested object is left read-only.
                  case .string(let originalText)? = argumentFields[argumentKey] else { continue }
            editableFields.append(EditableConfirmationField(
                argumentKey: argumentKey,
                label: candidateField.label,
                originalText: originalText,
                isMultiline: candidateField.isMultiline,
                replacedCardRowLabel: candidateField.replacedCardRowLabel
            ))
        }
        return editableFields
    }

    /// A field the card's shape could offer, before checking the input has it.
    private struct CandidateField {
        let label: String
        let candidateKeys: [String]
        let isMultiline: Bool
        let replacedCardRowLabel: String?
    }

    /// The text fields of the card shape the call was drawn as. Only the
    /// shapes that compose words for people — email, message/post, calendar
    /// event — have any; the key vocabularies are the card builder's own, so
    /// a field is editable exactly when it is the one the card shows.
    private static func candidateFieldsForCardShape(toolName: String, toolInput: JSONValue) -> [CandidateField] {
        let inspectedActions = ToolCallInspection.inspectedActions(toolName: toolName, toolInput: toolInput)
        // A wrapper that unwrapped into several calls (or into one call whose
        // arguments are not this input) is not edited.
        guard inspectedActions.count == 1,
              let onlyAction = inspectedActions.first,
              onlyAction.arguments == toolInput,
              let cardShape = ToolConfirmationCardBuilder.confirmationCardShape(for: onlyAction) else { return [] }

        switch cardShape {
        case .email:
            return [
                CandidateField(label: "Subject", candidateKeys: ToolConfirmationCardBuilder.subjectKeys, isMultiline: false, replacedCardRowLabel: "Subject"),
                CandidateField(label: "Body", candidateKeys: ToolConfirmationCardBuilder.bodyKeys, isMultiline: true, replacedCardRowLabel: nil),
            ]
        case .messageOrPost:
            return [
                CandidateField(label: "Title", candidateKeys: ToolConfirmationCardBuilder.postTitleKeys, isMultiline: false, replacedCardRowLabel: "Title"),
                CandidateField(label: "Text", candidateKeys: ToolConfirmationCardBuilder.bodyKeys, isMultiline: true, replacedCardRowLabel: nil),
            ]
        case .calendarEvent:
            return [
                CandidateField(label: "Title", candidateKeys: ToolConfirmationCardBuilder.eventTitleKeys, isMultiline: false, replacedCardRowLabel: "Title"),
                CandidateField(label: "Location", candidateKeys: ToolConfirmationCardBuilder.eventLocationKeys, isMultiline: false, replacedCardRowLabel: "Where"),
            ]
        case .fileWrite, .deletion, .otherIrreversibleAction:
            return []
        }
    }

    // MARK: - Applying edits

    /// The input with the user's edits applied — only to fields
    /// `editableFields` offers for *this* call and input.
    ///
    /// - Parameter editedTextsByArgumentKey: What the user typed, by exact
    ///   argument key. A key that is not an editable field of this call is
    ///   ignored, as is an edit that leaves a field blank (an emptied subject
    ///   or message is far more likely a slip than an intent, and the tool
    ///   would refuse or send nothing) or that matches the original.
    static func applyingEdits(
        _ editedTextsByArgumentKey: [String: String],
        toToolInput toolInput: JSONValue,
        toolNamed toolName: String
    ) -> AppliedConfirmationEdits {
        let unchanged = AppliedConfirmationEdits(toolInput: toolInput, editedFields: [])
        guard !editedTextsByArgumentKey.isEmpty, case .object(var argumentFields) = toolInput else { return unchanged }

        var editedFields: [EditedConfirmationField] = []
        for editableField in editableFields(forToolNamed: toolName, toolInput: toolInput) {
            guard let editedText = editedTextsByArgumentKey[editableField.argumentKey],
                  !editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  editedText != editableField.originalText else { continue }
            argumentFields[editableField.argumentKey] = .string(editedText)
            editedFields.append(EditedConfirmationField(
                argumentKey: editableField.argumentKey,
                label: editableField.label,
                editedText: editedText
            ))
        }
        guard !editedFields.isEmpty else { return unchanged }
        return AppliedConfirmationEdits(toolInput: .object(argumentFields), editedFields: editedFields)
    }

    // MARK: - Telling the model

    /// A line appended to the tool's result when the user edited the call,
    /// so the model reports what actually ran instead of claiming its own
    /// wording went out. Nil when nothing was edited.
    static func toolResultNote(for editedFields: [EditedConfirmationField]) -> String? {
        guard !editedFields.isEmpty else { return nil }
        let editedFieldDescriptions = editedFields.map { editedField in
            "\(editedField.label.lowercased()): \"\(clippedForToolResult(editedField.editedText))\""
        }
        return "(the user edited this on the confirmation card before allowing it, so it ran with their wording, not yours — "
            + editedFieldDescriptions.joined(separator: "; ")
            + ". describe it as they wrote it.)"
    }

    private static func clippedForToolResult(_ editedText: String) -> String {
        guard editedText.count > maximumEditedTextCharactersInToolResult else { return editedText }
        return String(editedText.prefix(maximumEditedTextCharactersInToolResult)) + "…"
    }

    // MARK: - The card beside the fields

    /// The confirmation card with the rows that the editable fields now show
    /// removed, so a subject or a body is not drawn twice — once as a row and
    /// once as the box that edits it. A body is matched by its preview line
    /// (the card builder's own truncation of the same text).
    static func card(_ confirmationCard: GlanceCard, hidingRowsShownBy editableFields: [EditableConfirmationField]) -> GlanceCard {
        guard !editableFields.isEmpty else { return confirmationCard }
        let replacedRowLabels = Set(editableFields.compactMap(\.replacedCardRowLabel))
        let replacedBodyPreviewTexts = Set(editableFields.filter { $0.replacedCardRowLabel == nil }.map { editableField in
            ToolConfirmationCardBuilder.truncatedPreview(
                editableField.originalText,
                maximumCharacters: ToolConfirmationCardBuilder.maximumBodyPreviewCharacters
            )
        })

        var remainingBlocks: [GlanceBlock] = []
        for block in confirmationCard.blocks {
            switch block {
            case .keyValue(let pairs):
                let remainingPairs = pairs.filter { !replacedRowLabels.contains($0.key) }
                if !remainingPairs.isEmpty { remainingBlocks.append(.keyValue(pairs: remainingPairs)) }
            case .list(let rows):
                // Only an icon-less row is a body preview; warning rows keep their icon.
                let remainingRows = rows.filter { row in
                    !(row.iconName == nil && replacedBodyPreviewTexts.contains(row.text))
                }
                if !remainingRows.isEmpty { remainingBlocks.append(.list(rows: remainingRows)) }
            case .header, .stats:
                remainingBlocks.append(block)
            }
        }
        return GlanceCard(id: confirmationCard.id, blocks: remainingBlocks)
    }
}
