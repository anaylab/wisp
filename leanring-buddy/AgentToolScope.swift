//
//  AgentToolScope.swift
//  leanring-buddy
//
//  Decides which of the registered tools the model is actually shown.
//
//  Registered and exposed are different things. Every tool's name, description
//  and argument list sits in the system prompt, so the whole set is paid for on
//  every turn whether or not any of it is relevant. Measured here against
//  qwen2.5-vl: twelve tools cost 698 prompt tokens and 2.65s of prompt
//  evaluation, where three relevant ones cost 262 tokens and 0.36s. That is
//  over two seconds added to every agent turn to describe tools the request has
//  nothing to do with.
//
//  The second cost is worse and harder to see. A 7B model's tool selection
//  degrades as the list grows — it starts reaching for plausible-sounding
//  neighbours. Showing it four filesystem tools during a browser task is not
//  neutral; it is an invitation to use one.
//
//  Deterministic, like the other routing in this app. A model to choose which
//  tools to show a model would cost more than it saves, and this does not need
//  one: the scopes are few and the vocabulary that distinguishes them is small.
//

import Foundation

/// Which family of tools a request plausibly needs.
enum AgentToolScope: String, CaseIterable {
    case browser
    case filesystem
    case coding
    /// The user's long-term memory (`remember` / `forget`). Its own scope
    /// because "remember that…" shares no vocabulary with the others, and
    /// without it the two tools would surface only on lexical luck.
    case memory
    /// Texting someone and looking them up in Contacts (`send_imessage`,
    /// `find_contact`).
    case messaging
    /// The user's brain — their personal wiki (`search_brain`,
    /// `read_brain_page`, `add_to_brain`, `ingest_into_brain`). A request
    /// that names one of its pages is boosted separately, by
    /// `AgentToolRegistry.definitions(forRequest:)`, since page names are the
    /// user's own and no fixed vocabulary knows them.
    case brain
    case general

    /// Words that indicate this scope, weighted equally.
    ///
    /// Deliberately concrete nouns and verbs rather than anything clever. The
    /// failure this guards against is a request quietly landing in the wrong
    /// scope and finding its tool missing, so terms are chosen to be
    /// unambiguous rather than broad.
    private var indicativeTerms: [String] {
        switch self {
        case .browser:
            return ["browser", "page", "website", "web site", "web page", "tab", "url",
                    "link", "click", "google", "search the web", "online", "chrome",
                    "safari", "scroll", "form", "button on the page", "site"]
        case .filesystem:
            return ["file", "files", "folder", "directory", "repo", "repository",
                    "read the", "in my project", "on disk", "path", "codebase"]
        case .coding:
            return ["code", "bug", "test", "tests", "refactor", "function", "compile",
                    "build", "commit", "git", "implement", "fix the", "stack trace"]
        case .memory:
            // Not "memory": "how much memory is free" is about RAM, and should
            // stay in the general scope.
            return ["remember", "forget", "memorize", "keep in mind", "note that"]
        case .messaging:
            // Not bare "text": "the text on screen" is a screen question.
            return ["message", "imessage", "sms", "send a text", "text message",
                    "contact", "phone number", "email address", "whose number"]
        case .brain:
            // Not bare "notes": "notes app" and "release notes" aren't the
            // brain. Not "remember": that routes to the memory tools.
            return ["my brain", "in my brain", "to my brain", "wiki", "my notes on", "my notes about",
                    "what do i know about", "what do you know about", "what have i saved",
                    "what did i save", "ingest"]
        case .general:
            return []
        }
    }

    /// Tools always worth offering, whatever the request looks like.
    ///
    /// Every addition here is paid for on every turn in every scope, which is
    /// the cost this whole type exists to avoid. `load_skill` earns its place
    /// as the exception: skill topics are open-ended and user-defined, so
    /// there is no fixed vocabulary that could route to one the way "page" or
    /// "url" routes to browser tools, and it is not mutually exclusive with
    /// any scope — a coding request might still need a skill.
    static let alwaysAvailableToolNames: Set<String> = [
        "get_current_time",
        "do_in_background",
        "load_skill",
    ]

    /// Picks a scope from the user's words.
    ///
    /// Ties and blanks fall to `.general`, which is the safe direction: a
    /// general turn that needed a browser tool costs one clarifying exchange,
    /// where a misrouted destructive tool costs rather more.
    static func forRequest(_ transcript: String) -> AgentToolScope {
        let text = transcript.lowercased()

        var bestScope = AgentToolScope.general
        var bestScore = 0

        // A named site ("youtube", "amazon") or a web address is as clear a
        // browser signal as the word "browser" — clearer, since nobody says
        // "open youtube" about anything else. Without this, "open youtube"
        // was routed to general and the browser tools never reached the model.
        let namesAWebDestination = BrowserSiteRegistry.site(namedIn: text) != nil
            || text.range(of: "\\b[a-z0-9-]+\\.(com|org|net|io|dev|ai|co|app|edu|gov)\\b", options: .regularExpression) != nil

        for scope in AgentToolScope.allCases where scope != .general {
            var score = scope.indicativeTerms.reduce(into: 0) { total, term in
                if text.contains(term) { total += 1 }
            }
            if scope == .browser && namesAWebDestination { score += 2 }
            // "text sam …" — the verb leading the request is the clearest sign.
            if scope == .messaging && text.hasPrefix("text ") { score += 1 }
            if score > bestScore {
                bestScore = score
                bestScope = scope
            }
        }
        return bestScope
    }

    /// Whether a registered tool belongs in this scope.
    func includes(toolNamed name: String) -> Bool {
        if Self.alwaysAvailableToolNames.contains(name) { return true }

        switch self {
        case .browser:
            return name == "browser_task" || name == "read_page"
                || name == "click_element" || name == "open_url"
                || name.hasPrefix("chrome_")
        case .filesystem:
            return name.hasPrefix("filesystem__")
        case .coding:
            return name == "delegate_coding_task" || name.hasPrefix("filesystem__")
        case .memory:
            return name == "remember" || name == "forget"
        case .messaging:
            return name == MessagingToolNames.sendIMessage || name == MessagingToolNames.findContact
        case .brain:
            return BrainToolNames.all.contains(name)
        case .general:
            // What a conversation plausibly reaches for: the things that
            // answer a question about the user's own machine right now.
            return name == "list_windows" || name == "read_clipboard" || name == "read_page"
                || name == "read_screen_text"
        }
    }

    /// Hard ceiling on how many tools reach the model.
    ///
    /// A small model's selection accuracy falls off well before this, so the
    /// limit is a backstop for a scope growing unnoticed rather than a target.
    static let maximumExposedTools = 6
}
