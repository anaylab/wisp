//
//  ShortcutBindingStore.swift
//  leanring-buddy
//
//  The single source of truth for Wisp's global shortcuts. The notch cheat-sheet
//  and the dashboard's Shortcuts tab both read it, and it pushes the live values
//  down to the plain statics the CGEvent tap reads on the main thread
//  (`BuddyPushToTalkShortcut.currentShortcutOption` / `.handsFreeDoubleTapModifier`).
//
//  The model deliberately mirrors the current engine rather than inventing a
//  general keymap: there is one hold chord (Talk), Dictate is that chord plus
//  Shift, and Hands-free is a double-tap of a bare modifier. Independent chords
//  per action can come later; this keeps the proven hold path untouched while
//  making what exists rebindable and adding the double-tap gesture.
//

import AppKit
import Combine
import Foundation

/// A single modifier key that can be double-tapped on its own to trigger an
/// action (nothing else held).
enum BareModifier: String, CaseIterable, Identifiable {
    case control
    case option
    case command
    case shift

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .control: return "Control"
        case .option: return "Option"
        case .command: return "Command"
        case .shift: return "Shift"
        }
    }

    /// The short label shown on a key capsule, matching the hold-chord labels.
    var capsuleLabel: String {
        switch self {
        case .control: return "ctrl"
        case .option: return "option"
        case .command: return "cmd"
        case .shift: return "shift"
        }
    }

    var eventModifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .control: return .control
        case .option: return .option
        case .command: return .command
        case .shift: return .shift
        }
    }
}

@MainActor
final class ShortcutBindingStore: ObservableObject {
    static let shared = ShortcutBindingStore()

    // MARK: - Bindings

    /// The hold chord for Talk; Dictate is this chord plus Shift.
    @Published var primaryHoldChord: BuddyPushToTalkShortcut.ShortcutOption {
        didSet { persistAndApplyToMonitor() }
    }

    /// Whether the double-tap hands-free dictation gesture is active.
    @Published var handsFreeDictationEnabled: Bool {
        didSet { persistAndApplyToMonitor() }
    }

    /// The bare modifier whose double-tap toggles hands-free dictation.
    @Published var handsFreeDictationModifier: BareModifier {
        didSet { persistAndApplyToMonitor() }
    }

    // MARK: - Defaults

    static let defaultPrimaryHoldChord: BuddyPushToTalkShortcut.ShortcutOption = .controlOption
    static let defaultHandsFreeDictationEnabled = true
    static let defaultHandsFreeDictationModifier: BareModifier = .control

    // MARK: - Persistence keys

    private static let primaryHoldChordKey = "wisp.shortcut.primaryHoldChord"
    private static let handsFreeEnabledKey = "wisp.shortcut.handsFreeDictationEnabled"
    private static let handsFreeModifierKey = "wisp.shortcut.handsFreeDictationModifier"

    private init() {
        let userDefaults = UserDefaults.standard

        if let rawChord = userDefaults.string(forKey: Self.primaryHoldChordKey),
           let storedChord = BuddyPushToTalkShortcut.ShortcutOption(rawValue: rawChord) {
            primaryHoldChord = storedChord
        } else {
            primaryHoldChord = Self.defaultPrimaryHoldChord
        }

        if userDefaults.object(forKey: Self.handsFreeEnabledKey) != nil {
            handsFreeDictationEnabled = userDefaults.bool(forKey: Self.handsFreeEnabledKey)
        } else {
            handsFreeDictationEnabled = Self.defaultHandsFreeDictationEnabled
        }

        if let rawModifier = userDefaults.string(forKey: Self.handsFreeModifierKey),
           let storedModifier = BareModifier(rawValue: rawModifier) {
            handsFreeDictationModifier = storedModifier
        } else {
            handsFreeDictationModifier = Self.defaultHandsFreeDictationModifier
        }

        applyToMonitor()
    }

    /// Restores every binding to its shipped default.
    func resetToDefaults() {
        primaryHoldChord = Self.defaultPrimaryHoldChord
        handsFreeDictationEnabled = Self.defaultHandsFreeDictationEnabled
        handsFreeDictationModifier = Self.defaultHandsFreeDictationModifier
    }

    // MARK: - Applying

    private func persistAndApplyToMonitor() {
        let userDefaults = UserDefaults.standard
        userDefaults.set(primaryHoldChord.rawValue, forKey: Self.primaryHoldChordKey)
        userDefaults.set(handsFreeDictationEnabled, forKey: Self.handsFreeEnabledKey)
        userDefaults.set(handsFreeDictationModifier.rawValue, forKey: Self.handsFreeModifierKey)
        applyToMonitor()
    }

    /// Pushes the current values into the statics the CGEvent tap reads.
    private func applyToMonitor() {
        BuddyPushToTalkShortcut.currentShortcutOption = primaryHoldChord
        BuddyPushToTalkShortcut.handsFreeDoubleTapModifier =
            handsFreeDictationEnabled ? handsFreeDictationModifier.eventModifierFlag : nil
    }
}
