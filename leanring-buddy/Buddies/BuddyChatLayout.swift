//
//  BuddyChatLayout.swift
//  leanring-buddy
//
//  The pure rules behind a buddy chat's layout, taken from OpenBot's
//  conversation: day separators between entries, when an answer continues the
//  run above it (and so draws no avatar of its own), and unsent composer text
//  that survives switching thread, buddy or quitting. Free of the stores and
//  views so `Tests/BuddyThread` checks them without the app.
//

import Foundation

enum BuddyChatLayoutPolicy {
    /// How long a run of answers stays one block. Beyond it the avatar and time
    /// return, because a reply an hour later is a new turn, not a continuation.
    static let runGroupingWindowSeconds: TimeInterval = 5 * 60

    /// "Today", "Yesterday", the weekday within the last week, else the date
    /// (with the year only when it isn't this one).
    static func dayLabel(for date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let startOfToday = calendar.startOfDay(for: now)
        let startOfDate = calendar.startOfDay(for: date)
        let daysAgo = calendar.dateComponents([.day], from: startOfDate, to: startOfToday).day ?? 0
        let format = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar)
        if daysAgo > 0 && daysAgo < 7 {
            return date.formatted(format.weekday(.wide))
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return sameYear
            ? date.formatted(format.month(.abbreviated).day())
            : date.formatted(format.month(.abbreviated).day().year())
    }

    /// Whether a day separator stands above the entry. The first entry always has one.
    static func startsNewDay(previous: Date?, current: Date, calendar: Calendar = .current) -> Bool {
        guard let previous else { return true }
        return !calendar.isDate(previous, inSameDayAs: current)
    }

    /// Whether an answer continues the run above it: no message from the user
    /// in between, no day break, and close enough in time. An unreadable time
    /// (no date) never continues a run.
    static func continuesAnswerRun(
        previous: Date?,
        current: Date?,
        currentHasUserMessage: Bool,
        startsNewDay: Bool
    ) -> Bool {
        guard let previous, let current, !currentHasUserMessage, !startsNewDay else { return false }
        let elapsed = current.timeIntervalSince(previous)
        return elapsed >= 0 && elapsed <= runGroupingWindowSeconds
    }

    /// Whether the scroll position is at the bottom, within a little slack so a
    /// tiny overscroll or a late layout doesn't flash the jump button.
    static func isAtBottom(contentOffsetY: CGFloat, containerHeight: CGFloat, contentHeight: CGFloat, slack: CGFloat = 48) -> Bool {
        contentOffsetY + containerHeight >= contentHeight - slack
    }
}

/// Unsent composer text, one draft per buddy thread, kept in UserDefaults so
/// switching thread or buddy, or quitting, loses nothing. Text only, as in
/// OpenBot: a restored attachment would point at nothing.
struct BuddyComposerDraftStore {
    private let defaults: UserDefaults
    private static let storageKey = "wisp.buddyComposerDrafts"
    /// A draft is kept this long untouched, so abandoned ones don't pile up.
    private static let maximumDrafts = 60

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `threadID` nil is the main thread.
    static func key(buddyID: UUID, threadID: UUID?) -> String {
        buddyID.uuidString + "/" + (threadID?.uuidString ?? "main")
    }

    func draft(buddyID: UUID, threadID: UUID?) -> String {
        stored()[Self.key(buddyID: buddyID, threadID: threadID)] ?? ""
    }

    /// A blank draft removes the entry.
    func save(_ text: String, buddyID: UUID, threadID: UUID?) {
        var drafts = stored()
        let key = Self.key(buddyID: buddyID, threadID: threadID)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            drafts[key] = nil
        } else {
            drafts[key] = text
        }
        if drafts.count > Self.maximumDrafts {
            for extraKey in drafts.keys.sorted().prefix(drafts.count - Self.maximumDrafts) where extraKey != key {
                drafts[extraKey] = nil
            }
        }
        defaults.set(drafts, forKey: Self.storageKey)
    }

    /// Forgets every draft of a buddy (it was deleted or its conversation cleared).
    func removeDrafts(ofBuddyWithID buddyID: UUID) {
        let prefix = buddyID.uuidString + "/"
        let remaining = stored().filter { !$0.key.hasPrefix(prefix) }
        defaults.set(remaining, forKey: Self.storageKey)
    }

    private func stored() -> [String: String] {
        defaults.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
    }
}
