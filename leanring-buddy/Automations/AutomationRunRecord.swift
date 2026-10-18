//
//  AutomationRunRecord.swift
//  leanring-buddy
//
//  What one run of an automation did, kept for the run history, the "Needs you" list and the
//  notch faces. Numbers, status and a capped result text only: never a prompt, a screenshot, a
//  Canvas link or a key. Pure (Foundation only).
//

import Foundation

nonisolated enum AutomationRunReason: String, Codable, Sendable {
    case schedule, missedSchedule, event, manual, shortcutDigit, testRun

    /// Whether nobody was there to answer a prompt. Scheduled, event and test runs are
    /// unattended; the user pressing Run now (or a digit) is attended.
    var isUnattended: Bool {
        switch self {
        case .schedule, .missedSchedule, .event, .testRun: return true
        case .manual, .shortcutDigit: return false
        }
    }
}

nonisolated enum AutomationRunOutcome: Codable, Equatable, Sendable {
    /// First ~200 characters of the result.
    case succeeded(summary: String)
    /// Ran, nothing changed; not shown as news.
    case succeededNothingNew
    /// Plain words, never a secret or a feed URL.
    case failed(reason: String)
    /// An unattended step was declined or timed out.
    case needsApproval
    /// Another run of the same automation was already active.
    case skippedBusy
    case skippedPaused

    var isSuccess: Bool {
        switch self {
        case .succeeded, .succeededNothingNew: return true
        case .failed, .needsApproval, .skippedBusy, .skippedPaused: return false
        }
    }

    /// Shown in "Needs you": a failure with a reason, or a declined approval.
    var needsAttention: Bool {
        switch self {
        case .failed, .needsApproval: return true
        case .succeeded, .succeededNothingNew, .skippedBusy, .skippedPaused: return false
        }
    }
}

nonisolated struct AutomationRunRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let automationID: UUID
    let buddyID: UUID?
    let reason: AutomationRunReason
    let startedAt: Date
    var finishedAt: Date?
    /// Nil while running.
    var outcome: AutomationRunOutcome?
    /// Capped at `AutomationResultText.maximumStoredCharacters`, machine tags stripped.
    var resultText: String?
    /// `AgentTaskRegistry` id, links to History.
    var backgroundTaskID: UUID?
    /// Test runs are never persisted.
    var isTestRun: Bool

    init(
        id: UUID = UUID(),
        automationID: UUID,
        buddyID: UUID?,
        reason: AutomationRunReason,
        startedAt: Date,
        finishedAt: Date? = nil,
        outcome: AutomationRunOutcome? = nil,
        resultText: String? = nil,
        backgroundTaskID: UUID? = nil,
        isTestRun: Bool = false
    ) {
        self.id = id
        self.automationID = automationID
        self.buddyID = buddyID
        self.reason = reason
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.resultText = resultText
        self.backgroundTaskID = backgroundTaskID
        self.isTestRun = isTestRun
    }

    var isRunning: Bool { outcome == nil }
}

nonisolated struct AutomationAttentionItem: Identifiable, Equatable, Sendable {
    /// The record id.
    let id: UUID
    let automationID: UUID
    let title: String
    /// The failure reason or "needs your OK".
    let detail: String
    let occurredAt: Date
}

/// Cleans a model answer for storage and for the places an automation shows it.
nonisolated enum AutomationResultText {
    static let maximumStoredCharacters = 4000
    static let maximumSummaryCharacters = 200

    private static let inlineTagPattern = try! NSRegularExpression(
        pattern: #"\[(?:POINT|SAY|BOX|HIGHLIGHT|ARROW|CIRCLE|NOTE|STEP|TOOL)[:\s][^\]]*\]"#,
        options: [.caseInsensitive]
    )
    private static let sayTagPattern = try! NSRegularExpression(
        pattern: #"\[SAY:\s*([^\]]+)\]"#,
        options: [.caseInsensitive]
    )

    /// Machine tags stripped (the glance card tag runs to the end of the reply), whitespace
    /// tidied, capped.
    static func cleaned(_ answerText: String) -> String {
        var cleanedText = answerText
        if let cardTagRange = cleanedText.range(of: "[CARD:", options: .caseInsensitive) {
            cleanedText = String(cleanedText[..<cardTagRange.lowerBound])
        }
        cleanedText = inlineTagPattern.stringByReplacingMatches(
            in: cleanedText,
            range: NSRange(cleanedText.startIndex..., in: cleanedText),
            withTemplate: ""
        )
        // Removing a tag leaves a double space behind; tidy runs of spaces (not line breaks).
        cleanedText = cleanedText.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        cleanedText = cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleanedText.prefix(maximumStoredCharacters))
    }

    /// The first ~200 characters, on a word boundary where possible.
    static func summary(of answerText: String) -> String {
        let cleanedText = cleaned(answerText).replacingOccurrences(of: "\n", with: " ")
        guard cleanedText.count > maximumSummaryCharacters else { return cleanedText }
        let clipped = String(cleanedText.prefix(maximumSummaryCharacters))
        if let lastSpace = clipped.lastIndex(of: " "), clipped.distance(from: clipped.startIndex, to: lastSpace) > maximumSummaryCharacters / 2 {
            return String(clipped[..<lastSpace]) + "…"
        }
        return clipped + "…"
    }

    /// The model's `[SAY: ...]` line, for the spoken-line output.
    static func spokenLine(in answerText: String) -> String? {
        guard let match = sayTagPattern.firstMatch(in: answerText, range: NSRange(answerText.startIndex..., in: answerText)),
              let lineRange = Range(match.range(at: 1), in: answerText) else { return nil }
        let line = answerText[lineRange].trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : line
    }

    /// Checklist item titles from an answer: bullet or numbered lines, else the lines as they
    /// are. Capped, so a long answer does not flood Reminders.
    static func checklistTitles(from answerText: String, maximumCount: Int = 12) -> [String] {
        let lines = cleaned(answerText)
            .components(separatedBy: .newlines)
            .map { line -> String in
                var strippedLine = line.trimmingCharacters(in: .whitespaces)
                for bulletPrefix in ["- ", "* ", "• ", "– "] where strippedLine.hasPrefix(bulletPrefix) {
                    strippedLine = String(strippedLine.dropFirst(bulletPrefix.count))
                }
                if let numberRange = strippedLine.range(of: #"^\d{1,2}[.)]\s+"#, options: .regularExpression) {
                    strippedLine.removeSubrange(numberRange)
                }
                strippedLine = strippedLine.replacingOccurrences(of: "**", with: "")
                return strippedLine.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
            .map { String($0.prefix(120)) }
        return Array(lines.prefix(maximumCount))
    }
}

/// Which finished runs are still worth the user's attention.
nonisolated enum AutomationAttentionPolicy {
    static let windowSeconds: TimeInterval = 24 * 60 * 60

    /// The latest attention-worthy run per automation within the last 24 hours, newest first,
    /// skipping dismissed ones and any whose automation has since run fine or no longer exists.
    static func items(
        from records: [AutomationRunRecord],
        automationNamesByID: [UUID: String],
        dismissedRecordIDs: Set<UUID>,
        now: Date
    ) -> [AutomationAttentionItem] {
        var itemsByAutomationID: [UUID: AutomationAttentionItem] = [:]
        // Records arrive newest first; the first finished record per automation decides.
        var decidedAutomationIDs: Set<UUID> = []
        for record in records where !record.isTestRun {
            guard let outcome = record.outcome, let automationName = automationNamesByID[record.automationID] else { continue }
            switch outcome {
            case .skippedBusy, .skippedPaused:
                continue
            default:
                break
            }
            guard decidedAutomationIDs.insert(record.automationID).inserted else { continue }
            guard outcome.needsAttention,
                  now.timeIntervalSince(record.finishedAt ?? record.startedAt) <= windowSeconds,
                  !dismissedRecordIDs.contains(record.id) else { continue }

            let detail: String
            switch outcome {
            case .failed(let reason): detail = reason
            default: detail = "Needs your OK"
            }
            itemsByAutomationID[record.automationID] = AutomationAttentionItem(
                id: record.id,
                automationID: record.automationID,
                title: automationName,
                detail: detail,
                occurredAt: record.finishedAt ?? record.startedAt
            )
        }
        return itemsByAutomationID.values.sorted { $0.occurredAt > $1.occurredAt }
    }
}

/// When a finished run posts a notification.
nonisolated enum AutomationNotificationDecision {
    static func shouldPost(outcome: AutomationRunOutcome, outputs: [AutomationOutput], policy: AutomationNotifyPolicy) -> Bool {
        let hasNotificationOutput = outputs.contains(.notification)
        switch outcome {
        case .succeeded:
            return hasNotificationOutput && (policy == .always || policy == .onlyWhenSomethingNew)
        case .succeededNothingNew:
            return hasNotificationOutput && policy == .always
        case .failed, .needsApproval:
            return policy == .always || policy == .onlyOnFailure
        case .skippedBusy, .skippedPaused:
            return false
        }
    }
}

/// Failure reasons are shown to the user and stored: plain words, never a link.
nonisolated enum AutomationFailureText {
    private static let linkPattern = try! NSRegularExpression(pattern: #"(?:https?|webcal|file)://\S+"#, options: [.caseInsensitive])

    static func sanitized(_ reason: String) -> String {
        let withoutLinks = linkPattern.stringByReplacingMatches(
            in: reason,
            range: NSRange(reason.startIndex..., in: reason),
            withTemplate: "[link]"
        )
        let trimmed = withoutLinks.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Something went wrong." : String(trimmed.prefix(240))
    }
}
