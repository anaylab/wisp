//
//  ChromeAskAboutThisRequest.swift
//  leanring-buddy
//
//  "Ask Wisp about this" from inside Chrome (phase 06): what the Wisp Tabs
//  extension sends when the user right-clicks a selection, image, link or
//  page, types "w …" in the address bar, or presses ⌘⇧Y — and what Wisp makes
//  of each one.
//
//  The events carry ids and URLs only (contracts.md §2): the tab, the page's
//  address, and the selection / image / link address from Chrome's menu info.
//  Everything that came from the page — the selection, the addresses — is
//  untrusted data, so it reaches a model only inside a data fence
//  (`ChromeAskAboutThisContext`), never as an instruction.
//
//  Pure (Foundation only), tested by `Tests/ChromeExtAskAboutThis`.
//

import Foundation

// MARK: - The events

nonisolated enum ChromeAskAboutThisEventName {
    static let askAboutSelection = "user.askAboutSelection"
    static let askAboutImage = "user.askAboutImage"
    static let askAboutLink = "user.askAboutLink"
    static let askAboutPage = "user.askAboutPage"
    static let omniboxQuestion = "user.omniboxQuestion"

    static let all: Set<String> = [askAboutSelection, askAboutImage, askAboutLink, askAboutPage, omniboxQuestion]
}

/// The `data` of every `user.*` event. Which fields are set depends on the
/// event; all of them are optional so a field the extension leaves out (an
/// empty selection, a tab-less omnibox question) still decodes.
nonisolated struct ChromeAskAboutThisEventPayload: Decodable, Equatable, Sendable {
    let tabId: Int?
    let windowId: Int?
    let frameId: Int?
    let pageUrl: String?
    let srcUrl: String?
    let linkUrl: String?
    let selectionText: String?
    let mediaType: String?
    /// The omnibox question.
    let text: String?
    /// "ask" (the default) or "addToBrain".
    let intent: String?
    /// "contextMenu", "command" or "omnibox".
    let source: String?
    let truncated: Bool?
}

// MARK: - What Wisp makes of one

/// Where in Chrome the user is asking about.
nonisolated struct ChromeAskTabReference: Equatable, Sendable {
    let tabID: Int
    let pageURL: String
}

nonisolated enum ChromeAskAboutThisRequest: Equatable, Sendable {
    /// Opens the composer about the selection. `menuSelectionText` is Chrome's
    /// own copy of it, the fallback when the page can't be read.
    case askAboutSelection(ChromeAskTabReference, menuSelectionText: String)
    /// `imageURLWasCutOff`: the extension had to shorten an address (a huge
    /// data: one, usually), so it can't be downloaded.
    case askAboutImage(ChromeAskTabReference, imageURL: String, imageURLWasCutOff: Bool)
    case askAboutLink(ChromeAskTabReference, linkURL: String, menuSelectionText: String)
    case askAboutPage(ChromeAskTabReference)
    /// Runs straight away as a typed question, with the tab as context when
    /// there is one.
    case omniboxQuestion(question: String, tab: ChromeAskTabReference?)
    case addSelectionToBrain(ChromeAskTabReference, menuSelectionText: String)
    case addLinkToBrain(linkURL: URL, pageURL: String)
    case addPageToBrain(ChromeAskTabReference)
}

nonisolated enum ChromeAskAboutThisRequestDecoder {

    /// The longest question Wisp takes from the address bar.
    static let maximumOmniboxQuestionCharacters = 2_000

    static let addToBrainIntent = "addToBrain"

    /// The request an event stands for, or nil when it isn't one of phase 06's
    /// events or lacks what that request needs (no tab, an empty question, a
    /// link that isn't a web address). A nil is dropped quietly: the user's
    /// click did nothing rather than something wrong.
    static func request(eventName: String, payload: ChromeAskAboutThisEventPayload) -> ChromeAskAboutThisRequest? {
        let isAddToBrain = payload.intent == addToBrainIntent

        if eventName == ChromeAskAboutThisEventName.omniboxQuestion {
            let question = (payload.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty else { return nil }
            return .omniboxQuestion(
                question: String(question.prefix(maximumOmniboxQuestionCharacters)),
                tab: tabReference(from: payload)
            )
        }

        guard let tab = tabReference(from: payload) else { return nil }
        let menuSelectionText = (payload.selectionText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        switch eventName {
        case ChromeAskAboutThisEventName.askAboutSelection:
            return isAddToBrain
                ? .addSelectionToBrain(tab, menuSelectionText: menuSelectionText)
                : .askAboutSelection(tab, menuSelectionText: menuSelectionText)
        case ChromeAskAboutThisEventName.askAboutImage:
            // The address is checked when it is downloaded; a data: or
            // cut-off address still opens the composer, whose turn then falls
            // back to the screenshot.
            guard let imageURL = payload.srcUrl, !imageURL.isEmpty, !isAddToBrain else { return nil }
            return .askAboutImage(tab, imageURL: imageURL, imageURLWasCutOff: payload.truncated == true)
        case ChromeAskAboutThisEventName.askAboutLink:
            guard let linkURLText = payload.linkUrl, !linkURLText.isEmpty, payload.truncated != true else { return nil }
            if isAddToBrain {
                guard let linkURL = webAddress(linkURLText) else { return nil }
                return .addLinkToBrain(linkURL: linkURL, pageURL: tab.pageURL)
            }
            return .askAboutLink(tab, linkURL: linkURLText, menuSelectionText: menuSelectionText)
        case ChromeAskAboutThisEventName.askAboutPage:
            return isAddToBrain ? .addPageToBrain(tab) : .askAboutPage(tab)
        default:
            return nil
        }
    }

    private static func tabReference(from payload: ChromeAskAboutThisEventPayload) -> ChromeAskTabReference? {
        guard let tabID = payload.tabId, tabID >= 0 else { return nil }
        return ChromeAskTabReference(tabID: tabID, pageURL: payload.pageUrl ?? "")
    }

    /// An http(s) address with a host, or nil.
    static func webAddress(_ text: String) -> URL? {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              let url = components.url else { return nil }
        return url
    }
}
