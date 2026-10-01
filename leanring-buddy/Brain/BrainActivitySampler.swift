//
//  BrainActivitySampler.swift
//  leanring-buddy
//
//  Takes one activity sample: the frontmost app, its focused window's title
//  (Accessibility), and for Chrome/Safari the front tab's URL and title
//  (AppleScript). Exclusions are checked as early as possible — an excluded
//  app's window title is never even read, and an excluded site drops the
//  whole sample.
//
//  Private browsing:
//  - Chrome: `mode of front window` is "incognito" for an Incognito window;
//    such a sample is dropped entirely (no app, title or URL recorded).
//  - Safari: its AppleScript dictionary does not expose Private Browsing, so
//    a private window can't be told apart reliably. Two guards apply: the
//    sample is dropped when the focused window's title is Safari's private
//    start page ("Private Browsing"), and Safari's URL is only recorded when
//    the AppleScript tab title appears in the focused window's title (so the
//    URL is known to belong to the window the user is looking at). Beyond
//    that, users who browse privately in Safari should add sites to the
//    exclusion list or pause recording — the Brain page's Sources card says so.
//  - Either browser: when no URL could be read and checked against the
//    exclusions (no permission, a failed guard), the window title is dropped
//    too and only the app name is kept, since an unchecked page title could
//    name a banking or private page. Other browsers (Arc, Firefox, Edge…)
//    are always recorded by app name only, for the same reason.
//
//  Automation: the browser is only asked when Wisp already has Automation
//  permission for it (`AEDeterminePermissionToAutomateTarget` without
//  prompting). Background sampling must never pop a consent dialog; without
//  permission the sample simply has no URL. `requestBrowserAutomationAccess`
//  lets the UI ask on purpose.
//

import AppKit
import ApplicationServices
import Foundation

@MainActor
enum BrainActivitySampler {
    static let chromeBundleIdentifier = "com.google.Chrome"
    static let safariBundleIdentifier = "com.apple.Safari"

    /// Longest the Accessibility call may block on an unresponsive app.
    nonisolated static let accessibilityMessagingTimeoutSeconds: Float = 0.2

    /// Takes a sample of what's frontmost, or nil when nothing may be
    /// recorded right now (an excluded app or site, Incognito, no app).
    static func takeSample(
        at sampleDate: Date,
        userExcludedBundleIdentifiers: [String],
        userExcludedDomains: [String],
        screenText: String?
    ) async -> BrainActivitySample? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = frontmostApplication.bundleIdentifier else { return nil }
        guard !BrainActivityExclusionPolicy.isApplicationExcluded(
            bundleIdentifier: bundleIdentifier,
            ownBundleIdentifier: Bundle.main.bundleIdentifier,
            userExcludedBundleIdentifiers: userExcludedBundleIdentifiers
        ) else { return nil }

        let applicationName = frontmostApplication.localizedName ?? bundleIdentifier
        let processIdentifier = frontmostApplication.processIdentifier
        let windowTitle = await readFocusedWindowTitleOffMainActor(processIdentifier: processIdentifier)

        var sample = BrainActivitySample(
            date: sampleDate,
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle.flatMap(cleanedWindowTitle),
            url: nil,
            domain: nil,
            screenText: screenText.flatMap(BrainActivityExclusionPolicy.cappedScreenText)
        )

        if BrainActivityExclusionPolicy.browserBundleIdentifiersWithoutURLReading.contains(bundleIdentifier) {
            sample.windowTitle = nil
        }

        if bundleIdentifier == chromeBundleIdentifier || bundleIdentifier == safariBundleIdentifier {
            let frontTabReading = await readBrowserFrontTab(bundleIdentifier: bundleIdentifier)
            switch frontTabReading {
            case .privateWindow:
                return nil
            case .unavailable:
                break
            case .page(let rawURL, let tabTitle):
                if bundleIdentifier == safariBundleIdentifier {
                    if sample.windowTitle?.caseInsensitiveCompare("Private Browsing") == .orderedSame { return nil }
                    // Only trust Safari's "window 1" when it's evidently the
                    // window in focus (see the header on private windows).
                    let focusedTitle = sample.windowTitle ?? ""
                    let trimmedTabTitle = tabTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedTabTitle.isEmpty, focusedTitle.localizedCaseInsensitiveContains(trimmedTabTitle) else { break }
                }
                if let sanitized = BrainActivityExclusionPolicy.sanitizedURL(rawURL) {
                    guard !BrainActivityExclusionPolicy.isDomainExcluded(
                        host: sanitized.domain,
                        userExcludedDomains: userExcludedDomains
                    ) else { return nil }
                    sample.url = sanitized.url
                    sample.domain = sanitized.domain
                }
            }
            // Without a checked URL, a browser window's title is an unchecked
            // page title — it could be a banking or private page. Keep only
            // the app name.
            if sample.url == nil { sample.windowTitle = nil }
        }
        return sample
    }

    // MARK: - Window title (Accessibility)

    private static func cleanedWindowTitle(_ windowTitle: String) -> String? {
        let collapsedTitle = windowTitle
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsedTitle.isEmpty else { return nil }
        return String(collapsedTitle.prefix(200))
    }

    /// Reads the focused window's title off the main actor, so a hung app
    /// can't stall the UI (and the messaging timeout bounds it anyway).
    private static func readFocusedWindowTitleOffMainActor(processIdentifier: pid_t) async -> String? {
        guard AXIsProcessTrusted() else { return nil }
        return await Task.detached(priority: .utility) {
            readFocusedWindowTitle(processIdentifier: processIdentifier)
        }.value
    }

    nonisolated private static func readFocusedWindowTitle(processIdentifier: pid_t) -> String? {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, accessibilityMessagingTimeoutSeconds)
        var focusedWindowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, &focusedWindowValue) == .success,
              let focusedWindowValue,
              CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() else { return nil }
        let focusedWindowElement = focusedWindowValue as! AXUIElement
        AXUIElementSetMessagingTimeout(focusedWindowElement, accessibilityMessagingTimeoutSeconds)
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedWindowElement, kAXTitleAttribute as CFString, &titleValue) == .success else { return nil }
        return titleValue as? String
    }

    // MARK: - Browser front tab (AppleScript)

    nonisolated enum BrowserFrontTabReading: Equatable, Sendable {
        case page(url: String, title: String)
        /// A Chrome Incognito window is in front: record nothing.
        case privateWindow
        /// No permission, no window, or the browser didn't answer.
        case unavailable
    }

    /// Whether Wisp may send Apple Events to the browser without asking.
    nonisolated static func hasAutomationPermission(forBundleIdentifier bundleIdentifier: String, askingUserIfNeeded: Bool) -> Bool {
        let targetDescriptor = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        guard let targetAEDesc = targetDescriptor.aeDesc else { return false }
        let permissionStatus = AEDeterminePermissionToAutomateTarget(
            targetAEDesc,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            askingUserIfNeeded
        )
        return permissionStatus == noErr
    }

    /// Asks macOS for Automation access to the browsers that are running, so
    /// the feed can record sites. Call only from a deliberate user action.
    static func requestBrowserAutomationAccess() async {
        let runningBrowserBundleIdentifiers = [chromeBundleIdentifier, safariBundleIdentifier].filter { bundleIdentifier in
            !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
        }
        for bundleIdentifier in runningBrowserBundleIdentifiers {
            // Blocks until the user answers the dialog, so off the main actor.
            _ = await Task.detached(priority: .userInitiated) {
                hasAutomationPermission(forBundleIdentifier: bundleIdentifier, askingUserIfNeeded: true)
            }.value
        }
    }

    private static func readBrowserFrontTab(bundleIdentifier: String) async -> BrowserFrontTabReading {
        // The permission check can take a moment on first use; keep it off main.
        let isPermitted = await Task.detached(priority: .utility) {
            hasAutomationPermission(forBundleIdentifier: bundleIdentifier, askingUserIfNeeded: false)
        }.value
        guard isPermitted else { return .unavailable }

        // NSAppleScript is run on the main actor, like the rest of Wisp's
        // browser AppleScript. `with timeout` bounds a hung browser to 1s.
        let script: String
        if bundleIdentifier == chromeBundleIdentifier {
            script = """
            with timeout of 1 second
                tell application id "com.google.Chrome"
                    if (count of windows) is 0 then return ""
                    if mode of front window is "incognito" then return "WISP-INCOGNITO"
                    return (URL of active tab of front window) & linefeed & (title of active tab of front window)
                end tell
            end timeout
            """
        } else {
            script = """
            with timeout of 1 second
                tell application id "com.apple.Safari"
                    if (count of windows) is 0 then return ""
                    return (URL of current tab of front window) & linefeed & (name of current tab of front window)
                end tell
            end timeout
            """
        }
        var scriptError: NSDictionary?
        let scriptResult = NSAppleScript(source: script)?.executeAndReturnError(&scriptError)
        if scriptError != nil { return .unavailable }
        guard let reply = scriptResult?.stringValue, !reply.isEmpty else { return .unavailable }
        return parseBrowserFrontTabReply(reply)
    }

    /// Reads the AppleScript reply ("URL\ntitle" or the incognito marker).
    nonisolated static func parseBrowserFrontTabReply(_ reply: String) -> BrowserFrontTabReading {
        if reply == "WISP-INCOGNITO" { return .privateWindow }
        let replyParts = reply.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let url = replyParts.first, url.lowercased().hasPrefix("http") else { return .unavailable }
        return .page(url: url, title: replyParts.count > 1 ? replyParts[1] : "")
    }
}
