//
//  ScreenWatcher.swift
//  leanring-buddy
//
//  The pure side of screen watchers — "tell me when the build finishes",
//  "let me know when it says Succeeded", "stop watching": what a watch waits
//  for (`ScreenWatchCondition`), deciding from successive OCR readings of the
//  screen whether that has happened (`ScreenWatchEvaluator`), and recognising
//  the spoken request (`ScreenWatchRequestParser`).
//
//  Why it exists: waiting for something on screen is a job people hand to a
//  companion all the time, and Wisp already reads the screen on this machine
//  with Vision (`ScreenTextRecognizer`). Watching therefore needs no model at
//  all — each poll is a capture plus OCR, compared here — so a two-hour watch
//  costs nothing on the model and never evicts the prefix cache a live turn
//  depends on.
//
//  Running the polls (capture, OCR, notifications) lives in
//  `ScreenWatcherStore`; this file has no AppKit, ScreenCaptureKit or Vision
//  calls so it can be unit tested (`Tests/ScreenWatcher`).
//

import Foundation

// MARK: - What a watch waits for

nonisolated enum ScreenWatchCondition: Equatable, Sendable {
    /// Some text shows up on screen that wasn't there before ("Succeeded").
    case textAppears(String)
    /// Text that is on screen goes away ("Downloading…").
    case textDisappears(String)
    /// The screen's text changes (a build log scrolling, a percentage
    /// climbing) and then stops changing — "finished" without a known keyword.
    case screenTextSettles
    /// The number beside some text goes past a threshold: "the price drops
    /// below $80". The first reading counts too — a price already under $80
    /// is news the user wants at once, not a baseline.
    case numberCrosses(ScreenWatchNumberThreshold)

    /// How the watch is described in the notch, History and replies:
    /// "“Succeeded” appears", "the screen stops changing".
    var summaryText: String {
        switch self {
        case .textAppears(let targetText):
            return "“\(targetText)” appears"
        case .textDisappears(let targetText):
            return "“\(targetText)” goes away"
        case .screenTextSettles:
            return "the screen stops changing"
        case .numberCrosses(let numberThreshold):
            return numberThreshold.summaryText
        }
    }
}

/// "The price drops below $80": which number (the one beside `nearText`),
/// which way, and how far.
nonisolated struct ScreenWatchNumberThreshold: Equatable, Sendable {
    enum Direction: String, Equatable, Sendable {
        case below
        case above
    }

    /// As the user said it, for the reply: "the price".
    let subjectText: String
    /// The words the number sits beside on screen: "price".
    let nearText: String
    let direction: Direction
    let threshold: Double
    /// As the user said it, for the reply: "$80".
    let thresholdText: String

    /// "the price drops below $80", "bitcoin goes above 100,000".
    var summaryText: String {
        switch direction {
        case .below: return "\(subjectText) drops below \(thresholdText)"
        case .above: return "\(subjectText) goes above \(thresholdText)"
        }
    }

    /// What Wisp says when it happened: "the price is below $80 on screen
    /// now: Price $79.99".
    func reachedMessage(matchedLineText: String?, place: String) -> String {
        let reachedText = "\(subjectText) is \(direction.rawValue) \(thresholdText) \(place) now"
        guard let matchedLineText, !matchedLineText.isEmpty else { return "\(reachedText)." }
        return "\(reachedText): \(matchedLineText)"
    }

    func isPastThreshold(_ value: Double) -> Bool {
        switch direction {
        case .below: return value < threshold
        case .above: return value > threshold
        }
    }
}

/// What a spoken request asks the watchers to do.
nonisolated enum ScreenWatchRequest: Equatable, Sendable {
    case startWatching(ScreenWatchCondition)
    case stopAllWatching
}

// MARK: - Text matching

/// Loose, deterministic text comparison for OCR output: case, accents,
/// punctuation and spacing are ignored, and a target only matches whole words
/// (so "done" does not match "abandoned").
nonisolated enum ScreenWatchTextMatching {
    /// Lowercased, accent-folded, punctuation turned into spaces, runs of
    /// whitespace collapsed. "** BUILD SUCCEEDED **" → "build succeeded".
    static func normalizedText(_ rawText: String) -> String {
        let foldedText = rawText.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var characterKeptText = ""
        characterKeptText.reserveCapacity(foldedText.count)
        for character in foldedText {
            if character.isLetter || character.isNumber {
                characterKeptText.append(character)
            } else {
                characterKeptText.append(" ")
            }
        }
        return characterKeptText
            .split(whereSeparator: { $0 == " " })
            .joined(separator: " ")
    }

    /// Whether one OCR line contains the target as whole words.
    static func screenLine(_ screenLineText: String, containsTargetText targetText: String) -> Bool {
        let normalizedTarget = normalizedText(targetText)
        guard !normalizedTarget.isEmpty else { return false }
        let normalizedLine = normalizedText(screenLineText)
        return " \(normalizedLine) ".contains(" \(normalizedTarget) ")
    }
}

// MARK: - Evaluating successive readings

nonisolated enum ScreenWatchEvaluation: Equatable, Sendable {
    case stillWaiting
    /// The condition is met. `matchedLineText` is the screen line that met it,
    /// when there is one (a "text appears" watch), for the notification.
    case conditionMet(matchedLineText: String?)
}

/// Feeds on one OCR reading of the watched screen per poll and says when the
/// condition is met. One evaluator per watch; it remembers what it has seen.
nonisolated struct ScreenWatchEvaluator: Sendable {
    /// Polls in a row with identical text, after a change, before the screen
    /// counts as settled. At the store's 3-second poll that is ~12 seconds of
    /// stillness — longer than the pause between a build's phases or a
    /// download's progress updates, short enough to feel prompt.
    static let unchangedPollCountToSettle = 4
    /// Polls in a row without the text before it counts as gone, so a single
    /// misread (OCR dropping a line once) is not taken as it disappearing.
    static let absentPollCountToDisappear = 2

    let condition: ScreenWatchCondition
    private(set) var observedPollCount = 0

    // textAppears: the fewest matching lines seen so far. The text counts as
    // having appeared when more lines match than that — so text already on
    // screen when the watch starts (the last build's "Succeeded") does not fire
    // it, but a new occurrence does, even after the old one scrolled away.
    private var fewestMatchingLineCountSeen: Int?
    private var previousPollMatchingLineCount: Int?

    // textDisappears
    private var hasSeenTargetText = false
    private var consecutiveAbsentPollCount = 0

    // screenTextSettles
    private var previousScreenTextSignature: [String]?
    private var hasSeenScreenTextChange = false
    private var consecutiveUnchangedPollCount = 0

    init(condition: ScreenWatchCondition) {
        self.condition = condition
    }

    /// Takes the text lines of the watched screen from one poll.
    mutating func observe(screenLines: [String]) -> ScreenWatchEvaluation {
        observedPollCount += 1
        switch condition {
        case .textAppears(let targetText):
            return observeForTextAppearing(targetText: targetText, screenLines: screenLines)
        case .textDisappears(let targetText):
            return observeForTextDisappearing(targetText: targetText, screenLines: screenLines)
        case .screenTextSettles:
            return observeForScreenTextSettling(screenLines: screenLines)
        case .numberCrosses(let numberThreshold):
            return observeForNumberCrossing(numberThreshold: numberThreshold, screenLines: screenLines)
        }
    }

    private func observeForNumberCrossing(numberThreshold: ScreenWatchNumberThreshold, screenLines: [String]) -> ScreenWatchEvaluation {
        guard let foundNumber = WatchedNumberParsing.number(nearText: numberThreshold.nearText, inLines: screenLines),
              numberThreshold.isPastThreshold(foundNumber.value) else { return .stillWaiting }
        return .conditionMet(matchedLineText: foundNumber.lineText)
    }

    private mutating func observeForTextAppearing(targetText: String, screenLines: [String]) -> ScreenWatchEvaluation {
        let matchingLines = screenLines.filter {
            ScreenWatchTextMatching.screenLine($0, containsTargetText: targetText)
        }
        let matchingLineCount = matchingLines.count
        defer { previousPollMatchingLineCount = matchingLineCount }

        guard let fewestMatchingLineCountSeen else {
            // The first reading is the baseline: whatever matches already was
            // there before the user asked.
            self.fewestMatchingLineCountSeen = matchingLineCount
            return .stillWaiting
        }

        if matchingLineCount > fewestMatchingLineCountSeen {
            return .conditionMet(matchedLineText: matchingLines.last)
        }

        // A lower count only becomes the new baseline once two readings in a
        // row agree, so one misread poll can't lower it and let the very next
        // (correct) reading look like a new appearance.
        let countConfirmedByTwoPolls = max(matchingLineCount, previousPollMatchingLineCount ?? matchingLineCount)
        self.fewestMatchingLineCountSeen = min(fewestMatchingLineCountSeen, countConfirmedByTwoPolls)
        return .stillWaiting
    }

    private mutating func observeForTextDisappearing(targetText: String, screenLines: [String]) -> ScreenWatchEvaluation {
        let isTargetTextOnScreen = screenLines.contains {
            ScreenWatchTextMatching.screenLine($0, containsTargetText: targetText)
        }
        if isTargetTextOnScreen {
            hasSeenTargetText = true
            consecutiveAbsentPollCount = 0
            return .stillWaiting
        }
        // Text that was never there can't go away; keep waiting for it to show
        // up first rather than firing at once.
        guard hasSeenTargetText else { return .stillWaiting }
        consecutiveAbsentPollCount += 1
        return consecutiveAbsentPollCount >= Self.absentPollCountToDisappear
            ? .conditionMet(matchedLineText: nil)
            : .stillWaiting
    }

    private mutating func observeForScreenTextSettling(screenLines: [String]) -> ScreenWatchEvaluation {
        // Sorted, so OCR returning the same lines in a slightly different order
        // is not mistaken for a change.
        let screenTextSignature = screenLines
            .map(ScreenWatchTextMatching.normalizedText)
            .filter { !$0.isEmpty }
            .sorted()

        guard let previousScreenTextSignature else {
            self.previousScreenTextSignature = screenTextSignature
            return .stillWaiting
        }

        if screenTextSignature != previousScreenTextSignature {
            hasSeenScreenTextChange = true
            consecutiveUnchangedPollCount = 0
            self.previousScreenTextSignature = screenTextSignature
            return .stillWaiting
        }

        consecutiveUnchangedPollCount += 1
        // Settling only means something after the screen was seen working; a
        // screen that never changes is still waiting for the work to start.
        guard hasSeenScreenTextChange else { return .stillWaiting }
        return consecutiveUnchangedPollCount >= Self.unchangedPollCountToSettle
            ? .conditionMet(matchedLineText: nil)
            : .stillWaiting
    }
}

// MARK: - Recognising the spoken request

/// Recognises "tell me when …" / "watch for …" / "stop watching" in a
/// transcript. Deliberately conservative, like the other deterministic
/// routers: anything it is not sure about returns nil and goes to the model as
/// an ordinary turn, which can still call the `watch_screen` tool.
nonisolated enum ScreenWatchRequestParser {
    /// Longest text target accepted. A watched phrase is a status word or a
    /// short message, not a sentence.
    static let maximumTargetWordCount = 8
    static let maximumTargetCharacterCount = 80
    /// Longest "the thing" in "tell me when the thing finishes".
    static let maximumFinishingSubjectWordCount = 5
    /// Longest subject in "tell me when <subject> says X".
    static let maximumSayingSubjectWordCount = 5

    static func request(from transcript: String) -> ScreenWatchRequest? {
        let cleanedTranscript = cleanedTranscriptText(transcript)
        guard !cleanedTranscript.isEmpty else { return nil }

        if isStopWatchingRequest(cleanedTranscript) {
            return .stopAllWatching
        }
        if let whenClause = firstCapture(of: tellMeWhenPattern, in: cleanedTranscript) {
            return condition(fromWhenClause: whenClause).map(ScreenWatchRequest.startWatching)
        }
        if let watchForCondition = conditionFromWatchForRequest(cleanedTranscript) {
            return .startWatching(watchForCondition)
        }
        return nil
    }

    // MARK: Transcript cleanup

    /// Straight quotes, no trailing punctuation or politeness, no leading
    /// "hey wisp," — the shapes below can then anchor on both ends.
    static func cleanedTranscriptText(_ transcript: String) -> String {
        var cleanedText = transcript
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        cleanedText = replacingMatches(of: #"^(?:(?:hey|hi|ok|okay)\s+)?wisp[\s,]+"#, in: cleanedText, with: "")
        // Trailing punctuation and courtesy words, repeatedly ("…, please.").
        var previousText = ""
        while previousText != cleanedText {
            previousText = cleanedText
            cleanedText = cleanedText.trimmingCharacters(in: CharacterSet(charactersIn: ".!?, ").union(.whitespaces))
            cleanedText = replacingMatches(of: #"[\s,]+(?:please|thanks|thank you|for me)$"#, in: cleanedText, with: "")
        }
        return cleanedText
    }

    // MARK: Stop

    private static let stopWatchingPattern = #"^(?:(?:ok|okay|please|you can|now)\s+)*(?:stop|cancel|end|quit)\s+(?:all\s+)?(?:the\s+|my\s+|your\s+|all\s+|of\s+the\s+)?(?:screen\s+)?(?:watching|watches|watchers|watcher|watch)(?:\s+(?:the|my)\s+screen|\s+(?:for\s+)?(?:that|it|this|them|those))?$"#

    static func isStopWatchingRequest(_ cleanedTranscript: String) -> Bool {
        firstMatch(of: stopWatchingPattern, in: cleanedTranscript) != nil
    }

    // MARK: "Tell me when …"

    /// "tell me when …", "let me know once …", "can you notify me as soon as …",
    /// optionally led by "watch this terminal and …". Captures the clause after
    /// "when".
    private static let tellMeWhenPattern = #"^(?:(?:please|ok|okay|hey)[\s,]+)*(?:(?:can|could|would|will)\s+you\s+(?:please\s+)?)?(?:(?:watch|monitor|keep\s+an\s+eye\s+on|check|refresh|reload)\s+(?:[^\s]+\s+){0,4}?[^\s]+\s+and\s+(?:then\s+)?)?(?:tell\s+me|let\s+me\s+know|notify\s+me|ping\s+me|alert\s+me|give\s+me\s+a\s+(?:shout|ping|heads\s+up))\s+(?:when|once|as\s+soon\s+as|the\s+moment)\s+(.+)$"#

    /// The condition in "… when <clause>", or nil when the clause isn't one
    /// this recognises.
    static func condition(fromWhenClause whenClause: String) -> ScreenWatchCondition? {
        // "the price drops below $80" — checked first: its threshold is a
        // number, which none of the text shapes below would make sense of.
        if let numberThreshold = numberThreshold(fromWhenClause: whenClause) {
            return .numberCrosses(numberThreshold)
        }
        // "it says Succeeded" — checked first, so "it says build finished"
        // watches for that text rather than for the screen to settle.
        if let sayingCaptures = captures(of: sayingPattern, in: whenClause),
           sayingCaptures.count == 2 {
            let sayingSubject = sayingCaptures[0]
            let saidText = sayingCaptures[1]
            if isAcceptableSayingSubject(sayingSubject),
               let targetText = cleanedTargetText(saidText, requiresExplicitTextMarker: false) {
                return .textAppears(targetText)
            }
            return nil
        }
        if let appearingSubject = firstCapture(of: appearingPattern, in: whenClause) {
            return cleanedTargetText(appearingSubject, requiresExplicitTextMarker: startsWithDeterminer(appearingSubject))
                .map(ScreenWatchCondition.textAppears)
        }
        if let disappearingSubject = firstCapture(of: disappearingPattern, in: whenClause) {
            return cleanedTargetText(disappearingSubject, requiresExplicitTextMarker: startsWithDeterminer(disappearingSubject))
                .map(ScreenWatchCondition.textDisappears)
        }
        if let finishingCaptures = captures(of: finishingPattern, in: whenClause), !finishingCaptures.isEmpty {
            let finishingSubject = finishingCaptures[0]
            let hasScreenWorkVerb = finishingCaptures.count > 1 && !finishingCaptures[1].isEmpty
            return isAcceptableFinishingSubject(finishingSubject, hasScreenWorkVerb: hasScreenWorkVerb)
                ? .screenTextSettles
                : nil
        }
        return nil
    }

    /// "<subject> says|shows|reads … <text>". "shows up" is the appearing form,
    /// not "shows" + "up", so it is excluded here.
    private static let sayingPattern = #"^(.+?)\s+(?:says|shows|displays|reads|prints|outputs|contains)(?!\s+up\b)[\s,:]+(.+)$"#

    private static let appearingPattern = #"^(.+?)\s+(?:appears|shows\s+up|pops\s+up|comes\s+up|is\s+on\s+(?:the\s+)?screen)$"#

    private static let disappearingPattern = #"^(.+?)\s+(?:disappears|goes\s+away|is\s+gone|vanishes|is\s+no\s+longer\s+(?:on\s+(?:the\s+)?screen|showing|there))$"#

    /// "<subject> finishes", "<subject> is done", "it's finished downloading",
    /// "the progress bar stops moving". The optional second capture is the
    /// kind of on-screen work ("downloading", "rendering"), which vouches for
    /// a subject that would otherwise be declined ("the video").
    private static let finishingPattern = #"^(.+?)(?:\s+is|'s|\s+has|\s+have)?\s+(?:finishes|finished|completes|completed|complete|done|ready|stops\s+(?:moving|changing)|stopped\s+(?:moving|changing))(?:\s+(running|loading|downloading|uploading|building|compiling|exporting|rendering|installing|updating|copying|syncing|processing|indexing|importing|converting))?$"#

    /// Words that mean the subject of "tell me when … is done" is not
    /// something on the screen: a person, or a thing in the world. Declined,
    /// so the model (or nobody) handles it rather than a pointless watch.
    private static let nonScreenSubjectWords: Set<String> = [
        "i", "you", "we", "he", "she", "they", "him", "her", "them", "someone", "somebody", "everyone", "anyone",
        "mom", "dad", "mum", "wife", "husband",
        "meeting", "call", "class", "lecture", "timer", "alarm", "dinner", "lunch", "breakfast", "food",
        "laundry", "washer", "dryer", "oven", "coffee", "kettle", "tea", "rain", "game", "match",
        "movie", "show", "episode", "song", "video", "podcast", "day", "week", "school", "work", "shift",
    ]

    private static let determinerWords: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those", "my", "your", "our", "it", "its", "some", "any",
    ]

    private static func isAcceptableSayingSubject(_ sayingSubject: String) -> Bool {
        let subjectWords = lowercasedWords(sayingSubject)
        guard !subjectWords.isEmpty, subjectWords.count <= maximumSayingSubjectWordCount else { return false }
        return !subjectWords.contains(where: nonScreenSubjectWords.contains)
    }

    private static func isAcceptableFinishingSubject(_ finishingSubject: String, hasScreenWorkVerb: Bool) -> Bool {
        let subjectWords = lowercasedWords(finishingSubject)
        guard !subjectWords.isEmpty, subjectWords.count <= maximumFinishingSubjectWordCount else { return false }
        // A person is never on-screen work, whatever verb follows.
        let personWords: Set<String> = ["i", "you", "we", "he", "she", "they", "someone", "somebody", "mom", "dad", "mum", "wife", "husband"]
        if subjectWords.contains(where: personWords.contains) { return false }
        if hasScreenWorkVerb { return true }
        return !subjectWords.contains(where: nonScreenSubjectWords.contains)
    }

    private static func startsWithDeterminer(_ phrase: String) -> Bool {
        guard let firstWord = lowercasedWords(phrase).first else { return false }
        return determinerWords.contains(firstWord)
    }

    // MARK: Numbers

    /// "<subject> drops below|goes above|is under|gets over <number>". The verb
    /// is required, so "the number below 5" isn't read as a watch.
    private static let numberCrossingPattern = #"^(.+?)(?:'s|\s+(?:is|gets|goes|drops|falls|dips|sinks|rises|climbs|jumps|moves))\s+(?:now\s+)?(?:down\s+|up\s+)?(below|under|less\s+than|lower\s+than|cheaper\s+than|above|over|more\s+than|higher\s+than|past)\s+(.+)$"#

    /// The threshold: a number with an optional currency sign before it or a
    /// unit after it, and nothing else ("$80", "80 dollars", "1,299.99", "5%").
    private static let numberThresholdPattern = #"^(?:[$€£¥]\s*)?([-\u2212]?\d[\d.,'\u00a0 ]*)\s*(?:dollars?|bucks|euros?|pounds?|usd|eur|gbp|yen|%|percent|points|degrees)?$"#

    /// A subject that names nothing on screen to read a number beside.
    private static let pronounSubjectWords: Set<String> = ["it", "this", "that", "they", "them", "these", "those", "something", "anything"]

    static let maximumNumberSubjectWordCount = 4

    /// The number condition in a "… when <clause>", or nil.
    static func numberThreshold(fromWhenClause whenClause: String) -> ScreenWatchNumberThreshold? {
        guard let numberCaptures = captures(of: numberCrossingPattern, in: whenClause),
              numberCaptures.count == 3 else { return nil }
        let subjectText = numberCaptures[0]
        let directionWord = numberCaptures[1].lowercased()
        let thresholdText = numberCaptures[2].trimmingCharacters(in: CharacterSet(charactersIn: ".,!? ").union(.whitespaces))

        guard let thresholdNumberText = firstCapture(of: numberThresholdPattern, in: thresholdText),
              let threshold = WatchedNumberParsing.parseNumber(thresholdNumberText) else { return nil }

        let subjectWords = lowercasedWords(subjectText)
        guard !subjectWords.isEmpty, subjectWords.count <= maximumNumberSubjectWordCount else { return nil }
        let personWords: Set<String> = ["i", "you", "we", "he", "she", "someone", "somebody", "mom", "dad", "mum", "wife", "husband"]
        guard !subjectWords.contains(where: personWords.contains) else { return nil }
        // "the price" → "price": the determiner isn't on the page.
        let labelWords = subjectWords.drop(while: determinerWords.contains)
        guard !labelWords.isEmpty, !labelWords.allSatisfy(pronounSubjectWords.contains) else { return nil }

        let isBelow = ["below", "under"].contains(directionWord)
            || directionWord.hasPrefix("less") || directionWord.hasPrefix("lower") || directionWord.hasPrefix("cheaper")
        return ScreenWatchNumberThreshold(
            subjectText: subjectText,
            nearText: labelWords.joined(separator: " "),
            direction: isBelow ? .below : .above,
            threshold: threshold,
            thresholdText: thresholdText
        )
    }

    // MARK: "Watch for …"

    /// "watch for "Done"", "watch the screen for the word error", "keep an eye
    /// out for Succeeded to appear", "wait for the export to finish".
    private static let watchForPattern = #"^(?:(?:please|ok|okay)[\s,]+)*(?:(?:can|could|would|will)\s+you\s+(?:please\s+)?)?(?:watch|look|keep\s+an\s+eye\s+out|wait)\s+(?:(?:the|my)\s+screen\s+)?(?:out\s+)?for\s+(.+?)(?:\s+to\s+(appear|show\s+up|pop\s+up|disappear|go\s+away|finish|complete|be\s+done|be\s+finished))?(?:\s+and\s+(?:then\s+)?(?:tell\s+me|let\s+me\s+know|notify\s+me))?$"#

    static func conditionFromWatchForRequest(_ cleanedTranscript: String) -> ScreenWatchCondition? {
        guard let watchForCaptures = captures(of: watchForPattern, in: cleanedTranscript),
              let watchedPhrase = watchForCaptures.first else { return nil }
        let expectedChange = watchForCaptures.count > 1 ? watchForCaptures[1].lowercased() : ""

        let isDisappearingChange = expectedChange == "disappear" || expectedChange.hasPrefix("go")
        let isFinishingChange = expectedChange == "finish" || expectedChange == "complete" || expectedChange.hasPrefix("be")

        if isDisappearingChange {
            return cleanedTargetText(watchedPhrase, requiresExplicitTextMarker: startsWithDeterminer(watchedPhrase))
                .map(ScreenWatchCondition.textDisappears)
        }
        if isFinishingChange {
            return isAcceptableFinishingSubject(watchedPhrase, hasScreenWorkVerb: false) ? .screenTextSettles : nil
        }
        if expectedChange.isEmpty {
            // A bare "watch for X" could be anything ("watch for new emails"),
            // so only an explicitly marked text is taken: quoted, or "the word
            // X" / "the text X".
            return cleanedTargetText(watchedPhrase, requiresExplicitTextMarker: true)
                .map(ScreenWatchCondition.textAppears)
        }
        // "… to appear / show up / pop up".
        return cleanedTargetText(watchedPhrase, requiresExplicitTextMarker: startsWithDeterminer(watchedPhrase))
            .map(ScreenWatchCondition.textAppears)
    }

    // MARK: Target text

    private static let explicitTextMarkerPattern = #"^(?:the\s+)?(?:words?|text|phrase|message|status)\s+(.+)$"#

    /// The text to watch for, cleaned: quotes and "the word" removed, a
    /// trailing "on the screen" dropped, within the length limits. Nil when
    /// nothing usable is left — or when `requiresExplicitTextMarker` and the
    /// text is neither quoted nor introduced by "the word/text/phrase".
    static func cleanedTargetText(_ rawTargetText: String, requiresExplicitTextMarker: Bool) -> String? {
        var targetText = rawTargetText.trimmingCharacters(in: .whitespacesAndNewlines)
        targetText = replacingMatches(of: #"\s+(?:on|in)\s+(?:the|my)\s+(?:screen|terminal|window|console|log)$"#, in: targetText, with: "")

        var hasExplicitTextMarker = false
        if let markedText = firstCapture(of: explicitTextMarkerPattern, in: targetText) {
            targetText = markedText
            hasExplicitTextMarker = true
        }
        if let quotedText = firstCapture(of: #"^["'](.+)["']$"#, in: targetText) {
            targetText = quotedText
            hasExplicitTextMarker = true
        }
        if requiresExplicitTextMarker && !hasExplicitTextMarker { return nil }

        // "it says that the build failed" — "that" introduces the text.
        if !hasExplicitTextMarker {
            targetText = replacingMatches(of: #"^(?:that|something\s+like)\s+"#, in: targetText, with: "")
        }
        targetText = targetText.trimmingCharacters(in: CharacterSet(charactersIn: "\"'.,:;!? ").union(.whitespaces))

        guard !ScreenWatchTextMatching.normalizedText(targetText).isEmpty else { return nil }
        guard targetText.count <= maximumTargetCharacterCount,
              lowercasedWords(targetText).count <= maximumTargetWordCount else { return nil }
        return targetText
    }

    // MARK: Regex helpers

    private static func lowercasedWords(_ phrase: String) -> [String] {
        ScreenWatchTextMatching.normalizedText(phrase).split(separator: " ").map(String.init)
    }

    private static func firstMatch(of pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let regularExpression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        return regularExpression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// Every capture group of the first match, in order; a group that didn't
    /// take part is an empty string. Nil when the pattern doesn't match.
    private static func captures(of pattern: String, in text: String) -> [String]? {
        guard let match = firstMatch(of: pattern, in: text) else { return nil }
        guard match.numberOfRanges > 1 else { return [] }
        return (1..<match.numberOfRanges).map { groupIndex in
            guard let groupRange = Range(match.range(at: groupIndex), in: text) else { return "" }
            return String(text[groupRange]).trimmingCharacters(in: .whitespaces)
        }
    }

    private static func firstCapture(of pattern: String, in text: String) -> String? {
        captures(of: pattern, in: text)?.first
    }

    private static func replacingMatches(of pattern: String, in text: String, with replacementText: String) -> String {
        guard let regularExpression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        return regularExpression.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: replacementText
        )
    }
}
