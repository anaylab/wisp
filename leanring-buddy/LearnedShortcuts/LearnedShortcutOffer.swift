//
//  LearnedShortcutOffer.swift
//  leanring-buddy
//
//  Pure: when a finished turn is worth offering as a learned shortcut, and how the save card's
//  edits (turning a blank back into a constant, rewording the phrase) become the shortcut that
//  is stored. See docs/learned-shortcuts-plan.md ("Recording", "UI").
//
//  An offer is passive: a button next to the answer, never a popup. Nothing is saved without the
//  user's click on the exact steps.
//

import Foundation

/// A turn that could be saved. Held by `CompanionManager` until the next turn starts.
struct LearnedShortcutOffer: Equatable, Sendable {
    let draft: LearnedShortcutDraft
}

enum LearnedShortcutOfferPolicy {
    /// - Parameters:
    ///   - transcript: what the user said or typed, not a history title.
    ///   - isUsersOwnQuestion: false for routine, skill and dictation turns, whose prompt is not the
    ///     user's own words. Only the user's own request can create a shortcut, so a model that read
    ///     a web page can't plant one.
    ///   - existingPhraseTemplates: `canonicalText` of the shortcuts already saved; a phrase that is
    ///     already taken isn't offered again.
    static func offer(
        transcript: String,
        isUsersOwnQuestion: Bool,
        hitIterationCap: Bool,
        toolCalls: [ShortcutRecordedToolCall],
        existingPhraseTemplates: Set<String>
    ) -> LearnedShortcutOffer? {
        guard isUsersOwnQuestion, !hitIterationCap else { return nil }
        guard case .replayable(let draft) = ShortcutReplayability.evaluate(
            transcript: transcript, toolCalls: toolCalls
        ) else { return nil }
        guard !existingPhraseTemplates.contains(draft.phraseTemplate) else { return nil }
        return LearnedShortcutOffer(draft: draft)
    }
}

enum LearnedShortcutDraftEditing {
    enum Problem: Error, Equatable, Sendable {
        case phraseIsNotATemplate
        /// The edited phrase must keep every blank the steps use, once each, and add none.
        case blanksDoNotMatchTheSteps(expected: [String], found: [String])
    }

    /// A blank's example: the words the user said when the shortcut was learned.
    static func exampleValue(forSlotNamed slotName: String, in draft: LearnedShortcutDraft) -> String? {
        exampleValue(forSlotNamed: slotName, inSteps: draft.steps)
    }

    static func exampleValue(forSlotNamed slotName: String, inSteps steps: [LearnedShortcutStep]) -> String? {
        for step in steps {
            for binding in step.slotBindings where binding.slotName == slotName {
                if let exampleText = stringValue(in: step.toolInput, at: binding.argumentPath[...]) {
                    return exampleText
                }
            }
        }
        return nil
    }

    /// Every blank's example, for a replay with nobody to say a new value (a promoted shortcut).
    static func exampleSlotValues(of shortcut: LearnedShortcut) -> [String: String] {
        var exampleValues: [String: String] = [:]
        for slot in shortcut.slots {
            if let exampleText = exampleValue(forSlotNamed: slot.name, inSteps: shortcut.steps) {
                exampleValues[slot.name] = exampleText
            }
        }
        return exampleValues
    }

    /// "arrange_windows" -> "Arrange windows".
    static func toolTitle(forToolNamed toolName: String) -> String {
        toolName.replacingOccurrences(of: "_", with: " ").capitalizedFirstLetter
    }

    /// The draft with only `blankSlotNames` left as blanks; every other blank goes back to being
    /// the words it had when learned ("put {app} on the left" -> "put safari on the left") and
    /// stops being bound. Nil if a demoted blank has no example to put back.
    static func keepingBlanks(_ blankSlotNames: Set<String>, in draft: LearnedShortcutDraft) -> LearnedShortcutDraft? {
        let slotsToDemote = draft.slots.filter { !blankSlotNames.contains($0.name) }
        guard !slotsToDemote.isEmpty else { return draft }

        var phraseText = draft.phraseTemplate
        for slotToDemote in slotsToDemote {
            guard let exampleText = exampleValue(forSlotNamed: slotToDemote.name, in: draft) else { return nil }
            let exampleWords = LearnedShortcutTokenizer.tokens(from: exampleText).map(\.normalizedText)
            phraseText = phraseText.replacingOccurrences(
                of: "{\(slotToDemote.name)}",
                with: exampleWords.joined(separator: " ")
            )
        }
        guard let keptTemplate = LearnedShortcutPhraseTemplate.parse(phraseText) else { return nil }

        let demotedNames = Set(slotsToDemote.map(\.name))
        let keptSteps = draft.steps.map { step in
            LearnedShortcutStep(
                toolName: step.toolName,
                toolInput: step.toolInput,
                slotBindings: step.slotBindings.filter { !demotedNames.contains($0.slotName) }
            )
        }
        return LearnedShortcutDraft(
            phraseTemplate: keptTemplate.canonicalText,
            slots: draft.slots.filter { !demotedNames.contains($0.name) },
            steps: keptSteps
        )
    }

    /// The shortcut for a draft and the phrase text the user ended up with.
    static func shortcut(
        from draft: LearnedShortcutDraft,
        editedPhrase: String,
        spokenConfirmation: String = "done.",
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) -> Result<LearnedShortcut, Problem> {
        guard let editedTemplate = LearnedShortcutPhraseTemplate.parse(editedPhrase) else {
            return .failure(.phraseIsNotATemplate)
        }
        let expectedSlotNames = draft.slots.map(\.name).sorted()
        let foundSlotNames = editedTemplate.slotNames.sorted()
        guard expectedSlotNames == foundSlotNames else {
            return .failure(.blanksDoNotMatchTheSteps(expected: expectedSlotNames, found: foundSlotNames))
        }
        return .success(LearnedShortcut(
            id: id,
            phraseTemplate: editedTemplate.canonicalText,
            slots: draft.slots,
            steps: draft.steps,
            spokenConfirmation: spokenConfirmation,
            createdAt: createdAt
        ))
    }

    /// One plain line per step for the save card: "Move window: app Safari, placement left_half".
    /// Blanks show as the blank's name, since that is what changes between runs.
    static func plainDescription(of step: LearnedShortcutStep) -> String {
        let toolTitle = toolTitle(forToolNamed: step.toolName)
        guard case .object(let arguments) = step.toolInput, !arguments.isEmpty else { return toolTitle }

        let blankedArgumentNames: [String: String] = Dictionary(
            step.slotBindings.compactMap { binding -> (String, String)? in
                guard case .key(let argumentName)? = binding.argumentPath.first, binding.argumentPath.count == 1 else { return nil }
                return (argumentName, binding.slotName)
            },
            uniquingKeysWith: { firstSlotName, _ in firstSlotName }
        )
        let argumentSummaries = arguments.keys.sorted().map { argumentName -> String in
            if let slotName = blankedArgumentNames[argumentName] { return "\(argumentName) {\(slotName)}" }
            return "\(argumentName) \(readableText(of: arguments[argumentName] ?? .null))"
        }
        return "\(toolTitle): \(argumentSummaries.joined(separator: ", "))"
    }

    // MARK: - Private

    /// `JSONValue.compactDescription` raises an Objective-C exception for a bare string or number
    /// (JSONSerialization only writes containers), so scalars are written here.
    private static func readableText(of value: JSONValue) -> String {
        switch value {
        case .null: return "none"
        case .bool(let boolValue): return boolValue ? "true" : "false"
        case .number(let numberValue):
            return numberValue == numberValue.rounded() ? String(Int(numberValue)) : String(numberValue)
        case .string(let text): return "\"\(text)\""
        case .array, .object: return value.compactDescription
        }
    }

    private static func stringValue(
        in value: JSONValue,
        at remainingPath: ArraySlice<LearnedShortcutArgumentPathComponent>
    ) -> String? {
        guard let nextComponent = remainingPath.first else {
            if case .string(let text) = value { return text }
            return nil
        }
        switch (nextComponent, value) {
        case (.key(let key), .object(let objectValue)):
            guard let childValue = objectValue[key] else { return nil }
            return stringValue(in: childValue, at: remainingPath.dropFirst())
        case (.index(let index), .array(let arrayValue)):
            guard arrayValue.indices.contains(index) else { return nil }
            return stringValue(in: arrayValue[index], at: remainingPath.dropFirst())
        default:
            return nil
        }
    }
}

extension String {
    fileprivate var capitalizedFirstLetter: String {
        guard let firstCharacter = first else { return self }
        return firstCharacter.uppercased() + dropFirst()
    }
}
