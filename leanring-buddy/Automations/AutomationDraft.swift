//
//  AutomationDraft.swift
//  leanring-buddy
//
//  The editable card every setup path ends on: "say it" (the parser), a template, or "save as
//  automation" on a History answer. A draft is not an automation yet. It also carries which
//  fields the parser had to guess, so the card can highlight them.
//
//  Pure (Foundation only).
//

import Foundation

/// A buddy as the parser sees it: enough to pick an owner without touching `BuddyStore`.
nonisolated struct AutomationBuddyReference: Equatable, Sendable {
    let id: UUID
    let name: String
    let specialty: BuddySpecialty?
}

nonisolated enum AutomationDraftField: String, CaseIterable, Sendable {
    case name, trigger, source, output, buddy, notify
}

nonisolated struct AutomationDraft: Equatable, Sendable {
    var originalText: String
    var name: String
    var buddyID: UUID?
    var trigger: AutomationTrigger
    var source: AutomationSource
    var action: AutomationAction
    var outputs: [AutomationOutput]
    var notify: AutomationNotifyPolicy
    /// Fields the parser guessed or could not fill: the draft card highlights these chips.
    var uncertainFields: Set<AutomationDraftField>
    /// Why: a short human reason per uncertain field ("I assumed 8:00 AM, change it if you meant evening").
    var notes: [AutomationDraftField: String]

    // Carried so editing an existing automation through the same card loses nothing.
    var symbolName: String?
    var shortcutDigit: Int?
    var parameterValues: [String: String]?
    var isEnabled: Bool
    var createdAt: Date?
    var lastRunAt: Date?
    var legacyOrigin: AutomationLegacyOrigin?
    /// Set by the draft card once it showed "this leaves your Mac" for a private source.
    var acknowledgedSourceLeavesMac: Bool?

    init(
        originalText: String = "",
        name: String,
        buddyID: UUID? = nil,
        trigger: AutomationTrigger,
        source: AutomationSource = .nothing,
        action: AutomationAction,
        outputs: [AutomationOutput] = [.notchCard],
        notify: AutomationNotifyPolicy = .always,
        uncertainFields: Set<AutomationDraftField> = [],
        notes: [AutomationDraftField: String] = [:],
        symbolName: String? = nil,
        shortcutDigit: Int? = nil,
        parameterValues: [String: String]? = nil,
        isEnabled: Bool = true,
        createdAt: Date? = nil,
        lastRunAt: Date? = nil,
        legacyOrigin: AutomationLegacyOrigin? = nil,
        acknowledgedSourceLeavesMac: Bool? = nil
    ) {
        self.originalText = originalText
        self.name = name
        self.buddyID = buddyID
        self.trigger = trigger
        self.source = source
        self.action = action
        self.outputs = outputs
        self.notify = notify
        self.uncertainFields = uncertainFields
        self.notes = notes
        self.symbolName = symbolName
        self.shortcutDigit = shortcutDigit
        self.parameterValues = parameterValues
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.lastRunAt = lastRunAt
        self.legacyOrigin = legacyOrigin
        self.acknowledgedSourceLeavesMac = acknowledgedSourceLeavesMac
    }

    /// Valid and with nothing important left to guess: the trigger and the place the result
    /// goes. (A guessed buddy or notify policy is harmless to save.)
    var isReadyToSave: Bool {
        let candidate = makeAutomation(id: UUID(), now: Date())
        return candidate.validationProblems().isEmpty
            && !uncertainFields.contains(.trigger)
            && !uncertainFields.contains(.output)
    }

    /// What blocks saving, in plain words (the card shows these under Save).
    func problemsBlockingSave(now: Date = Date()) -> [String] {
        makeAutomation(id: UUID(), now: now).validationProblems()
    }

    func makeAutomation(id: UUID, now: Date) -> Automation {
        var nextRunAt: Date?
        if case .schedule(let schedule) = trigger {
            nextRunAt = schedule.nextRunDate(after: now, calendar: .current)
        }
        return Automation(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            buddyID: buddyID,
            trigger: trigger,
            source: source,
            action: action,
            outputs: outputs,
            notify: notify,
            isEnabled: isEnabled,
            symbolName: symbolName ?? AutomationSymbolPolicy.symbolName(source: source, action: action, outputs: outputs),
            shortcutDigit: shortcutDigit,
            parameterValues: parameterValues,
            createdAt: createdAt ?? now,
            lastRunAt: lastRunAt,
            nextRunAt: nextRunAt,
            legacyOrigin: legacyOrigin,
            acknowledgedSourceLeavesMac: acknowledgedSourceLeavesMac
        )
    }

    /// Editing an existing automation reuses the same card.
    init(from automation: Automation) {
        self.init(
            originalText: "",
            name: automation.name,
            buddyID: automation.buddyID,
            trigger: automation.trigger,
            source: automation.source,
            action: automation.action,
            outputs: automation.outputs,
            notify: automation.notify,
            symbolName: automation.symbolName,
            shortcutDigit: automation.shortcutDigit,
            parameterValues: automation.parameterValues,
            isEnabled: automation.isEnabled,
            createdAt: automation.createdAt,
            lastRunAt: automation.lastRunAt,
            legacyOrigin: automation.legacyOrigin,
            acknowledgedSourceLeavesMac: automation.acknowledgedSourceLeavesMac
        )
    }

    /// Starting from a gallery template. A template with blanks to fill opens with its trigger
    /// highlighted, since the trigger is what is still missing.
    init(template: AutomationTemplate, buddyID: UUID?) {
        var uncertainFields: Set<AutomationDraftField> = []
        var notes: [AutomationDraftField: String] = [:]
        if let firstBlank = template.requiredBlanks.first {
            uncertainFields.insert(.trigger)
            notes[.trigger] = "Fill in the \(firstBlank)."
        }
        self.init(
            originalText: "",
            name: template.title,
            buddyID: buddyID,
            trigger: template.trigger,
            source: template.source,
            action: template.action,
            outputs: template.outputs,
            notify: template.notify,
            uncertainFields: uncertainFields,
            notes: notes,
            symbolName: template.symbolName
        )
    }

    /// "Save as automation" on a History answer: the question that produced it becomes the
    /// instruction. When it should run is still the user's call, so the trigger opens highlighted.
    static func fromAnswerRecord(originalQuestion: String, buddyID: UUID? = nil) -> AutomationDraft {
        let question = originalQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        return AutomationDraft(
            originalText: question,
            name: AutomationDraftNaming.name(fromInstruction: question),
            buddyID: buddyID,
            trigger: .schedule(AutomationSchedule(recurrence: .daily, hour: 9, minute: 0)),
            action: .askBuddy(instruction: question),
            outputs: [.notchCard],
            notify: .always,
            uncertainFields: [.trigger],
            notes: [.trigger: "Pick when this should run."]
        )
    }
}

/// Which SF Symbol a new automation gets when nothing chose one.
nonisolated enum AutomationSymbolPolicy {
    static func symbolName(source: AutomationSource, action: AutomationAction, outputs: [AutomationOutput]) -> String {
        switch action {
        case .syncCanvas: return "graduationcap"
        case .buildDailyChecklist: return "checklist"
        case .proposeStudyBlocks: return "timer"
        case .replayLearnedShortcut: return "bolt"
        case .askBuddy: break
        }
        switch source {
        case .todaysCalendar: return "calendar"
        case .canvasDeadlines: return "graduationcap"
        case .reminders: return "checklist"
        case .screenText: return "eye"
        case .folderFiles: return "folder"
        case .clipboard: return "doc.on.clipboard"
        case .nothing: break
        }
        if outputs.contains(where: { if case .remindersChecklist = $0 { return true } else { return false } }) {
            return "checklist"
        }
        return "sparkles"
    }
}

/// A short title from the instruction, no model call.
nonisolated enum AutomationDraftNaming {
    private static let leadingFillerPhrases = [
        "please ", "can you ", "could you ", "tell me ", "show me ", "let me know ", "give me ", "remind me to ",
        "remind me ", "and ", "to ",
    ]

    static func name(fromInstruction instruction: String) -> String {
        var remainingText = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        var removedLeadingFiller = true
        while removedLeadingFiller {
            removedLeadingFiller = false
            for fillerPhrase in leadingFillerPhrases where remainingText.lowercased().hasPrefix(fillerPhrase) {
                remainingText = String(remainingText.dropFirst(fillerPhrase.count))
                removedLeadingFiller = true
            }
        }
        let punctuationToTrim = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let leadingWords = remainingText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .prefix(6)
        var title = leadingWords.joined(separator: " ").trimmingCharacters(in: punctuationToTrim)
        if title.count > 40 {
            title = String(title.prefix(40)).trimmingCharacters(in: punctuationToTrim)
        }
        guard let firstCharacter = title.first else { return "New automation" }
        return firstCharacter.uppercased() + title.dropFirst()
    }
}
