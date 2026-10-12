//
//  MCPToolResultRendering.swift
//  leanring-buddy
//
//  Turns an MCP tool result into the text the model reads.
//
//  An MCP result has two halves: `content` (typed blocks — text, images) and,
//  since the 2025-06-18 protocol, an optional `structuredContent` object. Wisp
//  used to keep only the text blocks, which loses everything a server puts on
//  the structured side. cua-driver is the case that made it matter: the
//  `element_token` every click, type and set_value needs exists *only* in
//  `structuredContent.elements[]`, so a model reading the text alone could see
//  the Send button but never press it.
//
//  This is generic MCP behaviour, not cua-specific:
//  - A result without `structuredContent` is returned exactly as before.
//  - A structured list of UI elements (objects carrying a token/id and a role)
//    becomes one short line per element — `s1a2b3c4d:17 Button "Send"` — since
//    the same tree as raw JSON is ~10x larger (37 KB for 74 elements).
//  - Anything else becomes compact JSON.
//  Both are capped, like the other tool results Wisp hands back (the screen
//  text tool stops at 4000 characters), because every result is pushed into a
//  context window shared with a screenshot.
//

import Foundation

enum MCPToolResultRendering {

    // MARK: - Limits

    /// The structured half of a result, once rendered. Matches the screen-text
    /// tool's 4000, the largest result Wisp's own tools return.
    static let maximumStructuredContentCharacters = 4000

    /// Text blocks shown after a structured rendering share what is left of
    /// this budget, so one result can't crowd out the rest of the turn.
    static let maximumCombinedResultCharacters = 5000

    /// When the structured side is an element list, the text blocks are
    /// usually the same tree drawn as markdown — strictly less useful than
    /// the element lines, which also carry the tokens. Only their opening
    /// (a summary line, a warning) is kept.
    static let maximumTextCharactersBesideElementList = 500

    /// A long label or value is cut here; the line only has to identify the
    /// element, not reproduce a paragraph of text.
    static let maximumElementLabelCharacters = 80
    static let maximumElementValueCharacters = 60

    /// Top-level scalar fields longer than this (a whole markdown tree, a
    /// base64 blob) are left out of the header line.
    private static let maximumHeaderFieldCharacters = 200

    // MARK: - Element field vocabularies

    /// The keys an element's handle may live under, most specific first.
    static let elementIdentifierKeys = ["element_token", "token", "ref", "element_id", "id"]
    static let elementRoleKeys = ["role", "type"]
    static let elementLabelKeys = ["label", "title", "name", "description"]
    static let elementValueKeys = ["value"]

    // MARK: - Entry point

    /// The text the model sees for one successful tool result.
    ///
    /// - Parameters:
    ///   - flattenedContentText: The `content` blocks as Wisp has always
    ///     flattened them (text kept, other kinds named).
    ///   - structuredContent: The result's `structuredContent`, if any.
    static func modelText(flattenedContentText: String, structuredContent: JSONValue?) -> String {
        // No structured side: exactly the old behaviour, so a server that
        // never sends it is unaffected by any of this.
        guard let structuredContent, structuredContent != .null else {
            return flattenedContentText.isEmpty ? "(the tool returned nothing)" : flattenedContentText
        }

        let isElementList = elementList(in: structuredContent) != nil
        let renderedStructuredText = renderedStructuredContent(structuredContent)

        // The spec asks servers that send structured content to repeat it as
        // JSON in a text block for older clients. Showing both would say the
        // same thing twice, so a text block that *is* the structured content
        // is dropped.
        let trimmedContentText = flattenedContentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let contentTextRepeatsStructuredContent = textIsJSON(trimmedContentText, equalTo: structuredContent)

        var resultSections: [String] = [renderedStructuredText]
        if !trimmedContentText.isEmpty && !contentTextRepeatsStructuredContent {
            let remainingCharacterBudget = maximumCombinedResultCharacters - renderedStructuredText.count
            let contentTextBudget = isElementList
                ? min(maximumTextCharactersBesideElementList, remainingCharacterBudget)
                : remainingCharacterBudget
            if contentTextBudget > 0 {
                resultSections.append(truncated(trimmedContentText, maximumCharacters: contentTextBudget))
            }
        }
        return resultSections.joined(separator: "\n\n")
    }

    /// The structured content alone, rendered and capped: element lines when
    /// it holds an element list, compact JSON otherwise.
    static func renderedStructuredContent(_ structuredContent: JSONValue) -> String {
        if let renderedElementList = renderedElementList(structuredContent) {
            return renderedElementList
        }
        return truncated(compactJSONText(structuredContent), maximumCharacters: maximumStructuredContentCharacters)
    }

    // MARK: - Element lists

    /// The element list inside a structured result: the first top-level array
    /// (preferring one named `elements`) whose items are objects carrying both
    /// a role and an identifier. Returns the key it was found under so the
    /// header can leave it out.
    static func elementList(in structuredContent: JSONValue) -> (key: String, elements: [[String: JSONValue]])? {
        guard case .object(let topLevelFields) = structuredContent else { return nil }

        // Sorted so the same result always picks the same list.
        let candidateKeys = ["elements"] + topLevelFields.keys.sorted().filter { $0 != "elements" }
        for candidateKey in candidateKeys {
            guard case .array(let candidateItems)? = topLevelFields[candidateKey], !candidateItems.isEmpty else { continue }
            let candidateObjects: [[String: JSONValue]] = candidateItems.compactMap { candidateItem in
                guard case .object(let itemFields) = candidateItem else { return nil }
                return itemFields
            }
            guard candidateObjects.count == candidateItems.count else { continue }
            let looksLikeElements = candidateObjects.contains { itemFields in
                firstScalarText(forAnyOf: elementRoleKeys, in: itemFields) != nil
                    && firstScalarText(forAnyOf: elementIdentifierKeys, in: itemFields) != nil
            }
            if looksLikeElements { return (candidateKey, candidateObjects) }
        }
        return nil
    }

    /// One line per element under a header of the result's short scalar
    /// fields, or nil when the result holds no element list.
    static func renderedElementList(_ structuredContent: JSONValue) -> String? {
        guard case .object(let topLevelFields) = structuredContent,
              let (elementListKey, elements) = elementList(in: structuredContent) else { return nil }

        var renderedLines: [String] = []
        let headerLine = headerLine(for: topLevelFields, excludingKey: elementListKey)
        if !headerLine.isEmpty { renderedLines.append(headerLine) }
        renderedLines.append("\(elements.count) elements (token role \"label\" = value):")

        var renderedCharacterCount = renderedLines.reduce(0) { $0 + $1.count + 1 }
        var shownElementCount = 0
        for elementFields in elements {
            let elementLine = renderedElementLine(elementFields)
            // Leave room for the "… more" line so the cap is never exceeded.
            let roomNeededForOmissionNote = 60
            if renderedCharacterCount + elementLine.count + 1 + roomNeededForOmissionNote > maximumStructuredContentCharacters {
                break
            }
            renderedLines.append(elementLine)
            renderedCharacterCount += elementLine.count + 1
            shownElementCount += 1
        }
        let omittedElementCount = elements.count - shownElementCount
        if omittedElementCount > 0 {
            renderedLines.append("…(\(omittedElementCount) more elements not shown)")
        }
        return renderedLines.joined(separator: "\n")
    }

    /// `s00000001:3 Button "Hide sidebar"`, plus `= "value"` and `(disabled)`
    /// when they apply. The `AX` prefix on macOS roles is dropped — it is on
    /// every role and says nothing.
    static func renderedElementLine(_ elementFields: [String: JSONValue]) -> String {
        var lineParts: [String] = []
        lineParts.append(firstScalarText(forAnyOf: elementIdentifierKeys, in: elementFields) ?? "-")
        if let roleText = firstScalarText(forAnyOf: elementRoleKeys, in: elementFields) {
            lineParts.append(readableRoleName(roleText))
        }
        if let labelText = firstScalarText(forAnyOf: elementLabelKeys, in: elementFields) {
            let collapsedLabel = collapsedWhitespace(labelText)
            if !collapsedLabel.isEmpty {
                lineParts.append(quoted(shortened(collapsedLabel, maximumCharacters: maximumElementLabelCharacters)))
            }
        }
        if let valueText = firstScalarText(forAnyOf: elementValueKeys, in: elementFields) {
            let collapsedValue = collapsedWhitespace(valueText)
            if !collapsedValue.isEmpty {
                lineParts.append("= " + quoted(shortened(collapsedValue, maximumCharacters: maximumElementValueCharacters)))
            }
        }
        if case .bool(false)? = elementFields["enabled"] {
            lineParts.append("(disabled)")
        }
        return lineParts.joined(separator: " ")
    }

    /// `AXButton` → `Button`; any other role is kept as the server wrote it.
    static func readableRoleName(_ roleText: String) -> String {
        guard roleText.hasPrefix("AX"), roleText.count > 2 else { return roleText }
        let roleWithoutPrefix = roleText.dropFirst(2)
        guard let firstCharacter = roleWithoutPrefix.first, firstCharacter.isUppercase else { return roleText }
        return String(roleWithoutPrefix)
    }

    /// `app_name="Mail" window_id=123 truncated=true` — the result's short
    /// scalar fields in key order. Long strings (a markdown dump) and fields
    /// starting with `_` (server notes to developers) are left out.
    private static func headerLine(for topLevelFields: [String: JSONValue], excludingKey excludedKey: String) -> String {
        var headerParts: [String] = []
        for fieldKey in topLevelFields.keys.sorted() where fieldKey != excludedKey && !fieldKey.hasPrefix("_") {
            guard let fieldValue = topLevelFields[fieldKey] else { continue }
            switch fieldValue {
            case .string(let stringValue):
                let collapsedValue = collapsedWhitespace(stringValue)
                guard !collapsedValue.isEmpty, collapsedValue.count <= maximumHeaderFieldCharacters else { continue }
                headerParts.append("\(fieldKey)=\(quoted(collapsedValue))")
            case .number, .bool:
                headerParts.append("\(fieldKey)=\(compactJSONText(fieldValue))")
            default:
                continue
            }
        }
        return headerParts.joined(separator: " ")
    }

    // MARK: - Helpers

    /// The first of the keys present as a string, number or bool, as text.
    static func firstScalarText(forAnyOf candidateKeys: [String], in fields: [String: JSONValue]) -> String? {
        for candidateKey in candidateKeys {
            switch fields[candidateKey] {
            case .string(let stringValue)?:
                return stringValue
            case .number?, .bool?:
                return fields[candidateKey].map(compactJSONText)
            default:
                continue
            }
        }
        return nil
    }

    /// One-line JSON with sorted keys, so the same result always reads the
    /// same (and the prompt cache sees identical bytes).
    static func compactJSONText(_ value: JSONValue) -> String {
        guard let data = try? JSONSerialization.data(
                withJSONObject: value.untypedValue,
                options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
              ),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: value.untypedValue)
        }
        return text
    }

    /// Whether a text block parses as JSON equal to the structured content.
    private static func textIsJSON(_ text: String, equalTo structuredContent: JSONValue) -> Bool {
        guard let firstCharacter = text.first, firstCharacter == "{" || firstCharacter == "[",
              let textData = text.data(using: .utf8),
              let parsedObject = try? JSONSerialization.jsonObject(with: textData, options: [.fragmentsAllowed]) else {
            return false
        }
        return JSONValue(untypedValue: parsedObject) == structuredContent
    }

    private static func collapsedWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Wraps text in double quotes, escaping any quote inside it so the line
    /// can't be misread as ending the label early.
    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Cuts a label or value at the limit with an ellipsis. Unlike
    /// `truncated`, no character count — on a one-line element it would be
    /// longer than the label it replaces.
    static func shortened(_ text: String, maximumCharacters: Int) -> String {
        guard text.count > maximumCharacters else { return text }
        return String(text.prefix(maximumCharacters)) + "…"
    }

    /// Cuts text at the limit and says so, the way Wisp's other long tool
    /// results are cut.
    static func truncated(_ text: String, maximumCharacters: Int) -> String {
        guard text.count > maximumCharacters else { return text }
        let truncationNote = "…(truncated, \(text.count) characters total)"
        let keptCharacterCount = max(0, maximumCharacters - truncationNote.count - 1)
        return String(text.prefix(keptCharacterCount)) + "\n" + truncationNote
    }
}
