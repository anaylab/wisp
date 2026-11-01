//
//  StudyStats.swift
//  leanring-buddy
//
//  The finished-session log and the numbers drawn from it: today's focus time,
//  the last seven days and the day streak. Pure; the controller persists it.
//

import Foundation

struct StudyLogEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let goal: String
    let startedAt: Date
    let endedAt: Date
    let focusSeconds: TimeInterval
    let completedRounds: Int
    let distractionsHeldBack: Int
}

enum StudyStats {
    static let maximumStoredEntries = 500

    static func focusSeconds(on day: Date, in entries: [StudyLogEntry], calendar: Calendar = .current) -> TimeInterval {
        entries
            .filter { calendar.isDate($0.endedAt, inSameDayAs: day) }
            .reduce(0) { $0 + $1.focusSeconds }
    }

    /// Focus rounds finished on `day`: the plants in that day's garden.
    static func completedRounds(on day: Date, in entries: [StudyLogEntry], calendar: Calendar = .current) -> Int {
        entries
            .filter { calendar.isDate($0.endedAt, inSameDayAs: day) }
            .reduce(0) { $0 + $1.completedRounds }
    }

    /// Focus seconds for each of the last `dayCount` days, oldest first, ending today.
    static func dailyFocusSeconds(
        lastDays dayCount: Int,
        endingAt now: Date,
        in entries: [StudyLogEntry],
        calendar: Calendar = .current
    ) -> [(day: Date, seconds: TimeInterval)] {
        (0..<dayCount).reversed().compactMap { daysAgo in
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: now) else { return nil }
            return (day, focusSeconds(on: day, in: entries, calendar: calendar))
        }
    }

    /// Consecutive days with any focus time, counted back from today. A day not finished yet
    /// doesn't break the streak: if today is empty the count starts from yesterday.
    static func streakDays(endingAt now: Date, in entries: [StudyLogEntry], calendar: Calendar = .current) -> Int {
        var streak = 0
        var day = now
        if focusSeconds(on: day, in: entries, calendar: calendar) == 0 {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        while focusSeconds(on: day, in: entries, calendar: calendar) > 0 {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }

    static func appending(_ entry: StudyLogEntry, to entries: [StudyLogEntry]) -> [StudyLogEntry] {
        Array((entries + [entry]).suffix(maximumStoredEntries))
    }
}
