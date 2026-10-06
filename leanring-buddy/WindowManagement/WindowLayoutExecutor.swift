//
//  WindowLayoutExecutor.swift
//  leanring-buddy
//
//  Carries out a `WindowLayoutCommand` through the Accessibility API: finds
//  each app's focused (or main) window, unminimizes it, sets its position and
//  size, and raises it. Used by the direct spoken route in `CompanionManager`
//  and by the `arrange_windows` agent tool.
//
//  The app and the displays are read on the main actor (`NSWorkspace`,
//  `NSScreen`); the Accessibility calls themselves are blocking IPC to another
//  process, so they run detached, each with a short messaging timeout — a busy
//  or hung app otherwise holds a call for the system default of several
//  seconds. Same approach as `AccessibilityElementSnapshotter`.
//
//  Local and reversible (a window can always be put back), so it needs no
//  agent mode and no confirmation card when the user asked in their own words.
//

import AppKit
import ApplicationServices
import Foundation

enum WindowLayoutExecutor {
    /// Per-call Accessibility timeout. Longer than the snapshotter's 0.1s: this
    /// is the whole of a user-requested action, not a side job racing a
    /// screenshot, and some apps take a beat to answer a resize.
    nonisolated static let accessibilityMessagingTimeoutSeconds: Float = 0.5

    /// Why a window couldn't be placed, phrased to follow the app's name in
    /// the reply ("Xcode has no open window").
    nonisolated enum PlacementFailure: Error, Equatable, Sendable {
        case accessibilityNotGranted
        case applicationNotRunning
        case noFrontApplication
        case noWindow
        case windowIsInFullScreenSpace
        case windowCannotBeMoved
        case windowCannotBeResized
        case onlyOneDisplay
        case applicationNotResponding
        case accessibilityCallFailed

        var reasonFollowingApplicationName: String {
            switch self {
            case .accessibilityNotGranted:
                return "can't be moved — Wisp needs Accessibility access (System Settings → Privacy & Security → Accessibility)"
            case .applicationNotRunning: return "isn't running"
            case .noFrontApplication: return "can't be found — no other app is in front"
            case .noWindow: return "has no open window"
            case .windowIsInFullScreenSpace: return "is in its own full-screen space — exit full screen first"
            case .windowCannotBeMoved: return "has a window that can't be moved"
            case .windowCannotBeResized: return "has a window that can't be resized"
            case .onlyOneDisplay: return "can't go to another screen — there's only one display"
            case .applicationNotResponding: return "isn't responding"
            case .accessibilityCallFailed: return "didn't let me move its window"
            }
        }
    }

    // MARK: - Apps

    /// The names a spoken target may resolve to: ordinary apps (with a Dock
    /// icon and windows), never background agents and never Wisp itself.
    static func runningApplicationNamesForMatching() -> [String] {
        regularExternalRunningApplications().compactMap(\.localizedName)
    }

    private static func regularExternalRunningApplications() -> [NSRunningApplication] {
        let wispProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter { runningApplication in
            runningApplication.activationPolicy == .regular
                && runningApplication.processIdentifier != wispProcessIdentifier
        }
    }

    /// The app "this window" means: the frontmost app, or — when Wisp is
    /// frontmost because the question was typed into its composer — the last
    /// app the user was in before that.
    private static func frontWindowApplication() -> NSRunningApplication? {
        let wispProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        if let frontmostApplication = NSWorkspace.shared.frontmostApplication,
           frontmostApplication.processIdentifier != wispProcessIdentifier {
            return frontmostApplication
        }
        guard let lastExternalBundleIdentifier = FrontmostAppTracker.shared.lastExternalApplication?.bundleIdentifier else {
            return nil
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: lastExternalBundleIdentifier).first
    }

    // MARK: - Execution

    /// Places every window in the command, in order, and returns one result
    /// per assignment for `WindowLayoutReplyText`.
    static func execute(_ windowLayoutCommand: WindowLayoutCommand) async -> [WindowLayoutReplyText.AssignmentResult] {
        var assignmentResults: [WindowLayoutReplyText.AssignmentResult] = []
        for assignment in windowLayoutCommand.assignments {
            assignmentResults.append(await place(assignment))
        }
        return assignmentResults
    }

    /// Places one window.
    static func place(_ assignment: WindowLayoutAssignment) async -> WindowLayoutReplyText.AssignmentResult {
        let targetApplication: NSRunningApplication?
        let fallbackDisplayName: String
        switch assignment.target {
        case .frontWindow:
            targetApplication = frontWindowApplication()
            fallbackDisplayName = "the window"
        case .application(let applicationName):
            targetApplication = regularExternalRunningApplications().first { $0.localizedName == applicationName }
            fallbackDisplayName = applicationName
        }

        guard let targetApplication else {
            let failure: PlacementFailure = assignment.target == .frontWindow ? .noFrontApplication : .applicationNotRunning
            return WindowLayoutReplyText.AssignmentResult(
                applicationDisplayName: fallbackDisplayName,
                placement: assignment.placement,
                failureReason: failure.reasonFollowingApplicationName
            )
        }
        let applicationDisplayName = targetApplication.localizedName ?? fallbackDisplayName

        guard AXIsProcessTrusted() else {
            return WindowLayoutReplyText.AssignmentResult(
                applicationDisplayName: applicationDisplayName,
                placement: assignment.placement,
                failureReason: PlacementFailure.accessibilityNotGranted.reasonFollowingApplicationName
            )
        }

        // NSScreen.screens[0] is the primary display — the one at the AppKit
        // origin, whose height is the reference for the AX ↔ AppKit flip.
        let displayVisibleFramesInAppKitCoordinates = NSScreen.screens.map(\.visibleFrame)
        let primaryDisplayHeight = NSScreen.screens.first?.frame.height ?? 0
        let targetProcessIdentifier = targetApplication.processIdentifier
        let placement = assignment.placement

        let placementFailure = await Task.detached(priority: .userInitiated) {
            WindowLayoutExecutor.placeFocusedWindow(
                processIdentifier: targetProcessIdentifier,
                placement: placement,
                displayVisibleFramesInAppKitCoordinates: displayVisibleFramesInAppKitCoordinates,
                primaryDisplayHeight: primaryDisplayHeight
            )
        }.value

        if placementFailure == nil {
            // AXRaise brings the window up within its app; activating brings
            // the app forward, so a "left and right" pair both end up visible.
            targetApplication.activate()
        }
        return WindowLayoutReplyText.AssignmentResult(
            applicationDisplayName: applicationDisplayName,
            placement: placement,
            failureReason: placementFailure?.reasonFollowingApplicationName
        )
    }

    // MARK: - Accessibility (off the main actor)

    /// Moves and resizes the app's focused (or main, or first) window.
    /// Returns nil on success.
    private nonisolated static func placeFocusedWindow(
        processIdentifier: pid_t,
        placement: WindowPlacement,
        displayVisibleFramesInAppKitCoordinates: [CGRect],
        primaryDisplayHeight: CGFloat
    ) -> PlacementFailure? {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, accessibilityMessagingTimeoutSeconds)

        let windowLookup = findWindow(of: applicationElement)
        guard let windowElement = windowLookup.windowElement else {
            return failure(forAccessibilityError: windowLookup.lastError) ?? .noWindow
        }
        AXUIElementSetMessagingTimeout(windowElement, accessibilityMessagingTimeoutSeconds)

        // A window in its own full-screen Space ignores position and size.
        if copyBooleanAttribute(windowElement, attribute: "AXFullScreen") == true {
            return .windowIsInFullScreenSpace
        }
        if copyBooleanAttribute(windowElement, attribute: kAXMinimizedAttribute) == true {
            AXUIElementSetAttributeValue(windowElement, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }

        guard isAttributeSettable(windowElement, attribute: kAXPositionAttribute) else { return .windowCannotBeMoved }
        let canResize = isAttributeSettable(windowElement, attribute: kAXSizeAttribute)
        if placement.requiresResizing && !canResize { return .windowCannotBeResized }

        guard let currentPosition = copyPointAttribute(windowElement, attribute: kAXPositionAttribute),
              let currentSize = copySizeAttribute(windowElement, attribute: kAXSizeAttribute) else {
            return .accessibilityCallFailed
        }
        let currentWindowAccessibilityFrame = CGRect(origin: currentPosition, size: currentSize)

        guard let targetFrame = WindowFrameCalculator.targetAccessibilityFrame(
            for: placement,
            currentWindowAccessibilityFrame: currentWindowAccessibilityFrame,
            displayVisibleFramesInAppKitCoordinates: displayVisibleFramesInAppKitCoordinates,
            primaryDisplayHeight: primaryDisplayHeight
        ) else {
            return placement == .nextDisplay ? .onlyOneDisplay : .accessibilityCallFailed
        }

        // Position, then size, then position again: an app clamps a size that
        // would run off the display it is *currently* on, and some re-anchor
        // the origin when resized, so the second move settles both.
        let firstMoveError = setPointAttribute(windowElement, attribute: kAXPositionAttribute, point: targetFrame.origin)
        if let firstMoveFailure = failure(forAccessibilityError: firstMoveError) { return firstMoveFailure }
        if canResize {
            setSizeAttribute(windowElement, attribute: kAXSizeAttribute, size: targetFrame.size)
        }
        setPointAttribute(windowElement, attribute: kAXPositionAttribute, point: targetFrame.origin)

        AXUIElementPerformAction(windowElement, kAXRaiseAction as CFString)
        return nil
    }

    /// The focused window, else the main window, else the first standard
    /// window in the app's window list.
    private nonisolated static func findWindow(of applicationElement: AXUIElement) -> (windowElement: AXUIElement?, lastError: AXError) {
        var lastError = AXError.success
        for windowAttribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var attributeValue: AnyObject?
            lastError = AXUIElementCopyAttributeValue(applicationElement, windowAttribute as CFString, &attributeValue)
            if lastError == .success, let attributeValue, CFGetTypeID(attributeValue) == AXUIElementGetTypeID() {
                return ((attributeValue as! AXUIElement), .success)
            }
        }
        var windowListValue: AnyObject?
        lastError = AXUIElementCopyAttributeValue(applicationElement, kAXWindowsAttribute as CFString, &windowListValue)
        if lastError == .success, let windowElements = windowListValue as? [AXUIElement] {
            let standardWindow = windowElements.first { windowElement in
                var subroleValue: AnyObject?
                AXUIElementCopyAttributeValue(windowElement, kAXSubroleAttribute as CFString, &subroleValue)
                return (subroleValue as? String) == (kAXStandardWindowSubrole as String)
            }
            if let standardWindow { return (standardWindow, .success) }
        }
        return (nil, lastError)
    }

    /// The failure an Accessibility error means, or nil for success and for
    /// errors that only mean "that attribute isn't there".
    private nonisolated static func failure(forAccessibilityError accessibilityError: AXError) -> PlacementFailure? {
        switch accessibilityError {
        case .success, .noValue, .attributeUnsupported: return nil
        case .apiDisabled: return .accessibilityNotGranted
        case .cannotComplete: return .applicationNotResponding
        default: return .accessibilityCallFailed
        }
    }

    private nonisolated static func isAttributeSettable(_ element: AXUIElement, attribute: String) -> Bool {
        var isSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &isSettable) == .success else { return false }
        return isSettable.boolValue
    }

    private nonisolated static func copyBooleanAttribute(_ element: AXUIElement, attribute: String) -> Bool? {
        var attributeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &attributeValue) == .success else { return nil }
        return (attributeValue as? NSNumber)?.boolValue
    }

    private nonisolated static func copyPointAttribute(_ element: AXUIElement, attribute: String) -> CGPoint? {
        var attributeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &attributeValue) == .success,
              let attributeValue,
              CFGetTypeID(attributeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(attributeValue as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private nonisolated static func copySizeAttribute(_ element: AXUIElement, attribute: String) -> CGSize? {
        var attributeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &attributeValue) == .success,
              let attributeValue,
              CFGetTypeID(attributeValue) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(attributeValue as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    @discardableResult
    private nonisolated static func setPointAttribute(_ element: AXUIElement, attribute: String, point: CGPoint) -> AXError {
        var mutablePoint = point
        guard let pointValue = AXValueCreate(.cgPoint, &mutablePoint) else { return .failure }
        return AXUIElementSetAttributeValue(element, attribute as CFString, pointValue)
    }

    @discardableResult
    private nonisolated static func setSizeAttribute(_ element: AXUIElement, attribute: String, size: CGSize) -> AXError {
        var mutableSize = size
        guard let sizeValue = AXValueCreate(.cgSize, &mutableSize) else { return .failure }
        return AXUIElementSetAttributeValue(element, attribute as CFString, sizeValue)
    }
}
