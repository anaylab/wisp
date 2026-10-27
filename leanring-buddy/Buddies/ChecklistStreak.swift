//
//  ChecklistStreak.swift
//  leanring-buddy
//
//  The streak behind the checklist celebration: how many days in a row the whole
//  "Wisp Today" checklist was finished. The rule is pure (day keys in, a count
//  out) so it is tested without the app; the store only remembers which days were
//  finished and tells the views when one just was, so they can celebrate once.
//
//  Only day keys ("2026-10-17") are stored, never checklist contents.
//

import Combine
import Foundation

nonisolated enum ChecklistStreakPolicy {
    /// Consecutive local days, ending today or yesterday, on which the whole
    /// checklist was finished. A streak that ended yesterday is still alive today
    /// (today's checklist isn't over yet); one that ended two days ago is broken.
    static func currentStreak(completedDayKeys: Set<String>, today: Date, calendar: Calendar) -> Int {
        var dayToCheck = today
        if !completedDayKeys.contains(dayKey(for: dayToCheck, calendar: calendar)) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return 0 }
            dayToCheck = yesterday
        }

        var streakLength = 0
        while completedDayKeys.contains(dayKey(for: dayToCheck, calendar: calendar)) {
            streakLength += 1
            guard let previousDay = calendar.date(byAdding: .day, value: -1, to: dayToCheck) else { break }
            dayToCheck = previousDay
        }
        return streakLength
    }

    /// "2026-10-17", the same format `MorningBriefingSchedule.dayKey` writes. It is
    /// repeated here (rather than called) so this file stays free of the notch code
    /// and compiles into the pure test suite on its own.
    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let dateComponents = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            dateComponents.year ?? 0,
            dateComponents.month ?? 0,
            dateComponents.day ?? 0
        )
    }

    /// Older day keys are dropped so the stored list stays small.
    static let maximumRememberedDays = 400

    static func trimmed(_ completedDayKeys: Set<String>) -> Set<String> {
        guard completedDayKeys.count > maximumRememberedDays else { return completedDayKeys }
        // "yyyy-MM-dd" sorts the same as the dates do.
        return Set(completedDayKeys.sorted().suffix(maximumRememberedDays))
    }
}

@MainActor
final class ChecklistStreakStore: ObservableObject {
    static let shared = ChecklistStreakStore()

    private static let completedDayKeysUserDefaultsKey = "wisp.checklist.completedDayKeys"

    @Published private(set) var currentStreakDays: Int
    /// Increments each time a checklist is finished (once per day). A view keys its
    /// burst and bounce on it.
    @Published private(set) var celebrationTrigger: Int = 0

    private var completedDayKeys: Set<String>
    private let userDefaults: UserDefaults
    private let calendar: Calendar

    init(userDefaults: UserDefaults = .standard, calendar: Calendar = .current, today: Date = Date()) {
        self.userDefaults = userDefaults
        self.calendar = calendar
        let storedDayKeys = userDefaults.stringArray(forKey: Self.completedDayKeysUserDefaultsKey) ?? []
        completedDayKeys = Set(storedDayKeys)
        currentStreakDays = ChecklistStreakPolicy.currentStreak(
            completedDayKeys: completedDayKeys,
            today: today,
            calendar: calendar
        )
    }

    /// Called by `DailyChecklistView` when every item of today's checklist is
    /// complete. Idempotent per day: ticking an item off and on again doesn't
    /// celebrate twice.
    func recordChecklistFinished(today: Date) {
        let todayKey = ChecklistStreakPolicy.dayKey(for: today, calendar: calendar)
        guard !completedDayKeys.contains(todayKey) else { return }

        completedDayKeys.insert(todayKey)
        completedDayKeys = ChecklistStreakPolicy.trimmed(completedDayKeys)
        userDefaults.set(completedDayKeys.sorted(), forKey: Self.completedDayKeysUserDefaultsKey)
        currentStreakDays = ChecklistStreakPolicy.currentStreak(
            completedDayKeys: completedDayKeys,
            today: today,
            calendar: calendar
        )
        celebrationTrigger += 1
    }

    /// Re-reads the streak for a new day, so one that lapsed overnight reads 0.
    func refreshStreak(today: Date) {
        currentStreakDays = ChecklistStreakPolicy.currentStreak(
            completedDayKeys: completedDayKeys,
            today: today,
            calendar: calendar
        )
    }
}
