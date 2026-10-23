//
//  CanvasPageMatching.swift
//  leanring-buddy
//
//  The pure side of the Canvas page helper (phase 10): what the Wisp Tabs
//  extension reads from a Canvas assignment page, whether Wisp trusts the page's
//  host as Canvas, how the page is matched against the Canvas feed, today's
//  checklist and approved study blocks, and the words Wisp says about it.
//
//  Matching is keyed by the Canvas UID when the page exposes it: an assignment at
//  `/courses/45/assignments/1234` is the feed's `event-assignment-1234`. Otherwise
//  it falls back to the title plus the due date.
//
//  The host rule: `*.instructure.com`, or the host of the user's saved Canvas
//  feed. The feed URL is a secret that lives only in the Keychain; callers pass
//  its host alone, and nothing here ever sees the rest of it.
//
//  Page text is untrusted (contracts.md §6): titles, descriptions and rubric
//  lines reach a model only inside the <<< >>> data fence.
//
//  Pure (Foundation only), tested by `Tests/ChromeExtSiteHelpers`.
//

import Foundation

// MARK: - What the extension sends

/// `getCanvasAssignmentDetails`' result.
nonisolated struct CanvasAssignmentDetails: Decodable, Equatable, Sendable {
    struct RubricCriterion: Decodable, Equatable, Sendable {
        let criterion: String
        let points: String
    }

    let tabId: Int
    let windowId: Int?
    let url: String
    let courseId: String
    let assignmentId: String
    let title: String
    let courseName: String
    /// The due date as the page words it ("Oct 25 at 11:59pm").
    let dueText: String
    /// ISO 8601, or "" when the page has no due date Wisp could read.
    let dueAt: String
    let pointsPossible: String
    let submissionTypes: String
    let rubric: [RubricCriterion]
    let rubricTotal: String
    let description: String
    let truncated: Bool

    var dueDate: Date? { CanvasAssignmentPageMatcher.date(fromISOText: dueAt) }
}

/// The `site.canvasAssignmentOpened` event's payload.
nonisolated struct CanvasAssignmentOpenedPayload: Decodable, Equatable, Sendable {
    let tabId: Int
    let windowId: Int?
    let url: String
    let title: String
    let dueAt: String

    var dueDate: Date? { CanvasAssignmentPageMatcher.date(fromISOText: dueAt) }
}

// MARK: - Which pages are Canvas assignments

/// One assignment page, as its address identifies it.
nonisolated struct CanvasAssignmentPageReference: Equatable, Hashable, Sendable {
    let host: String
    let courseID: String
    let assignmentID: String

    /// The feed's UID for the same assignment.
    var feedUID: String { CanvasAssignmentPageMatcher.feedUID(forAssignmentID: assignmentID) }
    /// Remembers that the "Add to today?" chip was shown for this assignment.
    var offerKey: String { "\(host)|\(assignmentID)" }
}

nonisolated enum CanvasAssignmentPageMatcher {

    /// Canvas's own cloud hosting; schools on a custom domain are trusted through
    /// the host of their saved feed instead.
    static let instructureHostSuffix = ".instructure.com"

    static func feedUID(forAssignmentID assignmentID: String) -> String {
        "event-assignment-\(assignmentID)"
    }

    /// `school.instructure.com`, or exactly the saved feed's host.
    static func isTrustedCanvasHost(_ host: String, savedCanvasFeedHost: String?) -> Bool {
        let normalizedHost = host.lowercased()
        guard !normalizedHost.isEmpty else { return false }
        if normalizedHost.hasSuffix(instructureHostSuffix) && normalizedHost.count > instructureHostSuffix.count {
            return true
        }
        if let savedCanvasFeedHost, !savedCanvasFeedHost.isEmpty {
            return normalizedHost == savedCanvasFeedHost.lowercased()
        }
        return false
    }

    /// The assignment an https address on a trusted host points at, or nil.
    static func reference(forPageURLString pageURLString: String, savedCanvasFeedHost: String?) -> CanvasAssignmentPageReference? {
        guard let components = URLComponents(string: pageURLString),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              isTrustedCanvasHost(host, savedCanvasFeedHost: savedCanvasFeedHost) else { return nil }
        let pathParts = components.path.split(separator: "/").map(String.init)
        guard pathParts.count >= 4,
              pathParts[0] == "courses", pathParts[2] == "assignments",
              isDigits(pathParts[1]), isDigits(pathParts[3]) else { return nil }
        return CanvasAssignmentPageReference(host: host.lowercased(), courseID: pathParts[1], assignmentID: pathParts[3])
    }

    /// Whether an address's path looks like an assignment, on any https host. Used
    /// to remember which tabs to keep an eye on before the host rule applies.
    static func hasAssignmentPath(_ pageURLString: String) -> Bool {
        guard let components = URLComponents(string: pageURLString), components.scheme?.lowercased() == "https" else { return false }
        let pathParts = components.path.split(separator: "/").map(String.init)
        return pathParts.count >= 4 && pathParts[0] == "courses" && pathParts[2] == "assignments"
            && isDigits(pathParts[1]) && isDigits(pathParts[3])
    }

    /// ISO 8601 with or without fractional seconds (JavaScript's `toISOString`
    /// writes them; a `<time datetime>` may not).
    static func date(fromISOText isoText: String) -> Date? {
        let trimmedText = isoText.trimmingCharacters(in: .whitespaces)
        guard !trimmedText.isEmpty else { return nil }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let fractionalDate = fractionalFormatter.date(from: trimmedText) { return fractionalDate }
        let plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]
        return plainFormatter.date(from: trimmedText)
    }

    private static func isDigits(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

// MARK: - Against the feed, the checklist and the calendar

nonisolated struct CanvasAssignmentStatus: Equatable, Sendable {
    enum FeedMatch: Equatable, Sendable {
        case byUID
        case byTitleAndDueDate
        case notInFeed
    }

    let feedMatch: FeedMatch
    let matchedFeedItem: CanvasItem?
    /// The row on today's checklist, if it is there.
    let todayChecklistItem: ChecklistItem?
    /// Canvas items are mirrored into the "Wisp" calendar while the Canvas job is
    /// on and has calendar access, so a feed item is on that calendar.
    let isOnWispCalendar: Bool
    let approvedStudyBlocks: [StudyBlockProposal]
    /// The UID everything about this assignment is keyed by: the feed item's, or
    /// the one the feed would give the page's assignment.
    let itemUID: String

    var isOnTodayChecklist: Bool { todayChecklistItem != nil }
}

nonisolated enum CanvasAssignmentChecklistMatcher {

    /// How far apart the page's due time and the feed's may be and still be the
    /// same assignment: the page shows minutes, the feed has seconds.
    static let dueDateTolerance: TimeInterval = 90

    static func status(
        pageReference: CanvasAssignmentPageReference,
        pageTitle: String,
        pageDueDate: Date?,
        feedItems: [CanvasItem],
        todayChecklist: [ChecklistItem],
        approvedStudyBlocks: [StudyBlockProposal],
        isCanvasCalendarMirrored: Bool
    ) -> CanvasAssignmentStatus {
        let normalizedPageTitle = normalizedTitle(pageTitle)

        var feedMatch = CanvasAssignmentStatus.FeedMatch.notInFeed
        var matchedFeedItem = feedItems.first { $0.uid == pageReference.feedUID }
        if matchedFeedItem != nil {
            feedMatch = .byUID
        } else if !normalizedPageTitle.isEmpty {
            let sameTitleItems = feedItems.filter {
                ($0.kind == .assignment || $0.kind == .quiz) && normalizedTitle($0.title) == normalizedPageTitle
            }
            if let pageDueDate {
                matchedFeedItem = sameTitleItems.first { abs($0.startDate.timeIntervalSince(pageDueDate)) <= dueDateTolerance }
            } else if sameTitleItems.count == 1 {
                // No due date on the page: the title alone, but only when it can't be another assignment.
                matchedFeedItem = sameTitleItems.first
            }
            if matchedFeedItem != nil { feedMatch = .byTitleAndDueDate }
        }

        let itemUID = matchedFeedItem?.uid ?? pageReference.feedUID
        let todayChecklistItem = todayChecklist.first { DayChecklistBuilder.sourceKey(fromItemID: $0.id) == itemUID }
            ?? todayChecklist.first { checklistItem in
                (checklistItem.origin == .canvasDue || checklistItem.origin == .rolledOver)
                    && !normalizedPageTitle.isEmpty
                    && normalizedTitle(checklistItem.title) == normalizedPageTitle
            }

        return CanvasAssignmentStatus(
            feedMatch: feedMatch,
            matchedFeedItem: matchedFeedItem,
            todayChecklistItem: todayChecklistItem,
            isOnWispCalendar: matchedFeedItem != nil && isCanvasCalendarMirrored,
            approvedStudyBlocks: approvedStudyBlocks
                .filter { $0.forItemUID == itemUID }
                .sorted { $0.start < $1.start },
            itemUID: itemUID
        )
    }

    /// The Canvas item to add or plan: the feed's own when it matched, else one
    /// built from the page under the UID the feed would give it, so a later sync
    /// merges with it. Nil without a due date (there is nothing to plan toward).
    static func canvasItem(
        pageReference: CanvasAssignmentPageReference,
        pageTitle: String,
        pageDueDate: Date?,
        pageURLString: String,
        status: CanvasAssignmentStatus
    ) -> CanvasItem? {
        if let matchedFeedItem = status.matchedFeedItem { return matchedFeedItem }
        guard let pageDueDate else { return nil }
        let trimmedTitle = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }
        return CanvasItem(
            uid: pageReference.feedUID,
            title: trimmedTitle,
            courseCode: nil,
            kind: .assignment,
            startDate: pageDueDate,
            endDate: nil,
            isAllDay: false,
            location: nil,
            descriptionText: nil,
            // The assignment page itself, never the feed.
            linkURLString: pageURLString,
            contentFingerprint: "page:\(pageReference.feedUID)|\(trimmedTitle)|\(Int(pageDueDate.timeIntervalSince1970))"
        )
    }

    /// Lowercased, whitespace-collapsed, without a trailing "[COURSE]" (the feed
    /// appends one; the page doesn't).
    static func normalizedTitle(_ title: String) -> String {
        var workingTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if workingTitle.hasSuffix("]"), let openingBracketRange = workingTitle.range(of: "[", options: .backwards) {
            workingTitle = String(workingTitle[..<openingBracketRange.lowerBound])
        }
        return workingTitle.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

// MARK: - The "Add to today?" chip

nonisolated enum CanvasAddToTodayChipPolicy {
    /// At most once per assignment, only with the switch and the checklist on, only
    /// for one that isn't already listed and isn't past due.
    static func shouldOffer(
        status: CanvasAssignmentStatus,
        dueDate: Date?,
        offerKey: String,
        alreadyOfferedKeys: Set<String>,
        isOfferSwitchOn: Bool,
        isDailyChecklistEnabled: Bool,
        now: Date
    ) -> Bool {
        guard isOfferSwitchOn, isDailyChecklistEnabled else { return false }
        guard !alreadyOfferedKeys.contains(offerKey) else { return false }
        guard !status.isOnTodayChecklist else { return false }
        guard let dueDate, dueDate >= now else { return false }
        return true
    }

    /// The remembered keys, newest last, capped so the list can't grow forever.
    static let maximumRememberedOfferKeys = 300

    static func remembering(_ offerKey: String, in rememberedKeys: [String]) -> [String] {
        var updatedKeys = rememberedKeys.filter { $0 != offerKey }
        updatedKeys.append(offerKey)
        if updatedKeys.count > maximumRememberedOfferKeys {
            updatedKeys.removeFirst(updatedKeys.count - maximumRememberedOfferKeys)
        }
        return updatedKeys
    }
}

// MARK: - What Wisp says

nonisolated enum CanvasAssignmentReplyText {

    /// "Fri Oct 25, 11:59 PM", in the calendar's time zone.
    static func dueDateText(_ dueDate: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE MMM d, h:mm a"
        return formatter.string(from: dueDate)
    }

    private static func blockText(_ studyBlock: StudyBlockProposal, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE h:mm a"
        let endFormatter = DateFormatter()
        endFormatter.locale = Locale(identifier: "en_US_POSIX")
        endFormatter.timeZone = calendar.timeZone
        endFormatter.dateFormat = "h:mm a"
        return "\(formatter.string(from: studyBlock.start))–\(endFormatter.string(from: studyBlock.end))"
    }

    private static func quotedTitle(_ title: String) -> String {
        let collapsedTitle = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return "“\(String(collapsedTitle.prefix(120)))”"
    }

    /// "is this on my checklist?"
    static func statusReply(title: String, dueDate: Date?, status: CanvasAssignmentStatus, calendar: Calendar) -> String {
        var sentence = quotedTitle(title)
        if let dueDate { sentence += " (due \(dueDateText(dueDate, calendar: calendar)))" }
        switch (status.isOnTodayChecklist, status.isOnWispCalendar) {
        case (true, true):
            sentence += " is on today's checklist and your wisp calendar."
        case (true, false):
            sentence += " is on today's checklist."
        case (false, true):
            sentence += " isn't on today's checklist, but it's on your wisp calendar from your canvas feed. say \"add this to today\" to add it."
        case (false, false):
            sentence += status.feedMatch == .notInFeed
                ? " isn't on today's checklist, and it isn't in your canvas feed. say \"add this to today\" to add it."
                : " isn't on today's checklist. say \"add this to today\" to add it."
        }
        if let firstBlock = status.approvedStudyBlocks.first {
            let blockCount = status.approvedStudyBlocks.count
            sentence += blockCount == 1
                ? " you have a study block for it \(blockText(firstBlock, calendar: calendar))."
                : " you have \(blockCount) study blocks for it, the first \(blockText(firstBlock, calendar: calendar))."
        }
        return sentence
    }

    static func addToTodayReply(title: String, outcome: AddToTodayReplyOutcome) -> String {
        switch outcome {
        case .added: return "added \(quotedTitle(title)) to today's checklist."
        case .alreadyOnChecklist: return "\(quotedTitle(title)) is already on today's checklist."
        case .checklistTurnedOff: return "the daily checklist is off. turn it on in buddies → canvas, then ask again."
        case .checklistFull: return "today's checklist is full, so \(quotedTitle(title)) didn't fit. tick something off or rebuild it in buddies → canvas."
        case .noDueDate: return "i can't add \(quotedTitle(title)) — the page doesn't show a due date i can read."
        }
    }

    /// The same outcomes as `JobsEngine.AddToTodayOutcome`, plus the page having no
    /// date, mirrored here so this file stays free of the engine.
    enum AddToTodayReplyOutcome: Equatable, Sendable {
        case added, alreadyOnChecklist, checklistTurnedOff, checklistFull, noDueDate
    }

    static func planReply(title: String, outcome: PlanReplyOutcome, calendar: Calendar) -> String {
        switch outcome {
        case .written(let studyBlocks):
            let blockList = studyBlocks.map { blockText($0, calendar: calendar) }.joined(separator: ", ")
            return "added a study block for \(quotedTitle(title)) to your wisp calendar: \(blockList)."
        case .declined:
            return "okay, i didn't add a study block for \(quotedTitle(title))."
        case .alreadyPlanned(let studyBlocks):
            let firstBlock = studyBlocks.first.map { blockText($0, calendar: calendar) } ?? ""
            return "\(quotedTitle(title)) already has a study block: \(firstBlock)."
        case .noFreeTime:
            return "i couldn't find a free stretch before \(quotedTitle(title)) is due. try a shorter block length in buddies → canvas."
        case .noDueDate:
            return "i can't plan \(quotedTitle(title)) — the page doesn't show a due date i can read."
        case .pastDue:
            return "\(quotedTitle(title)) is already past due, so there's nothing to plan."
        case .tooFarAhead(let lookaheadDays):
            return "\(quotedTitle(title)) is due more than \(lookaheadDays) days out — i plan study blocks up to \(lookaheadDays) days ahead. ask again closer to it."
        }
    }

    enum PlanReplyOutcome: Equatable, Sendable {
        case written([StudyBlockProposal])
        case declined
        case alreadyPlanned([StudyBlockProposal])
        case noFreeTime
        case noDueDate
        case pastDue
        case tooFarAhead(lookaheadDays: Int)
    }

    static func notCanvasPageReply() -> String {
        "the tab you're looking at isn't a canvas assignment i know — open the assignment in chrome first."
    }
}

// MARK: - Into a prompt (the `chrome_canvas_assignment` tool)

nonisolated enum CanvasAssignmentPrompt {

    /// The local model's share of the description; a cloud model gets all of it.
    static let localModelDescriptionCharacterBudget = 3_000

    static func promptText(
        for details: CanvasAssignmentDetails,
        statusLine: String,
        isLocalModel: Bool
    ) -> String {
        let descriptionBudget = isLocalModel ? localModelDescriptionCharacterBudget : 8_000
        let trimmedDescription = ChromePageTextPrompt.trimmed(details.description, toCharacters: descriptionBudget)

        var fencedLines: [String] = []
        fencedLines.append("title: \(singleLine(details.title, maximumCharacters: 300))")
        if !details.courseName.isEmpty { fencedLines.append("course: \(singleLine(details.courseName, maximumCharacters: 200))") }
        if !details.dueText.isEmpty { fencedLines.append("due (as the page shows it): \(singleLine(details.dueText, maximumCharacters: 120))") }
        if !details.pointsPossible.isEmpty { fencedLines.append("points: \(details.pointsPossible)") }
        if !details.submissionTypes.isEmpty { fencedLines.append("submitting: \(singleLine(details.submissionTypes, maximumCharacters: 200))") }
        if !details.rubric.isEmpty {
            fencedLines.append("rubric\(details.rubricTotal.isEmpty ? "" : " (total \(details.rubricTotal))"):")
            for rubricCriterion in details.rubric {
                let pointsSuffix = rubricCriterion.points.isEmpty ? "" : " — \(rubricCriterion.points) pts"
                fencedLines.append("- \(singleLine(rubricCriterion.criterion, maximumCharacters: 200))\(pointsSuffix)")
            }
        }
        if !trimmedDescription.text.isEmpty {
            fencedLines.append("")
            fencedLines.append("description:")
            fencedLines.append(trimmedDescription.text)
        }

        var promptLines = [
            "the canvas assignment open in chrome, read from its page. \(statusLine)",
            "<<<",
            ChromePageTextPrompt.defused(fencedLines.joined(separator: "\n")),
            ">>>",
            ChromePageTextPrompt.dataFenceNote,
        ]
        if trimmedDescription.wasTrimmed || details.truncated {
            promptLines.append("(the description is longer than this; only its first part is shown.)")
        }
        return promptLines.joined(separator: "\n")
    }

    private static func singleLine(_ text: String, maximumCharacters: Int) -> String {
        String(text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces).prefix(maximumCharacters))
    }
}
