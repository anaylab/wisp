//
//  CanvasModels.swift
//  leanring-buddy
//
//  Pure value types for the Canvas calendar job: one item from the feed, the
//  difference between two syncs, and the persisted snapshot. Foundation only.
//
//  Every type is `nonisolated` on purpose: the app target defaults to
//  MainActor isolation, but the feed store and EventKit writers are actors
//  and the parser runs off the main thread, so these must be usable anywhere.
//

import Foundation

nonisolated struct CanvasItem: Equatable, Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case assignment, quiz, calendarEvent, other
    }

    /// Raw feed UID, e.g. "event-assignment-123". The idempotency key for every write.
    let uid: String
    /// SUMMARY without the trailing " [CODE]".
    let title: String
    /// Content of the trailing [..] in SUMMARY, nil if absent.
    let courseCode: String?
    /// Inferred from the UID prefix.
    let kind: Kind
    /// DTSTART (for an assignment this is its due time).
    let startDate: Date
    /// DTEND, nil if absent or equal to the start.
    let endDate: Date?
    /// True for DTSTART;VALUE=DATE; `startDate` is then local start-of-day.
    let isAllDay: Bool
    let location: String?
    /// Plain DESCRIPTION, unescaped.
    let descriptionText: String?
    /// The ICS URL property (an item page, not the secret feed URL).
    let linkURLString: String?
    /// Deterministic FNV-1a 64 (hex) of title|start|end|allDay|location|description.
    let contentFingerprint: String
}

nonisolated struct CanvasItemChange: Equatable, Codable, Sendable {
    enum Field: String, Codable, Sendable {
        case title, start, end, location, description, allDay
    }

    let before: CanvasItem
    let after: CanvasItem
    /// Sorted by `Field.rawValue` so the value is deterministic.
    let changedFields: [Field]
}

nonisolated struct CanvasDiff: Equatable, Codable, Sendable {
    let added: [CanvasItem]
    let changed: [CanvasItemChange]
    let removed: [CanvasItem]
    let unchangedCount: Int
    let isFirstSync: Bool

    var isEmpty: Bool { added.isEmpty && changed.isEmpty && removed.isEmpty }

    /// "2 new, 1 changed, 1 removed", leaving out zero parts; "No changes" when empty.
    var summaryLine: String {
        var parts: [String] = []
        if !added.isEmpty { parts.append("\(added.count) new") }
        if !changed.isEmpty { parts.append("\(changed.count) changed") }
        if !removed.isEmpty { parts.append("\(removed.count) removed") }
        return parts.isEmpty ? "No changes" : parts.joined(separator: ", ")
    }
}

nonisolated struct CanvasSnapshot: Equatable, Codable, Sendable {
    let fetchedAt: Date
    /// Sorted by startDate then uid.
    let items: [CanvasItem]
}

// MARK: - Study blocks

nonisolated struct BusyInterval: Equatable, Codable, Sendable {
    let start: Date
    let end: Date
}

nonisolated struct StudyBlockSettings: Equatable, Codable, Sendable {
    var isEnabled: Bool
    /// Clamped to 30...180 when used.
    var blockMinutes: Int
    /// A free gap shorter than this is skipped.
    var minimumGapMinutes: Int
    /// Kept clear on either side of busy time.
    var bufferMinutes: Int
    var workdayStartMinuteOfDay: Int
    var workdayEndMinuteOfDay: Int
    var lookaheadDays: Int
    var maximumBlocksPerDay: Int

    static let `default` = StudyBlockSettings(
        isEnabled: true,
        blockMinutes: 90,
        minimumGapMinutes: 100,
        bufferMinutes: 15,
        workdayStartMinuteOfDay: 9 * 60,
        workdayEndMinuteOfDay: 21 * 60,
        lookaheadDays: 7,
        maximumBlocksPerDay: 2
    )
}

nonisolated struct StudyBlockProposal: Identifiable, Equatable, Codable, Sendable {
    /// Stable: "study-<itemUID>-<yyyyMMdd>-<index>".
    let id: String
    let forItemUID: String
    /// "Study: <item title>".
    let title: String
    let courseCode: String?
    let start: Date
    let end: Date
}
