//
//  FastCommandRouter.swift
//  leanring-buddy
//
//  Handles the handful of requests that need no model at all.
//
//  "Open Safari" and "mute" are not questions. Routing them through a 7B vision
//  model costs a second of generation to produce a sentence nobody needed, and
//  on a cold model several seconds more, to do something NSWorkspace does in
//  about ten milliseconds. Recognising them up front is the difference between
//  Wisp feeling like an assistant and feeling like a chat window.
//
//  Deliberately deterministic. A second resident model to classify requests
//  would cost gigabytes on a machine that has none spare, and this job does not
//  need one: the commands worth fast-pathing are a small, closed set with rigid
//  phrasing.
//
//  The design bias throughout is toward *not* matching. A miss costs the user
//  one ordinary model round-trip, which is the behaviour they had anyway. A
//  false positive silently launches something they did not ask for, or worse,
//  answers a real question with "opened Mail". So every pattern requires an
//  explicit verb, and app names are matched against what is actually installed
//  rather than guessed at.
//

import AppKit
import Foundation

@MainActor
enum FastCommandRouter {
    /// What a matched command did, and what to say about it.
    struct Outcome {
        /// Short, spoken. These replace a model answer, so they have to sound
        /// like Wisp rather than like a shell.
        let spokenConfirmation: String

        /// A card to show for the command, resolved exactly like a model's
        /// `[CARD:]` tag. Only a timer has one today; nil for everything else.
        var glanceCardRequest: GlanceCardRequest? = nil
    }

    /// Attempts to handle `transcript` without the model.
    ///
    /// Returns nil for anything not recognised with high confidence, which is
    /// the overwhelming majority of input.
    static func handle(_ transcript: String) -> Outcome? {
        let normalized = transcript
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))

        guard !normalized.isEmpty else { return nil }

        if let outcome = handleAudioCommand(normalized) { return outcome }
        if let outcome = handleMediaCommand(normalized) { return outcome }
        if let outcome = handleTimerCommand(normalized) { return outcome }
        if let outcome = handleAppLaunch(normalized) { return outcome }
        return nil
    }

    // MARK: - Timers

    /// "Set a timer for five minutes" is a command with one parameter, and the
    /// model adds nothing but latency. The timer itself is started by
    /// `CompanionManager` resolving the returned card request — the same path a
    /// model-emitted `[CARD:{"kind":"timer",…}]` takes — so there is exactly
    /// one place timers begin.
    private static func handleTimerCommand(_ text: String) -> Outcome? {
        guard let timerRequest = TimerCommandParser.timerRequest(fromNormalizedText: text) else { return nil }

        let spokenDuration = WispTimerDurationFormatter.spokenDurationText(totalSeconds: timerRequest.durationSeconds)
        let spokenConfirmation: String
        if let label = timerRequest.label {
            spokenConfirmation = "\(label) timer set for \(spokenDuration)."
        } else {
            spokenConfirmation = "timer set for \(spokenDuration)."
        }
        return Outcome(spokenConfirmation: spokenConfirmation, glanceCardRequest: .timer(timerRequest))
    }

    // MARK: - Music

    /// "Pause", "next song", "play some music": rigid phrases with no song to
    /// look up. "Play <artist>" goes to the model and its `control_music` tool.
    private static func handleMediaCommand(_ text: String) -> Outcome? {
        guard let action = MediaPlaybackPhraseParser.action(fromNormalizedText: text) else { return nil }
        return Outcome(spokenConfirmation: MediaPlayback.perform(action))
    }

    // MARK: - Audio

    private static func handleAudioCommand(_ text: String) -> Outcome? {
        // Whole-utterance matches only. "mute" inside "how do I mute this
        // meeting" is a question about muting, not an instruction to mute.
        switch text {
        case "mute", "mute it", "mute the volume", "be quiet", "silence":
            setMuted(true)
            return Outcome(spokenConfirmation: "muted.")

        case "unmute", "unmute it", "sound on":
            setMuted(false)
            return Outcome(spokenConfirmation: "unmuted.")

        case "volume up", "turn it up", "louder", "turn the volume up":
            adjustVolume(by: 12)
            return Outcome(spokenConfirmation: "turned it up.")

        case "volume down", "turn it down", "quieter", "turn the volume down":
            adjustVolume(by: -12)
            return Outcome(spokenConfirmation: "turned it down.")

        default:
            return nil
        }
    }

    private static func setMuted(_ muted: Bool) {
        runAppleScript("set volume \(muted ? "with" : "without") output muted")
    }

    private static func adjustVolume(by delta: Int) {
        // Read-modify-write rather than a relative command, because AppleScript
        // has no relative form and clamping has to happen somewhere.
        guard let current = Int(runAppleScript("output volume of (get volume settings)") ?? "") else { return }
        let target = max(0, min(100, current + delta))
        runAppleScript("set volume output volume \(target)")
    }

    // MARK: - Launching apps

    /// Verbs that unambiguously mean "launch", paired with nothing else.
    private static let launchPrefixes = ["open ", "launch ", "start ", "go to "]

    private static func handleAppLaunch(_ text: String) -> Outcome? {
        guard let prefix = launchPrefixes.first(where: { text.hasPrefix($0) }) else { return nil }

        var name = String(text.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespaces)
        // "open up chrome", "open the terminal"
        for filler in ["up ", "the ", "my "] where name.hasPrefix(filler) {
            name = String(name.dropFirst(filler.count))
        }
        guard !name.isEmpty, name.count <= 40 else { return nil }

        // A request with a verb after the noun is a task, not a launch:
        // "open safari and search for x" belongs to the agent, not here.
        let taskIndicators = [" and ", " then ", " to ", " so ", " because "]
        guard !taskIndicators.contains(where: { name.contains($0) }) else { return nil }

        guard let url = applicationURL(matching: name) else { return nil }

        let displayName = url.deletingPathExtension().lastPathComponent
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return Outcome(spokenConfirmation: "opening \(displayName).")
    }

    /// Resolves a spoken app name against what is actually installed.
    ///
    /// Matching real applications is what makes the strict-verb rule safe: if
    /// the noun is not an installed app, this returns nil and the request falls
    /// through to the model, so "open the pod bay doors" is answered rather
    /// than acted on.
    private static func applicationURL(matching spokenName: String) -> URL? {
        let candidates = [spokenName, spokenName.replacingOccurrences(of: " ", with: "")]

        for candidate in candidates {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate) {
                return url
            }
        }

        // CoreServices holds Finder and friends, which people ask for by name
        // as readily as anything in /Applications.
        let searchDirectories = ["/Applications", "/System/Applications",
                                 "/System/Applications/Utilities", "/Applications/Utilities",
                                 "/System/Library/CoreServices"]

        var wordMatch: URL?
        for directory in searchDirectories {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let bareName = String(entry.dropLast(4)).lowercased()
                let url = URL(fileURLWithPath: directory).appendingPathComponent(entry)

                if bareName == spokenName || bareName.replacingOccurrences(of: " ", with: "") == spokenName {
                    return url
                }

                // People say "chrome", not "google chrome". Matching a whole
                // word inside the real name covers that without the looseness
                // of a substring match, which would let "mail" select
                // "Mailbox". Exact matches above always win.
                if wordMatch == nil, bareName.split(separator: " ").contains(where: { $0 == spokenName }) {
                    wordMatch = url
                }
            }
        }
        return wordMatch
    }

    // MARK: - AppleScript

    @discardableResult
    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            print("⚠️ Fast command AppleScript failed: \(error)")
            return nil
        }
        return result?.stringValue
    }
}

// MARK: - Timer phrase parsing

/// Recognises spoken "set a timer" commands and reads out their length and an
/// optional label, without the model.
///
/// Same bias as the rest of this router: toward *not* matching. The whole
/// utterance has to be consumed by the grammar below, so "set a timer for 5
/// minutes and then remind me to call mum" or "how long is a 5 minute timer"
/// fall through to the model rather than half-matching. Accepted shapes:
///
///   [set|start|make] [me] [a] timer for <duration> [for|called|named <label>]
///   [set|start|make] [me] [a] <duration> [<label>] timer [for|called <label>]
///
/// where <duration> is one or more "<number> <unit>" parts ("1 hour 30
/// minutes", "2 minutes and 30 seconds"), with "half an hour" and "… and a
/// half" understood. Numbers are digits (what Apple Speech usually writes) or
/// the common number words.
enum TimerCommandParser {

    /// The timer a command asks for, or nil when the text is not a timer command
    /// (or asks for a length outside 1 second … 24 hours).
    ///
    /// Expects text already lowercased with trailing punctuation removed, which
    /// is what `FastCommandRouter.handle` passes.
    static func timerRequest(fromNormalizedText normalizedText: String) -> TimerCardRequest? {
        let rawWords = normalizedText
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        let words = wordsWithoutCourtesyPhrases(rawWords)
        guard !words.isEmpty else { return nil }

        guard let parsedCommand = parsedTimerForDurationCommand(words)
                ?? parsedDurationTimerCommand(words) else {
            return nil
        }

        let roundedSeconds = Int(parsedCommand.durationSeconds.rounded())
        guard roundedSeconds >= 1, roundedSeconds <= TimerCardRequest.maximumDurationSeconds else {
            return nil
        }
        return TimerCardRequest(durationSeconds: roundedSeconds, label: parsedCommand.label)
    }

    // MARK: Command shapes

    private struct ParsedTimerCommand {
        let durationSeconds: Double
        let label: String?
    }

    /// Verbs that start a timer command. Optional — "timer for 5 minutes" alone
    /// is just as clear.
    private static let commandVerbs: Set<String> = ["set", "start", "make", "begin"]

    /// Words between the verb and the timer that carry no meaning: "set *me a*
    /// timer", "start *up a* timer".
    private static let fillerWordsAfterVerb: Set<String> = ["me", "up", "a", "an", "the"]

    /// "[set] [me a] timer for <duration> [label clause]"
    private static func parsedTimerForDurationCommand(_ words: [String]) -> ParsedTimerCommand? {
        var wordIndex = indexAfterVerbAndFillers(in: words)

        guard wordIndex < words.count, words[wordIndex] == "timer" else { return nil }
        wordIndex += 1
        guard wordIndex < words.count, words[wordIndex] == "for" || words[wordIndex] == "of" else { return nil }
        wordIndex += 1

        guard let parsedDuration = parsedDuration(in: words, startingAt: wordIndex) else { return nil }
        wordIndex = parsedDuration.nextWordIndex

        guard case let .valid(label) = parsedTrailingLabelClause(in: words, startingAt: wordIndex) else {
            return nil
        }
        return ParsedTimerCommand(durationSeconds: parsedDuration.seconds, label: label)
    }

    /// "[set] [a] <duration> [<label>] timer [label clause]", e.g. "set a 5
    /// minute timer", "start a ten minute tea timer".
    private static func parsedDurationTimerCommand(_ words: [String]) -> ParsedTimerCommand? {
        var wordIndex = indexAfterVerbAndFillers(in: words)

        guard let parsedDuration = parsedDuration(in: words, startingAt: wordIndex) else { return nil }
        wordIndex = parsedDuration.nextWordIndex

        // Up to a few label words may sit between the length and "timer".
        var labelWordsBeforeTimer: [String] = []
        while wordIndex < words.count, words[wordIndex] != "timer" {
            labelWordsBeforeTimer.append(words[wordIndex])
            wordIndex += 1
        }
        guard wordIndex < words.count, words[wordIndex] == "timer" else { return nil }
        wordIndex += 1

        let labelBeforeTimer: String?
        if labelWordsBeforeTimer.isEmpty {
            labelBeforeTimer = nil
        } else {
            guard let validatedLabel = validatedLabel(fromWords: labelWordsBeforeTimer, maximumWordCount: 3) else {
                return nil
            }
            labelBeforeTimer = validatedLabel
        }

        guard case let .valid(labelAfterTimer) = parsedTrailingLabelClause(in: words, startingAt: wordIndex) else {
            return nil
        }
        // "a 5 minute tea timer called pasta" names the timer twice; decline.
        if labelBeforeTimer != nil && labelAfterTimer != nil { return nil }
        return ParsedTimerCommand(durationSeconds: parsedDuration.seconds, label: labelBeforeTimer ?? labelAfterTimer)
    }

    /// Skips an optional leading verb and the filler words after it. Fillers
    /// are only skipped after a verb, so a bare "a minute timer" still reads
    /// "a" as the number one.
    private static func indexAfterVerbAndFillers(in words: [String]) -> Int {
        guard let firstWord = words.first, commandVerbs.contains(firstWord) else { return 0 }
        var wordIndex = 1
        while wordIndex < words.count, fillerWordsAfterVerb.contains(words[wordIndex]) {
            wordIndex += 1
        }
        return wordIndex
    }

    // MARK: Courtesy

    /// Leading phrases that wrap a command without changing it.
    private static let leadingCourtesyPhrases: [[String]] = [
        ["hey", "wisp"], ["wisp"], ["please"], ["can", "you"], ["could", "you"], ["would", "you"]
    ]

    /// Strips "hey wisp, can you please …" from the front and "please" from the
    /// end, so the grammar only has to describe the command itself.
    private static func wordsWithoutCourtesyPhrases(_ words: [String]) -> [String] {
        var remainingWords = words
        var didStripPhrase = true
        while didStripPhrase {
            didStripPhrase = false
            for courtesyPhrase in leadingCourtesyPhrases where remainingWords.starts(with: courtesyPhrase) {
                remainingWords.removeFirst(courtesyPhrase.count)
                didStripPhrase = true
            }
        }
        if remainingWords.last == "please" {
            remainingWords.removeLast()
        }
        return remainingWords
    }

    // MARK: Labels

    private enum TrailingLabelClause {
        /// Nothing after the duration (nil), or a well-formed label clause.
        case valid(String?)
        /// Something follows the duration that is not a label — the utterance
        /// is more than a timer command.
        case invalid
    }

    /// Words that introduce a label after the length: "for the pasta",
    /// "called tea".
    private static let labelIntroducerWords: Set<String> = ["for", "called", "named", "labeled", "labelled", "titled"]

    private static func parsedTrailingLabelClause(in words: [String], startingAt startWordIndex: Int) -> TrailingLabelClause {
        guard startWordIndex < words.count else { return .valid(nil) }
        guard labelIntroducerWords.contains(words[startWordIndex]) else { return .invalid }

        var labelWords = Array(words[(startWordIndex + 1)...])
        // "for the pasta" / "for my tea" → "pasta" / "tea".
        if let firstLabelWord = labelWords.first, ["the", "my", "a", "an"].contains(firstLabelWord) {
            labelWords.removeFirst()
        }
        guard let validatedLabel = validatedLabel(fromWords: labelWords, maximumWordCount: 4) else {
            return .invalid
        }
        return .valid(validatedLabel)
    }

    /// Words that mean the "label" is really a second instruction ("… for 5
    /// minutes and then call mum"), which belongs to the model.
    private static let wordsThatEndALabel: Set<String> = ["and", "then", "to", "so", "because", "timer"]

    /// Joins label words if they look like a short name: 1…max words, letters
    /// only, and no conjunctions.
    private static func validatedLabel(fromWords labelWords: [String], maximumWordCount: Int) -> String? {
        guard !labelWords.isEmpty, labelWords.count <= maximumWordCount else { return nil }
        for labelWord in labelWords {
            guard !wordsThatEndALabel.contains(labelWord),
                  labelWord.allSatisfy({ $0.isLetter || $0 == "'" }) else { return nil }
        }
        return labelWords.joined(separator: " ")
    }

    // MARK: Durations

    private struct ParsedDuration {
        let seconds: Double
        let nextWordIndex: Int
    }

    /// Reads one or more "<number> <unit>" parts, optionally joined by "and".
    private static func parsedDuration(in words: [String], startingAt startWordIndex: Int) -> ParsedDuration? {
        var wordIndex = startWordIndex
        var totalSeconds: Double = 0
        var hasParsedAnyPart = false

        while wordIndex < words.count {
            var partStartWordIndex = wordIndex
            if hasParsedAnyPart && words[wordIndex] == "and" {
                partStartWordIndex = wordIndex + 1
            }
            guard let parsedPart = parsedDurationPart(in: words, startingAt: partStartWordIndex) else { break }
            totalSeconds += parsedPart.seconds
            wordIndex = parsedPart.nextWordIndex
            hasParsedAnyPart = true
        }

        return hasParsedAnyPart ? ParsedDuration(seconds: totalSeconds, nextWordIndex: wordIndex) : nil
    }

    /// Reads one part: "5 minutes", "an hour", "half an hour", "two and a half
    /// minutes", "a minute and a half".
    private static func parsedDurationPart(in words: [String], startingAt startWordIndex: Int) -> ParsedDuration? {
        guard startWordIndex < words.count else { return nil }

        // "half an hour", "half a minute", "half hour".
        if words[startWordIndex] == "half" {
            var unitWordIndex = startWordIndex + 1
            if unitWordIndex < words.count, words[unitWordIndex] == "a" || words[unitWordIndex] == "an" {
                unitWordIndex += 1
            }
            guard unitWordIndex < words.count,
                  let secondsPerUnit = secondsPerUnit(forUnitWord: words[unitWordIndex]) else { return nil }
            return ParsedDuration(seconds: secondsPerUnit / 2, nextWordIndex: unitWordIndex + 1)
        }

        guard let parsedNumber = parsedNumber(in: words, startingAt: startWordIndex) else { return nil }
        var unitCount = parsedNumber.value
        var wordIndex = parsedNumber.nextWordIndex

        // "two and a half minutes"
        if isAndAHalf(in: words, startingAt: wordIndex) {
            unitCount += 0.5
            wordIndex += 3
        }

        guard wordIndex < words.count,
              let secondsPerUnit = secondsPerUnit(forUnitWord: words[wordIndex]) else { return nil }
        wordIndex += 1

        // "a minute and a half"
        if isAndAHalf(in: words, startingAt: wordIndex) {
            unitCount += 0.5
            wordIndex += 3
        }

        return ParsedDuration(seconds: unitCount * secondsPerUnit, nextWordIndex: wordIndex)
    }

    private static func isAndAHalf(in words: [String], startingAt wordIndex: Int) -> Bool {
        guard wordIndex + 2 < words.count else { return false }
        return words[wordIndex] == "and" && words[wordIndex + 1] == "a" && words[wordIndex + 2] == "half"
    }

    private static func secondsPerUnit(forUnitWord unitWord: String) -> Double? {
        switch unitWord {
        case "second", "seconds", "sec", "secs": return 1
        case "minute", "minutes", "min", "mins": return 60
        case "hour", "hours", "hr", "hrs": return 3600
        default: return nil
        }
    }

    private struct ParsedNumber {
        let value: Double
        let nextWordIndex: Int
    }

    private static let numberWordValues: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
        "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30,
        "forty": 40, "fifty": 50, "sixty": 60, "ninety": 90
    ]

    /// Tens that can take a ones word after them ("twenty five").
    private static let tensWordsThatTakeOnes: Set<String> = ["twenty", "thirty", "forty", "fifty"]
    private static let onesWordValues: [String: Double] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9
    ]

    /// Reads a number as digits ("5", "1.5") or words ("five", "twenty five" —
    /// hyphens were already turned into spaces).
    private static func parsedNumber(in words: [String], startingAt wordIndex: Int) -> ParsedNumber? {
        guard wordIndex < words.count else { return nil }
        let numberWord = words[wordIndex]

        if let digitValue = Double(numberWord), digitValue.isFinite, digitValue >= 0 {
            return ParsedNumber(value: digitValue, nextWordIndex: wordIndex + 1)
        }

        guard let wordValue = numberWordValues[numberWord] else { return nil }

        // "twenty five" → 25.
        if tensWordsThatTakeOnes.contains(numberWord),
           wordIndex + 1 < words.count,
           let onesValue = onesWordValues[words[wordIndex + 1]] {
            return ParsedNumber(value: wordValue + onesValue, nextWordIndex: wordIndex + 2)
        }
        return ParsedNumber(value: wordValue, nextWordIndex: wordIndex + 1)
    }
}
