//
//  StudyDistractionBlocker.swift
//  leanring-buddy
//
//  Holds distractions back while a focus phase runs. Nothing system-wide and
//  nothing that outlives the session:
//   - a blocked app that comes to the front is hidden at once;
//   - while a browser is frontmost, its active tab is checked every couple of
//     seconds and a blocked site is swapped for a calm "blocked" page (Back
//     returns to it). That needs Automation permission for the browser.
//

import AppKit

@MainActor
final class StudyDistractionBlocker {
    /// Called each time something was held back, with a short line for the UI.
    var onHeldBack: ((String) -> Void)?
    /// Called when the browser refused our Apple Events (Automation permission missing).
    var onBrowserPermissionMissing: ((String) -> Void)?

    private var blocklist = StudyBlocklist()
    private var activationObserver: NSObjectProtocol?
    private var tabCheckTimer: Timer?
    private var isCheckingTab = false
    private var browsersWithoutPermission: Set<String> = []

    private static let browsers: [(bundleIdentifier: String, appleScriptName: String, isSafari: Bool)] = [
        ("com.google.Chrome", "Google Chrome", false),
        ("com.apple.Safari", "Safari", true),
        ("com.brave.Browser", "Brave Browser", false),
        ("com.microsoft.edgemac", "Microsoft Edge", false),
        ("company.thebrowser.Browser", "Arc", false),
    ]

    var isActive: Bool { activationObserver != nil }

    func start(blocklist: StudyBlocklist) {
        stop()
        self.blocklist = blocklist
        browsersWithoutPermission = []
        guard !blocklist.isEmpty else { return }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activatedApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                self?.holdBackIfBlocked(activatedApplication)
            }
        }
        // The app that is already in front when the phase starts counts too.
        holdBackIfBlocked(NSWorkspace.shared.frontmostApplication)

        if !blocklist.allDomains.isEmpty {
            tabCheckTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkFrontBrowserTab() }
            }
        }
    }

    func stop() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        tabCheckTimer?.invalidate()
        tabCheckTimer = nil
    }

    // MARK: - Apps

    private func holdBackIfBlocked(_ application: NSRunningApplication?) {
        guard let application, let bundleIdentifier = application.bundleIdentifier,
              blocklist.blocksApp(bundleIdentifier: bundleIdentifier, ownBundleIdentifier: Bundle.main.bundleIdentifier) else {
            return
        }
        // Hiding returns the user to what they were doing; it never quits or loses anything in the app.
        application.hide()
        onHeldBack?("\(application.localizedName ?? "That app") is on hold until your break")
    }

    // MARK: - Websites

    private func checkFrontBrowserTab() {
        guard !isCheckingTab,
              let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              let browser = Self.browsers.first(where: { $0.bundleIdentifier == frontmostBundleIdentifier }),
              !browsersWithoutPermission.contains(browser.bundleIdentifier) else {
            return
        }
        isCheckingTab = true
        let blocklistSnapshot = blocklist
        Task { [weak self] in
            let outcome = await Task.detached(priority: .utility) {
                Self.readFrontTabURL(appleScriptName: browser.appleScriptName, isSafari: browser.isSafari)
            }.value

            guard let self else { return }
            self.isCheckingTab = false
            switch outcome {
            case .url(let urlString):
                guard let blockedDomain = blocklistSnapshot.blockedDomain(forURLString: urlString) else { return }
                let didReplace = await Task.detached(priority: .utility) {
                    Self.replaceFrontTab(
                        appleScriptName: browser.appleScriptName,
                        isSafari: browser.isSafari,
                        withBlockedPageFor: blockedDomain
                    )
                }.value
                if didReplace { self.onHeldBack?("\(blockedDomain) is on hold until your break") }
            case .permissionDenied:
                self.browsersWithoutPermission.insert(browser.bundleIdentifier)
                self.onBrowserPermissionMissing?(browser.appleScriptName)
            case .unavailable:
                break
            }
        }
    }

    private enum TabReadOutcome {
        case url(String)
        case permissionDenied
        case unavailable
    }

    private nonisolated static func readFrontTabURL(appleScriptName: String, isSafari: Bool) -> TabReadOutcome {
        let tabExpression = isSafari ? "current tab of front window" : "active tab of front window"
        let script = "tell application \"\(appleScriptName)\" to return URL of \(tabExpression)"
        let result = runOsascript(script)
        if result.exitStatus == 0 {
            let url = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            return url.isEmpty ? .unavailable : .url(url)
        }
        // -1743: the user hasn't allowed Wisp to control this browser.
        return result.standardError.contains("-1743") ? .permissionDenied : .unavailable
    }

    private nonisolated static func replaceFrontTab(appleScriptName: String, isSafari: Bool, withBlockedPageFor domain: String) -> Bool {
        let tabExpression = isSafari ? "current tab of front window" : "active tab of front window"
        let script = "tell application \"\(appleScriptName)\" to set URL of \(tabExpression) to \"\(blockedPageDataURL(for: domain))\""
        return runOsascript(script).exitStatus == 0
    }

    /// A self-contained page, so nothing is fetched and nothing is written to disk. The domain is
    /// percent-encoded on the way in, so it can't break out of the AppleScript string or the page.
    nonisolated static func blockedPageDataURL(for domain: String) -> String {
        let safeDomain = domain.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        let html = """
        <!doctype html><meta charset=utf-8><title>Blocked while you focus</title>
        <body style="margin:0;height:100vh;display:grid;place-items:center;background:#171815;color:#F2F1EC;font:16px -apple-system,system-ui,sans-serif;text-align:center">
        <div><div style="font-size:54px">🌿</div>
        <h1 style="font-weight:600;margin:12px 0 6px">\(safeDomain) is on hold</h1>
        <p style="color:#ADB2A8;margin:0">Wisp is keeping you in your focus block. Back to it, you've got this.</p>
        <p style="color:#6E736B;margin-top:28px;font-size:13px">Your break unlocks it. Press Back to return to where you were.</p></div>
        """
        var allowedCharacters = CharacterSet.alphanumerics
        allowedCharacters.insert(charactersIn: "-_.~")
        let encodedHTML = html.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? ""
        return "data:text/html;charset=utf-8," + encodedHTML
    }

    private nonisolated static func runOsascript(_ script: String) -> (exitStatus: Int32, standardOutput: String, standardError: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // The script is one argument, never spliced into a shell command.
        process.arguments = ["-e", script]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            return (-1, "", "")
        }
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: outputData, as: UTF8.self),
            String(decoding: errorData, as: UTF8.self)
        )
    }
}
