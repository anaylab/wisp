//
//  WispScheduled.swift
//  leanring-buddy
//
//  One list of everything Wisp will do on its own later. Automations, buddies with their own
//  schedule and scheduled workflows each keep their own engine and storage, so Today's "Next up"
//  only ever showed automations. This is the rule for merging the three into one soonest-first
//  list and grouping it by day, so the user looks in one place. Nothing is removed or migrated:
//  the engines run exactly as before.
//
//  Pure on purpose (ids, titles, dates), so it is tested without the app.
//

import Foundation

nonisolated enum WispScheduledSource: String, Sendable {
    case automation
    case buddy
    case workflow
}

nonisolated struct WispScheduledItem: Identifiable, Equatable, Sendable {
    /// Unique across sources, e.g. "automation-<uuid>".
    let id: String
    let source: WispScheduledSource
    let title: String
    /// The buddy that owns it, for the face beside the row.
    let buddyID: UUID?
    let nextRun: Date
}

nonisolated enum WispScheduledDay: Int, Comparable, Sendable {
    case today = 0
    case tomorrow = 1
    case later = 2

    static func < (left: WispScheduledDay, right: WispScheduledDay) -> Bool {
        left.rawValue < right.rawValue
    }

    var title: String {
        switch self {
        case .today: return "Today"
        case .tomorrow: return "Tomorrow"
        case .later: return "Later"
        }
    }
}

nonisolated struct WispScheduledGroup: Equatable, Sendable {
    let day: WispScheduledDay
    let items: [WispScheduledItem]
}

nonisolated enum WispScheduledPolicy {
    /// Soonest first. A buddy whose schedule an automation owns is dropped, because the
    /// automation already lists it and the old buddy scheduler no longer runs it. The id breaks
    /// exact ties so rows never swap places between redraws.
    static func merged(
        automationItems: [WispScheduledItem],
        buddyItems: [WispScheduledItem],
        workflowItems: [WispScheduledItem],
        buddyIDsOwnedByAutomations: Set<UUID>
    ) -> [WispScheduledItem] {
        let standaloneBuddyItems = buddyItems.filter { item in
            guard let buddyID = item.buddyID else { return true }
            return !buddyIDsOwnedByAutomations.contains(buddyID)
        }
        return (automationItems + standaloneBuddyItems + workflowItems).sorted { left, right in
            if left.nextRun != right.nextRun { return left.nextRun < right.nextRun }
            return left.id < right.id
        }
    }

    /// Items already sorted soonest first, grouped Today / Tomorrow / Later. Empty groups are left out.
    static func grouped(
        _ items: [WispScheduledItem],
        now: Date,
        calendar: Calendar = .current
    ) -> [WispScheduledGroup] {
        var itemsByDay: [WispScheduledDay: [WispScheduledItem]] = [:]
        for item in items {
            itemsByDay[day(of: item.nextRun, now: now, calendar: calendar), default: []].append(item)
        }
        return itemsByDay.keys.sorted().map { WispScheduledGroup(day: $0, items: itemsByDay[$0] ?? []) }
    }

    static func day(of date: Date, now: Date, calendar: Calendar = .current) -> WispScheduledDay {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return .tomorrow
        }
        return .later
    }

    /// The next time a "HH:mm" workflow trigger fires strictly after `date`, or nil if the text isn't a time.
    static func nextDailyRun(timeText: String, after date: Date, calendar: Calendar = .current) -> Date? {
        let parts = timeText.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return calendar.nextDate(
            after: date,
            matching: DateComponents(hour: hour, minute: minute, second: 0),
            matchingPolicy: .nextTime
        )
    }
}
