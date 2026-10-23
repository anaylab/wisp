//
//  ChromeAskAboutThisContext.swift
//  leanring-buddy
//
//  The part of a Chrome page the user asked about (phase 06) — a selection,
//  an image, a link or the whole page — and the per-turn context each one
//  builds: the text that rides the user message, and whether the screenshot
//  goes too.
//
//  It is the DOM twin of Ask About a Part: the composer shows an "About: …"
//  chip, the part rides every question until a fresh composer opens, and it
//  arrives as exact data (the selected text, the image's own pixels, the
//  link's address) instead of being read back from a screenshot by OCR.
//
//  The screenshot is left out unless the question is about how something
//  looks or where it is — the part is the subject, and on the local model a
//  screenshot costs ~4s of encoding and tempts it to describe the screen
//  instead. Everything from the page is fenced as DATA
//  (`ChromePageTextPrompt.dataFenceNote`).
//
//  Pure (Foundation only), tested by `Tests/ChromeExtAskAboutThis`.
//

import Foundation

nonisolated enum ChromeAskAboutThisPart: Equatable, Sendable {
    /// The selection as read from the page (with context), or built from
    /// Chrome's menu text when the page couldn't be read.
    case selection(ChromePageSelection)
    case image(ChromeAskTabReference, imageURL: String, imageURLWasCutOff: Bool)
    case link(ChromeAskTabReference, linkURL: String, linkText: String)
    /// The whole tab. `isFromAddressBar` for an omnibox question, which never
    /// shows the composer and uses the page only when the question is about it.
    case page(ChromeAskTabReference, isFromAddressBar: Bool)

    /// The composer chip's words.
    var chipLabel: String {
        switch self {
        case .selection: return "About: selected text"
        case .image: return "About: this image"
        case .link: return "About: this link"
        case .page: return "About: this page"
        }
    }

    /// What the chip's ✕ says to VoiceOver.
    var chipAccessibilityLabel: String {
        switch self {
        case .selection: return "Asking about the text you selected in Chrome. Clear it."
        case .image: return "Asking about the image you chose in Chrome. Clear it."
        case .link: return "Asking about the link you chose in Chrome. Clear it."
        case .page: return "Asking about the Chrome page. Clear it."
        }
    }

    var tabID: Int {
        switch self {
        case .selection(let selection): return selection.tabId
        case .image(let tab, _, _), .link(let tab, _, _), .page(let tab, _): return tab.tabID
        }
    }
}

/// What a turn carries for the part.
nonisolated struct ChromeAskAboutThisTurnPlan: Equatable, Sendable {
    /// Joins the per-turn context block on the user message (stripped from
    /// history like the screen's element ids).
    let promptText: String
    let attachesScreenshot: Bool
    /// The History step.
    let historyStepSummary: String
}

nonisolated enum ChromeAskAboutThisContext {

    // MARK: - When the screenshot still goes

    /// Words that ask about the look of something or a place on the screen.
    /// Narrower than `ChromePageContentRequestClassifier`'s list on purpose:
    /// "explain this link" or "what's in this image" is about the part itself,
    /// which the turn already carries exactly.
    private static let lookAndPlaceTerms: [String] = [
        "color", "colour", "look like", "looks like", "looking like", "layout", "design", "font",
        "styling", "logo", "icon", "screenshot", "highlighted", "highlight", "bold", "underlined",
        "where", "point", "show me", "on screen", "on the screen", "screen", "window",
        "next to", "above", "below", "on the left", "on the right", "at the top", "at the bottom",
        "button", "click", "what do i click",
    ]

    /// True when the question needs eyes as well as the part's data.
    static func questionAsksHowItLooks(_ question: String) -> Bool {
        let text = normalized(question)
        guard !text.isEmpty else { return false }
        return lookAndPlaceTerms.contains { containsWholePhrase($0, in: text) }
    }

    // MARK: - Selection

    /// A selection built from Chrome's own menu text, for when the page
    /// couldn't be read (no `pages.read`, a selection inside a frame).
    static func selectionFromMenuText(_ menuSelectionText: String, tab: ChromeAskTabReference) -> ChromePageSelection? {
        let trimmedText = menuSelectionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return nil }
        return ChromePageSelection(
            tabId: tab.tabID,
            windowId: nil,
            url: tab.pageURL,
            title: "",
            hasSelection: true,
            selectedText: trimmedText,
            contextBefore: "",
            contextAfter: "",
            truncated: false
        )
    }

    /// Which selection to use: the page's own read when it found one (it has
    /// the context around it), else Chrome's menu text, else nil — nothing
    /// readable was selected (a Google Doc draws its text on a canvas).
    static func chosenSelection(
        pageReadSelection: ChromePageSelection?,
        menuSelectionText: String,
        tab: ChromeAskTabReference
    ) -> ChromePageSelection? {
        if let pageReadSelection, pageReadSelection.hasSelection,
           !pageReadSelection.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return pageReadSelection
        }
        return selectionFromMenuText(menuSelectionText, tab: tab)
    }

    /// Said in the notch when nothing readable was selected.
    static let unreadableSelectionReply = "i couldn't read that selection — some pages, like google docs, draw their text in a way chrome extensions can't see. copy the text and ask me about it instead."

    static func plan(forSelection selection: ChromePageSelection, question: String, characterBudget: Int) -> ChromeAskAboutThisTurnPlan {
        let attachesScreenshot = questionAsksHowItLooks(question)
        var promptLines = [
            "the user is asking about text they selected in a chrome tab. it was read straight from the page, so answer about exactly this text.",
            ChromePageTextPrompt.promptText(for: selection, characterBudget: characterBudget),
        ]
        if !attachesScreenshot {
            promptLines.append("(there is no screenshot this turn — answer from the selected text, and don't point at the screen.)")
        }
        return ChromeAskAboutThisTurnPlan(
            promptText: promptLines.joined(separator: "\n"),
            attachesScreenshot: attachesScreenshot,
            historyStepSummary: "Used the text selected in Chrome\(attachesScreenshot ? " and the screenshot" : " instead of a screenshot")"
        )
    }

    // MARK: - Image

    static func plan(forImageURL imageURL: String, tab: ChromeAskTabReference, wasDownloaded: Bool) -> ChromeAskAboutThisTurnPlan {
        var promptLines = [
            wasDownloaded
                ? "the user is asking about an image in a chrome tab. that image itself is the last picture attached."
                : "the user is asking about an image in a chrome tab. wisp couldn't download it, so it isn't attached — find it in the screenshot.",
            "<<<",
            ChromePageTextPrompt.defused([
                "image address: \(singleLine(imageURL, maximumCharacters: 500))",
                "on page: \(singleLine(tab.pageURL, maximumCharacters: 500))",
            ].joined(separator: "\n")),
            ">>>",
            ChromePageTextPrompt.dataFenceNote,
        ]
        if wasDownloaded {
            promptLines.append("(there is no screenshot this turn — answer from the image.)")
        }
        return ChromeAskAboutThisTurnPlan(
            promptText: promptLines.joined(separator: "\n"),
            attachesScreenshot: !wasDownloaded,
            historyStepSummary: wasDownloaded
                ? "Attached the image from Chrome instead of a screenshot"
                : "Couldn't download the image from Chrome, so the screenshot went instead"
        )
    }

    /// The label the downloaded image goes to the model with.
    static let downloadedImageLabel = "the image the user right-clicked in chrome"

    // MARK: - Link

    static func plan(
        forLinkURL linkURL: String,
        linkText: String,
        tab: ChromeAskTabReference,
        question: String
    ) -> ChromeAskAboutThisTurnPlan {
        let attachesScreenshot = questionAsksHowItLooks(question)
        var fencedLines: [String] = []
        let trimmedLinkText = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        fencedLines.append("link text: \(trimmedLinkText.isEmpty ? "(unknown)" : singleLine(trimmedLinkText, maximumCharacters: 300))")
        fencedLines.append("link address: \(singleLine(linkURL, maximumCharacters: 1_000))")
        fencedLines.append("on page: \(singleLine(tab.pageURL, maximumCharacters: 500))")
        var promptLines = [
            "the user is asking about a link in a chrome tab.",
            "<<<",
            ChromePageTextPrompt.defused(fencedLines.joined(separator: "\n")),
            ">>>",
            ChromePageTextPrompt.dataFenceNote,
            "(nothing behind the link was opened or fetched. if the user wants to know what's behind it, open it with browser_task and read it with chrome_read_tab.)",
        ]
        if !attachesScreenshot {
            promptLines.append("(there is no screenshot this turn — answer from the link.)")
        }
        return ChromeAskAboutThisTurnPlan(
            promptText: promptLines.joined(separator: "\n"),
            attachesScreenshot: attachesScreenshot,
            historyStepSummary: "Used the link chosen in Chrome\(attachesScreenshot ? " and the screenshot" : " instead of a screenshot")"
        )
    }

    /// The link's own words, from a page snapshot's elements: the link whose
    /// address is the one right-clicked. The snapshot cuts `href` at 160
    /// characters, so a cut one matches by prefix. "" when it isn't listed.
    static func linkText(forLinkURL linkURL: String, among pageLinks: [(href: String?, label: String)]) -> String {
        let snapshotHrefLength = 160
        for pageLink in pageLinks {
            guard let href = pageLink.href, !href.isEmpty else { continue }
            let isSameAddress = href == linkURL || (href.count >= snapshotHrefLength && linkURL.hasPrefix(href))
            let label = pageLink.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if isSameAddress && !label.isEmpty {
                return label
            }
        }
        return ""
    }

    // MARK: - Page

    /// Whether to read the page's text for this turn at all. From the address
    /// bar only for a question about the page, since a question about anything
    /// else would pay for thousands of characters it doesn't need.
    static func wantsPageText(isFromAddressBar: Bool, question: String) -> Bool {
        if isFromAddressBar {
            return ChromePageContentRequestClassifier.isAboutPageContent(question)
        }
        return !questionAsksHowItLooks(question)
    }

    /// `pageText` is the read page, or nil when it wasn't wanted or couldn't be
    /// read. `questionRefersToScreen` is the ordinary turn's screenshot choice,
    /// used for an address-bar question that isn't about the page.
    static func plan(
        forPageText pageText: ChromePageText?,
        tab: ChromeAskTabReference,
        isFromAddressBar: Bool,
        question: String,
        questionRefersToScreen: Bool,
        characterBudget: Int
    ) -> ChromeAskAboutThisTurnPlan {
        if let pageText, pageText.wordCount >= ChromePageTextPrompt.minimumWordsToReplaceScreenshot,
           wantsPageText(isFromAddressBar: isFromAddressBar, question: question) {
            let framing = isFromAddressBar
                ? "the user typed this question into chrome's address bar while on this tab."
                : "the user asked about this whole chrome tab."
            return ChromeAskAboutThisTurnPlan(
                promptText: framing + "\n" + ChromePageTextPrompt.promptText(for: pageText, characterBudget: characterBudget),
                attachesScreenshot: false,
                historyStepSummary: "Read the Chrome tab's text instead of a screenshot"
            )
        }

        let attachesScreenshot = isFromAddressBar ? questionRefersToScreen : true
        let framing: String
        if isFromAddressBar {
            framing = attachesScreenshot
                ? "the user typed this question into chrome's address bar while on this tab, which is in the screenshot."
                : "the user typed this question into chrome's address bar while on this tab. use the tab only if the question is about it."
        } else {
            framing = "the user is asking about this chrome tab, which is in the screenshot."
        }
        let promptText = [
            framing,
            "<<<",
            ChromePageTextPrompt.defused("address: \(singleLine(tab.pageURL, maximumCharacters: 500))"),
            ">>>",
            ChromePageTextPrompt.dataFenceNote,
        ].joined(separator: "\n")
        return ChromeAskAboutThisTurnPlan(
            promptText: promptText,
            attachesScreenshot: attachesScreenshot,
            historyStepSummary: attachesScreenshot ? "Looked at the Chrome tab in the screenshot" : "Named the Chrome tab"
        )
    }

    // MARK: - Helpers

    private static func singleLine(_ text: String, maximumCharacters: Int) -> String {
        let collapsedText = text
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(collapsedText.prefix(maximumCharacters))
    }

    private static func normalized(_ question: String) -> String {
        question
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet(charactersIn: ",.!?:;\"“”()"))
            .joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    private static func containsWholePhrase(_ phrase: String, in text: String) -> Bool {
        (" " + text + " ").contains(" " + phrase + " ")
    }
}
