//
//  StudyBlockPlanner.swift
//  leanring-buddy
//
//  Proposes study blocks in free gaps before Canvas assignments and quizzes
//  are due. Pure and deterministic: same inputs give the same ids and times.
//  Nothing here writes to a calendar; the user approves proposals elsewhere.
//
//  Rules: a block never overlaps busy time and keeps `bufferMinutes` clear of
//  it, stays inside the workday window (so never in sleeping hours), never
//  starts in the past, and ends before the item's deadline.
//

import Foundation

nonisolated enum StudyBlockPlanner {
    private static let startGranularityMinutes = 15

    static func propose(items: [CanvasItem],
                        busyIntervals: [BusyInterval],
                        alreadyProposedOrCreatedIDs: Set<String>,
                        settings: StudyBlockSettings,
                        now: Date,
                        calendar: Calendar) -> [StudyBlockProposal] {
        guard settings.isEnabled else { return [] }

        let blockDuration = TimeInterval(min(180, max(30, settings.blockMinutes)) * 60)
        // A gap must hold a whole block too, whatever minimumGap says.
        let minimumGapDuration = max(TimeInterval(settings.minimumGapMinutes * 60), blockDuration)
        let bufferDuration = TimeInterval(max(0, settings.bufferMinutes) * 60)
        let lookaheadEnd = calendar.date(byAdding: .day, value: max(0, settings.lookaheadDays), to: now) ?? now
        let earliestStart = roundedUpToQuarterHour(now)

        // Demand: assignments and quizzes due after now and inside the window, soonest first.
        var demandingItems: [(item: CanvasItem, deadline: Date)] = []
        for item in items where item.kind == .assignment || item.kind == .quiz {
            let itemDeadline = deadline(for: item, calendar: calendar)
            if itemDeadline > now && itemDeadline <= lookaheadEnd {
                demandingItems.append((item: item, deadline: itemDeadline))
            }
        }
        demandingItems.sort { first, second in
            if first.deadline != second.deadline { return first.deadline < second.deadline }
            return first.item.uid < second.item.uid
        }

        // Busy time stays expanded by the buffer; placed blocks join it so later items don't collide.
        var occupiedIntervals = busyIntervals.map {
            BusyInterval(start: $0.start.addingTimeInterval(-bufferDuration), end: $0.end.addingTimeInterval(bufferDuration))
        }
        var proposals: [StudyBlockProposal] = []
        var blockCountByDayStart: [Date: Int] = [:]

        for (item, itemDeadline) in demandingItems {
            // Any prior id for this item means it was already proposed, created or dismissed.
            let itemIDPrefix = "study-\(item.uid)-"
            if alreadyProposedOrCreatedIDs.contains(where: { $0.hasPrefix(itemIDPrefix) }) { continue }

            let latestEnd = min(itemDeadline, lookaheadEnd)
            var dayStart = calendar.startOfDay(for: now)
            var placedProposal: StudyBlockProposal?

            dayLoop: while dayStart < latestEnd {
                defer { dayStart = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? latestEnd }
                if blockCountByDayStart[dayStart, default: 0] >= settings.maximumBlocksPerDay { continue }

                guard let workdayStart = wallClockDate(onDayStarting: dayStart, minuteOfDay: settings.workdayStartMinuteOfDay, calendar: calendar),
                      let workdayEnd = wallClockDate(onDayStarting: dayStart, minuteOfDay: settings.workdayEndMinuteOfDay, calendar: calendar),
                      workdayStart < workdayEnd else { continue }

                let windowStart = max(workdayStart, earliestStart)
                let windowEnd = min(workdayEnd, latestEnd)
                guard windowStart < windowEnd else { continue }

                for gap in freeGaps(inWindowFrom: windowStart, to: windowEnd, avoiding: occupiedIntervals) {
                    let blockStart = roundedUpToQuarterHour(gap.start)
                    let blockEnd = blockStart.addingTimeInterval(blockDuration)
                    // A short gap is skipped even if a block would squeeze in; rounding must also still fit.
                    guard gap.end.timeIntervalSince(gap.start) >= minimumGapDuration, blockEnd <= gap.end else { continue }

                    placedProposal = StudyBlockProposal(
                        id: "study-\(item.uid)-\(dayKey(for: dayStart, calendar: calendar))-0",
                        forItemUID: item.uid,
                        title: "Study: \(item.title)",
                        courseCode: item.courseCode,
                        start: blockStart,
                        end: blockEnd
                    )
                    blockCountByDayStart[dayStart, default: 0] += 1
                    break dayLoop
                }
            }

            if let placedProposal {
                proposals.append(placedProposal)
                occupiedIntervals.append(BusyInterval(
                    start: placedProposal.start.addingTimeInterval(-bufferDuration),
                    end: placedProposal.end.addingTimeInterval(bufferDuration)
                ))
            }
        }

        return proposals.sorted { $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id }
    }

    // MARK: - Helpers

    /// An all-day item is due by the end of its day.
    private static func deadline(for item: CanvasItem, calendar: Calendar) -> Date {
        if item.isAllDay { return calendar.date(byAdding: .day, value: 1, to: item.startDate) ?? item.startDate }
        return item.startDate
    }

    /// The parts of [windowStart, windowEnd] not covered by any occupied interval, in order.
    private static func freeGaps(inWindowFrom windowStart: Date, to windowEnd: Date, avoiding occupiedIntervals: [BusyInterval]) -> [BusyInterval] {
        var gaps: [BusyInterval] = []
        var cursor = windowStart
        let relevantIntervals = occupiedIntervals
            .filter { $0.end > windowStart && $0.start < windowEnd }
            .sorted { $0.start < $1.start }
        for interval in relevantIntervals {
            if interval.start > cursor { gaps.append(BusyInterval(start: cursor, end: min(interval.start, windowEnd))) }
            cursor = max(cursor, interval.end)
            if cursor >= windowEnd { break }
        }
        if cursor < windowEnd { gaps.append(BusyInterval(start: cursor, end: windowEnd)) }
        return gaps
    }

    /// Wall-clock time on a given day, so the workday stays 9:00-21:00 across DST changes.
    private static func wallClockDate(onDayStarting dayStart: Date, minuteOfDay: Int, calendar: Calendar) -> Date? {
        let clampedMinute = min(24 * 60, max(0, minuteOfDay))
        if clampedMinute == 24 * 60 { return calendar.date(byAdding: .day, value: 1, to: dayStart) }
        return calendar.date(bySettingHour: clampedMinute / 60, minute: clampedMinute % 60, second: 0, of: dayStart)
    }

    private static func roundedUpToQuarterHour(_ date: Date) -> Date {
        let granularitySeconds = TimeInterval(startGranularityMinutes * 60)
        let seconds = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / granularitySeconds).rounded(.up) * granularitySeconds)
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
