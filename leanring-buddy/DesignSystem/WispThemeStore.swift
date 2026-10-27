//
//  WispThemeStore.swift
//  leanring-buddy
//
//  The one source of truth for the chosen theme and the two switches that go with
//  it: "Tint the island with my theme" (off by default) and "Playful" (on by default).
//
//  Colours are resolved by dynamic `NSColor` providers, which AppKit calls on any
//  thread and on every draw, so they cannot hop to the main actor. They read the
//  `...Now` statics instead, backed by a small lock-guarded cache that mirrors the
//  UserDefaults keys (re-reading UserDefaults for every colour on every frame would
//  be wasteful). The `@MainActor` store writes through to both the cache and
//  UserDefaults, then posts `.wispThemeDidChange`.
//
//  Dynamic colours do not observe anything, so a theme change repaints because the
//  window root is keyed on `currentThemeID` (`.id(...)`), which rebuilds its views;
//  AppKit-drawn surfaces listen for the notification.
//

import AppKit
import Combine
import Foundation

extension Notification.Name {
    /// Posted after `currentThemeID` changes.
    static let wispThemeDidChange = Notification.Name("wispThemeDidChange")
}

/// Thread-safe mirror of the persisted theme settings, for code that is not on the
/// main actor. Loaded lazily from UserDefaults the first time anything asks.
private nonisolated final class WispThemeSettingsCache: @unchecked Sendable {
    static let shared = WispThemeSettingsCache()

    static let themeIDKey = "wisp.theme.id"
    static let tintsIslandKey = "wisp.theme.tintsIsland"
    static let isPlayfulKey = "wisp.theme.playful"

    private let lock = NSLock()
    private var cachedThemeID: WispThemeID?
    private var cachedTintsIsland: Bool?
    private var cachedIsPlayful: Bool?

    var themeID: WispThemeID {
        get {
            lock.lock(); defer { lock.unlock() }
            if let cachedThemeID { return cachedThemeID }
            let storedRawValue = UserDefaults.standard.string(forKey: Self.themeIDKey) ?? ""
            let loadedThemeID = WispThemeID(rawValue: storedRawValue) ?? WispTheme.defaultTheme.id
            cachedThemeID = loadedThemeID
            return loadedThemeID
        }
        set {
            lock.lock(); defer { lock.unlock() }
            cachedThemeID = newValue
        }
    }

    var tintsIsland: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            if let cachedTintsIsland { return cachedTintsIsland }
            // Absent means the default: off. The island is black unless the user opts in.
            let loadedValue = (UserDefaults.standard.object(forKey: Self.tintsIslandKey) as? Bool) ?? false
            cachedTintsIsland = loadedValue
            return loadedValue
        }
        set {
            lock.lock(); defer { lock.unlock() }
            cachedTintsIsland = newValue
        }
    }

    var isPlayful: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            if let cachedIsPlayful { return cachedIsPlayful }
            // Absent means the default: on.
            let loadedValue = (UserDefaults.standard.object(forKey: Self.isPlayfulKey) as? Bool) ?? true
            cachedIsPlayful = loadedValue
            return loadedValue
        }
        set {
            lock.lock(); defer { lock.unlock() }
            cachedIsPlayful = newValue
        }
    }
}

@MainActor
final class WispThemeStore: ObservableObject {
    static let shared = WispThemeStore()

    @Published var currentThemeID: WispThemeID {
        didSet {
            guard currentThemeID != oldValue else { return }
            WispThemeSettingsCache.shared.themeID = currentThemeID
            UserDefaults.standard.set(currentThemeID.rawValue, forKey: WispThemeSettingsCache.themeIDKey)
            NotificationCenter.default.post(name: .wispThemeDidChange, object: nil)
        }
    }

    /// "Tint the island with my theme". Off by default: the notch is black like the camera cutout.
    @Published var tintsIsland: Bool {
        didSet {
            guard tintsIsland != oldValue else { return }
            WispThemeSettingsCache.shared.tintsIsland = tintsIsland
            UserDefaults.standard.set(tintsIsland, forKey: WispThemeSettingsCache.tintsIslandKey)
            NotificationCenter.default.post(name: .wispThemeDidChange, object: nil)
        }
    }

    /// "Playful": small celebrations and the drifting backdrop. On by default.
    @Published var isPlayful: Bool {
        didSet {
            guard isPlayful != oldValue else { return }
            WispThemeSettingsCache.shared.isPlayful = isPlayful
            UserDefaults.standard.set(isPlayful, forKey: WispThemeSettingsCache.isPlayfulKey)
        }
    }

    var currentTheme: WispTheme { WispTheme.theme(withID: currentThemeID) }

    /// Playful AND the system's Reduce Motion is off. Every celebration, bounce, burst and
    /// drifting backdrop checks this, never `isPlayful` alone.
    var allowsPlayfulMotion: Bool { Self.allowsPlayfulMotionNow }

    private init() {
        // Seed the published values from the same cache the colours read, so the two can never disagree.
        currentThemeID = WispThemeSettingsCache.shared.themeID
        tintsIsland = WispThemeSettingsCache.shared.tintsIsland
        isPlayful = WispThemeSettingsCache.shared.isPlayful
    }

    // MARK: Synchronous reads for code that is not on the main actor

    nonisolated static var currentThemeNow: WispTheme {
        WispTheme.theme(withID: WispThemeSettingsCache.shared.themeID)
    }

    nonisolated static var tintsIslandNow: Bool {
        WispThemeSettingsCache.shared.tintsIsland
    }

    nonisolated static var isPlayfulNow: Bool {
        WispThemeSettingsCache.shared.isPlayful
    }

    /// `isPlayfulNow` and the system's Reduce Motion is off.
    nonisolated static var allowsPlayfulMotionNow: Bool {
        isPlayfulNow && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
