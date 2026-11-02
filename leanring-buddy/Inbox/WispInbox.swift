//
//  WispInbox.swift
//  leanring-buddy
//
//  The one list of things waiting on the user. Approvals, failed runs, health
//  problems and finished results used to appear as separate cards in separate
//  places; this is the rule for putting them in one order and showing only as
//  many as fit calmly. Idea borrowed from AgentUse's approval queue and
//  Paperclip's inbox: agents work quietly, and anything that needs a person
//  lands in one place.
//
//  Pure on purpose: it sees only ids, kinds and dates, so it is tested without
//  the app. The view keeps the titles and actions and looks them up by id.
//

import Foundation

nonisolated enum WispInboxKind: Int, Comparable, Sendable {
    /// Something is blocked until the user says yes or no.
    case approval = 0
    /// A run failed or was cut off.
    case failure = 1
    /// Wisp itself can't work properly (model not running, listening paused).
    case system = 2
    /// Work finished while the user was away. Nothing is wrong.
    case result = 3

    static func < (left: WispInboxKind, right: WispInboxKind) -> Bool {
        left.rawValue < right.rawValue
    }
}

nonisolated struct WispInboxEntry: Equatable, Sendable {
    let id: String
    let kind: WispInboxKind
    let occurredAt: Date
}

nonisolated struct WispInboxLayout: Equatable, Sendable {
    /// Ids to show, most pressing first.
    let shownIDs: [String]
    /// How many more are waiting behind "Show more".
    let hiddenCount: Int
}

nonisolated enum WispInboxPolicy {
    /// Enough to act on at a glance; the rest sit behind "Show more".
    static let defaultVisibleLimit = 3

    /// Approvals first, then failures, then system problems, then results. Newest first
    /// within a kind; the id breaks exact ties so the order never flickers between redraws.
    static func ordered(_ entries: [WispInboxEntry]) -> [WispInboxEntry] {
        entries.sorted { left, right in
            if left.kind != right.kind { return left.kind < right.kind }
            if left.occurredAt != right.occurredAt { return left.occurredAt > right.occurredAt }
            return left.id < right.id
        }
    }

    /// An approval is never hidden behind "Show more", even past the limit, because a
    /// blocked agent that nobody can see is the failure this inbox exists to prevent.
    static func layout(
        of entries: [WispInboxEntry],
        visibleLimit: Int = defaultVisibleLimit,
        showsAll: Bool = false
    ) -> WispInboxLayout {
        let orderedEntries = ordered(entries)
        if showsAll {
            return WispInboxLayout(shownIDs: orderedEntries.map(\.id), hiddenCount: 0)
        }
        var shownIDs: [String] = []
        for entry in orderedEntries {
            if shownIDs.count < max(visibleLimit, 0) || entry.kind == .approval {
                shownIDs.append(entry.id)
            }
        }
        return WispInboxLayout(shownIDs: shownIDs, hiddenCount: orderedEntries.count - shownIDs.count)
    }
}
