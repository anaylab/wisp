//
//  LearnedShortcut.swift
//  leanring-buddy
//
//  Pure model for a learned shortcut: a phrase template plus the recorded tool calls to replay
//  when something matching it is said. See docs/learned-shortcuts-plan.md.
//
//  What is stored is the user's phrase and tool arguments, nothing else: no screenshot, no OCR
//  text, no transcript beyond the phrase, no model output. `Tests/LearnedShortcuts` asserts the
//  persisted keys.
//

import Foundation

/// Where inside a tool call's JSON input a slot's value goes.
enum LearnedShortcutArgumentPathComponent: Codable, Equatable, Sendable {
    case key(String)
    case index(Int)
}

enum LearnedShortcutSlotKind: String, Codable, Equatable, Sendable {
    /// Words the user said that are used as-is (a reminder title, a song).
    case freeText
    /// The name of a running app; the matcher's resolver must accept it.
    case applicationName

    /// Longer than this and the matcher would not capture it, so a draft is refused instead.
    var maximumWordCount: Int {
        switch self {
        case .freeText: return 8
        case .applicationName: return 4
        }
    }
}

struct LearnedShortcutSlot: Codable, Equatable, Sendable {
    let name: String
    let kind: LearnedShortcutSlotKind
}

struct LearnedShortcutSlotBinding: Codable, Equatable, Sendable {
    let argumentPath: [LearnedShortcutArgumentPathComponent]
    let slotName: String
}

struct LearnedShortcutStep: Codable, Equatable, Sendable {
    let toolName: String
    /// The input the tool ran with when the shortcut was learned. Bound positions hold the
    /// value from that run and are replaced with the new utterance's words on replay.
    let toolInput: JSONValue
    let slotBindings: [LearnedShortcutSlotBinding]

    /// The input to run now, or nil if a bound value is missing or its position no longer holds
    /// a string. A nil is a failed replay, never a partly-filled call.
    func toolInput(fillingSlotsWith slotValues: [String: String]) -> JSONValue? {
        var inputToRun = toolInput
        for slotBinding in slotBindings {
            guard let slotValue = slotValues[slotBinding.slotName],
                  let updatedInput = Self.replacingString(
                      in: inputToRun,
                      at: slotBinding.argumentPath[...],
                      with: slotValue
                  ) else { return nil }
            inputToRun = updatedInput
        }
        return inputToRun
    }

    private static func replacingString(
        in value: JSONValue,
        at remainingPath: ArraySlice<LearnedShortcutArgumentPathComponent>,
        with newString: String
    ) -> JSONValue? {
        guard let nextComponent = remainingPath.first else {
            if case .string = value { return .string(newString) }
            return nil
        }
        let pathAfterNextComponent = remainingPath.dropFirst()
        switch (nextComponent, value) {
        case (.key(let key), .object(var objectValue)):
            guard let childValue = objectValue[key],
                  let updatedChild = replacingString(in: childValue, at: pathAfterNextComponent, with: newString)
            else { return nil }
            objectValue[key] = updatedChild
            return .object(objectValue)
        case (.index(let index), .array(var arrayValue)):
            guard arrayValue.indices.contains(index),
                  let updatedChild = replacingString(in: arrayValue[index], at: pathAfterNextComponent, with: newString)
            else { return nil }
            arrayValue[index] = updatedChild
            return .array(arrayValue)
        default:
            return nil
        }
    }
}

struct LearnedShortcut: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    /// `LearnedShortcutPhraseTemplate.canonicalText`.
    var phraseTemplate: String
    var slots: [LearnedShortcutSlot]
    var steps: [LearnedShortcutStep]
    /// The short line said and shown after a successful replay.
    var spokenConfirmation: String
    var isEnabled: Bool
    /// Why it is off, in plain words, when Wisp turned it off.
    var disabledReason: String?
    var createdAt: Date
    var lastRunAt: Date?
    var successCount: Int
    var consecutiveFailures: Int

    init(
        id: UUID = UUID(),
        phraseTemplate: String,
        slots: [LearnedShortcutSlot],
        steps: [LearnedShortcutStep],
        spokenConfirmation: String = "done.",
        isEnabled: Bool = true,
        disabledReason: String? = nil,
        createdAt: Date = Date(),
        lastRunAt: Date? = nil,
        successCount: Int = 0,
        consecutiveFailures: Int = 0
    ) {
        self.id = id
        self.phraseTemplate = phraseTemplate
        self.slots = slots
        self.steps = steps
        self.spokenConfirmation = spokenConfirmation
        self.isEnabled = isEnabled
        self.disabledReason = disabledReason
        self.createdAt = createdAt
        self.lastRunAt = lastRunAt
        self.successCount = successCount
        self.consecutiveFailures = consecutiveFailures
    }

    var parsedPhraseTemplate: LearnedShortcutPhraseTemplate? {
        LearnedShortcutPhraseTemplate.parse(phraseTemplate)
    }

    func slot(named slotName: String) -> LearnedShortcutSlot? {
        slots.first { $0.name == slotName }
    }
}

/// When a shortcut that keeps failing turns itself off, so a saved action that no longer works
/// (an app was renamed, a tool changed) stops being tried before the model.
enum LearnedShortcutDriftPolicy {
    static let consecutiveFailureLimit = 2

    static func applying(runSucceeded: Bool, at runDate: Date, to shortcut: LearnedShortcut) -> LearnedShortcut {
        var updatedShortcut = shortcut
        updatedShortcut.lastRunAt = runDate
        if runSucceeded {
            updatedShortcut.successCount += 1
            updatedShortcut.consecutiveFailures = 0
        } else {
            updatedShortcut.consecutiveFailures += 1
            if updatedShortcut.consecutiveFailures >= consecutiveFailureLimit {
                updatedShortcut.isEnabled = false
                updatedShortcut.disabledReason =
                    "Turned off after \(consecutiveFailureLimit) failed runs in a row."
            }
        }
        return updatedShortcut
    }
}
