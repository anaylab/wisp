//
//  ChromePageReader.swift
//  leanring-buddy
//
//  Reads a Chrome tab's text, selection or headings through the Wisp Tabs
//  extension (phase 02, `getPageText` / `getSelection` / `getPageOutline`).
//
//  The extension does the reading in the page (content/read-page.js) and
//  refuses pages it must never read (chrome://, the Web Store, incognito…).
//  This side checks the `pages.read` capability first, so a missing permission
//  becomes a sentence about where to allow it instead of a round trip that
//  fails, and turns the extension's errors into Wisp's voice.
//

import Foundation

@MainActor
enum ChromePageReader {

    enum ReaderError: LocalizedError, Equatable {
        case extensionNotConnected
        case pagesReadNotAllowed
        case couldNotRead(String)

        var errorDescription: String? {
            switch self {
            case .extensionNotConnected:
                return "the wisp tabs chrome extension isn't connected. install it from the chrome-extension folder (chrome://extensions → load unpacked) and make sure chrome is open."
            case .pagesReadNotAllowed:
                return "wisp isn't allowed to read pages in chrome yet. to allow it, open wisp's settings → agent → chrome tabs → \"choose what wisp can do in chrome…\" and click allow next to read pages."
            case .couldNotRead(let reason):
                return "i couldn't read that tab: \(reason)."
            }
        }
    }

    /// A page read inside a voice turn has to be quick: the screenshot is the
    /// fallback, and it is already captured.
    static let turnReadTimeoutSeconds: Double = 4
    /// An agent tool can wait longer; the extension caps everything at 30s.
    static let toolReadTimeoutSeconds: Double = 15

    private struct PageTextParameters: Encodable {
        let tabId: Int?
        let maximumCharacters: Int?
    }

    private struct TabParameters: Encodable {
        let tabId: Int?
    }

    /// The tab's main text, metadata and word count. `tabID` nil reads the tab
    /// showing in the Chrome window the user was last in.
    static func readPage(
        tabID: Int?,
        maximumCharacters: Int? = nil,
        timeoutSeconds: Double = toolReadTimeoutSeconds
    ) async throws -> ChromePageText {
        try requirePageReading()
        return try await sendReadRequest(
            method: "getPageText",
            parameters: PageTextParameters(tabId: tabID, maximumCharacters: maximumCharacters),
            resultType: ChromePageText.self,
            timeoutSeconds: timeoutSeconds
        )
    }

    /// What the user selected in the tab, with ~300 characters of context.
    static func readSelection(tabID: Int?, timeoutSeconds: Double = toolReadTimeoutSeconds) async throws -> ChromePageSelection {
        try requirePageReading()
        return try await sendReadRequest(
            method: "getSelection",
            parameters: TabParameters(tabId: tabID),
            resultType: ChromePageSelection.self,
            timeoutSeconds: timeoutSeconds
        )
    }

    /// The tab's headings, in order, with their levels.
    static func readOutline(tabID: Int?, timeoutSeconds: Double = toolReadTimeoutSeconds) async throws -> ChromePageOutline {
        try requirePageReading()
        return try await sendReadRequest(
            method: "getPageOutline",
            parameters: TabParameters(tabId: tabID),
            resultType: ChromePageOutline.self,
            timeoutSeconds: timeoutSeconds
        )
    }

    /// Whether a read could be attempted at all right now.
    static var canReadPages: Bool {
        let bridge = ChromeExtensionBridge.shared
        return bridge.isExtensionConnected && bridge.hasCapability(.pagesRead)
    }

    /// Whether the connected extension lives in the browser with this bundle
    /// identifier. Only Chrome today (phase 13 widens it to other Chromium
    /// browsers): reading Edge's tab while the user looks at Chrome would
    /// answer about the wrong page.
    static func isConnectedExtension(inBrowserWithBundleIdentifier bundleIdentifier: String) -> Bool {
        guard bundleIdentifier.hasPrefix("com.google.Chrome"),
              case .connected(_, let browserName) = ChromeExtensionBridge.shared.connectionState else { return false }
        return browserName.localizedCaseInsensitiveContains("chrome")
    }

    private static func requirePageReading() throws {
        let bridge = ChromeExtensionBridge.shared
        guard bridge.isExtensionConnected else { throw ReaderError.extensionNotConnected }
        guard bridge.hasCapability(.pagesRead) else { throw ReaderError.pagesReadNotAllowed }
    }

    private static func sendReadRequest<Parameters: Encodable, Result: Decodable>(
        method: String,
        parameters: Parameters,
        resultType: Result.Type,
        timeoutSeconds: Double
    ) async throws -> Result {
        do {
            return try await ChromeExtensionBridge.shared.sendRequest(
                method: method,
                parameters: parameters,
                resultType: resultType,
                timeoutSeconds: timeoutSeconds
            )
        } catch ChromeExtensionBridge.BridgeError.extensionReportedError(let extensionMessage) {
            // The capability list can lag a permission the user just removed.
            if extensionMessage.contains("missing capability pages.read") {
                throw ReaderError.pagesReadNotAllowed
            }
            throw ReaderError.couldNotRead(extensionMessage)
        } catch ChromeExtensionBridge.BridgeError.extensionNotConnected {
            throw ReaderError.extensionNotConnected
        }
    }
}
