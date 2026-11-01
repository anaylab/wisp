//
//  NoteCardFollowUp.swift
//  leanring-buddy
//
//  The pure side of asking a follow-up inside a note card (docs/note-cards-plan.md,
//  phase 3): the system prompt that tells the model what the card said and how to
//  answer, the earlier thread as history, and cleaning the reply for the card.
//  The model call itself is `CompanionManager.runNoteCardFollowUp`.
//
//  A follow-up is deliberately its own small turn, not the notch's full pipeline: the
//  fast-command routers there ("open safari", "set a timer") would catch a question
//  asked in a card, and the card has its own place to show the answer.
//

import Foundation

enum NoteCardFollowUp {
    static let maximumHistoryMessages = 8
    static let maximumCharactersPerHistoryMessage = 1200

    /// What the model is told: who it is here, what it already said on the screen, and
    /// how to answer. The card's steps are quoted as data the model wrote earlier.
    static func systemPrompt(for card: NoteCard) -> String {
        let explanation = card.steps.enumerated()
            .map { index, step in card.steps.count > 1 ? "\(index + 1). \(step.text)" : step.text }
            .joined(separator: "\n")
        return """
        you are wisp, a warm companion that lives in the user's menu bar. a moment ago you explained something on the user's screen, and it is now showing in a small card beside what it is about. the user is asking a follow-up in that card.

        what the card says:
        \(explanation)

        how to answer:
        - answer the follow-up directly, in plain words. a few short sentences is usually right; go longer only when the user asks you to go deeper or explain step by step.
        - if an image is attached it is a close-up of the part of the screen the card is about. use it to answer, and say so plainly if you cannot read it.
        - inline markdown (**bold**, `code`) is fine. no headings, no tables, and never any square-bracket tags such as [POINT], [BOX], [NOTE] or [SAY].
        - you cannot draw on the screen from here, so do not offer to.
        """
    }

    /// The earlier questions and answers as history, oldest first: the last few, clipped,
    /// leaving out the exchange being asked now (the final user + empty streaming pair),
    /// failures and anything empty.
    static func history(from card: NoteCard) -> [(role: NoteCardMessage.Role, text: String)] {
        var earlierMessages = card.thread
        // Drop the question just added and the answer waiting to be filled in.
        if earlierMessages.last?.isStreaming == true { earlierMessages.removeLast() }
        if earlierMessages.last?.role == .user { earlierMessages.removeLast() }

        return earlierMessages
            .filter { !$0.isFailure && !$0.text.isEmpty }
            .suffix(maximumHistoryMessages)
            .map { message in
                (message.role, String(message.text.prefix(maximumCharactersPerHistoryMessage)))
            }
    }

    /// The reply as the card shows it: machine tags removed, surrounding space trimmed.
    /// Streamed text goes through this too, so a half-written tag never flashes by.
    static func displayText(fromModelReply modelReply: String) -> String {
        var cleaned = balancingInlineMarkdown(AnswerDisplayText.cleaned(modelReply))
        // A tag still being written has no closing bracket yet: hide it until it does.
        if let openBracket = cleaned.lastIndex(of: "["), !cleaned[openBracket...].contains("]") {
            let possibleTag = cleaned[openBracket...]
            let tagNames = ["POINT", "BOX", "HIGHLIGHT", "ARROW", "SAY", "TOOL", "NOTE", "CIRCLE", "CARD", "STEP"]
            let looksLikeTag = tagNames.contains { possibleTag.uppercased().dropFirst().hasPrefix($0) || $0.hasPrefix(possibleTag.uppercased().dropFirst()) }
            if looksLikeTag { cleaned = String(cleaned[..<openBracket]).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return cleaned
    }

    /// While a reply streams, a bold or code span is open until its closing marker arrives, and
    /// the card would show the bare `**` or backtick for a moment. An unmatched marker is removed
    /// (the last one, which is the one still waiting for its partner).
    static func balancingInlineMarkdown(_ text: String) -> String {
        var balanced = text
        for marker in ["**", "`"] {
            let markerCount = balanced.components(separatedBy: marker).count - 1
            if markerCount % 2 == 1, let lastMarkerRange = balanced.range(of: marker, options: .backwards) {
                balanced.removeSubrange(lastMarkerRange)
                balanced = balanced.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return balanced
    }

    /// Text for VoiceOver and announcements: the same words without the `**` and backtick markers,
    /// which a screen reader would speak aloud.
    static func spokenText(fromMarkdown markdown: String) -> String {
        markdown
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
    }

    /// The one-tap follow-ups under a card's steps. Each is just a fixed question, asked the
    /// ordinary way, so they need no machinery of their own.
    enum Chip: CaseIterable {
        case simpler, example, quiz

        var title: String {
            switch self {
            case .simpler: return "Simpler"
            case .example: return "Example"
            case .quiz: return "Quiz me"
            }
        }

        var question: String {
            switch self {
            case .simpler: return "Explain that more simply."
            case .example: return "Give me a worked example of this."
            case .quiz: return "Quiz me on this with one short question, then wait for my answer."
            }
        }
    }

    /// The card as plain text for the clipboard: the steps, numbered when there are several, then
    /// anything asked in the card. Failed answers are left out.
    static func clipboardText(for card: NoteCard) -> String {
        var lines = card.steps.enumerated().map { index, step in
            card.steps.count > 1 ? "\(index + 1). \(step.text)" : step.text
        }
        let conversation = card.thread.filter { !$0.isFailure && !$0.text.isEmpty }
        if !conversation.isEmpty {
            lines.append("")
            for message in conversation {
                lines.append(message.role == .user ? "Q: \(message.text)" : "A: \(message.text)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static let failureMessage = "I couldn't answer that one. Try asking again."
}
