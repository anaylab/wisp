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

        /// AppleScript to run `script` in the frontmost tab. The two browsers
        /// spell this differently and neither accepts the other's phrasing.
        func evaluationScript(javaScript: String) -> String {
            let escaped = javaScript
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: " ")
            switch self {
            case .chrome:
                return "tell application \"Google Chrome\" to execute javascript \"\(escaped)\" in active tab of window 1"
            case .safari:
                return "tell application \"Safari\" to do JavaScript \"\(escaped)\" in current tab of window 1"
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
        // working, and saying so is far more useful than "unavailable".
        for browser in running {
            if runJavaScript("1", in: browser) != nil {
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
        if let activeBrowser { return activeBrowser }
        let availability = checkAvailability()
        guard let activeBrowser else { throw BrowserControllerError.unavailable(availability) }
        return activeBrowser
    }

    // MARK: - Navigation

    func openURL(_ url: URL) throws {
        // Deliberately NSWorkspace rather than JavaScript: opening a URL is the
        // one operation that works with no browser preferences enabled at all,
        // and it should keep working when everything else is blocked.
        NSWorkspace.shared.open(url)
    }

    func currentURL() throws -> String {
        let browser = try requireBrowser()
        // Reads a plain AppleScript property, which needs no JavaScript
        // permission, so this stays useful even on a locked-down browser.
        let script: String
        switch browser {
        case .chrome: script = "tell application \"Google Chrome\" to get URL of active tab of window 1"
        case .safari: script = "tell application \"Safari\" to get URL of current tab of window 1"
        }
        guard let result = runAppleScript(script) else {
            throw BrowserControllerError.scriptFailed("Couldn't read the current URL.")
        }
        return result
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
    /// being intrinsically cheap. Raising these limits gives it back.
    static let defaultElementLimit = 25
    static let defaultTextCharacterLimit = 1500

    func snapshot(maximumTextCharacters: Int = defaultTextCharacterLimit) throws -> BrowserPageSnapshot {
        let browser = try requireBrowser()
        guard let json = runJavaScript(Self.snapshotJavaScript(maximumTextCharacters: maximumTextCharacters, elementLimit: Self.defaultElementLimit),
                                       in: browser) else {
            throw BrowserControllerError.scriptFailed("Couldn't read the page.")
        }

        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrowserControllerError.scriptFailed("The page returned something unreadable.")
        }

        let elements: [BrowserElement] = (root["elements"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["id"] as? String,
                  let role = $0["role"] as? String,
                  let label = $0["label"] as? String else { return nil }
            return BrowserElement(
                id: id,
                role: role,
                label: label,
                href: $0["href"] as? String,
                value: $0["value"] as? String
            )
        }

        return BrowserPageSnapshot(
            url: root["url"] as? String ?? "",
            title: root["title"] as? String ?? "",
            headings: root["headings"] as? [String] ?? [],
            elements: elements,
            text: root["text"] as? String ?? ""
        )
    }

    // MARK: - Acting

    func click(elementID: String) throws {
        let browser = try requireBrowser()
        let script = """
        (function(){var e=document.querySelector('[data-wisp-id=\\'\(elementID)\\']');
        if(!e){return 'MISSING';}e.scrollIntoView({block:'center'});e.click();return 'OK';})()
        """
        let result = runJavaScript(script, in: browser)
        if result == "MISSING" { throw BrowserControllerError.elementNotFound(elementID) }
        guard result == "OK" else { throw BrowserControllerError.scriptFailed("Couldn't click \(elementID).") }
    }

    func typeText(_ text: String, intoElementID elementID: String, pressEnter: Bool) throws {
        let browser = try requireBrowser()
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\\\\\")
            .replacingOccurrences(of: "'", with: "\\\\'")
        // Setting .value alone leaves React and friends unaware the field
        // changed, so the events they actually listen for are dispatched too.
        let script = """
        (function(){var e=document.querySelector('[data-wisp-id=\\'\(elementID)\\']');
        if(!e){return 'MISSING';}e.focus();e.value='\(escaped)';
        e.dispatchEvent(new Event('input',{bubbles:true}));
        e.dispatchEvent(new Event('change',{bubbles:true}));
        \(pressEnter ? "e.form&&e.form.requestSubmit?e.form.requestSubmit():e.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',keyCode:13,bubbles:true}));" : "")
        return 'OK';})()
        """
        let result = runJavaScript(script, in: browser)
        if result == "MISSING" { throw BrowserControllerError.elementNotFound(elementID) }
        guard result == "OK" else { throw BrowserControllerError.scriptFailed("Couldn't type into \(elementID).") }
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

    // MARK: - The injected snapshot script

    /// Gathers the whole page in one pass and returns JSON.
    ///
    /// Kept to a single call because AppleScript round trips dominate the cost
    /// of this design; the DOM work itself is negligible beside them.
    private static func snapshotJavaScript(maximumTextCharacters: Int, elementLimit: Int) -> String {
        """
        (function(){
        function vis(e){var r=e.getBoundingClientRect();var s=getComputedStyle(e);
        return r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none'&&r.bottom>0&&r.top<innerHeight*3;}
        function lbl(e){var t=(e.getAttribute('aria-label')||e.innerText||e.value||e.placeholder||e.title||e.name||'').trim();
        return t.replace(/\\s+/g,' ').slice(0,80);}
        var sel='a[href],button,input:not([type=hidden]),select,textarea,[role=button],[role=link],[role=tab],[onclick]';
        var found=document.querySelectorAll(sel);var els=[];var n=0;
        for(var i=0;i<found.length&&els.length<\(elementLimit);i++){var e=found[i];
        if(!vis(e))continue;var label=lbl(e);if(!label)continue;
        var id='e'+(n++);e.setAttribute('data-wisp-id',id);
        var role=e.tagName==='A'?'link':e.tagName==='BUTTON'?'button':
        e.tagName==='INPUT'?(e.type||'textbox'):e.tagName==='SELECT'?'select':
        e.tagName==='TEXTAREA'?'textbox':(e.getAttribute('role')||'control');
        var o={id:id,role:role,label:label};
        if(e.tagName==='A'&&e.href)o.href=e.href.slice(0,200);
        if(e.value&&e.tagName!=='BUTTON')o.value=String(e.value).slice(0,60);
        els.push(o);}
        var hs=[];document.querySelectorAll('h1,h2,h3').forEach(function(h){
        if(hs.length<6&&vis(h)){var t=h.innerText.trim().replace(/\\s+/g,' ');if(t)hs.push(t.slice(0,90));}});
        var main=document.querySelector('main,article,[role=main]')||document.body;
        var txt=(main.innerText||'').replace(/\\n{3,}/g,'\\n\\n').trim().slice(0,\(maximumTextCharacters));
        return JSON.stringify({url:location.href,title:document.title,headings:hs,elements:els,text:txt});
        })()
        """
    }

    // MARK: - AppleScript plumbing

    private func runJavaScript(_ javaScript: String, in browser: SupportedBrowser) -> String? {
        runAppleScript(browser.evaluationScript(javaScript: javaScript))
    }

    private func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            // -1723 is specifically "JavaScript from Apple Events is off",
            // which callers turn into instructions rather than a failure.
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            if code != -1723 {
                print("⚠️ Browser AppleScript failed (\(code)): \(error[NSAppleScript.errorMessage] ?? "")")
            }
            return nil
        }
        return result?.stringValue
    }
}
