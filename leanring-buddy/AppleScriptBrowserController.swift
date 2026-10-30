//
//  AppleScriptBrowserController.swift
//  leanring-buddy
//
//  Drives Chrome or Safari by injecting JavaScript through AppleScript.
//
//  Chosen over the Accessibility API because AX exposes browser web content
//  inconsistently and walking it is slow, and over the Chrome DevTools Protocol
//  because that needs the browser relaunched with a debugging port — which is
//  not something to ask of someone's everyday browser.
//
//  Every operation is one AppleScript round trip carrying one self-contained
//  script that returns JSON. Round trips are the expensive part here, so
//  reading a page is a single call that gathers everything rather than a
//  conversation of small queries.
//
//  The snapshot stamps a data-wisp-id attribute onto each interactive element.
//  That is what makes the rest deterministic: actions address elements by id,
//  so a click lands on the element the model actually meant rather than on
//  whatever now occupies a remembered coordinate.
//

import AppKit
import Foundation

@MainActor
final class AppleScriptBrowserController: BrowserController {
    /// Browsers this can drive, most-preferred first.
    private enum SupportedBrowser: String, CaseIterable {
        case chrome = "Google Chrome"
        case safari = "Safari"

        var bundleIdentifier: String {
            switch self {
            case .chrome: return "com.google.Chrome"
            case .safari: return "com.apple.Safari"
            }
        }

        /// The tab the user is looking at. What every operation targets outside
        /// a browser task, so "read this page" means the page in front of them.
        var usersFrontTabSpecifier: String {
            switch self {
            case .chrome: return "active tab of window 1"
            case .safari: return "current tab of window 1"
            }
        }

        /// AppleScript to run `script` in the tab `tabSpecifier` names. The two
        /// browsers spell this differently and neither accepts the other's
        /// phrasing.
        func evaluationScript(javaScript: String, tabSpecifier: String) -> String {
            let escaped = javaScript
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: " ")
            switch self {
            case .chrome:
                // `execute javascript "..." in active tab of window 1` is the
                // documented form and it fails on current Chrome with -1723,
                // "Access not allowed" — which reads exactly like a permissions
                // refusal and sent this investigation to the Apple Events
                // setting, the profile prefs and TCC before the syntax. Telling
                // the tab and then executing works.
                return "tell application \"Google Chrome\" to tell \(tabSpecifier) to execute javascript \"\(escaped)\""
            case .safari:
                return "tell application \"Safari\" to do JavaScript \"\(escaped)\" in \(tabSpecifier)"
            }
        }

        var enableInstructions: String {
            switch self {
            case .chrome:
                return "Chrome needs one setting turned on before Wisp can read pages: View menu → Developer → Allow JavaScript from Apple Events."
            case .safari:
                return "Safari needs two settings before Wisp can read pages: Settings → Advanced → Show features for web developers, then Develop menu → Allow JavaScript from Apple Events."
            }
        }
    }

    private var activeBrowser: SupportedBrowser?

    var browserName: String { activeBrowser?.rawValue ?? "browser" }

    // MARK: - Wisp's own tab

    /// The tab a browser task works in, so the agent never drives the tab the
    /// user is reading — and the user can keep browsing in their own tabs while
    /// it works, the way Claude's browser agent keeps to its own tab.
    ///
    /// Addressed differently per browser because the browsers expose different
    /// handles. Chrome gives every tab an id that lasts its lifetime, so the tab
    /// can be found again even after it is dragged to another window. Safari
    /// tabs have no id, only a position, and a position shifts when a tab to its
    /// left closes; so Safari's reference is guarded by the window's tab count,
    /// and re-found by its URL whenever that count changes.
    private struct DedicatedTab {
        let browser: SupportedBrowser
        var windowID: Int
        /// Chrome only: the tab's own lifetime id.
        var chromeTabID: Int?
        /// Safari only: the tab's 1-based position in its window.
        var safariTabIndex: Int?
        /// Safari only: how many tabs the window had when the position was
        /// last confirmed. A different count means the position may be stale.
        var safariWindowTabCount: Int?
        /// The page last seen in the tab, which is how a Safari tab whose
        /// position moved is recognised again.
        var lastKnownURL: String?

        var tabSpecifier: String {
            switch browser {
            case .chrome: return "tab id \(chromeTabID ?? 0) of window id \(windowID)"
            case .safari: return "tab \(safariTabIndex ?? 1) of window id \(windowID)"
            }
        }
    }

    private var dedicatedTab: DedicatedTab?
    /// True for the duration of a browser task. Outside one, everything targets
    /// the user's front tab exactly as before.
    private var isDrivingDedicatedTab = false

    /// Set by an action that may have navigated (see `BrowserLoadReadiness`),
    /// consumed by the next `waitUntilLoaded`. `maximumWait` is how long the
    /// outgoing document may keep showing before it is concluded that nothing
    /// navigated.
    private var pendingNavigation: (startedAt: Date, maximumWait: TimeInterval)?

    /// Tags the page that is about to be left; the document that replaces it
    /// won't carry the tag. Returns a value so the call counts as a success.
    private static let tagOutgoingDocumentScript = "window.__wispOutgoingDocument=true;'OK'"
    private static let isOutgoingDocumentShowingScript = "String(window.__wispOutgoingDocument===true)"
    /// Set when the working tab disappears mid-task — almost always because the
    /// user closed it, which is taken as "stop". Every later operation in the
    /// session then fails rather than quietly falling back to the user's tab.
    private var dedicatedTabWasLost = false

    /// Error code the Safari guard raises when the window's tab count changed.
    private static let safariTabCountChangedErrorNumber = 9001

    func beginDedicatedTabSession() async throws -> BrowserTabDescription? {
        let browser = try await requireBrowserLaunchingIfNeeded()

        // What the user had in front of them, read before the switch, so a task
        // about "this page" can still find it.
        let usersPage = readUsersFrontPage(in: browser)

        dedicatedTabWasLost = false
        if let existing = dedicatedTab, existing.browser == browser, relocateDedicatedTab() {
            // A follow-up task continues in the same tab, like a conversation
            // continuing on the same page.
            revealDedicatedTab(activatingBrowser: false)
        } else {
            dedicatedTab = try createDedicatedTab(in: browser)
        }
        isDrivingDedicatedTab = true
        return usersPage
    }

    func endDedicatedTabSession() {
        // The tab is kept, not closed: it holds the result the user asked for,
        // and the next task picks up where this one left off.
        isDrivingDedicatedTab = false
        dedicatedTabWasLost = false
    }

    func revealDedicatedTab() {
        revealDedicatedTab(activatingBrowser: true)
    }

    private func revealDedicatedTab(activatingBrowser: Bool) {
        guard let tab = dedicatedTab else { return }
        let activateLine = activatingBrowser ? "activate" : ""
        let script: String
        switch tab.browser {
        case .chrome:
            // Chrome reports tab ids as text, so a numeric comparison silently
            // never matches; the ids are compared as strings.
            script = """
            tell application "Google Chrome"
            set targetWindow to window id \(tab.windowID)
            set tabPosition to 0
            set tabIDs to (get id of every tab of targetWindow)
            repeat with candidatePosition from 1 to count of tabIDs
            if ((item candidatePosition of tabIDs) as string) is "\(tab.chromeTabID ?? 0)" then set tabPosition to candidatePosition
            end repeat
            if tabPosition > 0 then set active tab index of targetWindow to tabPosition
            set index of targetWindow to 1
            \(activateLine)
            end tell
            """
        case .safari:
            script = """
            tell application "Safari"
            set targetWindow to window id \(tab.windowID)
            set current tab of targetWindow to tab \(tab.safariTabIndex ?? 1) of targetWindow
            set index of targetWindow to 1
            \(activateLine)
            end tell
            """
        }
        _ = runAppleScript(script)
    }

    private func createDedicatedTab(in browser: SupportedBrowser) throws -> DedicatedTab {
        // A new tab at the end of the front window, made current so the user
        // sees the work start. With no window open, one is made first.
        let script: String
        switch browser {
        case .chrome:
            script = """
            tell application "Google Chrome"
            if (count of windows) = 0 then make new window
            set targetWindow to front window
            set newTab to make new tab at end of tabs of targetWindow with properties {URL:"about:blank"}
            return ((id of targetWindow) as string) & "," & ((id of newTab) as string)
            end tell
            """
        case .safari:
            script = """
            tell application "Safari"
            if (count of windows) = 0 then make new document
            set targetWindow to front window
            set newTab to make new tab at end of tabs of targetWindow with properties {URL:"about:blank"}
            set current tab of targetWindow to newTab
            return ((id of targetWindow) as string) & "," & ((count of tabs of targetWindow) as string)
            end tell
            """
        }
        guard let reply = runAppleScript(script) else {
            throw BrowserControllerError.scriptFailed("Couldn't open a tab to work in.")
        }
        let numbers = reply.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 2 else {
            throw BrowserControllerError.scriptFailed("Couldn't open a tab to work in.")
        }

        switch browser {
        case .chrome:
            return DedicatedTab(browser: browser, windowID: numbers[0], chromeTabID: numbers[1],
                                lastKnownURL: "about:blank")
        case .safari:
            // Made at the end of the window, so its position is the tab count.
            return DedicatedTab(browser: browser, windowID: numbers[0],
                                safariTabIndex: numbers[1], safariWindowTabCount: numbers[1],
                                lastKnownURL: "about:blank")
        }
    }

    /// Finds the working tab again after a reference to it failed. Returns false
    /// when it is gone.
    private func relocateDedicatedTab() -> Bool {
        guard var tab = dedicatedTab else { return false }
        switch tab.browser {
        case .chrome:
            // Tab ids survive moving between windows; the window id does not.
            let script = """
            tell application "Google Chrome"
            repeat with candidateWindow in windows
            if exists (tab id \(tab.chromeTabID ?? 0) of candidateWindow) then return (id of candidateWindow) as string
            end repeat
            return "0"
            end tell
            """
            guard let reply = runAppleScript(script), let windowID = Int(reply), windowID != 0 else { return false }
            tab.windowID = windowID

        case .safari:
            // Re-found by the page it was last on, within its own window.
            guard let lastKnownURL = tab.lastKnownURL else { return false }
            let script = """
            tell application "Safari"
            if not (exists window id \(tab.windowID)) then return "0,0"
            set targetWindow to window id \(tab.windowID)
            set tabPosition to 0
            set currentPosition to 0
            repeat with candidateTab in tabs of targetWindow
            set currentPosition to currentPosition + 1
            if tabPosition = 0 and (URL of candidateTab as string) is "\(Self.appleScriptEscaped(lastKnownURL))" then set tabPosition to currentPosition
            end repeat
            return (tabPosition as string) & "," & ((count of tabs of targetWindow) as string)
            end tell
            """
            guard let reply = runAppleScript(script) else { return false }
            let numbers = reply.split(separator: ",").compactMap { Int($0) }
            guard numbers.count == 2, numbers[0] > 0 else { return false }
            tab.safariTabIndex = numbers[0]
            tab.safariWindowTabCount = numbers[1]
        }
        dedicatedTab = tab
        return true
    }

    private func readUsersFrontPage(in browser: SupportedBrowser) -> BrowserTabDescription? {
        let script: String
        switch browser {
        case .chrome:
            script = "tell application \"Google Chrome\" to if (count of windows) > 0 then return (URL of active tab of window 1) & linefeed & (title of active tab of window 1)"
        case .safari:
            script = "tell application \"Safari\" to if (count of windows) > 0 then return (URL of current tab of window 1) & linefeed & (name of current tab of window 1)"
        }
        guard let reply = runAppleScript(script) else { return nil }
        let parts = reply.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let url = parts.first, url.hasPrefix("http") else { return nil }
        return BrowserTabDescription(url: url, title: parts.count > 1 ? parts[1] : "")
    }

    /// Like `requireBrowser`, but starts an installed browser that isn't
    /// running rather than giving up — a task should not fail just because
    /// Chrome was closed.
    private func requireBrowserLaunchingIfNeeded() async throws -> SupportedBrowser {
        if case .notRunning = checkAvailability(),
           let installed = SupportedBrowser.allCases.first(where: isInstalled),
           let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: installed.bundleIdentifier) {
            _ = try? await NSWorkspace.shared.openApplication(at: applicationURL, configuration: NSWorkspace.OpenConfiguration())
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline, !checkAvailability().isReady {
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        return try requireBrowser()
    }

    // MARK: - Tab commands

    /// Carries out a browser-chrome command — new tab, close tab, back… — in the
    /// browser the user is using.
    ///
    /// Plain AppleScript, no JavaScript, so these work even before "Allow
    /// JavaScript from Apple Events" is turned on. The target is the frontmost
    /// supported browser if there is one, since that is the browser the user
    /// means; otherwise a running one; otherwise an installed one, launched.
    func performTabCommand(_ command: BrowserTabCommand) async throws {
        let browser = try await browserForTabCommand()
        let script: String
        switch (browser, command) {
        case (.chrome, .newTab):
            script = """
            tell application "Google Chrome"
            activate
            if (count of windows) = 0 then
            make new window
            else
            make new tab at end of tabs of front window
            end if
            end tell
            """
        case (.safari, .newTab):
            script = """
            tell application "Safari"
            activate
            if (count of windows) = 0 then
            make new document
            else
            set current tab of front window to (make new tab at end of tabs of front window)
            end if
            end tell
            """
        case (.chrome, .newWindow):
            script = "tell application \"Google Chrome\"\nactivate\nmake new window\nend tell"
        case (.safari, .newWindow):
            script = "tell application \"Safari\"\nactivate\nmake new document\nend tell"
        case (.chrome, .closeTab):
            script = "tell application \"Google Chrome\" to if (count of windows) > 0 then close active tab of front window"
        case (.safari, .closeTab):
            script = "tell application \"Safari\" to if (count of windows) > 0 then close current tab of front window"
        case (.chrome, .reload):
            script = "tell application \"Google Chrome\" to tell active tab of front window to reload"
        case (.safari, .reload):
            // Re-setting the URL reloads without needing JavaScript permission.
            script = "tell application \"Safari\" to tell current tab of front window to set URL to (get URL)"
        case (.chrome, .back):
            script = "tell application \"Google Chrome\" to tell active tab of front window to go back"
        case (.chrome, .forward):
            script = "tell application \"Google Chrome\" to tell active tab of front window to go forward"
        case (.safari, .back):
            script = "tell application \"Safari\" to do JavaScript \"history.back()\" in current tab of front window"
        case (.safari, .forward):
            script = "tell application \"Safari\" to do JavaScript \"history.forward()\" in current tab of front window"
        }

        if case .failure(let errorNumber) = runAppleScriptReportingError(script) {
            if errorNumber == -1723 || errorNumber == 8 {
                throw BrowserControllerError.unavailable(.javaScriptFromAppleEventsDisabled(
                    browserName: browser.rawValue, instructions: browser.enableInstructions
                ))
            }
            throw BrowserControllerError.scriptFailed("\(browser.rawValue) didn't do that.")
        }
    }

    private func browserForTabCommand() async throws -> SupportedBrowser {
        if let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           let frontmostBrowser = SupportedBrowser.allCases.first(where: { $0.bundleIdentifier == frontmostBundleIdentifier }) {
            return frontmostBrowser
        }
        if let runningBrowser = SupportedBrowser.allCases.first(where: isRunning) {
            return runningBrowser
        }
        guard let installedBrowser = SupportedBrowser.allCases.first(where: isInstalled),
              let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: installedBrowser.bundleIdentifier) else {
            throw BrowserControllerError.unavailable(.noSupportedBrowser)
        }
        _ = try? await NSWorkspace.shared.openApplication(at: applicationURL, configuration: NSWorkspace.OpenConfiguration())
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, !isRunning(installedBrowser) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        return installedBrowser
    }

    // MARK: - Availability

    func checkAvailability() -> BrowserAvailability {
        let running = SupportedBrowser.allCases.filter { isRunning($0) }
        guard !running.isEmpty else {
            let installed = SupportedBrowser.allCases.filter { isInstalled($0) }
            if let first = installed.first { return .notRunning(browserName: first.rawValue) }
            return .noSupportedBrowser
        }

        // A browser that is running but cannot evaluate JavaScript is the
        // common case, and worth distinguishing: it is one checkbox away from
        // working, and saying so is far more useful than "unavailable". Probed
        // in the user's front tab: it answers the permission question without
        // depending on Wisp's own tab existing yet.
        for browser in running {
            let probe = browser.evaluationScript(javaScript: "1", tabSpecifier: browser.usersFrontTabSpecifier)
            if runAppleScript(probe) != nil {
                activeBrowser = browser
                return .ready(browserName: browser.rawValue)
            }
        }

        let blocked = running[0]
        activeBrowser = nil
        return .javaScriptFromAppleEventsDisabled(
            browserName: blocked.rawValue,
            instructions: blocked.enableInstructions
        )
    }

    private func isRunning(_ browser: SupportedBrowser) -> Bool {
        NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == browser.bundleIdentifier }
    }

    private func isInstalled(_ browser: SupportedBrowser) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) != nil
    }

    private func requireBrowser() throws -> SupportedBrowser {
        if isDrivingDedicatedTab {
            if dedicatedTabWasLost { throw BrowserControllerError.dedicatedTabClosed }
            // Mid-task, the browser is the one the working tab lives in, even if
            // the user has since brought another browser forward.
            if let dedicatedTab { return dedicatedTab.browser }
        }
        if let activeBrowser { return activeBrowser }
        let availability = checkAvailability()
        guard let activeBrowser else { throw BrowserControllerError.unavailable(availability) }
        return activeBrowser
    }

    // MARK: - Navigation

    func openURL(_ url: URL) throws {
        // Inside a task, "open" means this task's tab: a URL opened any other
        // way lands in a new tab the rest of the task would never look at.
        if isDrivingDedicatedTab {
            try navigate(to: url)
            return
        }
        // Deliberately NSWorkspace rather than JavaScript: opening a URL is the
        // one operation that works with no browser preferences enabled at all,
        // and it should keep working when everything else is blocked.
        NSWorkspace.shared.open(url)
    }

    func currentURL() throws -> String {
        let browser = try requireBrowser()
        // Reads a plain AppleScript property, which needs no JavaScript
        // permission, so this stays useful even on a locked-down browser.
        let result = runInTargetTab(of: browser) { tabSpecifier in
            "tell application \"\(browser.rawValue)\" to get URL of \(tabSpecifier)"
        }
        guard let result else {
            throw lostTabErrorOr(.scriptFailed("Couldn't read the current URL."))
        }
        return result
    }

    func navigate(to url: URL) throws {
        let browser = try requireBrowser()
        // Tag the page being left so the wait that follows can tell the new
        // document from the old one (which also reads "complete").
        let didTagOutgoingDocument = runJavaScript(Self.tagOutgoingDocumentScript, in: browser) == "OK"
        let escapedURL = Self.appleScriptEscaped(url.absoluteString)
        let result = runInTargetTab(of: browser) { tabSpecifier in
            // `get URL` afterwards gives the command a string result, which is
            // how success is told apart from failure here.
            "tell application \"\(browser.rawValue)\"\nset URL of \(tabSpecifier) to \"\(escapedURL)\"\nreturn \"OK\"\nend tell"
        }
        guard result != nil else {
            throw lostTabErrorOr(.scriptFailed("Couldn't navigate to \(url.absoluteString)."))
        }
        dedicatedTab?.lastKnownURL = url.absoluteString
        // Only worth waiting for a replacement if the old page could be tagged;
        // an unscriptable page (blank tab) already reports "not ready" itself.
        pendingNavigation = didTagOutgoingDocument ? (Date(), .infinity) : nil
    }

    func goBack() throws { try navigateHistory(delta: -1) }
    func goForward() throws { try navigateHistory(delta: 1) }

    /// History movement via JavaScript rather than Chrome's `go back` command.
    ///
    /// Chrome and Safari spell their native history commands differently and
    /// Safari's is unreliable from AppleScript; history.go works identically in
    /// both and is already on the path this class depends on.
    private func navigateHistory(delta: Int) throws {
        let browser = try requireBrowser()
        guard runJavaScript("(function(){history.go(\(delta));return 'OK';})()", in: browser) == "OK" else {
            throw lostTabErrorOr(.scriptFailed(delta < 0 ? "Couldn't go back." : "Couldn't go forward."))
        }
    }

    func pageTitle() throws -> String {
        let browser = try requireBrowser()
        // A plain property, so this keeps working with JavaScript disabled.
        let titleProperty = browser == .chrome ? "title" : "name"
        let title = runInTargetTab(of: browser) { tabSpecifier in
            "tell application \"\(browser.rawValue)\" to get \(titleProperty) of \(tabSpecifier)"
        }
        guard let title else {
            throw lostTabErrorOr(.scriptFailed("Couldn't read the page title."))
        }
        return title
    }

    // MARK: - Reading the page

    /// How much of the page to include.
    ///
    /// This budget is the whole argument for reading the DOM instead of
    /// screenshotting it, and it is easy to lose by accident. Measured against
    /// qwen2.5-vl here: a 896px screenshot is 1097 tokens and 6.30s of prompt
    /// evaluation. An untrimmed snapshot of a dense page — 60 elements and
    /// 3000 characters — comes to 1828 tokens and 5.67s, which throws almost
    /// the entire advantage away. Trimmed to roughly these limits it lands
    /// near 300 tokens and well under a second.
    ///
    /// Text evaluates at about 320 tokens/sec against roughly 175 for image
    /// tokens, so the win comes from needing far fewer tokens, not from text
    /// being intrinsically cheap. Raising these limits gives it back. The
    /// agentic loop for a cloud model passes larger limits explicitly, because
    /// there the cost is a few hundred cheap tokens, not seconds of local
    /// prompt evaluation.
    static let defaultElementLimit = 25
    static let defaultTextCharacterLimit = 1500

    func snapshot(maximumTextCharacters: Int, elementLimit: Int) throws -> BrowserPageSnapshot {
        let browser = try requireBrowser()
        let snapshotScript = Self.snapshotJavaScript(
            maximumTextCharacters: maximumTextCharacters,
            elementLimit: elementLimit
        )
        guard let json = runJavaScript(snapshotScript, in: browser) else {
            throw lostTabErrorOr(.scriptFailed("Couldn't read the page."))
        }

        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrowserControllerError.scriptFailed("The page returned something unreadable.")
        }

        let elements: [BrowserElement] = (root["elements"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["id"] as? String,
                  let role = $0["role"] as? String,
                  let label = $0["label"] as? String else { return nil }
            let state = $0["state"] as? String
            return BrowserElement(
                id: id,
                role: role,
                label: label,
                href: $0["href"] as? String,
                value: $0["value"] as? String,
                state: (state?.isEmpty ?? true) ? nil : state,
                isSensitiveInput: ($0["sensitive"] as? Bool) ?? false
            )
        }

        var text = root["text"] as? String ?? ""
        // Where the viewport sits in the page, so the agent knows whether
        // scrolling could reveal more — and when it has reached the bottom.
        if let scrollDescription = root["scroll"] as? String, !scrollDescription.isEmpty {
            text = "(\(scrollDescription))\n" + text
        }
        // A modal is the one thing on the page that must be dealt with before
        // anything behind it can be clicked, so it is named outright.
        if let dialogLabel = root["dialog"] as? String, !dialogLabel.isEmpty {
            text = "(a dialog is open: \(dialogLabel) — its elements are listed first)\n" + text
        }

        // Keeps the working tab recognisable: Safari re-finds a tab whose
        // position moved by the page it was last seen on.
        if isDrivingDedicatedTab, let pageURL = root["url"] as? String {
            dedicatedTab?.lastKnownURL = pageURL
        }

        return BrowserPageSnapshot(
            url: root["url"] as? String ?? "",
            title: root["title"] as? String ?? "",
            headings: root["headings"] as? [String] ?? [],
            elements: elements,
            text: text
        )
    }

    // MARK: - Acting

    func click(elementID: String) throws {
        let browser = try requireBrowser()
        let safeElementID = try Self.sanitizedElementID(elementID)
        // A bare element.click() fires only the click event. Many sites — menus,
        // custom dropdowns, anything built on pointer events — listen for
        // pointerdown/mousedown instead and ignore a click that arrives without
        // them, which looks to the agent like a button that does nothing. So the
        // full sequence a real press produces is dispatched, at the element's
        // centre, before the click itself.
        let script = """
        (function(){\(Self.elementLookupJavaScript)
        var e=wispFind('\(safeElementID)');if(!e){return 'MISSING';}
        if(e.disabled||e.getAttribute('aria-disabled')==='true'){return 'DISABLED';}
        e.scrollIntoView({block:'center',inline:'center'});
        var r=e.getBoundingClientRect();var x=r.left+r.width/2;var y=r.top+r.height/2;
        var o={bubbles:true,cancelable:true,composed:true,clientX:x,clientY:y,view:window,button:0,buttons:1,pointerType:'mouse',isPrimary:true};
        function fire(C,n){try{e.dispatchEvent(new C(n,o));}catch(z){}}
        fire(PointerEvent,'pointerover');fire(MouseEvent,'mouseover');
        fire(PointerEvent,'pointerdown');fire(MouseEvent,'mousedown');
        if(e.focus){e.focus();}
        o.buttons=0;fire(PointerEvent,'pointerup');fire(MouseEvent,'mouseup');
        window.__wispOutgoingDocument=true;e.click();return 'OK';})()
        """
        let result = runJavaScript(script, in: browser)
        if result == "MISSING" { throw BrowserControllerError.elementNotFound(elementID) }
        if result == "DISABLED" {
            throw BrowserControllerError.scriptFailed("\(elementID) is disabled right now.")
        }
        guard result == "OK" else { throw BrowserControllerError.scriptFailed("Couldn't click \(elementID).") }
        // A click may follow a link; give the wait that comes next a short
        // window to see the old document replaced (see `BrowserLoadReadiness`).
        pendingNavigation = (Date(), BrowserLoadReadiness.maximumWaitForClickedNavigationSeconds)
    }

    func typeText(_ text: String, intoElementID elementID: String, pressEnter: Bool) throws {
        let browser = try requireBrowser()
        let safeElementID = try Self.sanitizedElementID(elementID)
        let textLiteral = Self.javaScriptStringLiteral(text)
        // Setting .value directly is invisible to React, which tracks the value
        // through the prototype's setter and silently reverts a field changed
        // behind its back. Calling the native setter and then dispatching
        // `input` is the change React (and Vue, and most others) actually sees.
        // Rich-text editors are contenteditable, not inputs, and take text
        // through insertText instead.
        //
        // Password and payment fields are refused here, in the page, as well as
        // by the agent above: the boundary holds even for a caller that forgot.
        let script = """
        (function(){\(Self.elementLookupJavaScript)
        var e=wispFind('\(safeElementID)');if(!e){return 'MISSING';}
        if(wispSensitive(e)){return 'SENSITIVE';}
        var t=\(textLiteral);
        e.scrollIntoView({block:'center'});if(e.focus){e.focus();}
        if(e.isContentEditable){document.execCommand('selectAll',false,null);document.execCommand('insertText',false,t);}
        else{var p=e.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;
        var d=Object.getOwnPropertyDescriptor(p,'value');if(d&&d.set){d.set.call(e,t);}else{e.value=t;}
        try{e.dispatchEvent(new InputEvent('input',{bubbles:true,composed:true,data:t,inputType:'insertText'}));}
        catch(z){e.dispatchEvent(new Event('input',{bubbles:true}));}
        e.dispatchEvent(new Event('change',{bubbles:true}));}
        \(pressEnter ? "window.__wispOutgoingDocument=true;wispKey(e,'Enter',true);" : "")
        return 'OK';})()
        """
        let result = runJavaScript(script, in: browser)
        if result == "MISSING" { throw BrowserControllerError.elementNotFound(elementID) }
        if result == "SENSITIVE" {
            throw BrowserControllerError.scriptFailed("\(elementID) is a password or payment field — only you can fill that in.")
        }
        guard result == "OK" else { throw BrowserControllerError.scriptFailed("Couldn't type into \(elementID).") }
        // Submitting a search form navigates; same reasoning as `click`.
        if pressEnter {
            pendingNavigation = (Date(), BrowserLoadReadiness.maximumWaitForClickedNavigationSeconds)
        }
    }

    func hover(elementID: String) throws {
        let browser = try requireBrowser()
        let safeElementID = try Self.sanitizedElementID(elementID)
        let script = """
        (function(){\(Self.elementLookupJavaScript)
        var e=wispFind('\(safeElementID)');if(!e){return 'MISSING';}
        e.scrollIntoView({block:'center'});var r=e.getBoundingClientRect();
        var o={bubbles:true,cancelable:true,composed:true,clientX:r.left+r.width/2,clientY:r.top+r.height/2,view:window,pointerType:'mouse'};
        ['pointerover','pointerenter','mouseover','mouseenter','pointermove','mousemove'].forEach(function(n){
        try{e.dispatchEvent(n.indexOf('pointer')===0?new PointerEvent(n,o):new MouseEvent(n,o));}catch(z){}});
        return 'OK';})()
        """
        let result = runJavaScript(script, in: browser)
        if result == "MISSING" { throw BrowserControllerError.elementNotFound(elementID) }
        guard result == "OK" else { throw BrowserControllerError.scriptFailed("Couldn't hover over \(elementID).") }
    }

    /// Keys the agent may press. A fixed list, so a model cannot smuggle an
    /// arbitrary string into the injected script through a key name.
    static let supportedKeyNames: Set<String> = [
        "Enter", "Escape", "Tab", "Backspace", "Delete", "Space",
        "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "PageUp", "PageDown", "Home", "End"
    ]

    func pressKey(_ keyName: String) throws {
        let browser = try requireBrowser()
        guard let canonicalKeyName = Self.supportedKeyNames.first(where: {
            $0.lowercased() == keyName.lowercased().replacingOccurrences(of: " ", with: "")
        }) else {
            throw BrowserControllerError.scriptFailed(
                "Can't press \"\(keyName)\". Supported: \(Self.supportedKeyNames.sorted().joined(separator: ", "))."
            )
        }
        let script = """
        (function(){\(Self.elementLookupJavaScript)
        var e=document.activeElement||document.body;
        while(e&&e.shadowRoot&&e.shadowRoot.activeElement){e=e.shadowRoot.activeElement;}
        wispKey(e,'\(canonicalKeyName)',\(canonicalKeyName == "Enter" ? "true" : "false"));return 'OK';})()
        """
        guard runJavaScript(script, in: browser) == "OK" else {
            throw BrowserControllerError.scriptFailed("Couldn't press \(canonicalKeyName).")
        }
    }

    func screenPoint(ofElementID elementID: String) throws -> (point: CGPoint, displayFrame: CGRect)? {
        let browser = try requireBrowser()
        guard let safeElementID = try? Self.sanitizedElementID(elementID) else { return nil }
        // Compute the element's centre in the browser's own screen coordinates:
        // getBoundingClientRect is viewport-relative, window.screenX/screenY are
        // the window's top-left on the desktop, and the chrome height is the
        // difference between the outer and inner window. All are CSS pixels,
        // which map 1:1 to points on macOS. scrollIntoView first so an element
        // just off the viewport can still be pointed at.
        let script = """
        (function(){\(Self.elementLookupJavaScript)
        var e=wispFind('\(safeElementID)');
        if(!e||document.visibilityState!=='visible'){return 'MISSING';}e.scrollIntoView({block:'center'});
        var r=e.getBoundingClientRect();
        var cx=window.screenX+(window.outerWidth-window.innerWidth)/2+r.left+r.width/2;
        var cy=window.screenY+(window.outerHeight-window.innerHeight)+r.top+r.height/2;
        return Math.round(cx)+','+Math.round(cy);})()
        """
        guard let result = runJavaScript(script, in: browser), result != "MISSING" else { return nil }
        let parts = result.split(separator: ",")
        guard parts.count == 2,
              let topLeftOriginX = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let topLeftOriginY = Double(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }

        // The browser reports a top-left origin anchored at the primary display;
        // AppKit's global space is bottom-left origin anchored the same way, so
        // only y flips, about the primary display's height.
        let primaryDisplayHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
        guard let primaryDisplayHeight else { return nil }

        let appKitPoint = CGPoint(x: topLeftOriginX, y: primaryDisplayHeight - topLeftOriginY)
        let display = NSScreen.screens.first(where: { $0.frame.contains(appKitPoint) }) ?? NSScreen.main
        guard let display else { return nil }
        return (appKitPoint, display.frame)
    }

    func scroll(_ direction: BrowserScrollDirection) throws {
        let browser = try requireBrowser()
        let body: String
        switch direction {
        case .down:   body = "window.scrollBy(0, window.innerHeight*0.85)"
        case .up:     body = "window.scrollBy(0, -window.innerHeight*0.85)"
        case .top:    body = "window.scrollTo(0, 0)"
        case .bottom: body = "window.scrollTo(0, document.body.scrollHeight)"
        }
        guard runJavaScript("(function(){\(body);return 'OK';})()", in: browser) == "OK" else {
            throw BrowserControllerError.scriptFailed("Couldn't scroll.")
        }
    }

    /// Ranks the page's elements against a query.
    ///
    /// Deliberately done in Swift over a fresh snapshot rather than in the
    /// page: the snapshot already stamps ids, and matching here means the
    /// ranking is testable without a browser attached.
    func findElements(matching query: String) throws -> [BrowserElement] {
        let normalizedQuery = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !normalizedQuery.isEmpty else { return [] }

        let elements = try snapshot().elements

        func score(_ element: BrowserElement) -> Int {
            let label = element.label.lowercased()
            if label == normalizedQuery { return 4 }
            if label.hasPrefix(normalizedQuery) { return 3 }
            if label.contains(normalizedQuery) { return 2 }
            // Every query word present somewhere, in any order.
            let words = normalizedQuery.split(separator: " ")
            if words.count > 1, words.allSatisfy({ label.contains($0) }) { return 1 }
            return 0
        }

        return elements
            .map { (element: $0, score: score($0)) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .map(\.element)
    }

    func selectOption(_ optionLabel: String, inElementID elementID: String) throws {
        let browser = try requireBrowser()
        let safeElementID = try Self.sanitizedElementID(elementID)
        let optionLiteral = Self.javaScriptStringLiteral(optionLabel.lowercased())
        // Matches on visible text, which is what a person names, then fires
        // change so frameworks bound to the select actually notice.
        let script = """
        (function(){\(Self.elementLookupJavaScript)
        var e=wispFind('\(safeElementID)');
        if(!e){return 'MISSING';}if(!e.options){return 'NOTSELECT';}var t=\(optionLiteral);var hit=null;
        for(var i=0;i<e.options.length;i++){var o=e.options[i];
        if(o.text.toLowerCase().indexOf(t)>=0||o.value.toLowerCase()===t){hit=o;break;}}
        if(!hit){return 'NOOPTION';}
        var d=Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype,'value');
        if(d&&d.set){d.set.call(e,hit.value);}else{e.value=hit.value;}
        e.dispatchEvent(new Event('input',{bubbles:true}));
        e.dispatchEvent(new Event('change',{bubbles:true}));return 'OK';})()
        """
        let result = runJavaScript(script, in: browser)
        if result == "MISSING" { throw BrowserControllerError.elementNotFound(elementID) }
        if result == "NOTSELECT" {
            throw BrowserControllerError.scriptFailed("\(elementID) isn't a dropdown — click it to open it instead.")
        }
        if result == "NOOPTION" {
            throw BrowserControllerError.scriptFailed("No option matching \"\(optionLabel)\".")
        }
        guard result == "OK" else {
            throw BrowserControllerError.scriptFailed("Couldn't select \"\(optionLabel)\".")
        }
    }

    func waitUntilLoaded(timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        // Taken once: a later wait belongs to a later action.
        let navigation = pendingNavigation
        pendingNavigation = nil
        while Date() < deadline {
            // readyState is the browser's own answer, so this waits exactly as
            // long as the page needs rather than a guessed constant. Right
            // after a navigation it is also the *outgoing* page's answer, so
            // the tag left on that page is checked too.
            if let browser = try? requireBrowser() {
                let readyState = runJavaScript("document.readyState", in: browser)
                let outgoingDocumentStillShowing = navigation != nil
                    && runJavaScript(Self.isOutgoingDocumentShowingScript, in: browser) == "true"
                if BrowserLoadReadiness.isLoaded(
                    readyState: readyState,
                    outgoingDocumentStillShowing: outgoingDocumentStillShowing,
                    expectsNavigation: navigation != nil,
                    secondsWaitedForReplacement: navigation.map { Date().timeIntervalSince($0.startedAt) } ?? 0,
                    maximumWaitForReplacementSeconds: navigation?.maximumWait ?? 0
                ) {
                    return true
                }
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
        return false
    }

    /// How long the DOM must go without structural change to count as settled.
    private static let quietPeriodMilliseconds = 400
    /// Most time spent waiting for quiet once the page has loaded. A page with a
    /// ticker or a carousel never goes quiet, and must not cost every step
    /// the whole timeout.
    private static let maximumQuietWaitSeconds: TimeInterval = 3

    func waitUntilSettled(timeout: TimeInterval = 8) async -> Bool {
        let startedAt = Date()
        guard await waitUntilLoaded(timeout: timeout) else { return false }
        guard let browser = try? requireBrowser() else { return false }

        let remainingTime = timeout - Date().timeIntervalSince(startedAt)
        let quietDeadline = Date().addingTimeInterval(max(0, min(remainingTime, Self.maximumQuietWaitSeconds)))

        // Observes child-list and text changes only. Attribute churn (hover
        // styles, animated classes) is constant on modern pages and says nothing
        // about whether the content the agent is waiting for has arrived.
        // Installed once per document; a navigation replaces the window and so
        // installs a fresh one, whose first answer is "just changed".
        let quietProbeScript = """
        (function(){var w=window;if(!w.__wispObserver){w.__wispLastMutation=Date.now();
        w.__wispObserver=new MutationObserver(function(){w.__wispLastMutation=Date.now();});
        w.__wispObserver.observe(document.documentElement,{subtree:true,childList:true,characterData:true});}
        return String(Date.now()-w.__wispLastMutation);})()
        """
        while Date() < quietDeadline {
            if Task.isCancelled { return false }
            if let millisecondsSinceLastMutation = runJavaScript(quietProbeScript, in: browser).flatMap(Int.init),
               millisecondsSinceLastMutation >= Self.quietPeriodMilliseconds {
                return true
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return true
    }

    /// Screenshots the whole screen, not just the page.
    ///
    /// Reuses the app's existing capture path so the 896px cap and the
    /// unchanged-frame reuse both still apply. This exists so vision stays a
    /// deliberate fallback; nothing above calls it.
    func captureScreenshot() async throws -> Data {
        let captures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
        guard let cursorScreen = captures.first(where: { $0.isCursorScreen }) ?? captures.first else {
            throw BrowserControllerError.scriptFailed("Couldn't capture the screen.")
        }
        return cursorScreen.imageData
    }

    // MARK: - Script safety

    /// Element ids come from the model, and are interpolated into injected
    /// JavaScript. Only the shape the snapshot itself produces is accepted, so
    /// an id can never close the string it sits in.
    private static func sanitizedElementID(_ elementID: String) throws -> String {
        let trimmed = elementID.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !trimmed.isEmpty, trimmed.count <= 12,
              trimmed.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) }) else {
            throw BrowserControllerError.elementNotFound(elementID)
        }
        return trimmed
    }

    /// Any string as a JavaScript string literal, quotes included. JSON's string
    /// grammar is a subset of JavaScript's, so the encoder does the escaping.
    private static func javaScriptStringLiteral(_ text: String) -> String {
        guard let data = try? JSONEncoder().encode([text]),
              let encodedArray = String(data: data, encoding: .utf8) else { return "''" }
        return String(encodedArray.dropFirst().dropLast())
    }

    // MARK: - The injected scripts

    /// Shared helpers every action script starts with.
    ///
    /// `wispFind` resolves an id through the registry the snapshot keeps on the
    /// window — which reaches elements inside shadow roots and same-origin
    /// frames, where a document-level querySelector cannot — and falls back to
    /// the stamped attribute. `wispSensitive` recognises password and payment
    /// fields. `wispKey` dispatches a key the way a real one arrives, and for
    /// Enter submits the enclosing form when no handler claimed the key.
    ///
    /// No `//` comments and no reliance on newlines: the evaluation script
    /// flattens newlines to spaces.
    private static let elementLookupJavaScript = """
    function wispFind(id){var m=window.__wispElements;var e=m&&m[id];if(e&&e.isConnected){return e;}
    return document.querySelector('[data-wisp-id="'+id+'"]');}
    function wispSensitive(e){var t=(e.type||'').toLowerCase();if(t==='password'){return true;}
    var a=(e.getAttribute('autocomplete')||'').toLowerCase();if(a.indexOf('cc-')===0||a.indexOf('password')>=0){return true;}
    var h=((e.name||'')+' '+(e.id||'')+' '+(e.placeholder||'')+' '+(e.getAttribute('aria-label')||'')).toLowerCase();
    return /card.?num|cardnumber|cvc|cvv|security.?code|expir/.test(h);}
    function wispKey(e,k,submit){var codes={Enter:13,Escape:27,Tab:9,Backspace:8,Delete:46,Space:32,ArrowUp:38,ArrowDown:40,ArrowLeft:37,ArrowRight:39,PageUp:33,PageDown:34,Home:36,End:35};
    var key=k==='Space'?' ':k;var o={key:key,code:k,keyCode:codes[k]||0,which:codes[k]||0,bubbles:true,cancelable:true,composed:true};
    var go=e.dispatchEvent(new KeyboardEvent('keydown',o));
    if(k==='Enter'){e.dispatchEvent(new KeyboardEvent('keypress',o));}
    e.dispatchEvent(new KeyboardEvent('keyup',o));
    if(submit&&go&&e.form){if(e.form.requestSubmit){e.form.requestSubmit();}else{e.form.submit();}}}
    """

    /// Gathers the whole page in one pass and returns JSON.
    ///
    /// Kept to a single call because AppleScript round trips dominate the cost
    /// of this design; the DOM work itself is negligible beside them.
    ///
    /// Three things make this usable for a many-step agent rather than a single
    /// read. Ids are *stable*: an element keeps the id it was given in an
    /// earlier snapshot, so "click e12" still means the same button after the
    /// page re-renders around it. Order is by *relevance*: an open dialog first,
    /// then what is in the viewport, then what is below it, so a tight element
    /// budget is spent on what the user can see. And the walk reaches *shadow
    /// roots and same-origin iframes*, where a lot of modern UI actually lives.
    private static func snapshotJavaScript(maximumTextCharacters: Int, elementLimit: Int) -> String {
        """
        (function(){\(elementLookupJavaScript)
        var w=window;if(!w.__wispElements){w.__wispElements={};}if(!w.__wispNextID){w.__wispNextID=0;}
        var reg=w.__wispElements;for(var k in reg){if(!reg[k].isConnected){delete reg[k];}}
        function clean(t){return (t||'').replace(/\\s+/g,' ').trim();}
        function vis(e){var r=e.getBoundingClientRect();if(r.width<=0||r.height<=0){return false;}
        var s=getComputedStyle(e);return s.visibility!=='hidden'&&s.display!=='none'&&s.opacity!=='0';}
        function inView(e){var r=e.getBoundingClientRect();return r.bottom>0&&r.top<innerHeight&&r.right>0&&r.left<innerWidth;}
        function nearView(e){var r=e.getBoundingClientRect();return r.bottom>-innerHeight&&r.top<innerHeight*3;}
        function lbl(e){var a=clean(e.getAttribute('aria-label'));if(a){return a;}
        var lb=e.getAttribute('aria-labelledby');if(lb){var s=lb.split(' ').map(function(i){var n=e.ownerDocument.getElementById(i);return n?n.innerText:'';}).join(' ');if(clean(s)){return clean(s);}}
        if(e.labels&&e.labels.length){var l=clean(e.labels[0].innerText);if(l){return l;}}
        var t=clean(e.innerText);if(t){return t;}
        var img=e.querySelector&&e.querySelector('img[alt]');if(img&&clean(img.alt)){return clean(img.alt);}
        var b=(e.tagName==='INPUT'&&/^(submit|button|reset)$/i.test(e.type))?e.value:'';
        return clean(e.placeholder||e.title||e.alt||b||e.name||'');}
        function role(e){var r=e.getAttribute('role');if(r){return r;}var t=e.tagName;
        if(t==='A'){return 'link';}if(t==='BUTTON'||t==='SUMMARY'){return 'button';}if(t==='SELECT'){return 'select';}
        if(t==='TEXTAREA'||e.isContentEditable){return 'textbox';}
        if(t==='INPUT'){var ty=(e.type||'text').toLowerCase();if(/^(submit|button|reset|image)$/.test(ty)){return 'button';}
        if(/^(text|email|search|url|tel|number|password)$/.test(ty)){return ty==='text'?'textbox':'textbox:'+ty;}return ty;}
        return 'control';}
        function st(e){var s=[];if(e.disabled||e.getAttribute('aria-disabled')==='true'){s.push('disabled');}
        if(e.checked||e.getAttribute('aria-checked')==='true'){s.push('checked');}
        var x=e.getAttribute('aria-expanded');if(x){s.push(x==='true'?'expanded':'collapsed');}
        if(e.getAttribute('aria-selected')==='true'||(e.getAttribute('aria-current')&&e.getAttribute('aria-current')!=='false')){s.push('selected');}
        if(e.required){s.push('required');}
        var f=document.activeElement;if(f===e){s.push('focused');}return s.join(',');}
        var sel='a[href],button,input:not([type=hidden]),select,textarea,summary,[role=button],[role=link],[role=tab],[role=menuitem],[role=menuitemcheckbox],[role=option],[role=checkbox],[role=radio],[role=switch],[role=combobox],[role=textbox],[role=searchbox],[role=slider],[contenteditable=""],[contenteditable=true],[onclick]';
        var found=[];
        function collect(root,depth){if(depth>4){return;}root.querySelectorAll(sel).forEach(function(e){found.push(e);});
        root.querySelectorAll('*').forEach(function(n){if(n.shadowRoot){collect(n.shadowRoot,depth+1);}
        if(n.tagName==='IFRAME'){try{var d=n.contentDocument;if(d&&d.body){collect(d,depth+1);}}catch(z){}}});}
        collect(document,0);
        var dialogs=[].slice.call(document.querySelectorAll('dialog[open],[role=dialog],[role=alertdialog],[aria-modal=true]')).filter(vis);
        var dlg=dialogs.length?dialogs[dialogs.length-1]:null;
        var ranked=[];var seen=new Set();
        found.forEach(function(e,i){if(seen.has(e)){return;}seen.add(e);if(!vis(e)){return;}
        var inDlg=dlg&&dlg.contains(e);if(!inDlg&&!nearView(e)){return;}
        var p=inDlg?0:(inView(e)?1:2);ranked.push({e:e,p:p,i:i});});
        ranked.sort(function(a,b){return a.p-b.p||a.i-b.i;});
        var els=[];
        for(var j=0;j<ranked.length&&els.length<\(elementLimit);j++){var e=ranked[j].e;var label=lbl(e).slice(0,90);
        var ro=role(e);if(!label&&ro.indexOf('textbox')<0&&ro!=='select'&&ro!=='combobox'){continue;}
        var id=e.getAttribute('data-wisp-id');if(!id||reg[id]!==e){id='e'+(w.__wispNextID++);e.setAttribute('data-wisp-id',id);}
        reg[id]=e;var o={id:id,role:ro,label:label||'(unlabelled)'};var s=st(e);if(s){o.state=s;}
        if(wispSensitive(e)){o.sensitive=true;}
        if(e.tagName==='A'&&e.href){o.href=e.href.slice(0,160);}
        if(!o.sensitive&&e.value&&e.tagName!=='BUTTON'&&typeof e.value==='string'){o.value=e.value.slice(0,60);}
        if(e.tagName==='SELECT'&&e.selectedOptions&&e.selectedOptions[0]){o.value=clean(e.selectedOptions[0].text).slice(0,60);}
        els.push(o);}
        var hs=[];document.querySelectorAll('h1,h2,h3').forEach(function(h){
        if(hs.length<6&&vis(h)){var t=clean(h.innerText);if(t){hs.push(t.slice(0,90));}}});
        var main=dlg||document.querySelector('main,article,[role=main]')||document.body;
        var txt=(main.innerText||'').replace(/\\n{3,}/g,'\\n\\n').trim().slice(0,\(maximumTextCharacters));
        var sh=Math.max(document.documentElement.scrollHeight-innerHeight,0);
        var scroll=sh<=4?'the whole page fits on screen':('scrolled '+Math.round(100*scrollY/sh)+'% down the page');
        return JSON.stringify({url:location.href,title:document.title,headings:hs,elements:els,text:txt,scroll:scroll,dialog:dlg?clean(dlg.getAttribute('aria-label')||(dlg.querySelector('h1,h2,h3')||{}).innerText||'untitled').slice(0,80):''});
        })()
        """
    }

    // MARK: - AppleScript plumbing

    private func runJavaScript(_ javaScript: String, in browser: SupportedBrowser) -> String? {
        runInTargetTab(of: browser) { tabSpecifier in
            browser.evaluationScript(javaScript: javaScript, tabSpecifier: tabSpecifier)
        }
    }

    /// Runs a command against the tab operations should currently target: the
    /// user's front tab normally, Wisp's own tab during a task.
    ///
    /// `makeCommand` is given the tab's AppleScript specifier. During a task,
    /// a reference that fails is re-found once — the tab may have moved window
    /// (Chrome) or position (Safari) — and a tab that cannot be re-found marks
    /// the session lost, so nothing ever falls back to acting in the user's tab.
    private func runInTargetTab(of browser: SupportedBrowser, makeCommand: (String) -> String) -> String? {
        guard isDrivingDedicatedTab, dedicatedTab?.browser == browser else {
            return runAppleScript(makeCommand(browser.usersFrontTabSpecifier))
        }

        for attempt in 0..<2 {
            guard let tab = dedicatedTab, !dedicatedTabWasLost else { return nil }
            var source = makeCommand(tab.tabSpecifier)
            if tab.browser == .safari, let expectedTabCount = tab.safariWindowTabCount {
                // Safari addresses the tab by position, so first make sure no tab
                // has been opened or closed in that window since the position was
                // confirmed — otherwise this would act in whichever tab slid into
                // the working tab's place.
                source = """
                tell application "Safari"
                if (count of tabs of window id \(tab.windowID)) is not \(expectedTabCount) then error "tab positions changed" number \(Self.safariTabCountChangedErrorNumber)
                end tell
                """ + "\n" + source
            }

            switch runAppleScriptReportingError(source) {
            case .success(let result):
                return result
            case .failure(let errorNumber):
                // -1723 is the browser refusing JavaScript: a setting, not a
                // missing tab, so there is nothing to re-find.
                guard attempt == 0, errorNumber != -1723 else { return nil }
                if !relocateDedicatedTab() {
                    dedicatedTabWasLost = true
                    return nil
                }
            }
        }
        return nil
    }

    /// The error to throw when an operation failed: the lost-tab error if that
    /// is why, so the agent stops instead of retrying against a tab that is gone.
    private func lostTabErrorOr(_ fallback: BrowserControllerError) -> BrowserControllerError {
        (isDrivingDedicatedTab && dedicatedTabWasLost) ? .dedicatedTabClosed : fallback
    }

    private static func appleScriptEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func runAppleScript(_ source: String) -> String? {
        if case .success(let result) = runAppleScriptReportingError(source) { return result }
        return nil
    }

    private enum AppleScriptOutcome {
        case success(String?)
        case failure(errorNumber: Int)
    }

    private func runAppleScriptReportingError(_ source: String) -> AppleScriptOutcome {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            // -1723 is specifically "JavaScript from Apple Events is off",
            // which callers turn into instructions rather than a failure.
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            if code != -1723 {
                print("⚠️ Browser AppleScript failed (\(code)): \(error[NSAppleScript.errorMessage] ?? "")")
            }
            return .failure(errorNumber: code)
        }
        return .success(result?.stringValue)
    }
}
