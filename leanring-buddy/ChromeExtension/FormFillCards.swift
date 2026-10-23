//
//  FormFillCards.swift
//  leanring-buddy
//
//  The form helper's tool name, the shape of its prepared input, its
//  confirmation card and the card's editable rows (phase 12). Kept apart from
//  the main-actor code in `ChromeFormFill.swift` because `ToolCallSafety`,
//  `ToolConfirmationCardBuilder` and `EditableConfirmationFields` name them, and
//  the standalone suites that compile those compile this file too.
//
//  The prepared input is built by Swift from the form the extension described
//  and the user's own sources, never from the model's arguments:
//
//      {"tab_id": 7, "page_url": "...", "page_host": "club.example", "form_label": "...",
//       "fields": [{"id": "e3", "label": "First name", "multiline": false, "source": "your Me card"}, …],
//       "value_e3": "Ada", …,
//       "refused": [{"label": "Password", "reason": "passwords"}, …],
//       "for_the_user": ["Referral code", …], "already_filled": [...], "other_fields": [...]}
//
//  Each proposed value is a top-level `value_<id>` string, so the card's one
//  rule for edits (`EditableConfirmationFields.applyingEdits`, top-level strings
//  only, re-derived from the input that was asked about) is what lets the user
//  change a value — and nothing else: not which fields, not the tab, not the page.
//

import Foundation

nonisolated enum FormFillToolNames {
    static let fillForm = "fill_form"
}

enum FormFillCards {

    static let valueKeyPrefix = "value_"
    static let footnoteText = "Wisp won't submit — check it, then press the page's own button."
    /// Rows listed per "won't fill" / "you'll fill" block before "and N more".
    static let maximumListedRows = 8

    /// A proposed field, as the prepared input lists it.
    struct ProposedField: Equatable {
        let elementID: String
        let label: String
        let isMultiline: Bool
        let sourceName: String
        let value: String

        var valueKey: String { FormFillCards.valueKeyPrefix + elementID }
    }

    // MARK: - The prepared input

    static func preparedToolInput(
        plan: FormFillPlan,
        tabID: Int,
        pageURL: String,
        formLabel: String?
    ) -> JSONValue {
        var fields: [String: JSONValue] = [
            "tab_id": .number(Double(tabID)),
            "page_url": .string(pageURL),
            "page_host": .string(URL(string: pageURL)?.host ?? ""),
            "form_label": .string(formLabel ?? ""),
        ]
        fields["fields"] = .array(plan.proposals.map { proposal in
            .object([
                "id": .string(proposal.fieldID),
                "label": .string(proposal.label),
                "multiline": .bool(proposal.isMultiline),
                "source": .string(proposal.sourceName),
            ])
        })
        for proposal in plan.proposals {
            fields[valueKeyPrefix + proposal.fieldID] = .string(proposal.value)
        }
        fields["refused"] = .array(plan.refusedFields.map { refused in
            .object(["label": .string(refused.label), "reason": .string(refused.reason.plainWords)])
        })
        fields["for_the_user"] = .array(plan.fieldsForTheUser.map(JSONValue.string))
        fields["already_filled"] = .array(plan.alreadyFilledFields.map(JSONValue.string))
        fields["other_fields"] = .array(plan.otherFields.map(JSONValue.string))
        return .object(fields)
    }

    /// The proposed fields with their (possibly edited) values. A field whose
    /// value is missing, or whose id isn't an `e` id, is dropped — the input
    /// came from Swift, so that only happens if something tampered with it.
    static func proposedFields(in toolInput: JSONValue) -> [ProposedField] {
        guard case .object(let inputFields) = toolInput, case .array(let fieldValues)? = inputFields["fields"] else { return [] }
        var proposedFields: [ProposedField] = []
        var seenElementIDs: Set<String> = []
        for fieldValue in fieldValues {
            guard case .object(let fieldDetails) = fieldValue,
                  case .string(let elementID)? = fieldDetails["id"],
                  elementID.range(of: #"^e\d{1,9}$"#, options: .regularExpression) != nil,
                  !seenElementIDs.contains(elementID),
                  case .string(let value)? = inputFields[valueKeyPrefix + elementID] else { continue }
            seenElementIDs.insert(elementID)
            var label = ""
            if case .string(let labelText)? = fieldDetails["label"] { label = labelText }
            var isMultiline = false
            if case .bool(let multilineFlag)? = fieldDetails["multiline"] { isMultiline = multilineFlag }
            var sourceName = ""
            if case .string(let sourceText)? = fieldDetails["source"] { sourceName = sourceText }
            proposedFields.append(ProposedField(
                elementID: elementID, label: label, isMultiline: isMultiline, sourceName: sourceName, value: value
            ))
        }
        return proposedFields
    }

    /// The labels each proposed field shows on the card, made unique ("Email",
    /// "Email (2)") so an edit box replaces exactly its own row.
    static func cardLabels(for proposedFields: [ProposedField]) -> [String] {
        var countsByLabel: [String: Int] = [:]
        return proposedFields.map { proposedField in
            let baseLabel = proposedField.label.isEmpty ? "Field" : proposedField.label
            let count = (countsByLabel[baseLabel] ?? 0) + 1
            countsByLabel[baseLabel] = count
            return count == 1 ? baseLabel : "\(baseLabel) (\(count))"
        }
    }

    // MARK: - The card

    static func confirmationCard(toolInput: JSONValue) -> GlanceCard {
        let proposedFields = proposedFields(in: toolInput)
        let host = ToolCallInspection.stringValue(forAnyOf: ["page_host"], in: toolInput) ?? ""
        var blocks: [GlanceBlock] = [
            .header(title: "Fill This Form", iconName: "square.and.pencil", trailingText: host.isEmpty ? nil : host)
        ]
        if !proposedFields.isEmpty {
            let labels = cardLabels(for: proposedFields)
            blocks.append(.keyValue(pairs: zip(labels, proposedFields).map { label, proposedField in
                GlanceKeyValuePair(
                    key: label,
                    value: ToolConfirmationCardBuilder.truncatedPreview(
                        proposedField.value, maximumCharacters: ToolConfirmationCardBuilder.maximumFieldValueCharacters
                    ),
                    tone: .neutral
                )
            }))
        }

        var noteRows: [GlanceListRow] = []
        let refusedRows = objectRows(named: "refused", in: toolInput).map { refused in
            "Won't fill \(refused["label"] ?? "a field") (\(refused["reason"] ?? "private"))"
        }
        noteRows += listedRows(refusedRows, iconName: "xmark.circle", tone: .bad)
        let rowsForTheUser = stringRows(named: "for_the_user", in: toolInput).map { "You'll fill \($0)" }
        noteRows += listedRows(rowsForTheUser, iconName: "pencil", tone: .neutral)
        let alreadyFilled = stringRows(named: "already_filled", in: toolInput)
        if !alreadyFilled.isEmpty {
            noteRows.append(GlanceListRow(
                text: "Left as you typed: " + alreadyFilled.prefix(maximumListedRows).joined(separator: ", "),
                iconName: "checkmark.circle", tone: .neutral
            ))
        }
        noteRows.append(GlanceListRow(text: footnoteText, iconName: "info.circle", tone: .neutral))
        blocks.append(.list(rows: noteRows))
        return GlanceCard(blocks: blocks)
    }

    // MARK: - Editable rows

    /// One editable row per proposed value. The key is the exact top-level
    /// `value_<id>`, so an edit can only ever change a value Wisp proposed.
    static func editableFields(toolInput: JSONValue) -> [EditableConfirmationField] {
        let proposedFields = proposedFields(in: toolInput)
        return zip(cardLabels(for: proposedFields), proposedFields).map { label, proposedField in
            EditableConfirmationField(
                argumentKey: proposedField.valueKey,
                label: label,
                originalText: proposedField.value,
                isMultiline: proposedField.isMultiline,
                replacedCardRowLabel: label
            )
        }
    }

    // MARK: - Reading the note lists

    private static func listedRows(_ texts: [String], iconName: String, tone: GlanceTone) -> [GlanceListRow] {
        var rows = texts.prefix(maximumListedRows).map { GlanceListRow(text: $0, iconName: iconName, tone: tone) }
        if texts.count > maximumListedRows {
            rows.append(GlanceListRow(text: "and \(texts.count - maximumListedRows) more", iconName: nil, tone: .neutral))
        }
        return rows
    }

    private static func stringRows(named key: String, in toolInput: JSONValue) -> [String] {
        guard case .object(let inputFields) = toolInput, case .array(let values)? = inputFields[key] else { return [] }
        return values.compactMap { value in
            if case .string(let text) = value { return text }
            return nil
        }
    }

    private static func objectRows(named key: String, in toolInput: JSONValue) -> [[String: String]] {
        guard case .object(let inputFields) = toolInput, case .array(let values)? = inputFields[key] else { return [] }
        return values.compactMap { value in
            guard case .object(let rowFields) = value else { return nil }
            var row: [String: String] = [:]
            for (rowKey, rowValue) in rowFields {
                if case .string(let text) = rowValue { row[rowKey] = text }
            }
            return row
        }
    }
}
