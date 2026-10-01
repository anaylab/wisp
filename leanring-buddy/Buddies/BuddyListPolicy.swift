//
//  BuddyListPolicy.swift
//  leanring-buddy
//
//  The pure rules behind how buddies are listed (modeled on Rakazo's bot list):
//  which ones have news the user hasn't seen, what order they sit in, what a
//  copy is called, and which runs make up a buddy's visible thread. Kept free
//  of the stores so `Tests/BuddyThread` checks them without the app.
//

import Foundation

enum BuddyListPolicy {
    /// Whether a buddy has a finished run the user hasn't looked at yet.
    ///
    /// - Parameter latestFinishedRunAt: when its latest run that counts as news
    ///   ended (see `isNews(_:)`); nil when there is none.
    /// - Parameter lastReadAt: when the user last had its thread open; nil
    ///   means never, so anything since `createdAt` counts.
    /// - Parameter isMarkedUnread: the user asked to keep it unread.
    static func isUnread(
        latestFinishedRunAt: Date?,
        lastReadAt: Date?,
        createdAt: Date,
        isMarkedUnread: Bool
    ) -> Bool {
        if isMarkedUnread { return true }
        guard let latestFinishedRunAt else { return false }
        return latestFinishedRunAt > (lastReadAt ?? createdAt)
    }

    /// A finished run is news unless the user stopped it themselves (they
    /// already know) or it was cut off by Wisp quitting (nothing to read).
    static func isNews(_ status: AgentTaskRecord.Status) -> Bool {
        switch status {
        case .succeeded, .failed: return true
        case .running, .waitingForApproval, .cancelled, .interrupted: return false
        }
    }

    /// Pinned buddies first, then whichever did something most recently, then
    /// the newest. Generic over the item so the rule is tested without the
    /// store; the app passes `WispBuddy`s (`BuddyStore.orderedBuddies`).
    static func ordered<Item>(
        _ items: [Item],
        isPinned: (Item) -> Bool,
        lastActivityAt: (Item) -> Date,
        createdAt: (Item) -> Date
    ) -> [Item] {
        items.sorted { firstItem, secondItem in
            if isPinned(firstItem) != isPinned(secondItem) {
                return isPinned(firstItem)
            }
            let firstActivityAt = lastActivityAt(firstItem)
            let secondActivityAt = lastActivityAt(secondItem)
            if firstActivityAt != secondActivityAt {
                return firstActivityAt > secondActivityAt
            }
            return createdAt(firstItem) > createdAt(secondItem)
        }
    }

    /// "Gmail Digest copy", then "Gmail Digest copy 2", …
    static func duplicateName(of originalName: String, existingNames: [String]) -> String {
        let takenNames = Set(existingNames.map { $0.lowercased() })
        let baseName = "\(originalName) copy"
        guard takenNames.contains(baseName.lowercased()) else { return baseName }
        var suffixNumber = 2
        while takenNames.contains("\(baseName) \(suffixNumber)".lowercased()) {
            suffixNumber += 1
        }
        return "\(baseName) \(suffixNumber)"
    }

    /// The runs shown in a buddy's thread, oldest first. The thread store keeps
    /// far more exchanges (100) than the buddy keeps run ids (20), so the
    /// thread is built from the exchanges; run ids with no exchange (runs from
    /// before buddies had threads) come first, since they are older.
    static func threadTaskIDs(exchangeTaskIDs: [UUID], runTaskIDs: [UUID]) -> [UUID] {
        let exchangeTaskIDSet = Set(exchangeTaskIDs)
        let runsWithoutExchange = runTaskIDs.filter { !exchangeTaskIDSet.contains($0) }
        return runsWithoutExchange + exchangeTaskIDs
    }

    /// Jobs offered on an empty new-buddy form, each one Wisp can actually do
    /// with its built-in tools. The wording sets the schedule
    /// (`BuddySchedule.inferred`).
    static let starterJobs: [(symbolName: String, instruction: String)] = [
        ("newspaper", "Every morning, summarize the top stories on Hacker News"),
        ("calendar", "Every morning, tell me what's on my calendar today and what to prepare"),
        ("checklist", "Every evening, list my reminders that are due tomorrow"),
        ("chart.line.uptrend.xyaxis", "Every Monday, check GitHub trending for interesting Swift projects"),
    ]
}

/// A buddy's answer as styled text. Models write markdown (**bold**, `code`,
/// links); drawn raw, the asterisks and backticks are noise. Inline syntax
/// only, keeping the line breaks, so "- item" lists still read as lists.
enum BuddyAnswerFormatting {
    static func attributedAnswer(_ answerText: String) -> AttributedString {
        let parsingOptions = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: answerText, options: parsingOptions)) ?? AttributedString(answerText)
    }
}
