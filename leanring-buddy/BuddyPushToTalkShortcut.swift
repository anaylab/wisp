//
//  BuddyPushToTalkShortcut.swift
//  leanring-buddy
//
//  What counts as "the Talk chord": which key combinations can be chosen,
//  and how raw keyboard events become press / release transitions. Pure
//  matching only — `GlobalPushToTalkShortcutMonitor` owns the event tap and
//  the state around it.
//

import AppKit
import CoreGraphics

enum BuddyPushToTalkShortcut {

    // MARK: - Choosable chords

    enum ShortcutOption: String, CaseIterable, Identifiable {
        case shiftFunction
        case controlOption
        case shiftControl
        case controlOptionSpace
        case shiftControlSpace

        var id: String { rawValue }

        /// Names of the keys to draw as separate capsules, in press order.
        var keyCapsuleLabels: [String] {
            switch self {
            case .shiftFunction: return ["shift", "fn"]
            case .controlOption: return ["ctrl", "option"]
            case .shiftControl: return ["shift", "control"]
            case .controlOptionSpace: return ["ctrl", "option", "space"]
            case .shiftControlSpace: return ["shift", "control", "space"]
            }
        }

        var displayText: String {
            keyCapsuleLabels.joined(separator: " + ")
        }

        /// How the chord is physically pressed.
        fileprivate enum Activation {
            /// Satisfied the instant these modifiers are all down.
            case modifiersAlone(NSEvent.ModifierFlags)
            /// These modifiers held while Space is pressed.
            case modifiersWithSpace(NSEvent.ModifierFlags)
        }

        fileprivate var activation: Activation {
            switch self {
            case .shiftFunction: return .modifiersAlone([.shift, .function])
            case .controlOption: return .modifiersAlone([.control, .option])
            case .shiftControl: return .modifiersAlone([.shift, .control])
            case .controlOptionSpace: return .modifiersWithSpace([.control, .option])
            case .shiftControlSpace: return .modifiersWithSpace([.shift, .control])
            }
        }
    }

    // MARK: - Gesture vocabulary

    /// What holding the chord means this time.
    ///
    /// Dictation is the same chord plus Shift rather than a second chord of its
    /// own: the mental model stays "same keys, shift means type it instead of
    /// say it", and there is no new combination to learn or collide with.
    enum InvocationMode: Sendable, Equatable {
        /// The chord alone: ask a question, hear an answer.
        case assistant
        /// The chord plus Shift: dictate into whatever has focus.
        case dictation
    }

    /// A double-tap gesture that isn't a hold; today only the one that toggles
    /// hands-free dictation.
    enum DoubleTapAction: Sendable, Equatable {
        case handsFreeDictate
    }

    /// A quick press-and-release of the chord, as opposed to holding it.
    enum TapAction: Sendable, Equatable {
        case textComposer
    }

    enum ShortcutTransition: Equatable {
        case none
        case pressed(InvocationMode)
        /// A quick tap of the hold chord (tap ctrl + option to type).
        case tapped(TapAction)
        /// A double-tap of a bare modifier (Control twice).
        case doubleTapped(DoubleTapAction)
        /// Shift arrived just after the chord did.
        ///
        /// Nobody presses three modifiers in the same instant. Ctrl + Option is
        /// already satisfied when option lands, typically tens of milliseconds
        /// before shift, so fixing the mode at that moment would turn every
        /// dictation attempt into a question. The mode therefore gets a short
        /// window to settle (`invocationModeSettlingWindow`).
        case modeChanged(InvocationMode)
        case released(InvocationMode)
    }

    // MARK: - Timing

    /// A press shorter than this is a tap, not a hold. Nobody says anything
    /// useful in 0.3s, so a real hold is never mistaken for a tap, and a
    /// deliberate quick tap is caught. It used to be 0.22s, but a tap measured at
    /// 0.224s was heard as a hold with nothing said and the composer silently
    /// never opened; a busy main thread just after launch can stretch a tap
    /// that far.
    static let tapMaxDuration: TimeInterval = 0.30

    /// How long after the chord is first satisfied the mode may still change.
    /// Covers the natural stagger between modifier keys yet is too short to flip
    /// in the middle of a sentence, since speech doesn't start that quickly.
    static let invocationModeSettlingWindow: TimeInterval = 0.3

    /// A tap in a double-tap must be at least this quick; slower is a hold.
    static let doubleTapMaxTapDuration: TimeInterval = 0.30

    /// The two taps of a double-tap must land within this gap of each other.
    static let doubleTapBetweenTapsInterval: TimeInterval = 0.40

    // MARK: - Current bindings

    /// The hold chord for Talk (and Dictate, with Shift added). Mutable so
    /// `ShortcutBindingStore` can rebind it live. It is only read and written
    /// on the main thread (the event-tap callback runs on the main run loop),
    /// which is why `nonisolated(unsafe)` is accurate here and not a hazard.
    nonisolated(unsafe) static var currentShortcutOption: ShortcutOption = .controlOption

    /// The bare modifier whose double-tap toggles hands-free dictation, or nil
    /// when hands-free is off. Same main-thread-only contract as above.
    nonisolated(unsafe) static var handsFreeDoubleTapModifier: NSEvent.ModifierFlags? = .control

    /// Key code of Space, used by the two "+ space" chords.
    static let pushToTalkKeyCode: UInt16 = 49

    static var pushToTalkDisplayText: String { currentShortcutOption.displayText }
    static var pushToTalkTooltipText: String { "push to talk (\(pushToTalkDisplayText))" }

    // MARK: - Matching events

    private enum KeyboardEventKind {
        case flagsChanged
        case keyDown
        case keyUp
    }

    static func shortcutTransition(
        for event: NSEvent,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        let eventKind: KeyboardEventKind
        switch event.type {
        case .flagsChanged: eventKind = .flagsChanged
        case .keyDown: eventKind = .keyDown
        case .keyUp: eventKind = .keyUp
        default: return .none
        }

        return transition(
            for: eventKind,
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
            wasPressed: wasShortcutPreviouslyPressed
        )
    }

    static func shortcutTransition(
        for eventType: CGEventType,
        keyCode: UInt16,
        modifierFlagsRawValue: UInt64,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        let eventKind: KeyboardEventKind
        switch eventType {
        case .flagsChanged: eventKind = .flagsChanged
        case .keyDown: eventKind = .keyDown
        case .keyUp: eventKind = .keyUp
        default: return .none
        }

        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
            .intersection(.deviceIndependentFlagsMask)

        return transition(
            for: eventKind,
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            wasPressed: wasShortcutPreviouslyPressed
        )
    }

    private static func transition(
        for eventKind: KeyboardEventKind,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        wasPressed: Bool
    ) -> ShortcutTransition {
        switch currentShortcutOption.activation {

        case .modifiersAlone(let requiredModifiers):
            guard eventKind == .flagsChanged else { return .none }

            let isPressedNow = modifierFlags.contains(requiredModifiers)

            if isPressedNow && !wasPressed {
                // Shift must be checked explicitly: the test above is `contains`,
                // so Ctrl + Option + Shift satisfies Ctrl + Option as well and
                // would quietly start the assistant when the user meant to dictate.
                return .pressed(modifierFlags.contains(.shift) ? .dictation : .assistant)
            }

            if !isPressedNow && wasPressed {
                // The caller remembers the mode chosen at press time, so adding
                // or dropping shift part-way through can't change modes mid-utterance.
                return .released(.assistant)
            }

            return .none

        case .modifiersWithSpace(let requiredModifiers):
            guard keyCode == pushToTalkKeyCode else { return .none }

            if eventKind == .keyDown
                && !wasPressed
                && modifierFlags.isSuperset(of: requiredModifiers) {
                return .pressed(modifierFlags.contains(.shift) ? .dictation : .assistant)
            }

            if eventKind == .keyUp && wasPressed {
                return .released(.assistant)
            }

            return .none
        }
    }
}
