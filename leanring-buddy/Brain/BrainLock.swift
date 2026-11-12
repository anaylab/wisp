//
//  BrainLock.swift
//  leanring-buddy
//
//  An optional Touch ID lock in front of the Brain pages of the Wisp window
//  (Settings → Brain → Lock, off by default). Unlocking asks LocalAuthentication
//  for the device owner — Touch ID, or the Mac's password when there is no
//  sensor or it fails — and the lock comes back after `autoLockMinutes` away
//  from Wisp (measured from when Wisp stopped being the active app), on quit,
//  or with Lock Now.
//
//  What it is and isn't: it keeps someone at an unlocked Mac from browsing
//  the brain in the window. The vault is still plain markdown in ~/.wisp/brain
//  (FileVault protects it at rest) and Wisp still reads it to answer questions.
//
//  `BrainLockPolicy` is the pure timing rule (tested by `Tests/BrainCore`);
//  `BrainLockController` holds the state and talks to LocalAuthentication.
//

import AppKit
import Combine
import Foundation
import LocalAuthentication

nonisolated enum BrainLockPolicy {
    /// Choices offered for auto-lock, in minutes (0 = only when Wisp quits).
    static let autoLockMinuteChoices = [1, 5, 15, 60, 0]

    /// Whether an unlocked brain should lock again now, given when the user
    /// last left Wisp (nil while Wisp is the active app).
    static func shouldRelock(leftWispDate: Date?, now: Date, autoLockMinutes: Int) -> Bool {
        guard autoLockMinutes > 0, let leftWispDate else { return false }
        return now.timeIntervalSince(leftWispDate) >= Double(autoLockMinutes) * 60
    }

    static func autoLockChoiceTitle(minutes: Int) -> String {
        switch minutes {
        case 0: return "Only when Wisp quits"
        case 1: return "After 1 minute away"
        case 60: return "After 1 hour away"
        default: return "After \(minutes) minutes away"
        }
    }
}

@MainActor
final class BrainLockController: ObservableObject {
    static let shared = BrainLockController()

    /// True while the Brain pages are hidden behind the lock. Starts locked
    /// whenever the lock is on, so a fresh launch always asks.
    @Published private(set) var isLocked: Bool
    @Published private(set) var isAuthenticating = false
    @Published private(set) var lastFailureMessage: String?

    private var leftWispDate: Date?
    private var notificationObservers: [NSObjectProtocol] = []
    private var relockCheckTimer: Timer?

    private init() {
        isLocked = BrainPreferences.shared.isLockEnabled
        let notificationCenter = NotificationCenter.default
        notificationObservers.append(notificationCenter.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.leftWispDate = Date() }
        })
        notificationObservers.append(notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.relockIfDue()
                self?.leftWispDate = nil
            }
        })
        // Wisp is a menu bar app and is often not the active app while its
        // window is visible, so also check once a minute.
        relockCheckTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.relockIfDue() }
        }
    }

    var isLockAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// "Touch ID" when the Mac has a sensor enrolled, otherwise "your password".
    var unlockMethodName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType == .touchID ? "Touch ID" : "your password"
    }

    func lockNow() {
        guard BrainPreferences.shared.isLockEnabled else { return }
        isLocked = true
    }

    /// Asks for Touch ID / the password; unlocks on success.
    func unlock() async {
        guard await authenticate(reason: "show your brain") else { return }
        isLocked = false
        leftWispDate = nil
    }

    /// Turning the lock on or off both need the owner, so someone at the Mac
    /// can't simply switch it off.
    func setLockEnabled(_ shouldEnable: Bool) async {
        guard shouldEnable != BrainPreferences.shared.isLockEnabled else { return }
        guard await authenticate(reason: shouldEnable ? "lock your brain" : "turn off the brain lock") else { return }
        BrainPreferences.shared.isLockEnabled = shouldEnable
        // Just proved who they are: leave it open until they step away.
        isLocked = false
    }

    private func relockIfDue() {
        guard BrainPreferences.shared.isLockEnabled, !isLocked else { return }
        if BrainLockPolicy.shouldRelock(leftWispDate: leftWispDate, now: Date(), autoLockMinutes: BrainPreferences.shared.autoLockMinutes) {
            isLocked = true
        }
    }

    private func authenticate(reason: String) async -> Bool {
        guard !isAuthenticating else { return false }
        isAuthenticating = true
        lastFailureMessage = nil
        defer { isAuthenticating = false }
        let context = LAContext()
        var availabilityError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &availabilityError) else {
            lastFailureMessage = availabilityError?.localizedDescription ?? "this Mac can't check who you are."
            return false
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch let authenticationError as LAError where authenticationError.code == .userCancel || authenticationError.code == .appCancel || authenticationError.code == .systemCancel {
            return false
        } catch {
            lastFailureMessage = error.localizedDescription
            return false
        }
    }
}
