//
//  CalendarEventDraftExtractor.swift
//  leanring-buddy
//
//  The second step of the calendar fast path, for a request
//  `CalendarEventCommandParser` recognised as scheduling but couldn't split
//  into title, place and time ("schedule catch up w sam around 1 friday at
//  tartine"). Apple's on-device model (the Foundation Models framework, the
//  one Siri uses) picks those parts out with guided generation into a
//  `@Generable` struct. That gives a typed answer, not text to parse, which
//  the local Ollama model can't produce reliably.
//
//  The model only says *which words* are the title, place and time; the
//  parser turns the time words into a date and rejects a title or time the
//  user never said (`CalendarEventCommandParser.draft(fromExtractedTitle:…)`).
//
//  On-device and optional: when Apple Intelligence is off, not supported or
//  still downloading, this returns nil at once and the request goes to the
//  ordinary model turn, exactly as it did before. The system owns the model's
//  memory, so it adds nothing resident to Wisp, and it isn't the Ollama
//  model, so it doesn't go through `ModelAccessGate`.
//

import Foundation
import FoundationModels

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

    /// The model answers in well under a second when warm; a cold load is
    /// slower. Past this the user is better served by the ordinary turn.
    static let extractionTimeoutSeconds: Double = 6

    /// Whether Apple's on-device model can be used right now.
    static var isOnDeviceModelAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// A checked draft for `requestBody`, or nil when the model is unavailable,
    /// slow, or answers with something that doesn't hold up.
    static func extractDraft(fromRequestBody requestBody: String, now: Date = Date()) async -> CalendarEventDraft? {
        guard isOnDeviceModelAvailable else { return nil }

        let extractedFields: ExtractedCalendarEventFields? = await withTaskGroup(of: ExtractedCalendarEventFields?.self) { taskGroup in
            taskGroup.addTask {
                let session = LanguageModelSession(instructions: """
                    You pick out the parts of a request to add an event to a calendar. \
                    Copy words from the request; never add words, never compute dates.
                    """)
                let response = try? await session.respond(
                    to: "Request: \(requestBody)",
                    generating: ExtractedCalendarEventFields.self
                )
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
        guard let extractedFields else { return nil }

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
