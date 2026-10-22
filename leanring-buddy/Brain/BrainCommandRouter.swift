//
//  BrainCommandRouter.swift
//  leanring-buddy
//
//  "Add this page to my brain", "save this to my brain", "remember this
//  page", "ingest this" — recognised without the model and handed straight to
//  `BrainIngestQueue`, like `BrowserCommandRouter` does for tab commands. The
//  local model can't see which tab or file "this" is, and was measured
//  choosing no tool at all for plain commands of this shape.
//
//  Two halves:
//  - `BrainCommandRouter.command(from:)` is pure: it matches the whole
//    utterance against a few fixed shapes and says what "this" most likely
//    is. Conservative — anything else returns nil and becomes a normal turn.
//  - `BrainCommandTargetResolver` finds the actual thing: the front browser
//    tab's URL and title, or the Finder selection, by AppleScript.
//

import AppKit
import Foundation

// MARK: - Parsing (pure)

enum BrainCommandRouter {
    /// What "this" refers to, from the word the user used.
    enum TargetHint: Equatable {
        /// "page", "article", "link", "site", "tab" — the front browser tab.
        case webPage
        /// "file", "pdf", "document" — the Finder selection.
        case file
        /// Plain "this" — whatever the frontmost app shows (browser tab or
        /// Finder selection).
        case frontmostThing
    }

    struct Command: Equatable {
        var targetHint: TargetHint
    }

    private static let webPageWords: Set<String> = ["page", "webpage", "web page", "article", "link", "site", "website", "tab", "post", "url"]
    private static let fileWords: Set<String> = ["file", "pdf", "document", "doc", "files", "documents", "pdfs"]

    /// Filler that may wrap a command without changing it.
    private static let leadingFillers = ["hey wisp ", "wisp ", "please ", "can you ", "could you ", "would you ", "go ahead and ", "okay ", "ok "]
    private static let trailingFillers = [" please", " for me", " now", " thanks", " thank you"]

    /// The command in an utterance, or nil if it isn't one.
    static func command(from transcript: String) -> Command? {
        let normalizedText = normalized(transcript)
        guard !normalizedText.isEmpty else { return nil }

        // "(add|save|put|send) this [thing] to|in|into my brain"
        // "remember this <thing>"   (a bare "remember this" is left to the
        //                            memory tools — it usually means a fact)
        // "ingest this [thing]"
        let thingAlternatives = (webPageWords.union(fileWords)).sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        let patterns = [
            "^(?:add|save|put|send|file|clip) (?:this|it|that)(?: (\(thingAlternatives)))? (?:to|in|into|in to) (?:my |the )?(?:brain|wiki)$",
            "^remember this (\(thingAlternatives))$",
            "^ingest (?:this|it|that)(?: (\(thingAlternatives)))?(?: (?:to|in|into) (?:my |the )?(?:brain|wiki))?$",
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: normalizedText, range: NSRange(normalizedText.startIndex..., in: normalizedText)) else {
                continue
            }
            var thingWord: String?
            if match.numberOfRanges > 1, let thingRange = Range(match.range(at: 1), in: normalizedText) {
                thingWord = String(normalizedText[thingRange])
            }
            return Command(targetHint: targetHint(forThingWord: thingWord))
        }
        return nil
    }

    static func targetHint(forThingWord thingWord: String?) -> TargetHint {
        guard let thingWord else { return .frontmostThing }
        if webPageWords.contains(thingWord) { return .webPage }
        if fileWords.contains(thingWord) { return .file }
        return .frontmostThing
    }

    /// Lowercased, punctuation dropped, fillers stripped, spaces collapsed.
    static func normalized(_ transcript: String) -> String {
        var text = transcript.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: " ")).inverted)
            .joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        var didStripFiller = true
        while didStripFiller {
            didStripFiller = false
            for leadingFiller in leadingFillers where text.hasPrefix(leadingFiller) {
                text = String(text.dropFirst(leadingFiller.count))
                didStripFiller = true
            }
            for trailingFiller in trailingFillers where text.hasSuffix(trailingFiller) {
                text = String(text.dropLast(trailingFiller.count))
                didStripFiller = true
            }
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// The fact in "remember that my favourite hiking spot is Mount Tam" /
    /// "remember my sister's name is Ana", or nil. Measured: the local model
    /// answered "I'll remember that" without ever calling `remember`, so a
    /// plain fact goes straight to the Me page. The user's own words are the
    /// consent, like the other direct routes. Conservative: "remember to …"
    /// is a reminder, "remember this/that page" is ingest, and anything that
    /// isn't a statement about the user (no "that", "my" or "I") is left alone.
    static func rememberedFact(from transcript: String) -> String? {
        var text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "’", with: "'")
        while let lastCharacter = text.last, ".!?".contains(lastCharacter) { text.removeLast() }
        var didStripFiller = true
        while didStripFiller {
            didStripFiller = false
            for leadingFiller in leadingFillers + ["can you please ", "please "] {
                // Spoken or typed, "hey wisp, remember…" often carries a comma.
                let commaFiller = leadingFiller.trimmingCharacters(in: .whitespaces) + ", "
                for fillerForm in [leadingFiller, commaFiller] where text.lowercased().hasPrefix(fillerForm) {
                    text = String(text.dropFirst(fillerForm.count))
                    didStripFiller = true
                }
            }
        }
        guard let expression = try? NSRegularExpression(
            pattern: #"^remember,? (?:that )?((?:my|i|i'm|i am|i've|we|our) .+|.+)$"#,
            options: [.caseInsensitive]
        ), let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let factRange = Range(match.range(at: 1), in: text) else { return nil }

        let saidThat = text.lowercased().hasPrefix("remember that ") || text.lowercased().hasPrefix("remember, that ")
        var fact = String(text[factRange]).trimmingCharacters(in: .whitespaces)
        let lowercasedFact = fact.lowercased()
        let firstWord = lowercasedFact.split(separator: " ").first.map(String.init) ?? ""
        let isAboutTheUser = ["my", "i", "i'm", "i've", "we", "our"].contains(firstWord) || lowercasedFact.hasPrefix("i am ")
        guard saidThat || isAboutTheUser else { return nil }
        // Not facts: reminders, ingest commands, questions, and too little to keep.
        if ["to", "this", "it", "me", "when", "where", "what", "who", "how", "why"].contains(firstWord) { return nil }
        // "remember the milk" is a reminder; "remember that the launch moved" is a fact.
        if firstWord == "the" && !saidThat { return nil }
        let thingWords = webPageWords.union(fileWords)
        if firstWord == "that", lowercasedFact.split(separator: " ").count <= 2 { return nil }
        if lowercasedFact.split(separator: " ").count == 1 && thingWords.contains(lowercasedFact) { return nil }
        guard fact.split(separator: " ").count >= 3 else { return nil }

        // Write it about the user, the way me.md facts read: "my favourite
        // spot is X" → "Favourite spot is X"; "I'm vegetarian" → "Is vegetarian".
        if lowercasedFact.hasPrefix("my ") {
            fact = String(fact.dropFirst(3))
        } else if lowercasedFact.hasPrefix("i'm ") {
            fact = "Is " + fact.dropFirst(4)
        } else if lowercasedFact.hasPrefix("i am ") {
            fact = "Is " + fact.dropFirst(5)
        }
        return fact.prefix(1).uppercased() + fact.dropFirst()
    }

    /// The notch reply once sources are queued: "adding “Title” to your brain".
    static func queuedReply(forTitles titles: [String]) -> String {
        switch titles.count {
        case 0: return "there was nothing to add."
        case 1: return "adding “\(titles[0])” to your brain."
        default: return "adding \(titles.count) things to your brain."
        }
    }
}

// MARK: - Finding "this"

/// Reads the thing a brain command refers to from the user's apps.
@MainActor
enum BrainCommandTargetResolver {
    struct WebPage: Equatable {
        var url: URL
        var title: String
        /// The browser the page was read from ("" when unknown).
        var browserBundleIdentifier: String = ""
    }

    enum Target: Equatable {
        case webPage(WebPage)
        /// A page whose text the Chrome extension read in the user's own tab:
        /// what they see, logged in, rather than a fresh fetch of the URL.
        case webPageWithText(WebPage, pageText: String)
        case files([URL])
        /// Why nothing could be found, as a short reply for the notch.
        case unavailable(String)
    }

    /// Browsers whose front tab can be read by AppleScript, with the phrase
    /// each one's dictionary uses. Chromium browsers share Chrome's.
    private static let chromiumBrowserBundleIdentifiers = [
        "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser"
    ]
    private static let safariBundleIdentifier = "com.apple.Safari"
    private static let finderBundleIdentifier = "com.apple.finder"
    /// Most Finder items one command queues.
    static let maximumFinderItems = 10

    static func resolve(_ targetHint: BrainCommandRouter.TargetHint) -> Target {
        // The app the user was in — not Wisp, which the text composer
        // activates while they type.
        let frontmostBundleIdentifier = FrontmostAppTracker.shared.lastExternalApplication?.bundleIdentifier ?? ""
        let frontmostIsBrowser = isReadableBrowser(frontmostBundleIdentifier)

        switch targetHint {
        case .webPage:
            if frontmostIsBrowser, let webPage = frontWebPage(inBrowserWithBundleIdentifier: frontmostBundleIdentifier) {
                return .webPage(webPage)
            }
            // Not in front (the user asked from another app): the first
            // running browser's front tab is still what "this page" means.
            for bundleIdentifier in [safariBundleIdentifier] + chromiumBrowserBundleIdentifiers
            where bundleIdentifier != frontmostBundleIdentifier && isRunning(bundleIdentifier) {
                if let webPage = frontWebPage(inBrowserWithBundleIdentifier: bundleIdentifier) {
                    return .webPage(webPage)
                }
            }
            return .unavailable("i couldn't find a web page to add — open it in Safari or Chrome and ask again.")

        case .file:
            return finderSelectionTarget()

        case .frontmostThing:
            if frontmostIsBrowser, let webPage = frontWebPage(inBrowserWithBundleIdentifier: frontmostBundleIdentifier) {
                return .webPage(webPage)
            }
            if frontmostBundleIdentifier == finderBundleIdentifier {
                return finderSelectionTarget()
            }
            return .unavailable("i can add a web page or a file — open the page, or select the file in Finder, and ask again.")
        }
    }

    private static func isReadableBrowser(_ bundleIdentifier: String) -> Bool {
        bundleIdentifier == safariBundleIdentifier || chromiumBrowserBundleIdentifiers.contains(bundleIdentifier)
    }

    private static func isRunning(_ bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    /// The URL and title of the tab the user is looking at.
    private static func frontWebPage(inBrowserWithBundleIdentifier bundleIdentifier: String) -> WebPage? {
        let tabSpecifier = bundleIdentifier == safariBundleIdentifier ? "current tab of front window" : "active tab of front window"
        let titleProperty = bundleIdentifier == safariBundleIdentifier ? "name" : "title"
        let script = """
        tell application id "\(bundleIdentifier)"
        if (count of windows) is 0 then return ""
        return (URL of \(tabSpecifier)) & linefeed & (\(titleProperty) of \(tabSpecifier))
        end tell
        """
        guard let reply = runAppleScript(script) else { return nil }
        let replyParts = reply.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let urlText = replyParts.first,
              urlText.hasPrefix("http"),
              let pageURL = URL(string: urlText) else { return nil }
        let pageTitle = replyParts.count > 1 ? replyParts[1].trimmingCharacters(in: .whitespaces) : ""
        return WebPage(
            url: pageURL,
            title: pageTitle.isEmpty ? (pageURL.host ?? urlText) : pageTitle,
            browserBundleIdentifier: bundleIdentifier
        )
    }

    private static func finderSelectionTarget() -> Target {
        let script = """
        tell application "Finder"
        set selectedItems to selection
        set selectedPaths to ""
        repeat with selectedItem in selectedItems
        set selectedPaths to selectedPaths & POSIX path of (selectedItem as alias) & linefeed
        end repeat
        return selectedPaths
        end tell
        """
        guard let reply = runAppleScript(script) else {
            return .unavailable("i couldn't read the Finder selection — allow Wisp to control Finder in System Settings → Privacy & Security → Automation.")
        }
        let selectedFileURLs = reply.split(separator: "\n")
            .map { URL(fileURLWithPath: String($0)) }
            .prefix(maximumFinderItems)
        guard !selectedFileURLs.isEmpty else {
            return .unavailable("select the file in Finder first, then ask again.")
        }
        return .files(Array(selectedFileURLs))
    }

    private static func runAppleScript(_ source: String) -> String? {
        var errorInfo: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo) else {
            if let errorInfo {
                print("⚠️ Brain command AppleScript failed: \(errorInfo[NSAppleScript.errorMessage] ?? errorInfo)")
            }
            return nil
        }
        return result.stringValue ?? ""
    }
}
