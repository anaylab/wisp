//
//  OnDeviceModelExtraction.swift
//  leanring-buddy
//
//  The second step of the Siri-style fast paths (calendar events, reminders),
//  for a request the deterministic parser recognised but couldn't split into
//  its parts ("schedule catch up w sam around 1 friday at tartine"). Apple's
//  on-device model (the Foundation Models framework, the one Siri uses) picks
//  those parts out with guided generation into a `@Generable` struct. That
//  gives a typed answer, not text to parse, which the local Ollama model can't
//  produce reliably.
//
//  The model only says *which words* are which. The parsers turn the time
//  words into a date and reject a title or time the user never said
//  (`CalendarEventCommandParser.draft(fromExtractedTitle:…)`,
//  `ReminderCommandParser.draft(fromExtractedTitle:…)`).
//
//  On-device and optional: when Apple Intelligence is off, not supported or
//  still downloading, every extractor returns nil at once and the request
//  goes to the ordinary model turn, exactly as it did before. The system owns
//  the model's memory, so it adds nothing resident to Wisp, and it isn't the
//  Ollama model, so it doesn't go through `ModelAccessGate`.
//

import Foundation
import FoundationModels

enum OnDeviceModelExtraction {

    /// The model answers in about a second when warm (0.8–2.4s measured on an
    /// M3 Pro); a cold load is slower. Past this the user is better served by
    /// the ordinary turn.
    static let extractionTimeoutSeconds: Double = 6

    /// Whether Apple's on-device model can be used right now.
    static var isOnDeviceModelAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Fills `ExtractedFields` from `prompt`, or nil when the model is
    /// unavailable, fails, or takes longer than `extractionTimeoutSeconds`.
    static func extract<ExtractedFields: Generable & Sendable>(
        _ extractedFieldsType: ExtractedFields.Type,
        instructions: String,
        prompt: String
    ) async -> ExtractedFields? {
        guard isOnDeviceModelAvailable else { return nil }

        return await withTaskGroup(of: ExtractedFields?.self) { taskGroup in
            taskGroup.addTask {
                let session = LanguageModelSession(instructions: instructions)
                let response = try? await session.respond(to: prompt, generating: extractedFieldsType)
                return response?.content
            }
            taskGroup.addTask {
                try? await Task.sleep(for: .seconds(extractionTimeoutSeconds))
                return nil
            }
            let firstFinishedResult = await taskGroup.next() ?? nil
            taskGroup.cancelAll()
            return firstFinishedResult
        }
    }

    /// The shared rule both extractors give the model.
    static let copyWordsOnlyInstruction = "Copy words from the request; never add words, never compute dates."
}

// MARK: - Calendar events

@Generable
struct ExtractedCalendarEventFields {
    @Guide(description: "The event's name in the user's own words, without the time or place. For example \"lunch with Sam\" or \"dentist\".")
    var title: String

    @Guide(description: "The place, copied from the request, or an empty string if no place was said.")
    var location: String

    @Guide(description: "The exact words of the request that say when, copied verbatim. For example \"friday at 1\" or \"tomorrow morning at 9\".")
    var whenPhrase: String
}

enum CalendarEventDraftExtractor {
    /// A checked event draft for `requestBody`, or nil.
    static func extractDraft(fromRequestBody requestBody: String, now: Date = Date()) async -> CalendarEventDraft? {
        guard let extractedFields = await OnDeviceModelExtraction.extract(
            ExtractedCalendarEventFields.self,
            instructions: "You pick out the parts of a request to add an event to a calendar. \(OnDeviceModelExtraction.copyWordsOnlyInstruction)",
            prompt: "Request: \(requestBody)"
        ) else { return nil }

        let trimmedLocation = extractedFields.location.trimmingCharacters(in: .whitespacesAndNewlines)
        return CalendarEventCommandParser.draft(
            fromExtractedTitle: extractedFields.title,
            extractedLocation: trimmedLocation.isEmpty ? nil : trimmedLocation,
            extractedWhenPhrase: extractedFields.whenPhrase,
            requestBody: requestBody,
            now: now
        )
    }
}

// MARK: - Reminders

@Generable
struct ExtractedReminderFields {
    @Guide(description: "What to be reminded to do, in the user's own words, without the time. For example \"call the bank\" or \"renew my passport\".")
    var title: String

    @Guide(description: "The exact words of the request that say when, copied verbatim, or an empty string if no time was said. For example \"tomorrow at 9\".")
    var whenPhrase: String
}

enum ReminderDraftExtractor {
    /// A checked reminder draft for `requestBody`, or nil.
    static func extractDraft(
        fromRequestBody requestBody: String,
        listName: String?,
        now: Date = Date()
    ) async -> ReminderDraft? {
        guard let extractedFields = await OnDeviceModelExtraction.extract(
            ExtractedReminderFields.self,
            instructions: "You pick out the parts of a request to set a reminder. \(OnDeviceModelExtraction.copyWordsOnlyInstruction)",
            prompt: "Request: remind me \(requestBody)"
        ) else { return nil }

        return ReminderCommandParser.draft(
            fromExtractedTitle: extractedFields.title,
            extractedWhenPhrase: extractedFields.whenPhrase,
            requestBody: requestBody,
            listName: listName,
            now: now
        )
    }
}
