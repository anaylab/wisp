//
//  BrainChromePageTarget.swift
//  leanring-buddy
//
//  "Add this page to my brain" with the Wisp Tabs extension (phase 02): the
//  page's text is read in the user's own Chrome tab instead of the URL being
//  fetched again. Kept apart from `BrainCommandRouter.swift`, which the
//  brain's standalone test suite compiles on its own.
//

import Foundation

extension BrainCommandTargetResolver {
    /// `resolve`, but a Chrome page is read through the Wisp Tabs extension
    /// when it may read pages: the text of the tab the user is looking at —
    /// signed in, after scripts ran, without the page furniture — instead of
    /// a fresh cookie-less fetch of its URL, which for many pages is a login
    /// wall or an empty app shell. Anything that doesn't work out falls back
    /// to the plain page target, which fetches the URL as before.
    static func resolvePreferringChromeExtensionText(_ targetHint: BrainCommandRouter.TargetHint) async -> Target {
        let target = resolve(targetHint)
        guard case .webPage(let webPage) = target,
              ChromePageReader.canReadPages,
              ChromePageReader.isConnectedExtension(inBrowserWithBundleIdentifier: webPage.browserBundleIdentifier) else {
            return target
        }
        do {
            // The tab AppleScript named, found by its address: the showing
            // one in the front window first.
            let snapshot = try await ChromeTabOrganizer.fetchSnapshot()
            let tabsAtThisAddress = snapshot.tabs.filter { $0.url == webPage.url.absoluteString }
            let chosenTab = tabsAtThisAddress.first { $0.active && $0.windowId == snapshot.focusedWindowId }
                ?? tabsAtThisAddress.first { $0.active }
                ?? tabsAtThisAddress.first
            guard let chosenTab else { return target }

            let pageText = try await ChromePageReader.readPage(tabID: chosenTab.id)
            guard pageText.wordCount >= ChromePageTextPrompt.minimumWordsToReplaceScreenshot else { return target }
            var pageWithTitle = webPage
            let extensionTitle = pageText.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !extensionTitle.isEmpty { pageWithTitle.title = extensionTitle }
            let truncationNote = pageText.truncated
                ? "\n\n(the page was longer; only its first part was read.)"
                : ""
            return .webPageWithText(pageWithTitle, pageText: pageText.text + truncationNote)
        } catch {
            print("⚠️ Brain: reading the Chrome tab through the extension failed, fetching its address instead — \(error.localizedDescription)")
            return target
        }
    }
}
