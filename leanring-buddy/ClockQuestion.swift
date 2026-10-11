//
//  ClockQuestion.swift
//  leanring-buddy
//
//  "What time is it", "what's the date", "what day is it" — answered from the
//  clock, with no model call. The local model has no clock: unless it chose
//  to call `get_current_time`, it guessed, and the answer was a confident,
//  wrong time after a multi-second turn. Recognised by `FastCommandRouter`.
//
//  Whole-utterance matching only, like the router's other commands: "what
//  time is it in Tokyo" or "what time is my meeting" are different questions
//  and go to the model.
//
//  `currentMomentPromptText` is the other half: every model turn is told the
//  current local date and time in its per-turn context block, so time-relative
//  questions ("how long until 5?") start from the real time too.
//
//  Pure, tested by `Tests/CalendarEventCommand`.
//

import Foundation

nonisolated enum ClockQuestion: Sendable, Equatable {
    case time
    case date
    case dayOfWeek

    /// The clock question `transcript` asks, or nil for anything else.
    static func question(in transcript: String) -> ClockQuestion? {
        var normalizedText = transcript.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .!?\n\t"))
        for leadingFiller in ["hey wisp ", "hey ", "ok ", "okay ", "so ", "um ", "uh "] where normalizedText.hasPrefix(leadingFiller) {
            normalizedText.removeFirst(leadingFiller.count)
        }
        for trailingFiller in [" please", " right now", " now", " today"] where normalizedText.hasSuffix(trailingFiller) {
            normalizedText.removeLast(trailingFiller.count)
        }
        normalizedText = normalizedText.replacingOccurrences(of: "what is", with: "what's")
            .replacingOccurrences(of: "whats", with: "what's")

        if timeQuestions.contains(normalizedText) { return .time }
        if dateQuestions.contains(normalizedText) { return .date }
        if dayQuestions.contains(normalizedText) { return .dayOfWeek }
        return nil
    }

    private static let timeQuestions: Set<String> = [
        "what time is it", "what's the time", "time", "the time", "current time", "what's the current time",
        "tell me the time", "do you know what time it is", "what time it is", "got the time",
    ]

    private static let dateQuestions: Set<String> = [
        "what's the date", "what date is it", "what's today's date", "today's date", "the date", "date",
        "what's the date and time", "what's the current date", "tell me the date",
    ]

    private static let dayQuestions: Set<String> = [
        "what day is it", "what day of the week is it", "what's the day", "which day is it",
    ]

    /// "It's 11:42 PM.", "It's Wednesday, October 7.", "It's Wednesday."
    func answer(now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        switch self {
        case .time:
            formatter.setLocalizedDateFormatFromTemplate("jmm")
        case .date:
            formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        case .dayOfWeek:
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
        }
        return "It's \(SchedulingPhrasing.plainSpaced(formatter.string(from: now)))."
    }

    /// One line for the model's per-turn context:
    /// "Current local time: Wednesday, October 7, 2026, 11:42 PM (America/New_York)."
    static func currentMomentPromptText(now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE, MMMM d, yyyy, h:mm a"
        return "Current local time: \(formatter.string(from: now)) (\(calendar.timeZone.identifier))."
    }
}
