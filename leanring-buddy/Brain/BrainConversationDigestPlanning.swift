//
//  BrainConversationDigestPlanning.swift
//  leanring-buddy
//
//  The pure side of the conversation digest: which finished sessions are due,
//  which exchanges in them are the user's real conversation (not a routine
//  run, a failed turn or "open safari"), whether what's left is worth a model
//  call at all, and the text handed to the model and saved under
//  `raw/conversations/`. No file system, no model — so the whole policy is
//  testable in Tests/BrainDigest.
//
//  Why a "worth digesting" gate before the model: the default model is a local
//  3B that shares the machine with the user's own turns. Most sessions are a
//  single screen question or a general-knowledge lookup, and neither says
//  anything lasting about the user; asking the model to confirm that costs
//  seconds of residency for an empty `[]`.
//

import Foundation

/// One question and answer kept for a digest, already cleaned.
nonisolated struct BrainDigestExchange: Equatable, Sendable {
    var question: String
    var answer: String
    var askedDate: Date
}

/// What the digester remembers between passes, persisted as
/// `~/.wisp/brain/.brain/digest-state.json`.
nonisolated struct BrainConversationDigestState: Codable, Equatable, Sendable {
    /// The last exchange of the newest session digested (or skipped). Only
    /// exchanges after this are considered, so a session is never read twice
    /// even if History later trims the exchange whose id named it.
    var lastDigestedExchangeDate: Date?
    /// Ids (first exchange) of sessions already handled, newest last. A second
    /// guard next to the date, capped.
    var digestedSessionIDs: [UUID] = []
    /// How many times the model failed on a session; after
    /// `maximumAttemptsPerSession` the session is given up on so one bad
    /// session can't block every later one.
    var failedAttemptCountsBySessionID: [String: Int] = [:]
    var lastDigestDate: Date?
    var lastDigestSummary: String?

    static let maximumRememberedSessionIDs = 200
    static let maximumAttemptsPerSession = 3

    /// Records a session as handled: its id, and the date watermark.
    mutating func markSessionHandled(sessionID: UUID, lastExchangeDate: Date) {
        if !digestedSessionIDs.contains(sessionID) {
            digestedSessionIDs.append(sessionID)
        }
        if digestedSessionIDs.count > Self.maximumRememberedSessionIDs {
            digestedSessionIDs.removeFirst(digestedSessionIDs.count - Self.maximumRememberedSessionIDs)
        }
        failedAttemptCountsBySessionID[sessionID.uuidString] = nil
        if let lastDigestedExchangeDate, lastDigestedExchangeDate >= lastExchangeDate { return }
        lastDigestedExchangeDate = lastExchangeDate
    }

    /// Counts a failed attempt; returns true when the session should now be
    /// given up on (and marks it handled).
    mutating func recordFailedAttempt(sessionID: UUID, lastExchangeDate: Date) -> Bool {
        let attemptCount = (failedAttemptCountsBySessionID[sessionID.uuidString] ?? 0) + 1
        if attemptCount >= Self.maximumAttemptsPerSession {
            markSessionHandled(sessionID: sessionID, lastExchangeDate: lastExchangeDate)
            return true
        }
        failedAttemptCountsBySessionID[sessionID.uuidString] = attemptCount
        return false
    }
}

enum BrainConversationDigestPlanner {
    /// A session has ended once nothing has been said for this long — the same
    /// gap `NotchConversationSessionGrouper` splits sessions on, so a session
    /// that is "ended" here can't grow afterwards.
    static let sessionEndedAfterSilenceSeconds: TimeInterval = NotchConversationSessionGrouper.newConversationGapSeconds
    /// On the very first run, only this much history is read, so installing
    /// the brain doesn't send weeks of old conversation through the model.
    static let firstRunLookbackSeconds: TimeInterval = 7 * 24 * 60 * 60
    /// Most sessions one pass digests; the rest wait for the next pass.
    static let maximumSessionsPerPass = 3

    /// Caps on what goes to the model. The default model is a 3B with a small
    /// context, and the user's words matter more than Wisp's answers, so
    /// answers are cut harder.
    static let maximumQuestionCharactersInMaterial = 800
    static let maximumAnswerCharactersInMaterial = 500
    static let shortenedAnswerCharactersInMaterial = 150
    static let maximumMaterialCharacters = 6000
    /// The raw transcript keeps much more — it's the evidence, not a prompt.
    static let maximumAnswerCharactersInTranscript = 4000

    // MARK: Which sessions

    /// The watermark to use: the stored one, or (first run) a week ago.
    static func effectiveWatermark(state: BrainConversationDigestState, now: Date) -> Date {
        state.lastDigestedExchangeDate ?? now.addingTimeInterval(-firstRunLookbackSeconds)
    }

    /// Records after the watermark, the input to the session grouper.
    static func recordsAfterWatermark(_ records: [AgentTaskRecord], watermark: Date) -> [AgentTaskRecord] {
        records.filter { $0.startedAt > watermark }
    }

    /// Sessions that have ended, aren't handled yet and have no turn still
    /// running — oldest first (so the watermark only ever moves forward),
    /// at most `maximumSessionCount`.
    static func sessionsReadyToDigest(
        from sessionsNewestFirst: [NotchConversationSession],
        state: BrainConversationDigestState,
        now: Date,
        maximumSessionCount: Int = maximumSessionsPerPass
    ) -> [NotchConversationSession] {
        let watermark = effectiveWatermark(state: state, now: now)
        let alreadyHandledSessionIDs = Set(state.digestedSessionIDs)
        let readySessionsOldestFirst = sessionsNewestFirst.reversed().filter { session in
            guard !alreadyHandledSessionIDs.contains(session.id) else { return false }
            guard session.lastActivityAt > watermark else { return false }
            guard now.timeIntervalSince(session.lastActivityAt) >= sessionEndedAfterSilenceSeconds else { return false }
            return session.exchanges.allSatisfy { $0.status.isTerminal }
        }
        return Array(readySessionsOldestFirst.prefix(maximumSessionCount))
    }

    // MARK: Which exchanges

    /// The step `CompanionManager` records for a request handled without the
    /// model (open an app, volume, a timer). Matching it catches every fast
    /// command, however it was phrased.
    static let handledNativelyStepSummaryPrefix = "Handled natively"

    /// The exchanges worth reading: the user's own question (not a routine,
    /// skill, buddy or dictation label), a turn that succeeded with an answer,
    /// and not a plain command. `isDirectCommand` lets the app add its own
    /// routers (browser, messages) on top of the word heuristic.
    static func digestibleExchanges(
        from records: [AgentTaskRecord],
        isDirectCommand: (String) -> Bool = { _ in false }
    ) -> [BrainDigestExchange] {
        records.compactMap { record in
            guard record.kind == .interactive, record.isUsersOwnQuestion else { return nil }
            guard record.status == .succeeded else { return nil }
            let wasHandledWithoutModel = record.steps.contains { step in
                step.summary.hasPrefix(handledNativelyStepSummaryPrefix)
            }
            guard !wasHandledWithoutModel else { return nil }
            let question = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty else { return nil }
            guard !looksLikePlainCommand(question), !isDirectCommand(question) else { return nil }
            let answer = AnswerDisplayText.cleaned(record.finalText ?? "")
            guard !answer.isEmpty else { return nil }
            return BrainDigestExchange(question: question, answer: answer, askedDate: record.startedAt)
        }
    }

    /// Leading phrases of requests that are an action, not a conversation:
    /// apps, volume, timers, tabs, media, messages, web tasks. Deliberately
    /// broad — missing a fact in "open safari and …" costs little; digesting
    /// commands costs a model call each.
    private static let plainCommandPrefixes: [String] = [
        "open ", "launch ", "quit ", "close ",
        "set a timer", "set timer", "start a timer", "timer for", "cancel the timer", "cancel timer",
        "mute", "unmute", "volume", "turn up", "turn down", "turn the volume", "louder", "quieter",
        "new tab", "new window", "go back", "go forward", "reload", "refresh",
        "organize my tabs", "organise my tabs", "group my tabs", "ungroup", "close duplicate",
        "play ", "pause", "resume", "skip", "next song", "next track", "previous song", "previous track",
        "text ", "message ", "send a text", "send a message", "tell mom", "tell dad",
        "go to ", "search for ", "search google", "google ", "look up ",
        "remind me", "type ", "dictate"
    ]

    /// Requests about what is on screen right now — useful at the time, gone
    /// the moment the screen changes.
    private static let ephemeralRequestPrefixes: [String] = [
        "point at", "point to", "show me where", "where do i click", "where should i click",
        "where is the", "where's the", "click ", "what is this", "what's this", "whats this",
        "what am i looking at", "what's on my screen", "whats on my screen", "what is on my screen",
        "read this", "read the screen", "summarize this", "summarise this", "explain this"
    ]

    /// Whole requests that are small talk.
    private static let smallTalkPhrases: Set<String> = [
        "hi", "hello", "hey", "hey wisp", "hi wisp", "thanks", "thank you", "thanks wisp", "thank you wisp",
        "ok", "okay", "cool", "nice", "great", "yes", "no", "yep", "nope", "sure", "stop", "never mind",
        "nevermind", "good morning", "good night", "how are you", "what time is it", "what's the time",
        "whats the time", "what day is it"
    ]

    /// Lowercased, punctuation to spaces, courtesy openers ("hey wisp, can you
    /// please") removed, so prefixes match however the request began.
    static func normalizedRequest(_ request: String) -> String {
        var normalized = request.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let courtesyOpeners = ["hey wisp ", "hi wisp ", "ok wisp ", "okay wisp ", "wisp ", "please ",
                               "can you ", "could you ", "would you ", "will you ", "can u ", "please "]
        var didStripOpener = true
        while didStripOpener {
            didStripOpener = false
            for opener in courtesyOpeners where normalized.hasPrefix(opener) {
                normalized = String(normalized.dropFirst(opener.count))
                didStripOpener = true
            }
        }
        return normalized
    }

    static func looksLikePlainCommand(_ request: String) -> Bool {
        let normalized = normalizedRequest(request)
        return plainCommandPrefixes.contains { commandPrefix in
            normalized.hasPrefix(commandPrefix) || normalized == commandPrefix.trimmingCharacters(in: .whitespaces)
        }
    }

    static func looksLikeEphemeralScreenRequest(_ request: String) -> Bool {
        let normalized = normalizedRequest(request)
        return ephemeralRequestPrefixes.contains { normalized.hasPrefix($0) || normalized == $0.trimmingCharacters(in: .whitespaces) }
    }

    static func isSmallTalk(_ request: String) -> Bool {
        let normalized = normalizedRequest(request)
        return smallTalkPhrases.contains(normalized)
    }

    // MARK: Worth a model call?

    /// Phrasings where "i"/"me" is grammar, not information about the user
    /// ("how do i center a div", "tell me about rust").
    private static let impersonalFirstPersonPhrases: [String] = [
        "how do i", "how can i", "how would i", "how should i", "can i", "could i",
        "tell me", "show me", "give me", "help me", "let me", "explain to me", "remind me"
    ]

    private static let firstPersonWords: Set<String> = [
        "i", "i'm", "im", "i've", "ive", "i'll", "ill", "i'd", "my", "mine", "me", "myself",
        "we", "we're", "our", "ours", "us"
    ]

    /// Whether the request says something about the user ("my sister",
    /// "i'm moving to berlin", "we decided to use postgres").
    static func mentionsTheUser(_ request: String) -> Bool {
        var normalized = " " + normalizedRequest(request) + " "
        for phrase in impersonalFirstPersonPhrases {
            normalized = normalized.replacingOccurrences(of: " " + phrase + " ", with: " ")
        }
        return normalized.split(separator: " ").contains { firstPersonWords.contains(String($0)) }
    }

    /// An exchange that could carry something lasting: not small talk, not a
    /// screen question, and at least four words — or, when the user is
    /// talking about themselves, two ("i'm vegetarian").
    static func isSubstantive(_ exchange: BrainDigestExchange) -> Bool {
        guard !isSmallTalk(exchange.question), !looksLikeEphemeralScreenRequest(exchange.question) else { return false }
        let wordCount = normalizedRequest(exchange.question).split(separator: " ").count
        if wordCount >= 4 { return true }
        return wordCount >= 2 && mentionsTheUser(exchange.question)
    }

    /// Enough user words that a session is a real discussion even without "i".
    static let minimumUserWordCountForDiscussion = 25

    /// Whether a session deserves a model call: at least one substantive
    /// exchange, and either the user talks about themselves, or it's a real
    /// back-and-forth (two substantive exchanges, or plenty of the user's own
    /// words). A lone "what's the capital of france" is skipped.
    static func isWorthDigesting(_ exchanges: [BrainDigestExchange]) -> Bool {
        let substantiveExchanges = exchanges.filter(isSubstantive)
        guard !substantiveExchanges.isEmpty else { return false }
        if substantiveExchanges.contains(where: { mentionsTheUser($0.question) }) { return true }
        if substantiveExchanges.count >= 2 { return true }
        let userWordCount = exchanges.reduce(0) { total, exchange in
            total + normalizedRequest(exchange.question).split(separator: " ").count
        }
        return userWordCount >= minimumUserWordCountForDiscussion
    }

    // MARK: Text

    /// "2026-09-29 1405" — the raw transcript's file name stem.
    static func transcriptFileStem(for sessionStartDate: Date, timeZone: TimeZone = .current) -> String {
        dateFormatter(format: "yyyy-MM-dd HHmm", timeZone: timeZone).string(from: sessionStartDate)
    }

    /// "conversation 2026-09-29 14:05" — the provenance label.
    static func provenanceLabel(for sessionStartDate: Date, timeZone: TimeZone = .current) -> String {
        "conversation " + dateFormatter(format: "yyyy-MM-dd HH:mm", timeZone: timeZone).string(from: sessionStartDate)
    }

    /// The saved transcript: markdown, the user's words in full, answers long.
    static func transcriptMarkdown(
        exchanges: [BrainDigestExchange],
        sessionStartDate: Date,
        timeZone: TimeZone = .current
    ) -> String {
        let heading = dateFormatter(format: "yyyy-MM-dd HH:mm", timeZone: timeZone).string(from: sessionStartDate)
        var lines = ["# Conversation \(heading)", ""]
        for exchange in exchanges {
            lines.append("**You:** \(exchange.question)")
            lines.append("")
            lines.append("**Wisp:** \(truncated(exchange.answer, toCharacterCount: maximumAnswerCharactersInTranscript))")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// The text given to the model: compact "User:/Wisp:" lines within
    /// `maximumMaterialCharacters`. Answers are shortened first, then the
    /// oldest exchanges dropped — the user's own words are what's being read.
    static func materialText(exchanges: [BrainDigestExchange], sessionStartDate: Date, timeZone: TimeZone = .current) -> String {
        let dayAndTime = dateFormatter(format: "yyyy-MM-dd HH:mm", timeZone: timeZone).string(from: sessionStartDate)
        let header = "Conversation on \(dayAndTime) (today's date for any Timeline entry: \(dayAndTime.prefix(10))).\n"

        func renderedExchanges(answerLimit: Int, droppingOldestCount: Int) -> String {
            exchanges.dropFirst(droppingOldestCount).map { exchange in
                "User: \(singleParagraph(truncated(exchange.question, toCharacterCount: maximumQuestionCharactersInMaterial)))\n"
                    + "Wisp: \(singleParagraph(truncated(exchange.answer, toCharacterCount: answerLimit)))"
            }.joined(separator: "\n")
        }

        var body = renderedExchanges(answerLimit: maximumAnswerCharactersInMaterial, droppingOldestCount: 0)
        if header.count + body.count > maximumMaterialCharacters {
            body = renderedExchanges(answerLimit: shortenedAnswerCharactersInMaterial, droppingOldestCount: 0)
        }
        var droppedExchangeCount = 0
        while header.count + body.count > maximumMaterialCharacters && droppedExchangeCount < exchanges.count - 1 {
            droppedExchangeCount += 1
            body = renderedExchanges(answerLimit: shortenedAnswerCharactersInMaterial, droppingOldestCount: droppedExchangeCount)
        }
        return String((header + body).prefix(maximumMaterialCharacters))
    }

    /// Material-specific guidance for `BrainKnowledgeExtractor`.
    static let extractionInstructions = """
    this is the user talking with wisp, their assistant. keep only lasting things about the user's life and work.
    - facts the USER says about themselves (work, preferences, plans, people in their life) → page "me", kind "me", section "Facts".
    - decisions the user makes about a project → section "Decisions" on that project's page (kind "project").
    - people, projects, organizations and topics the user discusses get their own pages; dated plans go under "Timeline" as "- yyyy-MM-dd: …".
    - wisp's answers are general knowledge: never record them as facts about the user. skip general questions entirely ("what's the capital of france" is not worth keeping), and skip screen help, chores and small talk.
    """

    // MARK: Summary

    /// "filed 4 facts into 2 pages from 1 conversation", or a line saying why
    /// nothing was filed.
    static func summaryLine(
        changeDescriptions: [String],
        touchedPageCount: Int,
        digestedSessionCount: Int,
        skippedSessionCount: Int
    ) -> String {
        let conversationCount = digestedSessionCount + skippedSessionCount
        let conversationsPhrase = "\(conversationCount) \(conversationCount == 1 ? "conversation" : "conversations")"
        guard !changeDescriptions.isEmpty, touchedPageCount > 0 else {
            return "nothing lasting in \(conversationsPhrase)"
        }
        var factCount = 0
        var otherChangeCount = 0
        for description in changeDescriptions {
            if let addedFactCount = addedFactCount(in: description) {
                factCount += addedFactCount
            } else {
                otherChangeCount += 1
            }
        }
        let pagesPhrase = "\(touchedPageCount) \(touchedPageCount == 1 ? "page" : "pages")"
        var filedPhrase: String
        if factCount > 0 {
            filedPhrase = "\(factCount) \(factCount == 1 ? "fact" : "facts")"
            if otherChangeCount > 0 {
                filedPhrase += " and \(otherChangeCount) other \(otherChangeCount == 1 ? "change" : "changes")"
            }
        } else {
            filedPhrase = "\(otherChangeCount) \(otherChangeCount == 1 ? "change" : "changes")"
        }
        return "filed \(filedPhrase) into \(pagesPhrase) from \(conversationsPhrase)"
    }

    /// The N in the planner's "added N facts to …" description.
    private static func addedFactCount(in changeDescription: String) -> Int? {
        let words = changeDescription.split(separator: " ")
        guard words.count >= 3, words[0] == "added", let count = Int(words[1]),
              words[2].hasPrefix("fact") else { return nil }
        return count
    }

    // MARK: Helpers

    private static func truncated(_ text: String, toCharacterCount maximumCharacterCount: Int) -> String {
        guard text.count > maximumCharacterCount else { return text }
        return String(text.prefix(maximumCharacterCount)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func singleParagraph(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*\n\s*"#, with: " ", options: .regularExpression)
    }

    private static func dateFormatter(format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}
