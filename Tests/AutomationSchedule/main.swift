//
//  Automation schedule suite: when a scheduled automation runs next, across recurrences, DST
//  gaps and repeats, month ends, missed runs, and the words-to-schedule inference.
//

import Foundation

var failureCount = 0
var checkCount = 0

func check(_ condition: Bool, _ description: String) {
    checkCount += 1
    if !condition {
        failureCount += 1
        print("FAIL: \(description)")
    }
}

func makeCalendar(_ zoneIdentifier: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zoneIdentifier)!
    calendar.locale = Locale(identifier: "en_US")
    return calendar
}

func makeDate(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: 0))!
}

func parts(_ date: Date?, _ calendar: Calendar) -> String {
    guard let date else { return "nil" }
    let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    return String(format: "%04d-%02d-%02d %02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!)
}

let newYork = makeCalendar("America/New_York")
let london = makeCalendar("Europe/London")

// MARK: - Daily, weekdays, weekly

let dailyEight = AutomationSchedule(recurrence: .daily, hour: 8, minute: 0)
check(parts(dailyEight.nextRunDate(after: makeDate(newYork, 2026, 10, 14, 7, 59), calendar: newYork), newYork) == "2026-10-14 08:00", "daily: before the slot runs today")
check(parts(dailyEight.nextRunDate(after: makeDate(newYork, 2026, 10, 14, 8, 0), calendar: newYork), newYork) == "2026-10-15 08:00", "daily: strictly after, so exactly at the slot goes to tomorrow")

let weekdaysEight = AutomationSchedule(recurrence: .weekdays, hour: 8, minute: 0)
// 2026-10-16 is a Friday.
check(parts(weekdaysEight.nextRunDate(after: makeDate(newYork, 2026, 10, 16, 9), calendar: newYork), newYork) == "2026-10-19 08:00", "weekdays: Friday after the slot skips the weekend to Monday")
check(parts(weekdaysEight.nextRunDate(after: makeDate(newYork, 2026, 10, 17, 9), calendar: newYork), newYork) == "2026-10-19 08:00", "weekdays: Saturday goes to Monday")
check(parts(weekdaysEight.nextRunDate(after: makeDate(newYork, 2026, 10, 14, 6), calendar: newYork), newYork) == "2026-10-14 08:00", "weekdays: Wednesday morning runs today")

let sundayEvening = AutomationSchedule(recurrence: .weekly(weekday: 1), hour: 18, minute: 0)
check(parts(sundayEvening.nextRunDate(after: makeDate(newYork, 2026, 10, 14, 9), calendar: newYork), newYork) == "2026-10-18 18:00", "weekly: next Sunday")

// MARK: - Monthly

let monthlyThirtyFirst = AutomationSchedule(recurrence: .monthly(dayOfMonth: 31), hour: 9, minute: 0)
check(parts(monthlyThirtyFirst.nextRunDate(after: makeDate(newYork, 2026, 1, 31, 10), calendar: newYork), newYork) == "2026-02-28 09:00", "monthly: the 31st runs on Feb 28 in a short month")
check(parts(monthlyThirtyFirst.nextRunDate(after: makeDate(newYork, 2026, 2, 28, 10), calendar: newYork), newYork) == "2026-03-31 09:00", "monthly: back to the 31st")
check(parts(monthlyThirtyFirst.nextRunDate(after: makeDate(newYork, 2026, 3, 31, 10), calendar: newYork), newYork) == "2026-04-30 09:00", "monthly: April clamps to the 30th")
let monthlyThirtieth = AutomationSchedule(recurrence: .monthly(dayOfMonth: 30), hour: 9, minute: 0)
check(parts(monthlyThirtieth.nextRunDate(after: makeDate(newYork, 2028, 1, 31, 10), calendar: newYork), newYork) == "2028-02-29 09:00", "monthly: leap year Feb 29 for the 30th")
let monthlyFirst = AutomationSchedule(recurrence: .monthly(dayOfMonth: 1), hour: 19, minute: 0)
check(parts(monthlyFirst.nextRunDate(after: makeDate(newYork, 2026, 12, 15, 10), calendar: newYork), newYork) == "2027-01-01 19:00", "monthly: rolls over the year")
check(parts(monthlyFirst.nextRunDate(after: makeDate(newYork, 2026, 12, 1, 18, 59), calendar: newYork), newYork) == "2026-12-01 19:00", "monthly: same day later")

// MARK: - DST

// Spring forward, New York: 2026-03-08 02:00 -> 03:00. A 02:30 slot does not exist that day.
let dailyTwoThirty = AutomationSchedule(recurrence: .daily, hour: 2, minute: 30)
let springGapRun = dailyTwoThirty.nextRunDate(after: makeDate(newYork, 2026, 3, 7, 12), calendar: newYork)
let springGapParts = parts(springGapRun, newYork)
check(springGapParts.hasPrefix("2026-03-08 03:"), "DST gap NY: a nonexistent 02:30 runs at the next valid time on the same day (got \(springGapParts))")
if let springGapRun {
    check(parts(dailyTwoThirty.nextRunDate(after: springGapRun, calendar: newYork), newYork) == "2026-03-09 02:30", "DST gap NY: the day after is back to 02:30")
}
// Fall back, New York: 2026-11-01 01:00-02:00 happens twice. A 01:30 slot must run once.
let dailyOneThirty = AutomationSchedule(recurrence: .daily, hour: 1, minute: 30)
let fallFirstRun = dailyOneThirty.nextRunDate(after: makeDate(newYork, 2026, 10, 31, 12), calendar: newYork)
check(parts(fallFirstRun, newYork) == "2026-11-01 01:30", "DST repeat NY: first 01:30")
if let fallFirstRun {
    let afterFirst = dailyOneThirty.nextRunDate(after: fallFirstRun, calendar: newYork)
    check(parts(afterFirst, newYork) == "2026-11-02 01:30", "DST repeat NY: the repeated 01:30 does not run a second time (got \(parts(afterFirst, newYork)))")
}
// London: spring forward 2026-03-29 01:00 -> 02:00; fall back 2026-10-25 02:00 -> 01:00.
let londonGapRun = dailyOneThirty.nextRunDate(after: makeDate(london, 2026, 3, 28, 12), calendar: london)
check(parts(londonGapRun, london).hasPrefix("2026-03-29 02:"), "DST gap London: 01:30 runs at the next valid time (got \(parts(londonGapRun, london)))")
let londonRepeatRun = dailyOneThirty.nextRunDate(after: makeDate(london, 2026, 10, 24, 12), calendar: london)
check(parts(londonRepeatRun, london) == "2026-10-25 01:30", "DST repeat London: first 01:30")
if let londonRepeatRun {
    check(parts(dailyOneThirty.nextRunDate(after: londonRepeatRun, calendar: london), london) == "2026-10-26 01:30", "DST repeat London: runs once")
}

// A pinned zone keeps its wall clock regardless of the Mac's zone.
let londonNine = AutomationSchedule(recurrence: .daily, hour: 9, minute: 0, timeZoneIdentifier: "Europe/London")
let pinnedRun = londonNine.nextRunDate(after: makeDate(newYork, 2026, 10, 14, 2), calendar: newYork)
check(parts(pinnedRun, london) == "2026-10-14 09:00", "pinned zone: 09:00 in London even under a New York calendar")
check(AutomationSchedule(recurrence: .daily, hour: 9, minute: 0, timeZoneIdentifier: "Not/AZone").nextRunDate(after: Date(), calendar: newYork) == nil, "an unknown zone has no next run")

// MARK: - Once

let onceDate = makeDate(newYork, 2026, 10, 16, 15)
let onceSchedule = AutomationSchedule(recurrence: .once(onceDate), hour: 15, minute: 0)
check(onceSchedule.nextRunDate(after: makeDate(newYork, 2026, 10, 15), calendar: newYork) == onceDate, "once: future date returns itself")
check(onceSchedule.nextRunDate(after: makeDate(newYork, 2026, 10, 17), calendar: newYork) == nil, "once in the past has no next run")
check(onceSchedule.missedRunDate(lastRunAt: nil, createdAt: makeDate(newYork, 2026, 10, 15), now: makeDate(newYork, 2026, 10, 17), calendar: newYork) == onceDate, "once: a slot that passed while asleep is missed once")
check(onceSchedule.missedRunDate(lastRunAt: onceDate, createdAt: makeDate(newYork, 2026, 10, 15), now: makeDate(newYork, 2026, 10, 17), calendar: newYork) == nil, "once: already ran, not missed again")

// MARK: - Missed runs

let missedBaseline = makeDate(newYork, 2026, 10, 12, 8) // Monday 8:00 ran
let missedNow = makeDate(newYork, 2026, 10, 15, 10)     // Thursday 10:00, Mac was asleep
let missedSlot = dailyEight.missedRunDate(lastRunAt: missedBaseline, createdAt: makeDate(newYork, 2026, 10, 1), now: missedNow, calendar: newYork)
check(parts(missedSlot, newYork) == "2026-10-15 08:00", "missed: only the latest missed slot is returned, so it runs once")
check(dailyEight.missedRunDate(lastRunAt: makeDate(newYork, 2026, 10, 15, 8), createdAt: makeDate(newYork, 2026, 10, 1), now: missedNow, calendar: newYork) == nil, "missed: nothing missed after today's run")
check(dailyEight.missedRunDate(lastRunAt: nil, createdAt: makeDate(newYork, 2026, 10, 15, 9), now: missedNow, calendar: newYork) == nil, "missed: a slot before creation is not missed")
check(parts(dailyEight.missedRunDate(lastRunAt: nil, createdAt: makeDate(newYork, 2026, 10, 14, 9), now: missedNow, calendar: newYork), newYork) == "2026-10-15 08:00", "missed: nil lastRunAt uses createdAt")
check(parts(weekdaysEight.missedRunDate(lastRunAt: makeDate(newYork, 2026, 10, 9, 8), createdAt: makeDate(newYork, 2026, 10, 1), now: makeDate(newYork, 2026, 10, 18, 12), calendar: newYork), newYork) == "2026-10-16 08:00", "missed: weekdays skip the weekend, latest is Friday")
check(dailyEight.missedRunDate(lastRunAt: makeDate(newYork, 2025, 1, 1), createdAt: makeDate(newYork, 2025, 1, 1), now: makeDate(newYork, 2026, 10, 15, 10), calendar: newYork) != nil, "missed: a year asleep still answers quickly with the latest slot")

// MARK: - Summary

check(weekdaysEight.summary(calendar: newYork) == "Every weekday at 8:00 AM", "summary weekdays")
check(dailyEight.summary(calendar: newYork) == "Every day at 8:00 AM", "summary daily")
check(AutomationSchedule(recurrence: .weekly(weekday: 2), hour: 9, minute: 0).summary(calendar: newYork) == "Every Monday at 9:00 AM", "summary weekly")
check(monthlyFirst.summary(calendar: newYork) == "On the 1st at 7:00 PM", "summary monthly")
check(AutomationSchedule(recurrence: .monthly(dayOfMonth: 22), hour: 12, minute: 30).summary(calendar: newYork) == "On the 22nd at 12:30 PM", "summary ordinal and noon")
check(onceSchedule.summary(calendar: newYork) == "Once, Fri 3:00 PM", "summary once")
check(AutomationSchedule(recurrence: .daily, hour: 0, minute: 5).summary(calendar: newYork) == "Every day at 12:05 AM", "summary midnight")

// MARK: - Validation and legacy

check(AutomationSchedule(recurrence: .daily, hour: 24, minute: 0).validationProblems().count == 1, "hour 24 is invalid")
check(AutomationSchedule(recurrence: .weekly(weekday: 8), hour: 1, minute: 0).validationProblems().count == 1, "weekday 8 is invalid")
check(AutomationSchedule(recurrence: .monthly(dayOfMonth: 0), hour: 1, minute: 0).validationProblems().count == 1, "day 0 is invalid")
check(AutomationSchedule(recurrence: .daily, hour: 9, minute: 0).validationProblems().isEmpty, "a plain daily schedule is valid")
check(AutomationSchedule(legacy: .once) == nil, "a once buddy is not a schedule")
check(AutomationSchedule(legacy: .daily(hour: 7, minute: 15)) == AutomationSchedule(recurrence: .daily, hour: 7, minute: 15), "legacy daily maps across")
check(AutomationSchedule(legacy: .weekly(weekday: 3, hour: 9, minute: 0)) == AutomationSchedule(recurrence: .weekly(weekday: 3), hour: 9, minute: 0), "legacy weekly maps across")

// Codable round trip, including a once date.
let encodedSchedules = try! JSONEncoder().encode([dailyEight, weekdaysEight, onceSchedule, monthlyFirst, sundayEvening])
check(try! JSONDecoder().decode([AutomationSchedule].self, from: encodedSchedules) == [dailyEight, weekdaysEight, onceSchedule, monthlyFirst, sundayEvening], "schedules survive JSON")

// MARK: - Inference

let inferenceNow = makeDate(newYork, 2026, 10, 14, 10) // Wednesday 10:00
func inferred(_ text: String) -> AutomationSchedule? {
    AutomationSchedule.inferred(fromText: text, now: inferenceNow, calendar: newYork)
}
check(inferred("every weekday at 8 tell me what's due") == AutomationSchedule(recurrence: .weekdays, hour: 8, minute: 0), "infer: weekdays at 8")
check(inferred("every day at 3:30pm") == AutomationSchedule(recurrence: .daily, hour: 15, minute: 30), "infer: 3:30pm")
check(inferred("daily at 7 pm") == AutomationSchedule(recurrence: .daily, hour: 19, minute: 0), "infer: 7 pm")
check(inferred("every Sunday evening plan my week") == AutomationSchedule(recurrence: .weekly(weekday: 1), hour: 18, minute: 0), "infer: Sunday evening is weekly(1) 18:00")
check(inferred("every Monday at 9:00 AM") == AutomationSchedule(recurrence: .weekly(weekday: 2), hour: 9, minute: 0), "infer: Monday 9am")
check(inferred("every morning summarize the news") == AutomationSchedule(recurrence: .daily, hour: 9, minute: 0), "infer: every morning is a soft 9:00")
check(inferred("on the 1st of each month at 7pm") == AutomationSchedule(recurrence: .monthly(dayOfMonth: 1), hour: 19, minute: 0), "infer: monthly on the 1st")
check(inferred("every day") == nil, "infer: every day names no time, so no schedule")
check(inferred("every Monday") == nil, "infer: every Monday names no time")
check(inferred("what's the weather") == nil, "infer: ordinary question")
check(inferred("every weekday at 14:30") == AutomationSchedule(recurrence: .weekdays, hour: 14, minute: 30), "infer: 24-hour time")
check(inferred("each night at noon") == AutomationSchedule(recurrence: .daily, hour: 12, minute: 0), "infer: noon")
if case .once(let tomorrowRun)? = inferred("remind me tomorrow at 8am")?.recurrence {
    check(parts(tomorrowRun, newYork) == "2026-10-15 08:00", "infer: tomorrow at 8am is a one-off tomorrow")
} else {
    check(false, "infer: tomorrow at 8am should be a one-off")
}
if case .once(let fridayRun)? = inferred("remind me on friday at 3pm")?.recurrence {
    check(parts(fridayRun, newYork) == "2026-10-16 15:00", "infer: on friday at 3pm")
} else {
    check(false, "infer: on friday at 3pm should be a one-off")
}
if case .once(let todayRun)? = inferred("remind me at 5pm to call mom")?.recurrence {
    check(parts(todayRun, newYork) == "2026-10-14 17:00", "infer: remind me at 5pm means today")
} else {
    check(false, "infer: remind me at 5pm should be a one-off today")
}
check(AutomationScheduleInference.infer(fromText: "every morning", now: inferenceNow, calendar: newYork)?.assumptions.isEmpty == false, "infer: a part of the day is a noted assumption")
check(AutomationScheduleInference.infer(fromText: "every weekday at 8", now: inferenceNow, calendar: newYork)?.assumptions.isEmpty == true, "infer: a stated time is not an assumption")
check(inferred("every morning at 6 summarize my inbox") == AutomationSchedule(recurrence: .daily, hour: 6, minute: 0), "infer: 'morning at 6' is 6 AM")
check(inferred("every evening at 7") == AutomationSchedule(recurrence: .daily, hour: 19, minute: 0), "infer: 'evening at 7' is 7 PM")
check(inferred("every day at 6") == AutomationSchedule(recurrence: .daily, hour: 18, minute: 0), "infer: bare 'at 6' still reads as evening")
if case .once(let tonightRun)? = inferred("remind me at 7 tonight")?.recurrence {
    check(parts(tonightRun, newYork) == "2026-10-14 19:00", "infer: at 7 tonight is 7 PM")
} else {
    check(false, "infer: at 7 tonight should be a one-off")
}
let everyOtherInference = AutomationScheduleInference.infer(fromText: "every other Monday at 9am review the budget", now: inferenceNow, calendar: newYork)
check(everyOtherInference?.assumptions.contains(where: { $0.contains("every other week") }) == true, "infer: 'every other Monday' notes that it runs weekly")

print("\(checkCount - failureCount)/\(checkCount) checks passed")
if failureCount > 0 {
    print("\(failureCount) FAILED")
    exit(1)
}
