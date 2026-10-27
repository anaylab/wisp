//
//  MessageCommandParser.swift
//  leanring-buddy
//
//  Recognises "text mom i'm running late" and its common spoken shapes, so a
//  message can be sent without the model choosing a tool — the local 3B model
//  is unreliable at tool choice, and this is a command with two parameters.
//
//  Pure and conservative. It only reads the words; whether the recipient is a
//  real contact is decided later by `MessageRecipientResolver`, and anything
//  that isn't clearly a message command returns nil and reaches the model as
//  an ordinary turn.
//
//  The hard part is where the name ends. "text sarah saying see you soon" says
//  so; "text sarah chen see you soon" does not. For the second shape the parser
//  offers every plausible split (longest name first) and lets the resolver
//  pick the one that is actually someone in Contacts — with an exact match
//  required, so "text size bigger" never finds a contact called "size".
//

import Foundation

/// One reading of a message command: who, what, and whether the user marked
/// where the name ended.
struct MessageCommandCandidate: Equatable {
    let recipient: String
    let messageText: String
    /// True when a word like "saying" separated the name from the message.
    /// False for a guessed split, which must then match a contact exactly.
    let isRecipientBoundaryCertain: Bool
}

enum MessageCommandParser {

    /// Politeness and wake words said before the command itself.
    private static let leadInPattern = #"^(?:(?:hey |ok |okay )?wisp[,.]?\s+|please\s+|can you\s+|could you\s+|would you\s+|will you\s+)+"#

    /// The command verb, with the recipient following it. Longest first so
    /// "send a text message to" wins over "send a text".
    private static let verbBeforeRecipientPattern =
        #"^(?:send (?:an? )?(?:text message|imessage|message|text) to|send (?:an? )?(?:text message|imessage|message|text)|text message|imessage|message|text)\s+(.+)$"#

    /// "send mom a text saying …" — the recipient between "send" and the noun.
    private static let recipientBeforeNounPattern =
        #"^send\s+(.+?)\s+an?\s+(?:text message|imessage|message|text)\s+(.+)$"#

    /// "tell mom that i'm late" — only with "that", since "tell me a joke" and
    /// "tell her story" are not messages.
    private static let tellPattern = #"^tell\s+(.+?)\s+that\s+(.+)$"#

    /// Words that separate the name from the message, earliest one wins.
    private static let recipientMessageSeparators = [" saying ", " that says ", " to say ", " and say ", " that "]

    /// Recipients that mean the user or nobody in particular — "text me",
    /// "message him" — and so are never a contact lookup.
    private static let nonContactRecipients: Set<String> = [
        "me", "myself", "him", "her", "them", "us", "it", "someone", "somebody", "anyone", "everyone",
    ]

    /// Words that show the verb is being used as a noun ("text size", "message
    /// from mom") rather than the start of a command.
    private static let recipientStartWordsThatAreNotNames: Set<String> = [
        "from", "about", "to", "size", "box", "field", "the", "this", "that", "back", "on", "in", "for",
    ]

    /// How many words a guessed name may have ("sarah jane smith").
    private static let maximumGuessedRecipientWordCount = 3

    /// Every plausible reading of `transcript` as a message command, best
    /// first; nil when it isn't one.
    static func candidates(from transcript: String) -> [MessageCommandCandidate]? {
        var commandText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if let leadInRange = commandText.range(of: leadInPattern, options: [.regularExpression, .caseInsensitive]) {
            commandText.removeSubrange(leadInRange)
        }
        guard !commandText.isEmpty else { return nil }

        // "tell mom that …" and "send mom a text saying …" name the recipient
        // in a fixed slot, so the boundary is certain.
        // A shape that matches but yields no plausible name falls through to
        // the other shapes rather than ending the parse.
        if let tellGroups = captureGroups(of: tellPattern, in: commandText),
           let tellCandidate = certainCandidate(recipient: tellGroups[0], messageText: tellGroups[1]) {
            return tellCandidate
        }
        if let recipientBeforeNounGroups = captureGroups(of: recipientBeforeNounPattern, in: commandText),
           let recipientBeforeNounCandidate = certainCandidate(
               recipient: recipientBeforeNounGroups[0],
               messageText: strippingLeadingSeparatorWord(from: recipientBeforeNounGroups[1])
           ) {
            return recipientBeforeNounCandidate
        }

        guard let verbGroups = captureGroups(of: verbBeforeRecipientPattern, in: commandText) else { return nil }
        let recipientAndMessageText = verbGroups[0]

        // With a separator the boundary is known, so an implausible name ("text
        // me saying hi") ends the parse instead of being re-guessed.
        if containsRecipientMessageSeparator(recipientAndMessageText) {
            return candidateSplitAtSeparator(recipientAndMessageText)
        }
        return guessedSplitCandidates(recipientAndMessageText)
    }

    // MARK: - Splitting

    private static func containsRecipientMessageSeparator(_ recipientAndMessageText: String) -> Bool {
        recipientMessageSeparators.contains { separator in
            recipientAndMessageText.range(of: separator, options: .caseInsensitive) != nil
        }
    }

    private static func candidateSplitAtSeparator(_ recipientAndMessageText: String) -> [MessageCommandCandidate]? {
        let earliestSeparatorRange = recipientMessageSeparators
            .compactMap { separator in recipientAndMessageText.range(of: separator, options: .caseInsensitive) }
            .min { $0.lowerBound < $1.lowerBound }
        guard let earliestSeparatorRange else { return nil }

        let recipient = String(recipientAndMessageText[..<earliestSeparatorRange.lowerBound])
        let messageText = strippingLeadingSeparatorWord(from: String(recipientAndMessageText[earliestSeparatorRange.upperBound...]))
        return certainCandidate(recipient: recipient, messageText: messageText)
    }

    /// "sarah chen see you soon" → "sarah chen" / "see you soon", then "sarah"
    /// / "chen see you soon". At least one word is always left for the message.
    private static func guessedSplitCandidates(_ recipientAndMessageText: String) -> [MessageCommandCandidate]? {
        let words = recipientAndMessageText.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard words.count >= 2 else { return nil }

        let longestRecipientWordCount = min(maximumGuessedRecipientWordCount, words.count - 1)
        var guessedCandidates: [MessageCommandCandidate] = []
        for recipientWordCount in stride(from: longestRecipientWordCount, through: 1, by: -1) {
            let recipient = cleanedRecipient(words.prefix(recipientWordCount).joined(separator: " "))
            let messageText = words.dropFirst(recipientWordCount).joined(separator: " ")
            guard isPlausibleRecipient(recipient) else { continue }
            guessedCandidates.append(MessageCommandCandidate(
                recipient: recipient,
                messageText: messageText,
                isRecipientBoundaryCertain: false
            ))
        }
        return guessedCandidates.isEmpty ? nil : guessedCandidates
    }

    private static func certainCandidate(recipient rawRecipient: String, messageText rawMessageText: String) -> [MessageCommandCandidate]? {
        let recipient = cleanedRecipient(rawRecipient)
        let messageText = rawMessageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPlausibleRecipient(recipient), !messageText.isEmpty else { return nil }
        return [MessageCommandCandidate(recipient: recipient, messageText: messageText, isRecipientBoundaryCertain: true)]
    }

    // MARK: - Helpers

    /// "my mom" → "mom"; stray punctuation dropped.
    private static func cleanedRecipient(_ rawRecipient: String) -> String {
        var recipient = rawRecipient.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",:;")))
        if recipient.lowercased().hasPrefix("my ") {
            recipient = String(recipient.dropFirst(3))
        }
        return recipient.trimmingCharacters(in: .whitespaces)
    }

    private static func isPlausibleRecipient(_ recipient: String) -> Bool {
        let lowercasedRecipient = recipient.lowercased()
        guard !lowercasedRecipient.isEmpty,
              !nonContactRecipients.contains(lowercasedRecipient),
              let firstWord = lowercasedRecipient.split(separator: " ").first,
              !recipientStartWordsThatAreNotNames.contains(String(firstWord)) else { return false }
        return lowercasedRecipient.split(separator: " ").count <= 5
    }

    /// "saying that i'm late" → "i'm late".
    private static func strippingLeadingSeparatorWord(from messageText: String) -> String {
        let trimmedMessageText = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        for leadingWord in ["saying that ", "saying ", "that ", "to say "] where trimmedMessageText.lowercased().hasPrefix(leadingWord) {
            return String(trimmedMessageText.dropFirst(leadingWord.count))
        }
        return trimmedMessageText
    }

    private static func captureGroups(of pattern: String, in text: String) -> [String]? {
        guard let regularExpression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regularExpression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        return (1..<match.numberOfRanges).compactMap { groupIndex in
            Range(match.range(at: groupIndex), in: text).map { String(text[$0]) }
        }
    }
}
