//
//  ComposioToolRouting.swift
//  leanring-buddy
//
//  Decides when Composio's meta-tools should be shown for a request.
//
//  Composio's connect server exposes a handful of generic tools
//  (`COMPOSIO_SEARCH_TOOLS`, `COMPOSIO_MULTI_EXECUTE_TOOL`, …) whose names and
//  descriptions never mention the user's apps, so "check my calendar" scored
//  zero against them and the model was shown no way to reach Google Calendar —
//  it then said it had no calendar connection. When the request names an app
//  the user has connected (or the everyday word for one), those meta-tools get
//  the router's boost.
//

import Foundation

enum ComposioToolRouting {
    /// Everyday words that mean a connected app, beyond its name.
    private static let aliasWordsByAppSlug: [String: [String]] = [
        "gmail": ["email", "emails", "inbox", "mail"],
        "googlecalendar": [
            "calendar", "calender", "calandar", "schedule", "meeting", "meetings", "agenda",
            "event", "events", "appointment", "appointments", "busy", "free",
            // "what do i have tmr?" names no app, but a question about a day is
            // a question about the calendar.
            "today", "tonight", "tomorrow", "tmr", "tmrw", "tomorrows", "week", "weekend", "monday",
            "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        ],
        "googledrive": ["drive"],
        "googlesheets": ["spreadsheet", "spreadsheets", "sheet", "sheets"],
        "googledocs": ["doc", "docs", "document"],
        "outlook": ["email", "emails", "inbox", "mail", "calendar", "schedule"],
        "slack": ["channel", "channels"],
        "linear": ["issue", "issues"],
        "github": ["repo", "repos", "repository", "pull", "commit", "commits"],
        "asana": ["task", "tasks"],
    ]

    static func isComposioMetaTool(_ toolName: String) -> Bool {
        toolName.contains("COMPOSIO_")
    }

    /// The meta-tools that only look up tool names and schemas.
    static func isLookupOnlyMetaTool(bareToolName: String) -> Bool {
        let uppercasedName = bareToolName.uppercased()
        return uppercasedName == "COMPOSIO_SEARCH_TOOLS" || uppercasedName == "COMPOSIO_GET_TOOL_SCHEMAS"
    }

    /// True when the request is about an app in `connectedAppSlugs`.
    static func requestIsAboutConnectedApp(
        _ transcript: String,
        connectedAppSlugs: Set<String>,
        appNamesBySlug: [String: String]
    ) -> Bool {
        let requestWords = Set(transcript.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let lowercasedTranscript = transcript.lowercased()
        for slug in connectedAppSlugs {
            if requestWords.contains(slug) { return true }
            if let name = appNamesBySlug[slug]?.lowercased(), lowercasedTranscript.contains(name) { return true }
            if let aliases = aliasWordsByAppSlug[slug], aliases.contains(where: requestWords.contains) { return true }
        }
        return false
    }
}
