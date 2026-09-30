//
//  FastPointing.swift
//  leanring-buddy
//
//  The pure, testable side of fast pointing: recognising "where is X" /
//  "point at X" requests, matching X against the elements Wisp already knows
//  are on screen (Accessibility elements and OCR lines, each with an exact
//  box), and leniently reading the id back out of a small text-only model
//  reply when the deterministic match isn't sure.
//
//  Why this exists: asking the local vision model to point meant encoding a
//  fresh screenshot (~4s on every new screen, measured with the model warm;
//  ~9s cold) and then trusting its pixel guess — which was measured wrong on
//  4 of 5 plain "where is X" questions, including one below the bottom of the
//  screen. The Accessibility tree and OCR already give every button and line
//  of text an exact box, so a plain pointing request is answered here with no
//  model (≈ the OCR time, which already ran during speech), and an unsure one
//  with a text-only call (~0.35s measured, 5/5 correct) instead of vision.
//
//  Running the capture/model call and drawing the marker live in
//  `CompanionManager.runFastPointingTurn`; this file has no AppKit or model
//  calls so it can be unit tested (`Tests/FastPointing`).
//

import CoreGraphics
import Foundation

/// Timing shared by the fast pointing turn.
nonisolated enum FastPointingTiming {
    /// How long a pointing turn waits for OCR. Longer than an ordinary screen
    /// turn's 0.4s because the text list is the whole answer here, and a typed
    /// question has no capture running during speech, so recognition starts
    /// cold at submit (~1.2s measured on a full screen). Still far under the
    /// ~4s a new screenshot costs the vision model.
    static let screenTextWaitBudgetSeconds: TimeInterval = 1.5
    /// OCR lines considered for matching. Far above the model prompt's 60-line
    /// cap: matching costs nothing per line, and a capped list hid the lower
    /// half of a busy screen (a Finder list's "Movies" row) from the matcher.
    static let maximumMatchedScreenTextLineCount = 400
    static let maximumMatchedScreenTextCharacterCount = 40_000
    /// Most places marked at once when the target is on screen more than once.
    static let maximumMarkedPlaces = 3
    /// Below this many readable things (a canvas, a photo, a game) the element
    /// list can't be trusted to hold the target, so a miss goes to the vision
    /// model. At or above it, a miss means the target isn't visible (scrolled
    /// away, in another window), and Wisp says so at once instead of spending
    /// seconds on a pixel guess measured wrong 4 times in 5.
    static let minimumCandidatesToTrustAMiss = 12
}

// MARK: - Request recognition

/// What the user asked Wisp to point at.
nonisolated struct PointingRequest: Equatable {
    /// The thing to find, with articles and role words removed ("voice and models").
    let targetText: String
    /// A role word the user said ("button", "tab", …), which breaks ties
    /// toward an Accessibility element of that kind.
    let roleHint: String?
}

/// Recognises plain spoken pointing requests. Biased toward not matching,
/// like `FastCommandRouter`: a miss simply goes to an ordinary turn, while a
/// false match would point at something instead of answering a question
/// ("show me the weather" is a card, not a place on screen).
nonisolated enum PointingRequestParser {
    /// Longest target kept. A longer "where is …" is a question, not a label.
    static let maximumTargetWordCount = 6

    /// Words that mark the target as a kind of control. Stripped from the
    /// target (labels rarely include them) and kept as a tie-breaking hint.
    static let roleWords: Set<String> = [
        "button", "buttons", "icon", "tab", "menu", "link", "field", "option",
        "setting", "toggle", "switch", "checkbox", "section", "item", "box", "bar",
        "folder", "file",
    ]

    /// Phrases that start a pointing request, most specific first. Each
    /// captures the target. "find"/"locate" only count with a role word
    /// (checked below) so "find coffee near me" stays a places question.
    private static let requestPatterns: [(pattern: String, requiresRoleWord: Bool)] = [
        (#"^where (?:do|should|can) i (?:click|tap|press) (?:to |for |on )?(.+)$"#, false),
        (#"^(?:where is|where's|wheres|where are) (.+)$"#, false),
        (#"^(?:point|pointed) (?:at|to|out) (.+)$"#, false),
        (#"^show me where (.+?)(?: is| are)?$"#, false),
        (#"^(?:highlight) (.+)$"#, false),
        (#"^(?:find|locate) (.+)$"#, true),
    ]

    /// A spoken lead-in that doesn't change the request.
    private static let leadingPhrases = [
        "hey wisp ", "wisp ", "okay ", "ok ", "please ", "can you ", "could you ", "would you ",
    ]

    /// Trailing words that say where to look rather than what to find.
    private static let trailingPhrases = [
        " on the screen", " on my screen", " on screen", " on this page", " on the page",
        " in this app", " in this window", " here", " please", " again", " at",
    ]

    /// Whole targets that name nothing on their own ("where is it").
    private static let emptyTargets: Set<String> = ["it", "that", "this", "them", "those", "these", "one", "thing"]

    /// Words that make "where is …" a question about the world or about how
    /// something works, not a request to point at a label.
    private static let questionWords: Set<String> = [
        "what", "why", "how", "when", "who", "which", "if", "because", "then", "does", "do",
    ]

    static func request(from transcript: String) -> PointingRequest? {
        var normalized = transcript.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            // Dictation punctuates lead-ins ("hey wisp, where is…").
            .replacingOccurrences(of: ",", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let lastCharacter = normalized.last, ".?!,".contains(lastCharacter) {
            normalized.removeLast()
        }
        normalized = normalized.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")

        var didStripLeadIn = true
        while didStripLeadIn {
            didStripLeadIn = false
            for leadingPhrase in leadingPhrases where normalized.hasPrefix(leadingPhrase) {
                normalized.removeFirst(leadingPhrase.count)
                didStripLeadIn = true
            }
        }
        normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: ", "))

        for (pattern, requiresRoleWord) in requestPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
                  let targetRange = Range(match.range(at: 1), in: normalized) else { continue }

            var rawTarget = String(normalized[targetRange])
            var didStripTrailing = true
            while didStripTrailing {
                didStripTrailing = false
                for trailingPhrase in trailingPhrases where rawTarget.hasSuffix(trailingPhrase) {
                    rawTarget.removeLast(trailingPhrase.count)
                    didStripTrailing = true
                }
            }

            var targetWords = rawTarget.split(separator: " ").map(String.init)
            // Leading articles and possessives: "the", "my", "a".
            while let firstWord = targetWords.first, ["the", "a", "an", "my", "your"].contains(firstWord) {
                targetWords.removeFirst()
            }
            // "where is the save button at" → trailing "at" already stripped;
            // "where are the settings located" → drop the verb.
            if let lastWord = targetWords.last, ["located", "is", "are"].contains(lastWord) {
                targetWords.removeLast()
            }

            var roleHint: String?
            if let lastWord = targetWords.last, roleWords.contains(lastWord), targetWords.count > 1 {
                roleHint = lastWord.hasSuffix("s") && lastWord != "box" ? String(lastWord.dropLast()) : lastWord
                targetWords.removeLast()
            }

            if requiresRoleWord && roleHint == nil { return nil }
            guard !targetWords.isEmpty, targetWords.count <= maximumTargetWordCount else { return nil }
            guard !targetWords.contains(where: { questionWords.contains($0) }) else { return nil }
            let targetText = targetWords.joined(separator: " ")
            guard !emptyTargets.contains(targetText) else { return nil }

            return PointingRequest(targetText: targetText, roleHint: roleHint)
        }
        return nil
    }
}

// MARK: - Matching

/// Something on screen that can be pointed at, from either source.
nonisolated struct PointingCandidate: Equatable {
    /// `a12` (Accessibility) or `t7` (OCR) — the same ids the model sees.
    let elementID: String
    let text: String
    /// The Accessibility short role name ("button"), nil for an OCR line.
    let accessibilityRoleName: String?
    let regionInScreenshotPixels: CGRect
    let screenNumber: Int

    var isAccessibilityElement: Bool { accessibilityRoleName != nil }
}

nonisolated struct PointingMatch: Equatable {
    let candidate: PointingCandidate
    /// 0…1, how much of the candidate's text the target accounts for (all of
    /// the target's words are always present in a match).
    let score: Double
}

/// Deterministic target → element matching. Every word of the target must be
/// in the candidate (with a little tolerance for OCR/dictation spelling), and
/// the candidate with the least unexplained text wins. It declines — returning
/// nil so a model can decide — whenever two different places match about as
/// well, because pointing confidently at the wrong one of two "Save" buttons
/// is worse than taking half a second longer.
nonisolated enum PointingTargetMatcher {
    /// Below this the candidate is mostly other text ("wisp" inside a long
    /// sentence that mentions Wisp), which is not what "where is wisp" means.
    static let minimumConfidentScore = 0.5
    /// How far ahead the best match must be of a match somewhere else.
    static let requiredLeadOverRunnerUp = 0.15
    /// Bonus for an Accessibility element whose role is the one the user said.
    static let roleHintBonus = 0.1
    /// Credit for a word matched only with tolerance (plural, one letter off).
    static let toleratedWordCredit = 0.8
    /// Small bonus for Accessibility over OCR: it is the actual control rather
    /// than text that may be a caption beside it.
    static let accessibilityElementBonus = 0.02

    private static let ignoredWords: Set<String> = ["the", "a", "an", "my", "your", "of", "to"]

    /// Words that join a label but don't identify it. They still count toward
    /// a full match, but sharing only these ("and" in "AutoFill & Passwords"
    /// for "privacy and security") doesn't make a candidate related.
    static let connectorWords: Set<String> = ["and", "or", "for", "in", "on", "with", "at", "by", "from"]

    /// Whether the candidate shares at least one identifying word with the target.
    static func sharesContentWord(targetText: String, candidate: PointingCandidate) -> Bool {
        let targetContentWords = words(in: targetText).filter { !connectorWords.contains($0) }
        let candidateWords = words(in: candidate.text)
        return targetContentWords.contains { targetWord in
            candidateWords.contains { candidateWord in
                wordsMatch(targetWord, candidateWord)
                    || (targetWord.count >= 3 && candidateWord.hasPrefix(targetWord))
                    || (candidateWord.count >= 3 && targetWord.hasPrefix(candidateWord))
            }
        }
    }

    static func words(in text: String) -> [String] {
        let lowered = text.lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "+", with: " plus ")
        var currentWord = ""
        var foundWords: [String] = []
        for character in lowered {
            if character.isLetter || character.isNumber {
                currentWord.append(character)
            } else if !currentWord.isEmpty {
                foundWords.append(currentWord)
                currentWord = ""
            }
        }
        if !currentWord.isEmpty { foundWords.append(currentWord) }
        return foundWords.filter { !ignoredWords.contains($0) }
    }

    /// Whether two words are the same allowing a plural, or one letter of
    /// difference for longer words (OCR reads "Settinqs", dictation "colour").
    static func wordsMatch(_ firstWord: String, _ secondWord: String) -> Bool {
        if firstWord == secondWord { return true }
        if firstWord + "s" == secondWord || secondWord + "s" == firstWord { return true }
        guard min(firstWord.count, secondWord.count) >= 5 else { return false }
        return editDistance(firstWord, secondWord) <= 1
    }

    static func editDistance(_ firstWord: String, _ secondWord: String) -> Int {
        let firstCharacters = Array(firstWord)
        let secondCharacters = Array(secondWord)
        guard !firstCharacters.isEmpty, !secondCharacters.isEmpty else {
            return max(firstCharacters.count, secondCharacters.count)
        }
        guard abs(firstCharacters.count - secondCharacters.count) <= 1 else { return 2 }
        var previousRow = Array(0...secondCharacters.count)
        for firstIndex in 1...firstCharacters.count {
            var currentRow = [firstIndex] + Array(repeating: 0, count: secondCharacters.count)
            for secondIndex in 1...secondCharacters.count {
                let substitutionCost = firstCharacters[firstIndex - 1] == secondCharacters[secondIndex - 1] ? 0 : 1
                currentRow[secondIndex] = min(
                    previousRow[secondIndex] + 1,
                    currentRow[secondIndex - 1] + 1,
                    previousRow[secondIndex - 1] + substitutionCost
                )
            }
            previousRow = currentRow
        }
        return previousRow[secondCharacters.count]
    }

    /// The match score for one candidate, or nil when a target word is missing.
    static func score(targetWords: [String], roleHint: String?, candidate: PointingCandidate) -> Double? {
        var candidateWords = words(in: candidate.text)
        // OCR reads a row's icon as a stray letter ("I Documents", "D Documents"
        // for Finder's folder icons), which would otherwise halve the score of
        // exactly the line the user means.
        if !candidate.isAccessibilityElement {
            candidateWords.removeAll { $0.count == 1 && !$0.allSatisfy(\.isNumber) }
        }
        guard !targetWords.isEmpty, !candidateWords.isEmpty else { return nil }

        // An exact word earns full credit and a tolerated one (plural, one
        // letter off) less, so "share" means the Share button over "Shared".
        var unmatchedCandidateWordIndexes = Set(candidateWords.indices)
        var matchedWordCredit = 0.0
        for targetWord in targetWords {
            let orderedUnmatchedIndexes = unmatchedCandidateWordIndexes.sorted()
            if let exactIndex = orderedUnmatchedIndexes.first(where: { candidateWords[$0] == targetWord }) {
                unmatchedCandidateWordIndexes.remove(exactIndex)
                matchedWordCredit += 1
            } else if let tolerantIndex = orderedUnmatchedIndexes.first(where: { wordsMatch(targetWord, candidateWords[$0]) }) {
                unmatchedCandidateWordIndexes.remove(tolerantIndex)
                matchedWordCredit += toleratedWordCredit
            } else {
                return nil
            }
        }

        var score = matchedWordCredit / Double(candidateWords.count)
        // The bonus is for the control or its label; an icon's description
        // ("document" for a folder glyph) is where the user looks last.
        if let accessibilityRoleName = candidate.accessibilityRoleName, accessibilityRoleName != "image" {
            score += accessibilityElementBonus
            if let roleHint, accessibilityRoleName.contains(roleHint) || roleHint.contains(accessibilityRoleName) {
                score += roleHintBonus
            }
        }
        return score
    }

    /// Two candidates are the same place when their boxes overlap substantially
    /// — the Accessibility element and the OCR line of its own label, say.
    static func isSamePlace(_ firstCandidate: PointingCandidate, _ secondCandidate: PointingCandidate) -> Bool {
        guard firstCandidate.screenNumber == secondCandidate.screenNumber else { return false }
        let firstRegion = firstCandidate.regionInScreenshotPixels
        let secondRegion = secondCandidate.regionInScreenshotPixels
        if firstRegion.contains(CGPoint(x: secondRegion.midX, y: secondRegion.midY))
            || secondRegion.contains(CGPoint(x: firstRegion.midX, y: firstRegion.midY)) {
            return true
        }
        // An icon beside its label on the same row (Finder's sidebar) is two
        // elements but one place: vertical centres within half a line, and a
        // horizontal gap under two line heights.
        let largerHeight = max(firstRegion.height, secondRegion.height)
        let horizontalGap = max(firstRegion.minX - secondRegion.maxX, secondRegion.minX - firstRegion.maxX, 0)
        if abs(firstRegion.midY - secondRegion.midY) <= largerHeight / 2, horizontalGap <= largerHeight * 2 {
            return true
        }
        let overlap = firstRegion.intersection(secondRegion)
        guard !overlap.isNull else { return false }
        let smallerArea = min(firstRegion.width * firstRegion.height, secondRegion.width * secondRegion.height)
        return smallerArea > 0 && overlap.width * overlap.height >= smallerArea * 0.5
    }

    /// The confident match for the request, or nil.
    static func bestMatch(for request: PointingRequest, among candidates: [PointingCandidate]) -> PointingMatch? {
        bestMatch(targetText: request.targetText, roleHint: request.roleHint, among: candidates, minimumScore: minimumConfidentScore)
    }

    /// Every place the request matches equally well — one, or several when
    /// the same label is on screen more than once ("Documents" in both
    /// Finder's sidebar and its file list). Both are right answers, so all are
    /// marked at once rather than asking a model to break a tie it can't see
    /// any better. Empty when nothing matches confidently.
    static func bestPlaces(
        for request: PointingRequest,
        among candidates: [PointingCandidate],
        maximumPlaceCount: Int = FastPointingTiming.maximumMarkedPlaces
    ) -> [PointingMatch] {
        let targetWords = words(in: request.targetText)
        guard !targetWords.isEmpty else { return [] }

        let scoredMatches = candidates
            .compactMap { candidate -> PointingMatch? in
                guard let candidateScore = score(targetWords: targetWords, roleHint: request.roleHint, candidate: candidate) else { return nil }
                return PointingMatch(candidate: candidate, score: candidateScore)
            }
            .sorted { $0.score > $1.score }

        guard let topMatch = scoredMatches.first, topMatch.score >= minimumConfidentScore else { return [] }

        var places: [PointingMatch] = []
        for scoredMatch in scoredMatches {
            // Only near-equal matches; a clearly weaker one is a different thing.
            guard topMatch.score - scoredMatch.score < requiredLeadOverRunnerUp else { break }
            // One marker per place: an element and the OCR line of its own label
            // are the same place, and the stronger one is already kept.
            if places.contains(where: { isSamePlace($0.candidate, scoredMatch.candidate) }) { continue }
            places.append(scoredMatch)
        }
        // More equal places than can be marked means the label is everywhere
        // (a column of "Folder"), which is not an answer.
        guard places.count <= maximumPlaceCount else { return [] }
        return places
    }

    /// The candidates sharing at least one word with the target, best first —
    /// what the text-only model chooses from. A short list keeps that call to a
    /// few hundred tokens: the full element list of a busy window was measured
    /// at ~2.5k tokens, 4–6s of prompt evaluation for a 3B model, and it then
    /// picked the wrong line.
    static func shortlist(
        targetText: String,
        among candidates: [PointingCandidate],
        limit: Int = 15
    ) -> [PointingCandidate] {
        let targetWords = words(in: targetText).filter { !connectorWords.contains($0) }
        guard !targetWords.isEmpty else { return [] }
        let rankedCandidates = candidates.compactMap { candidate -> (candidate: PointingCandidate, sharedWordCount: Int)? in
            let candidateWords = words(in: candidate.text)
            let sharedWordCount = targetWords.filter { targetWord in
                candidateWords.contains { candidateWord in
                    wordsMatch(targetWord, candidateWord)
                        || (targetWord.count >= 3 && candidateWord.hasPrefix(targetWord))
                        || (candidateWord.count >= 3 && targetWord.hasPrefix(candidateWord))
                }
            }.count
            return sharedWordCount > 0 ? (candidate, sharedWordCount) : nil
        }
        // Stable order within a count keeps reading order, which the ids follow.
        return rankedCandidates
            .enumerated()
            .sorted { first, second in
                if first.element.sharedWordCount != second.element.sharedWordCount {
                    return first.element.sharedWordCount > second.element.sharedWordCount
                }
                return first.offset < second.offset
            }
            .prefix(limit)
            .map(\.element.candidate)
    }

    static func bestMatch(
        targetText: String,
        roleHint: String?,
        among candidates: [PointingCandidate],
        minimumScore: Double
    ) -> PointingMatch? {
        let targetWords = words(in: targetText)
        guard !targetWords.isEmpty else { return nil }

        let scoredMatches = candidates
            .compactMap { candidate -> PointingMatch? in
                guard let candidateScore = score(targetWords: targetWords, roleHint: roleHint, candidate: candidate) else { return nil }
                return PointingMatch(candidate: candidate, score: candidateScore)
            }
            .sorted { $0.score > $1.score }

        guard let topMatch = scoredMatches.first, topMatch.score >= minimumScore else { return nil }

        // The strongest competitor that is somewhere else on screen.
        if let runnerUpElsewhere = scoredMatches.dropFirst().first(where: { !isSamePlace($0.candidate, topMatch.candidate) }),
           topMatch.score - runnerUpElsewhere.score < requiredLeadOverRunnerUp {
            return nil
        }
        return topMatch
    }
}

// MARK: - Text-only model fallback

/// The prompt and reply parsing for the text-only model call used when the
/// deterministic match declines. No screenshot: the element list already says
/// what is where, and picking a line from a list is a text task a small model
/// does well and fast, where guessing pixels from an image is neither.
nonisolated enum PointingModelFallback {
    /// Enough for `[POINT:a123:a short label]`.
    static let maximumOutputTokens = 32

    static let systemPrompt = """
        you find things on the user's screen. you get a list of what is on screen, each with an id \
        (a1, a2… are app controls; t1, t2… are lines of text). pick the one the user means and reply \
        with only one tag, e.g. [POINT:t6:voice and models]. if nothing in the list is it, reply [POINT:none].
        """

    /// The shortlist as one line per candidate, e.g. `a14 button "Search"`.
    static func userMessageText(transcript: String, shortlistedCandidates: [PointingCandidate]) -> String {
        var lines = ["on screen:"]
        for candidate in shortlistedCandidates {
            let quotedText = candidate.text
                .replacingOccurrences(of: "\"", with: "'")
                .replacingOccurrences(of: "[", with: "(")
                .replacingOccurrences(of: "]", with: ")")
            lines.append("\(candidate.elementID) \(candidate.accessibilityRoleName ?? "text") \"\(quotedText.prefix(60))\"")
        }
        lines.append("")
        lines.append("user: \(transcript)")
        return lines.joined(separator: "\n")
    }

    /// The id the reply names, read leniently — a 3B model was measured
    /// writing `[POINT:id:16]`, `[POINT:id="t1"]` and `[POINT:id:Ungrouped]`
    /// for the same instruction. Returns nil for `[POINT:none]`.
    ///
    /// - A real id (`t6`, `A12`) anywhere in the reply wins.
    /// - A bare number is accepted only when every candidate uses one prefix,
    ///   so `16` can't be read as `a16` when `t16` was meant.
    /// - Otherwise a label in the tag is matched against the candidates' text.
    static func elementID(fromReply replyText: String, candidates: [PointingCandidate]) -> String? {
        let knownElementIDs = Set(candidates.map(\.elementID))
        let lowercasedReply = replyText.lowercased()
        if lowercasedReply.contains("point:none") || lowercasedReply.contains("point: none") { return nil }

        if let idRegex = try? NSRegularExpression(pattern: #"(?<![a-z0-9])([at]\d+)(?![a-z0-9])"#) {
            for match in idRegex.matches(in: lowercasedReply, range: NSRange(lowercasedReply.startIndex..., in: lowercasedReply)) {
                if let idRange = Range(match.range(at: 1), in: lowercasedReply) {
                    let elementID = String(lowercasedReply[idRange])
                    if knownElementIDs.contains(elementID) { return elementID }
                }
            }
        }

        let tagBody = tagBodyText(in: lowercasedReply) ?? lowercasedReply
        let idPrefixes = Set(candidates.compactMap { $0.elementID.first })
        if idPrefixes.count == 1, let onlyPrefix = idPrefixes.first,
           let numberRegex = try? NSRegularExpression(pattern: #"(?<![a-z0-9])(\d+)(?![0-9])"#),
           let numberMatch = numberRegex.firstMatch(in: tagBody, range: NSRange(tagBody.startIndex..., in: tagBody)),
           let numberRange = Range(numberMatch.range(at: 1), in: tagBody) {
            let elementID = "\(onlyPrefix)\(tagBody[numberRange])"
            if knownElementIDs.contains(elementID) { return elementID }
        }

        // A label instead of an id: strip the tag syntax and match it like a
        // spoken target, a little more leniently since the model already chose.
        let labelText = tagBody
            .replacingOccurrences(of: "point:", with: " ")
            .replacingOccurrences(of: #"(?<![a-z0-9])id(?![a-z0-9])"#, with: " ", options: .regularExpression)
        return PointingTargetMatcher.bestMatch(
            targetText: labelText,
            roleHint: nil,
            among: candidates,
            minimumScore: 0.34
        )?.candidate.elementID
    }

    private static func tagBodyText(in text: String) -> String? {
        guard let openRange = text.range(of: "[point:") else { return nil }
        let afterOpen = text[openRange.upperBound...]
        let body = afterOpen.split(separator: "]", maxSplits: 1, omittingEmptySubsequences: false).first ?? afterOpen[...]
        return String(body)
    }
}
