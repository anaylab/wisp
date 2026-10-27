//
//  LearnedShortcutDisplay.swift
//  leanring-buddy
//
//  Pure: the plain-words lines the Settings list shows for a learned shortcut. The clock and the
//  locale are passed in so the wording is testable.
//

import Foundation

enum LearnedShortcutDisplay {
    /// "Ran 3 times · last ran 2 hours ago", "Not run yet", or "Never worked · last tried yesterday".
    static func runSummary(for shortcut: LearnedShortcut, now: Date, locale: Locale = .current) -> String {
        guard let lastRunAt = shortcut.lastRunAt else { return "Not run yet" }
        let lastRunText = relativeText(for: lastRunAt, now: now, locale: locale)
        if shortcut.successCount == 0 {
            return "Never worked · last tried \(lastRunText)"
        }
        let timesText = shortcut.successCount == 1 ? "1 time" : "\(shortcut.successCount) times"
        return "Ran \(timesText) · last ran \(lastRunText)"
    }

    /// The exact steps that will run, one plain line each. A blank shows by name.
    static func stepLines(for shortcut: LearnedShortcut) -> [String] {
        shortcut.steps.map { LearnedShortcutDraftEditing.plainDescription(of: $0) }
    }

    /// Why a shortcut isn't being used, or nil while it is. A shortcut the user switched off
    /// has no reason; one Wisp switched off carries `disabledReason`.
    static func attentionLine(for shortcut: LearnedShortcut) -> String? {
        if let disabledReason = shortcut.disabledReason, !shortcut.isEnabled { return disabledReason }
        if shortcut.isEnabled, shortcut.consecutiveFailures > 0 {
            return "The last run didn't work. One more failure turns it off."
        }
        return nil
    }

    /// Newest first, so a shortcut just saved is at the top.
    static func listOrder(_ shortcuts: [LearnedShortcut]) -> [LearnedShortcut] {
        shortcuts.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Private

    private static func relativeText(for date: Date, now: Date, locale: Locale) -> String {
        if abs(now.timeIntervalSince(date)) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = locale
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
