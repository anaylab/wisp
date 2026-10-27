//
//  LearnedShortcutPromotion.swift
//  leanring-buddy
//
//  Pure: turning a learned shortcut into an automation, and the rule for which triggers a
//  shortcut may have. See docs/learned-shortcuts-plan.md ("Promote to automation").
//
//  A manual automation is attended: its steps may ask for the user's OK like anything else.
//  A scheduled or event automation runs with nobody there, so each step must pass
//  `AutomationToolPolicy.permitsRecordedShortcutStepInUnattendedRun`: it may never ask. Today
//  that leaves only steps like music play/pause; a window move, a reminder or a tab regroup asks,
//  so a shortcut that has one can be promoted to a button or notch chip but not to a schedule.
//

import Foundation

enum LearnedShortcutPromotion {
    enum Verdict: Equatable, Sendable {
        case allowed
        case refused(reason: String)
    }

    /// Why this shortcut cannot run with nobody there, or nil if every step may.
    /// - Parameter toolRequiresConfirmation: whether the named tool asks the user before it
    ///   runs, or nil if no such tool is registered (treated as unsafe).
    static func unattendedProblem(
        for shortcut: LearnedShortcut,
        toolRequiresConfirmation: (String) -> Bool?
    ) -> String? {
        for step in shortcut.steps {
            let toolTitle = LearnedShortcutDraftEditing.toolTitle(forToolNamed: step.toolName)
            guard let requiresConfirmation = toolRequiresConfirmation(step.toolName) else {
                return "\(toolTitle) isn't available, so this can't run on its own."
            }
            guard AutomationToolPolicy.permitsRecordedShortcutStepInUnattendedRun(
                toolName: step.toolName,
                requiresConfirmation: requiresConfirmation
            ) else {
                return "\(toolTitle) asks for your OK each time, so this can't run on its own."
            }
        }
        return nil
    }

    static func verdict(
        for shortcut: LearnedShortcut,
        trigger: AutomationTrigger,
        toolRequiresConfirmation: (String) -> Bool?
    ) -> Verdict {
        guard trigger != .manual else { return .allowed }
        if let problem = unattendedProblem(for: shortcut, toolRequiresConfirmation: toolRequiresConfirmation) {
            return .refused(reason: problem + " Use a button instead.")
        }
        return .allowed
    }

    /// The automation for a shortcut: replay with the values it was saved with, nothing read,
    /// the result in the notch. A scheduled one stays quiet unless it fails.
    static func automation(
        from shortcut: LearnedShortcut,
        trigger: AutomationTrigger,
        now: Date,
        id: UUID = UUID()
    ) -> Automation {
        Automation(
            id: id,
            name: name(for: shortcut),
            buddyID: nil,
            trigger: trigger,
            source: .nothing,
            action: .replayLearnedShortcut(shortcutID: shortcut.id),
            outputs: [.notchCard],
            notify: trigger == .manual ? .always : .onlyOnFailure,
            symbolName: "bolt",
            createdAt: now
        )
    }

    /// The phrase with its blanks filled by the values it was saved with, first letter capitalised.
    static func name(for shortcut: LearnedShortcut) -> String {
        var phraseText = shortcut.phraseTemplate
        for (slotName, exampleText) in LearnedShortcutDraftEditing.exampleSlotValues(of: shortcut) {
            phraseText = phraseText.replacingOccurrences(of: "{\(slotName)}", with: exampleText)
        }
        guard let firstCharacter = phraseText.first else { return "Shortcut" }
        return firstCharacter.uppercased() + phraseText.dropFirst()
    }
}
