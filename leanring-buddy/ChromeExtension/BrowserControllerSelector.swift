//
//  BrowserControllerSelector.swift
//  leanring-buddy
//
//  Which browser controller serves the next browser task: the Chrome
//  extension (`ExtensionBrowserController`) or AppleScript
//  (`AppleScriptBrowserController`).
//
//  The extension is preferred whenever it can do the job: it works in a
//  background tab inside a "Wisp" tab group, addresses the tab by a real id,
//  and reads cross-origin frames. AppleScript stays the fallback — for Safari,
//  and for when the extension isn't connected or the user hasn't let it read
//  pages. The decision is re-made for every task (and every read_page /
//  click_element call), so granting or removing the permission takes effect on
//  the next one with nothing to restart.
//
//  With several Chromium browsers connected (phase 13), the extension path
//  serves the bridge's *active* browser (`ChromiumBrowserRouting`). When the
//  browser in front is a different one, Google Chrome without the extension
//  goes to AppleScript, so the work happens where the user is looking; any
//  other Chromium browser can't be driven by AppleScript, so the active
//  browser's extension does the work in its own background tab.
//
//  Pure (Foundation only) so `Tests/ChromeExtDOMController` can compile it;
//  `AgentToolRegistry.browserController(servingRequest:)` gathers the inputs.
//

import Foundation

nonisolated enum BrowserControllerKind: String, Equatable, Sendable {
    case chromeExtension
    case appleScript
}

nonisolated struct BrowserControllerSelectionInputs: Equatable, Sendable {
    /// What the app in front of the user is, as far as browsers go.
    enum FrontmostApplication: Equatable, Sendable {
        case safari
        /// Chrome, or another Chromium browser the extension could be loaded in.
        case chromiumBrowser
        /// Not a browser (Wisp itself, after a typed question, lands here too).
        case other

        init(bundleIdentifier: String?) {
            guard let bundleIdentifier else {
                self = .other
                return
            }
            if bundleIdentifier == "com.apple.Safari" || bundleIdentifier.hasPrefix("com.apple.SafariTechnologyPreview") {
                self = .safari
            } else if ChromiumBrowserCatalog.isChromiumBrowser(bundleIdentifier: bundleIdentifier) {
                self = .chromiumBrowser
            } else {
                self = .other
            }
        }
    }

    let isExtensionConnected: Bool
    let extensionCanReadPages: Bool
    let frontmostApplication: FrontmostApplication
    /// Whether the browser in front is the one the bridge sends requests to.
    /// Only read when a Chromium browser is in front; true keeps the
    /// one-browser behaviour.
    var activeExtensionBrowserIsFrontmost: Bool = true
    /// Whether the browser in front is one AppleScript drives (Google Chrome).
    var appleScriptCanDriveFrontmostBrowser: Bool = false
}

nonisolated struct BrowserControllerSelection: Equatable, Sendable {
    let kind: BrowserControllerKind
    /// Why, in a few words, for the log line each task writes.
    let reason: String
}

nonisolated enum BrowserControllerSelector {
    static func choose(_ inputs: BrowserControllerSelectionInputs) -> BrowserControllerSelection {
        guard inputs.isExtensionConnected else {
            return BrowserControllerSelection(kind: .appleScript, reason: "the chrome extension isn't connected")
        }
        guard inputs.extensionCanReadPages else {
            return BrowserControllerSelection(kind: .appleScript, reason: "the chrome extension can't read pages yet")
        }
        // Safari in front means the user is working in Safari; the extension
        // only reaches Chrome.
        if inputs.frontmostApplication == .safari {
            return BrowserControllerSelection(kind: .appleScript, reason: "safari is in front")
        }
        if inputs.frontmostApplication == .chromiumBrowser, !inputs.activeExtensionBrowserIsFrontmost {
            if inputs.appleScriptCanDriveFrontmostBrowser {
                return BrowserControllerSelection(kind: .appleScript, reason: "chrome is in front, and the extension is connected in another browser")
            }
            return BrowserControllerSelection(kind: .chromeExtension, reason: "the browser in front has no extension, so the extension's browser does it")
        }
        return BrowserControllerSelection(kind: .chromeExtension, reason: "the chrome extension is connected and can read pages")
    }
}
