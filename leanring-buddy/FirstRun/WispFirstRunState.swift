//
//  WispFirstRunState.swift
//  leanring-buddy
//
//  Whether the four-step first-run setup has been finished (or skipped through). One flag, so the
//  setup shows once and "Run setup again" in Settings -> General can bring it back.
//

import Foundation
import Combine

@MainActor
final class WispFirstRunState: ObservableObject {
    static let shared = WispFirstRunState()

    private static let completedUserDefaultsKey = "wisp.firstRun.completed"

    @Published private(set) var isCompleted: Bool

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        isCompleted = userDefaults.bool(forKey: Self.completedUserDefaultsKey)
    }

    private let userDefaults: UserDefaults

    func markCompleted() {
        userDefaults.set(true, forKey: Self.completedUserDefaultsKey)
        isCompleted = true
    }

    /// "Run setup again": the flag clears and the window is asked to show the flow now, so the
    /// button does something visible even on a Mac that has long since finished setup.
    func reset() {
        userDefaults.set(false, forKey: Self.completedUserDefaultsKey)
        isCompleted = false
        WispWindowRouter.shared.isFirstRunSetupRequested = true
    }
}
