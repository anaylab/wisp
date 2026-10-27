//
//  WindowPositionManager.swift
//  leanring-buddy
//
//  Permission helpers for the two system grants Wisp cannot work without —
//  Accessibility and Screen Recording — plus the display-ID lookup the
//  capture and overlay code share.
//

import AppKit
import ApplicationServices

/// Where a permission request should send the user, decided before anything
/// is shown so the system dialog and System Settings never appear together.
enum PermissionRequestPresentationDestination: Equatable {
    case alreadyGranted
    case systemPrompt
    case systemSettings
}

@MainActor
class WindowPositionManager {
    private static var hasShownAccessibilitySystemPromptThisLaunch = false
    private static var hasShownScreenRecordingSystemPromptThisLaunch = false

    /// macOS sometimes reports screen recording as denied right after a rebuild
    /// even though the user already approved it, so the last confirmed grant is
    /// remembered here.
    private static let confirmedScreenRecordingGrantDefaultsKey = "wisp.screenRecording.grantWasConfirmed"
    private static let legacyConfirmedScreenRecordingGrantDefaultsKey = "com.learningbuddy.hasPreviouslyConfirmedScreenRecordingPermission"

    // MARK: - Choosing the path

    /// One tap, one path: the system dialog the first time, System Settings
    /// afterwards (macOS only shows its own dialog once per launch of the app).
    static func permissionRequestPresentationDestination(
        hasPermissionNow: Bool,
        hasAttemptedSystemPrompt: Bool
    ) -> PermissionRequestPresentationDestination {
        switch (hasPermissionNow, hasAttemptedSystemPrompt) {
        case (true, _):
            return .alreadyGranted
        case (false, true):
            return .systemSettings
        case (false, false):
            return .systemPrompt
        }
    }

    // MARK: - Accessibility

    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibilityPermission() -> PermissionRequestPresentationDestination {
        let destination = permissionRequestPresentationDestination(
            hasPermissionNow: hasAccessibilityPermission(),
            hasAttemptedSystemPrompt: hasShownAccessibilitySystemPromptThisLaunch
        )

        switch destination {
        case .alreadyGranted:
            break
        case .systemPrompt:
            hasShownAccessibilitySystemPromptThisLaunch = true
            let promptOption = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
            _ = AXIsProcessTrustedWithOptions([promptOption: true] as CFDictionary)
        case .systemSettings:
            openAccessibilitySettings()
        }

        return destination
    }

    static func openAccessibilitySettings() {
        openSystemSettingsPrivacyPane(named: "Privacy_Accessibility")
    }

    /// Shows the running app in Finder, for dragging it into the Accessibility
    /// list by hand when it doesn't appear on its own.
    static func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    // MARK: - Screen Recording

    static func hasScreenRecordingPermission() -> Bool {
        let isGrantedNow = CGPreflightScreenCaptureAccess()
        if isGrantedNow {
            UserDefaults.standard.set(true, forKey: confirmedScreenRecordingGrantDefaultsKey)
        }
        return isGrantedNow
    }

    /// Whether launch may carry on without showing the permission gate. The
    /// remembered grant covers the false negatives described above.
    static func shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch() -> Bool {
        let defaults = UserDefaults.standard
        let wasConfirmedBefore = defaults.bool(forKey: confirmedScreenRecordingGrantDefaultsKey)
            || defaults.bool(forKey: legacyConfirmedScreenRecordingGrantDefaultsKey)

        return shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: hasScreenRecordingPermission(),
            hasPreviouslyConfirmedScreenRecordingPermission: wasConfirmedBefore
        )
    }

    static func shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
        hasScreenRecordingPermissionNow: Bool,
        hasPreviouslyConfirmedScreenRecordingPermission: Bool
    ) -> Bool {
        hasScreenRecordingPermissionNow || hasPreviouslyConfirmedScreenRecordingPermission
    }

    @discardableResult
    static func requestScreenRecordingPermission() -> PermissionRequestPresentationDestination {
        let destination = permissionRequestPresentationDestination(
            hasPermissionNow: hasScreenRecordingPermission(),
            hasAttemptedSystemPrompt: hasShownScreenRecordingSystemPromptThisLaunch
        )

        switch destination {
        case .alreadyGranted:
            break
        case .systemPrompt:
            hasShownScreenRecordingSystemPromptThisLaunch = true
            _ = CGRequestScreenCaptureAccess()
        case .systemSettings:
            openSystemSettingsPrivacyPane(named: "Privacy_ScreenCapture")
        }

        return destination
    }

    // MARK: - System Settings

    private static func openSystemSettingsPrivacyPane(named paneAnchor: String) {
        let paneURLString = "x-apple.systempreferences:com.apple.preference.security?\(paneAnchor)"
        guard let paneURL = URL(string: paneURLString) else { return }
        NSWorkspace.shared.open(paneURL)
    }
}

extension NSScreen {
    /// The Core Graphics display ID behind this screen (0 if AppKit doesn't report one).
    var displayID: CGDirectDisplayID {
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[screenNumberKey] as? CGDirectDisplayID) ?? 0
    }
}
