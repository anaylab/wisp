//
//  AutomationQuickAddPlanner.swift
//  leanring-buddy
//
//  The pure decision behind quick add: does this line of speech or typing become an automation
//  draft card, or is it an ordinary question for the model? Kept separate from the router so a
//  plain `swiftc` suite can test it without the app.
//
//  Biased toward NOT matching. A wrongly captured question costs the user a detour through a card
//  they did not want; a missed automation costs nothing, because it goes on to the model like
//  any other turn and the Automations page is one click away.
//

import Foundation

nonisolated enum AutomationQuickAddDecision: Equatable, Sendable {
    /// Open the draft card with this pre-filled draft instead of sending a model turn.
    case openDraft(AutomationDraft)
    /// Not ours: carry on as an ordinary turn.
    case fallThrough
}

nonisolated enum AutomationQuickAddPlanner {
    /// A question that merely mentions a recurrence ("what happens every morning at the hospital?")
    /// is a question. These openers, with a trailing question mark, mark it as one.
    private static let questionOpeners = [
        "what", "whats", "what's", "why", "how", "who", "where", "which", "when", "is", "are", "does",
        "do", "did", "can", "could", "should", "would", "explain", "tell me about",
    ]

    /// A request phrased as a question that really is a request ("can you remind me at 6 to ...").
    private static let requestOpeners = [
        "remind me", "can you remind", "could you remind", "will you remind", "would you remind",
        "can you tell me when", "could you tell me when", "can you let me know when",
        "every", "each", "daily", "weekly",
    ]

    static func decide(
        transcript: String,
        now: Date,
        calendar: Calendar,
        buddies: [AutomationBuddyReference]
    ) -> AutomationQuickAddDecision {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AutomationDraftParser.looksLikeAutomationRequest(trimmedTranscript) else { return .fallThrough }
        guard !isPlainQuestion(trimmedTranscript) else { return .fallThrough }
        // "Tell me when it says Succeeded" / "tell me when this tab says Deployed" is a one-off
        // watch (screen or Chrome tab), not a standing automation; "whenever it says …" still is.
        guard ScreenWatchRequestParser.request(from: trimmedTranscript) == nil else { return .fallThrough }

        switch AutomationDraftParser.parse(trimmedTranscript, now: now, calendar: calendar, buddies: buddies) {
        case .draft(let completeDraft):
            return .openDraft(completeDraft)
        case .needsChoice(let draftWithOneOpenChoice, _, _):
            // The card opens with the unsure field highlighted, which is where the choice is made.
            return .openDraft(draftWithOneOpenChoice)
        case .unsure, .notAnAutomation:
            // "Unsure" looks like an automation but is too unclear to put in front of the user as
            // one; the model can answer it, and the Say-it box on the Automations page remains.
            return .fallThrough
        }
    }

    static func isPlainQuestion(_ text: String) -> Bool {
        let lowercasedText = text.lowercased()
        guard lowercasedText.hasSuffix("?") else { return false }
        if requestOpeners.contains(where: { lowercasedText.hasPrefix($0) }) { return false }
        return questionOpeners.contains { opener in
            lowercasedText == opener || lowercasedText.hasPrefix(opener + " ")
        }
    }
}
