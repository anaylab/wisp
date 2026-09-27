//
//  BrowserCommandRouter.swift
//  leanring-buddy
//
//  Recognises spoken browser commands so they reach the browser without asking
//  the model to pick a tool.
//
//  The local 3B model does not reliably emit a tool call. Measured directly:
//  given "open a new tab", "open youtube", "go to github.com" and "search google
//  for nvidia stock" with the real system prompt and tool list, it called no tool
//  for any of them — it replied "sure, i'll open a new tab for you" and did
//  nothing. An instruction the user gave plainly should not depend on a model
//  choosing to act on it.
//
//  So, like FastCommandRouter, this recognises a small set of unambiguous
//  phrasings up front:
//
//  * Tab commands — new tab, close tab, back, forward, reload, new window — run
//    straight against the user's browser. No model, no page reading.
//  * Web tasks — a named site, a web address, or "search for …" — go straight
//    to BrowserAgent, which works in its own tab.
//
//  The bias is the same as FastCommandRouter's: toward *not* matching. A miss
//  costs one ordinary model turn, which is what happened before; a false match
//  opens a browser the user did not ask for.
//

import Foundation

/// Something done to the browser itself rather than to a page.
enum BrowserTabCommand: Equatable {
    case newTab
    case closeTab
    case reload
    case back
    case forward
    case newWindow

    var confirmation: String {
        switch self {
        case .newTab:    return "opened a new tab."
        case .closeTab:  return "closed the tab."
        case .reload:    return "reloaded the page."
        case .back:      return "went back."
        case .forward:   return "went forward."
        case .newWindow: return "opened a new window."
        }
    }
}

@MainActor
enum BrowserCommandRouter {
    enum Route: Equatable {
        case tabCommand(BrowserTabCommand)
        /// A web task, already rephrased where that lets the deterministic
        /// planner take it ("search for x" → "search google for x").
        case browserTask(request: String)
    }

    static func route(_ transcript: String) -> Route? {
        let text = normalize(transcript)
        guard !text.isEmpty else { return nil }

        if let tabCommand = tabCommand(in: text) {
            return .tabCommand(tabCommand)
        }

        // "open a new tab and go to youtube": the task runs in a tab of its
        // own anyway, so the new-tab half is already satisfied.
        for phrase in newTabPhrases {
            if text.hasPrefix(phrase + " and ") {
                let remainder = String(text.dropFirst((phrase + " and ").count))
                return browserTaskRoute(for: remainder) ?? .browserTask(request: remainder)
            }
        }

        return browserTaskRoute(for: text)
    }

    // MARK: - Tab commands

    private static let newTabPhrases = [
        "open a new tab", "open new tab", "open a tab", "open another tab", "new tab",
        "make a new tab", "create a new tab", "open up a new tab", "open a new browser tab",
    ]

    /// Whole-utterance matches only, after polite filler is removed. "go back"
    /// inside "go back to the settings screen in xcode" is not a browser command.
    private static func tabCommand(in text: String) -> BrowserTabCommand? {
        let command = stripPoliteFiller(text)
        if newTabPhrases.contains(command) { return .newTab }
        switch command {
        case "close this tab", "close the tab", "close tab", "close the current tab":
            return .closeTab
        case "reload", "reload the page", "reload this page", "refresh", "refresh the page",
             "refresh this page", "reload the tab", "refresh the tab":
            return .reload
        case "go back", "go back a page", "back a page", "go back one page", "previous page":
            return .back
        case "go forward", "go forward a page", "forward a page", "next page in history":
            return .forward
        case "open a new window", "new window", "open new window", "open a new browser window",
             "open a new chrome window":
            return .newWindow
        default:
            return nil
        }
    }

    // MARK: - Web tasks

    private static let taskVerbs = [
        "open ", "go to ", "navigate to ", "visit ", "take me to ", "pull up ", "bring up ",
        "search ", "look up ", "find ", "google ", "browse ", "show me ", "check ", "buy ", "order ",
    ]

    /// Words that put a request on the web even when no site is named.
    private static let webMarkers = [
        "website", "web site", "web page", "webpage", "online", "on the web", "on the internet",
        "in the browser", "in my browser", "in chrome", "in safari", "in a new tab", "browser",
    ]

    private static func browserTaskRoute(for text: String) -> Route? {
        let request = stripPoliteFiller(text)

        // The deterministic planner already knows this shape — a named site or
        // a literal address — so it is certainly a browser request.
        if BrowserTaskPlanner.intent(for: request) != nil {
            return .browserTask(request: request)
        }

        guard taskVerbs.contains(where: { request.hasPrefix($0) }) else { return nil }

        // "search for x" / "search the web for x" / "look up x online": a web
        // search with no site named means the default search engine. Rephrased
        // so the planner takes it with no model call.
        for prefix in ["search the web for ", "search online for ", "search the internet for ",
                       "search for ", "google "] where request.hasPrefix(prefix) {
            let query = String(request.dropFirst(prefix.count))
                .replacingOccurrences(of: " online", with: "")
                .trimmingCharacters(in: .whitespaces)
            // "search for the file called notes" is about the Mac, not the web.
            let localSearchWords = ["file", "folder", "document", "email", "message", "app ", "setting"]
            guard !query.isEmpty, !localSearchWords.contains(where: { query.contains($0) }) else { return nil }
            return .browserTask(request: "search google for \(query)")
        }

        // A known site anywhere in a verb-led request — "find a usb-c cable on
        // amazon" — or an explicit mention of the web.
        if BrowserSiteRegistry.site(namedIn: request) != nil
            || webMarkers.contains(where: { request.contains($0) }) {
            return .browserTask(request: request)
        }
        return nil
    }

    // MARK: - Text

    private static func normalize(_ transcript: String) -> String {
        // Commas are dropped and spaces collapsed, so "hey wisp, new tab"
        // reads as "hey wisp new tab" and its filler strips cleanly.
        transcript
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: ",", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
    }

    /// Removes the polite framing speech adds around a command — "hey wisp,
    /// can you please open a new tab for me" → "open a new tab".
    private static func stripPoliteFiller(_ text: String) -> String {
        var command = text
        let leadingFillers = [
            "hey wisp ", "wisp ", "hey ", "okay ", "ok ", "so ", "um ", "uh ",
            "can you please ", "could you please ", "can you ", "could you ", "would you ",
            "will you ", "please ", "i want you to ", "i'd like you to ", "i need you to ",
            "go ahead and ", "just ",
        ]
        var didStrip = true
        while didStrip {
            didStrip = false
            command = command.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
            for filler in leadingFillers where command.hasPrefix(filler) {
                command = String(command.dropFirst(filler.count))
                didStrip = true
            }
        }
        for trailing in [" for me please", " please", " for me", " thanks", " thank you"]
        where command.hasSuffix(trailing) {
            command = String(command.dropLast(trailing.count))
        }
        return command.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
    }
}
