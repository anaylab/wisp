//
//  ChromePageContentRequestClassifier.swift
//  leanring-buddy
//
//  Whether a question is about what the page in Chrome *says* ("summarize this
//  page", "what's the price on this page", "explain this article") rather than
//  how it *looks* ("what color is the header", "where is the sign in button").
//
//  A yes lets the turn send the page's text instead of the screenshot: faster
//  (no ~4s of vision encoding on the local model), exact (prices and names
//  aren't read back from pixels) and complete (it reaches below the fold). A
//  wrong yes is the costly mistake — the model loses its eyes on a question
//  about the screen — so this is biased hard toward no: it needs a content
//  question *and* something that names the page, and any word about looks,
//  places or controls wins over both. A no keeps today's screenshot turn.
//
//  Pure (Foundation only), tested by `Tests/ChromeExtPageReading`.
//

import Foundation

nonisolated enum ChromePageContentRequestClassifier {

    /// Asking about the page's appearance, a place on it, or a control. Any of
    /// these keeps the screenshot. Also the furniture the page reader drops
    /// (sidebar, menu, header, footer), since the text would not contain it.
    private static let lookTerms: [String] = [
        "color", "colour", "look like", "looks like", "looking like", "layout", "design", "font",
        "style", "styling", "theme", "dark mode", "light mode", "logo", "icon", "image", "picture",
        "photo", "screenshot", "video", "chart", "graph", "diagram", "map",
        "button", "click", "tap", "link", "menu", "sidebar", "side bar", "header", "footer",
        "banner", "popup", "pop-up", "dialog", "toolbar", "tab bar", "search bar", "scroll",
        "where", "point", "show me", "highlight", "underline", "bold", "cursor", "mouse",
        "left", "right", "top", "bottom", "corner", "above", "below", "next to",
        "screen", "window", "how do i", "how can i", "what do i click", "error", "bug",
    ]

    /// Phrases that name the page itself.
    private static let pageReferencePhrases: [String] = [
        "this page", "the page", "this web page", "this webpage", "the webpage", "this tab", "the tab",
        "this article", "the article", "this site", "this website", "the website", "this post",
        "this blog", "this doc", "this document", "the doc", "this documentation", "the docs",
        "these docs", "this story", "this thread", "this recipe", "this paper", "this listing",
        "this product", "this review", "this essay", "this report", "this guide", "this tutorial",
        "this readme", "this email", "on here",
    ]

    /// Asking what the page says, in any form. Needs a page reference.
    private static let contentIntentPhrases: [String] = [
        "summarize", "summarise", "summary", "sum up", "tl;dr", "tldr", "gist", "key points",
        "main points", "takeaways", "take aways", "explain", "what does", "what is", "what's",
        "what are", "who is", "who are", "who wrote", "author", "when was", "published", "price",
        "cost", "how much", "how many", "ingredients", "steps", "instructions", "requirements",
        "deadline", "due date", "quote", "mention", "mentions", "say about", "talk about",
        "according to", "translate", "list", "find", "tell me about", "about", "conclusion",
        "argument", "pros and cons", "compare", "read",
    ]

    /// Content questions clear enough to need only "this" or "it" for the
    /// page ("summarize this", "how much does this cost").
    private static let strongContentIntentPhrases: [String] = [
        "summarize", "summarise", "summary", "sum up", "tl;dr", "tldr", "gist", "key points",
        "main points", "takeaways", "what does this say", "what does it say", "what is this about",
        "what's this about", "whats this about", "what is it about", "what's it about",
        "who wrote this", "when was this published", "how much does this cost", "how much is this",
        "what's the price", "whats the price", "what is the price", "how much does it cost",
    ]

    /// True when the question is about the content of the page in front of the
    /// user, so its text can stand in for the screenshot.
    static func isAboutPageContent(_ transcript: String) -> Bool {
        let text = normalized(transcript)
        guard !text.isEmpty else { return false }

        if lookTerms.contains(where: { containsWholePhrase($0, in: text) }) {
            return false
        }

        let namesThePage = pageReferencePhrases.contains { containsWholePhrase($0, in: text) }
        if namesThePage && contentIntentPhrases.contains(where: { containsWholePhrase($0, in: text) }) {
            return true
        }

        let pointsAtSomething = containsWholePhrase("this", in: text) || containsWholePhrase("it", in: text)
        let asksStrongly = strongContentIntentPhrases.contains { containsWholePhrase($0, in: text) }
        // "Summarize this" and "what's the price" (a price is only ever on a
        // page) carry their own reference.
        let isPriceQuestion = ["what's the price", "whats the price", "what is the price"]
            .contains { containsWholePhrase($0, in: text) }
        return asksStrongly && (pointsAtSomething || isPriceQuestion)
    }

    private static func normalized(_ transcript: String) -> String {
        transcript
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet(charactersIn: ",.!?:\"“”()"))
            .joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// "it" in "summarize it", not inside "with"; "map" not inside "mapping".
    private static func containsWholePhrase(_ phrase: String, in text: String) -> Bool {
        (" " + text + " ").contains(" " + phrase + " ")
    }
}
