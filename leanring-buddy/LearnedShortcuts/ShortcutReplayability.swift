//
//  ShortcutReplayability.swift
//  leanring-buddy
//
//  Pure: decides whether a finished agent turn can be saved as a learned shortcut, and if so
//  turns it into a draft (phrase template, slots, steps) for the save card.
//
//  The rules are an allow-list, not a deny-list: a tool that registers later is not replayable
//  until someone decides it is. See docs/learned-shortcuts-plan.md ("Recording").
//
//  What makes a call unsafe to replay is anything that was true only during the run that made
//  it: per-turn ids, an absolute time computed from "tomorrow", or text the model wrote that the
//  user never said. Replaying those would act on yesterday's screen or send yesterday's words.
//
//  Reads are not allowed in v1, so the "a later argument was chosen from an earlier result" rule
//  holds because no read is on the list.
//

import Foundation

enum ShortcutNotReplayableReason: Equatable, Sendable {
    case emptyRequest
    case noToolCalls
    case tooManySteps
    case aCallDidNotSucceed(toolName: String)
    case toolNotAllowed(toolName: String)
    case inputIsNotAnObject(toolName: String)
    /// A per-turn id (cua element token, `a12`/`t7`/`e7` ids, tab or window ids, pids).
    case ephemeralArgument(toolName: String, argumentName: String)
    /// An absolute date or time that only meant something on the day it was computed.
    case timeDependentArgument(toolName: String, argumentName: String)
    /// Free text the user did not say, so the model wrote it.
    case modelAuthoredText(toolName: String, argumentName: String)
    /// A value that appears twice in the request, so which one is the blank is a guess.
    case ambiguousArgumentPosition(toolName: String, argumentName: String)
    case blankTooLong(argumentName: String)
    case blanksOverlapOrTouch
    case noFixedWordsLeft
}

struct LearnedShortcutDraft: Equatable, Sendable {
    let phraseTemplate: String
    let slots: [LearnedShortcutSlot]
    let steps: [LearnedShortcutStep]

    func makeShortcut(
        id: UUID = UUID(),
        spokenConfirmation: String = "done.",
        createdAt: Date = Date()
    ) -> LearnedShortcut {
        LearnedShortcut(
            id: id,
            phraseTemplate: phraseTemplate,
            slots: slots,
            steps: steps,
            spokenConfirmation: spokenConfirmation,
            createdAt: createdAt
        )
    }
}

enum ShortcutReplayability {
    enum Evaluation: Equatable, Sendable {
        case replayable(LearnedShortcutDraft)
        case notReplayable(ShortcutNotReplayableReason)
    }

    static let maximumStepCount = 8

    /// What a replayable tool's arguments mean. Every argument not named here is a constant the
    /// save card shows: enum choices like a window placement or a music action.
    struct ReplayableToolSpecification: Sendable {
        /// Words the user said and the tool uses as-is. Must appear in the request.
        var freeTextArgumentNames: Set<String> = []
        /// A running app's name. Becomes a blank when the user said it.
        var applicationNameArgumentNames: Set<String> = []
        /// Absolute dates and times. Never replayable.
        var timeDependentArgumentNames: Set<String> = []
    }

    static let replayableTools: [String: ReplayableToolSpecification] = [
        "arrange_windows": ReplayableToolSpecification(applicationNameArgumentNames: ["app"]),
        "control_music": ReplayableToolSpecification(freeTextArgumentNames: ["query"]),
        "create_reminder": ReplayableToolSpecification(
            freeTextArgumentNames: ["title", "list"],
            timeDependentArgumentNames: ["due"]
        ),
        "run_shortcut": ReplayableToolSpecification(freeTextArgumentNames: ["input"]),
        "chrome_organize_tabs": ReplayableToolSpecification(),
        "chrome_close_duplicate_tabs": ReplayableToolSpecification(),
        "chrome_ungroup_tabs": ReplayableToolSpecification(),
    ]

    /// App-name values that mean "the window I'm working in" (see `arrange_windows`).
    static let frontWindowWords: Set<String> = ["", "front", "frontmost", "current", "this", "this window", "it", "active"]

    /// Argument names (lowercased) that hold something only valid during the run that made it.
    static let ephemeralArgumentNames: Set<String> = [
        "element_token", "element_index", "element_id", "element", "pid", "window_id", "windowid",
        "tab_id", "tabid", "tab_ids", "tabids", "task_id", "taskid",
    ]

    static func evaluate(transcript: String, toolCalls: [ShortcutRecordedToolCall]) -> Evaluation {
        let requestTokens = LearnedShortcutTokenizer.tokens(from: transcript)
        guard !requestTokens.isEmpty else { return .notReplayable(.emptyRequest) }
        guard !toolCalls.isEmpty else { return .notReplayable(.noToolCalls) }
        guard toolCalls.count <= maximumStepCount else { return .notReplayable(.tooManySteps) }

        // A blank found in the request: the words it covers and what it is called.
        struct PlannedBlank {
            let slot: LearnedShortcutSlot
            let tokenRange: Range<Int>
        }
        var plannedBlanks: [PlannedBlank] = []
        var slotNamesByNormalizedValue: [String: String] = [:]
        var steps: [LearnedShortcutStep] = []

        for toolCall in toolCalls {
            guard toolCall.succeeded else { return .notReplayable(.aCallDidNotSucceed(toolName: toolCall.toolName)) }
            guard let specification = replayableTools[toolCall.toolName] else {
                return .notReplayable(.toolNotAllowed(toolName: toolCall.toolName))
            }
            let arguments: [String: JSONValue]
            switch toolCall.toolInput {
            case .object(let objectArguments): arguments = objectArguments
            case .null: arguments = [:]
            default: return .notReplayable(.inputIsNotAnObject(toolName: toolCall.toolName))
            }

            if let ephemeralName = firstEphemeralArgumentName(in: toolCall.toolInput) {
                return .notReplayable(.ephemeralArgument(toolName: toolCall.toolName, argumentName: ephemeralName))
            }
            if let timeName = arguments.keys.sorted().first(where: {
                specification.timeDependentArgumentNames.contains($0)
            }) {
                return .notReplayable(.timeDependentArgument(toolName: toolCall.toolName, argumentName: timeName))
            }

            var slotBindings: [LearnedShortcutSlotBinding] = []
            for argumentName in arguments.keys.sorted() {
                let isFreeText = specification.freeTextArgumentNames.contains(argumentName)
                let isApplicationName = specification.applicationNameArgumentNames.contains(argumentName)
                guard isFreeText || isApplicationName else { continue }

                guard case .string(let argumentText)? = arguments[argumentName] else {
                    if isFreeText {
                        return .notReplayable(.modelAuthoredText(toolName: toolCall.toolName, argumentName: argumentName))
                    }
                    continue
                }
                // "this window" / "it" mean the front window, not an app that could be resolved
                // later, so they stay in the call as constants (same words `arrange_windows` accepts).
                if isApplicationName && frontWindowWords.contains(argumentText.lowercased().trimmingCharacters(in: .whitespaces)) {
                    continue
                }
                let valueWords = LearnedShortcutTokenizer.tokens(from: argumentText).map(\.normalizedText)
                let occurrenceRanges = rangesOfWords(valueWords, in: requestTokens.map(\.normalizedText))

                if occurrenceRanges.count != 1 {
                    // Free text the user did not say is the model's own words. An app the user did
                    // not name ("this", "") is just a constant. Said twice, neither can be trusted.
                    if isFreeText && occurrenceRanges.isEmpty && !valueWords.isEmpty {
                        return .notReplayable(.modelAuthoredText(toolName: toolCall.toolName, argumentName: argumentName))
                    }
                    if isFreeText && occurrenceRanges.count > 1 {
                        return .notReplayable(.ambiguousArgumentPosition(toolName: toolCall.toolName, argumentName: argumentName))
                    }
                    continue
                }

                let slotKind: LearnedShortcutSlotKind = isApplicationName ? .applicationName : .freeText
                guard valueWords.count <= slotKind.maximumWordCount else {
                    return .notReplayable(.blankTooLong(argumentName: argumentName))
                }

                let normalizedValue = valueWords.joined(separator: " ")
                let slotName: String
                if let existingSlotName = slotNamesByNormalizedValue[normalizedValue] {
                    slotName = existingSlotName
                } else {
                    slotName = uniqueSlotName(basedOn: argumentName, alreadyUsed: Set(plannedBlanks.map(\.slot.name)))
                    slotNamesByNormalizedValue[normalizedValue] = slotName
                    plannedBlanks.append(PlannedBlank(
                        slot: LearnedShortcutSlot(name: slotName, kind: slotKind),
                        tokenRange: occurrenceRanges[0]
                    ))
                }
                slotBindings.append(LearnedShortcutSlotBinding(argumentPath: [.key(argumentName)], slotName: slotName))
            }

            steps.append(LearnedShortcutStep(
                toolName: toolCall.toolName,
                toolInput: toolCall.toolInput,
                slotBindings: slotBindings
            ))
        }

        // The blanks must sit apart: two touching, or overlapping, would leave where one ends a guess.
        let blanksInOrder = plannedBlanks.sorted { $0.tokenRange.lowerBound < $1.tokenRange.lowerBound }
        for (blankIndex, blank) in blanksInOrder.enumerated().dropFirst() {
            if blank.tokenRange.lowerBound <= blanksInOrder[blankIndex - 1].tokenRange.upperBound {
                return .notReplayable(.blanksOverlapOrTouch)
            }
        }

        var templateElements: [String] = []
        var nextTokenIndex = 0
        for blank in blanksInOrder {
            templateElements += requestTokens[nextTokenIndex..<blank.tokenRange.lowerBound].map(\.normalizedText)
            templateElements.append("{\(blank.slot.name)}")
            nextTokenIndex = blank.tokenRange.upperBound
        }
        templateElements += requestTokens[nextTokenIndex...].map(\.normalizedText)

        let templateText = templateElements.joined(separator: " ")
        guard let template = LearnedShortcutPhraseTemplate.parse(templateText) else {
            return .notReplayable(.noFixedWordsLeft)
        }
        return .replayable(LearnedShortcutDraft(
            phraseTemplate: template.canonicalText,
            slots: blanksInOrder.map(\.slot),
            steps: steps
        ))
    }

    // MARK: - Private

    private static func rangesOfWords(_ words: [String], in requestWords: [String]) -> [Range<Int>] {
        guard !words.isEmpty, words.count <= requestWords.count else { return [] }
        var ranges: [Range<Int>] = []
        for startIndex in 0...(requestWords.count - words.count)
        where Array(requestWords[startIndex..<(startIndex + words.count)]) == words {
            ranges.append(startIndex..<(startIndex + words.count))
        }
        return ranges
    }

    private static func uniqueSlotName(basedOn argumentName: String, alreadyUsed: Set<String>) -> String {
        let baseName = LearnedShortcutPhraseTemplate.isValidSlotName(argumentName) ? argumentName : "value"
        guard alreadyUsed.contains(baseName) else { return baseName }
        var suffix = 2
        while alreadyUsed.contains("\(baseName)\(suffix)") { suffix += 1 }
        return "\(baseName)\(suffix)"
    }

    /// Looks through the whole input, not just the top level, so a nested id is still caught.
    private static func firstEphemeralArgumentName(in value: JSONValue) -> String? {
        switch value {
        case .object(let objectValue):
            for key in objectValue.keys.sorted() {
                if ephemeralArgumentNames.contains(key.lowercased()) { return key }
                if let nestedName = firstEphemeralArgumentName(in: objectValue[key] ?? .null) { return nestedName }
            }
            return nil
        case .array(let arrayValue):
            for element in arrayValue {
                if let nestedName = firstEphemeralArgumentName(in: element) { return nestedName }
            }
            return nil
        case .string(let text):
            return looksLikePerTurnElementID(text) ? text : nil
        default:
            return nil
        }
    }

    /// Wisp's own `a12` / `t7` and the browser's `e7`, which only name something on one screen.
    private static func looksLikePerTurnElementID(_ text: String) -> Bool {
        guard text.count >= 2, text.count <= 5, let firstCharacter = text.first,
              "aAtTeE".contains(firstCharacter) else { return false }
        return text.dropFirst().allSatisfy(\.isNumber)
    }
}
