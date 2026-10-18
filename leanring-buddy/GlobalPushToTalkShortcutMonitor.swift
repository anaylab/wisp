//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while Wisp is running in the
//  background. Uses a listen-only CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()

    /// Fires the digit (1–9) when a number key is pressed while the Talk chord is
    /// held — ⌃⌥1 runs routine 1. Separate from `shortcutTransitionPublisher`
    /// because it is an extra gesture layered on the hold, not a hold state.
    let routineShortcutPublisher = PassthroughSubject<Int, Never>()

    /// Fires on every Escape key press (not auto-repeat), whichever app has it.
    /// Wisp uses it to clear its drawings; the event is never consumed.
    let escapeKeyPublisher = PassthroughSubject<Void, Never>()

    /// Steps through a worked solution: +1 for Right Arrow, -1 for Left Arrow
    /// while the Talk chord is held (⌃⌥→ / ⌃⌥←). Another gesture layered on the hold.
    let noteStepShortcutPublisher = PassthroughSubject<Int, Never>()

    /// Fires when A is pressed while the Talk chord is held — ⌃⌥A is "Ask About
    /// a Part". Like a routine digit, an extra gesture layered on the hold.
    let askAboutPartShortcutPublisher = PassthroughSubject<Void, Never>()

    /// Fires when S is pressed while the Talk chord is held — ⌃⌥S is "Save
    /// Worked Solution". Another gesture layered on the hold.
    let saveWorkedSolutionShortcutPublisher = PassthroughSubject<Void, Never>()

    /// Fires when R is pressed while the Talk chord is held — ⌃⌥R opens the radial
    /// quick menu around the pointer. Another gesture layered on the hold.
    let radialMenuShortcutPublisher = PassthroughSubject<Void, Never>()

    /// The key pressed with the Talk chord for the radial quick menu (ANSI R).
    nonisolated(unsafe) static var radialMenuKeyCode: UInt16 = 15

    /// The key pressed with the Talk chord for "Save Worked Solution" (ANSI key
    /// code; S by default). Kept current by `ShortcutBindingStore`.
    nonisolated(unsafe) static var saveWorkedSolutionKeyCode: UInt16 = 1

    /// The key pressed with the Talk chord for "Ask About a Part" (ANSI key code;
    /// A by default). A plain static like the other bindings the tap reads on the
    /// main thread; `ShortcutBindingStore` keeps it current.
    nonisolated(unsafe) static var askAboutPartKeyCode: UInt16 = 0

    /// Set when a routine digit fires during the current hold. The hold's own
    /// release is then swallowed: the routine replaced whatever the hold would
    /// have become (a spoken turn or the tap-to-type composer).
    private var didFireRoutineShortcutDuringCurrentHold = false

    /// ANSI key codes for the number row, 1 through 9.
    private static let digitByKeyCode: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
    ]

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false

    /// Which mode the current hold started in.
    ///
    /// Remembered rather than re-derived on release: the user lifts shift and
    /// control at slightly different moments, so the flags at release time do
    /// not reliably say what they meant when they started speaking.
    private var activeInvocationMode: BuddyPushToTalkShortcut.InvocationMode = .assistant

    /// When the current hold began, for the mode-settling window.
    private var shortcutPressedAt = Date.distantPast

    // MARK: - Hands-free double-tap detection
    //
    // A separate, additive recogniser for double-tapping a bare modifier (e.g.
    // Control twice). It is deliberately independent of the hold path above: the
    // hold chord requires a second modifier, so a bare-modifier tap can never be
    // confused with it, and vice-versa.
    private var handsFreeModifierWasDown = false
    private var handsFreeTapCandidateActive = false
    private var handsFreeTapCandidateStartedAt = Date.distantPast
    private var handsFreeLastTapAt = Date.distantPast

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        isShortcutCurrentlyPressed = false

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Shift arriving a moment after Ctrl+Option is the normal case, not an
        // edge case: the chord is already satisfied by then, so without this
        // every dictation attempt is read as a question.
        if isShortcutCurrentlyPressed,
           eventType == .flagsChanged,
           activeInvocationMode == .assistant,
           Date().timeIntervalSince(shortcutPressedAt) < BuddyPushToTalkShortcut.invocationModeSettlingWindow,
           NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)).contains(.shift) {
            activeInvocationMode = .dictation
            shortcutTransitionPublisher.send(.modeChanged(.dictation))
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        // A number key while the Talk chord is held runs that routine. Key
        // repeat is ignored so holding the digit doesn't fire it again.
        if isShortcutCurrentlyPressed,
           activeInvocationMode == .assistant,
           eventType == .keyDown,
           event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
           let routineDigit = Self.digitByKeyCode[eventKeyCode] {
            didFireRoutineShortcutDuringCurrentHold = true
            routineShortcutPublisher.send(routineDigit)
        }

        // 53 is Escape.
        if eventType == .keyDown,
           eventKeyCode == 53,
           event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            escapeKeyPublisher.send()
        }

        // Right (124) and Left (123) arrow with the Talk chord held step through
        // a worked solution. Auto-repeat is allowed so holding the key keeps
        // revealing.
        if isShortcutCurrentlyPressed,
           activeInvocationMode == .assistant,
           eventType == .keyDown,
           eventKeyCode == 124 || eventKeyCode == 123 {
            didFireRoutineShortcutDuringCurrentHold = true
            noteStepShortcutPublisher.send(eventKeyCode == 124 ? 1 : -1)
        }

        if isShortcutCurrentlyPressed,
           activeInvocationMode == .assistant,
           eventType == .keyDown,
           event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
           eventKeyCode == Self.askAboutPartKeyCode {
            didFireRoutineShortcutDuringCurrentHold = true
            askAboutPartShortcutPublisher.send()
        }

        if isShortcutCurrentlyPressed,
           activeInvocationMode == .assistant,
           eventType == .keyDown,
           event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
           eventKeyCode == Self.saveWorkedSolutionKeyCode,
           // If both were bound to one letter, Ask About a Part (above) keeps it.
           Self.saveWorkedSolutionKeyCode != Self.askAboutPartKeyCode {
            didFireRoutineShortcutDuringCurrentHold = true
            saveWorkedSolutionShortcutPublisher.send()
        }

        if isShortcutCurrentlyPressed,
           activeInvocationMode == .assistant,
           eventType == .keyDown,
           event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
           eventKeyCode == Self.radialMenuKeyCode,
           // A letter someone bound to another gesture keeps that gesture.
           Self.radialMenuKeyCode != Self.askAboutPartKeyCode,
           Self.radialMenuKeyCode != Self.saveWorkedSolutionKeyCode {
            didFireRoutineShortcutDuringCurrentHold = true
            radialMenuShortcutPublisher.send()
        }

        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed(let mode):
            isShortcutCurrentlyPressed = true
            didFireRoutineShortcutDuringCurrentHold = false
            activeInvocationMode = mode
            shortcutPressedAt = Date()
            shortcutTransitionPublisher.send(.pressed(mode))
        case .modeChanged:
            // Raised by the settling check above, not by the matcher.
            break
        case .released:
            isShortcutCurrentlyPressed = false
            // The routine that fired mid-hold already cleaned up the recording
            // this hold started, so the release has nothing left to do.
            if didFireRoutineShortcutDuringCurrentHold {
                didFireRoutineShortcutDuringCurrentHold = false
                break
            }
            // A quick tap of the Talk chord opens the text composer instead of
            // submitting a (near-empty) spoken turn. Only the assistant chord
            // taps to type; a short Dictate press falls through to release.
            let holdDuration = Date().timeIntervalSince(shortcutPressedAt)
            if activeInvocationMode == .assistant && holdDuration < BuddyPushToTalkShortcut.tapMaxDuration {
                shortcutTransitionPublisher.send(.tapped(.textComposer))
            } else {
                shortcutTransitionPublisher.send(.released(activeInvocationMode))
            }
        case .tapped, .doubleTapped:
            // The hold matcher never produces these; the tap-duration check above
            // and the double-tap recogniser below do. Nothing to do here.
            break
        }

        detectHandsFreeDoubleTap(eventType: eventType, event: event)

        return Unmanaged.passUnretained(event)
    }

    /// Recognises a double-tap of the configured bare modifier and publishes a
    /// `.doubleTapped(.handsFreeDictate)` transition. A "tap" is the modifier
    /// pressed and released on its own, quickly; two taps within the interval are
    /// a double-tap. If any other modifier joins while ours is held, the tap is
    /// cancelled — which is exactly what keeps this from firing during a hold
    /// chord (that chord always includes a second modifier).
    private func detectHandsFreeDoubleTap(eventType: CGEventType, event: CGEvent) {
        guard eventType == .flagsChanged,
              let handsFreeModifier = BuddyPushToTalkShortcut.handsFreeDoubleTapModifier else {
            return
        }

        let relevantModifiers: NSEvent.ModifierFlags = [.control, .option, .command, .shift, .function]
        let currentFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            .intersection(relevantModifiers)
        let modifierIsDown = currentFlags.contains(handsFreeModifier)
        let onlyThatModifierIsDown = (currentFlags == handsFreeModifier)

        // A second modifier joined while ours was held — no longer a bare tap.
        if modifierIsDown && handsFreeModifierWasDown && !onlyThatModifierIsDown {
            handsFreeTapCandidateActive = false
        }

        // Modifier just pressed.
        if modifierIsDown && !handsFreeModifierWasDown {
            if onlyThatModifierIsDown {
                handsFreeTapCandidateActive = true
                handsFreeTapCandidateStartedAt = Date()
            } else {
                handsFreeTapCandidateActive = false
            }
        }

        // Modifier just released — a tap completes here.
        if !modifierIsDown && handsFreeModifierWasDown && handsFreeTapCandidateActive {
            let now = Date()
            let tapDuration = now.timeIntervalSince(handsFreeTapCandidateStartedAt)
            if tapDuration <= BuddyPushToTalkShortcut.doubleTapMaxTapDuration {
                if now.timeIntervalSince(handsFreeLastTapAt) <= BuddyPushToTalkShortcut.doubleTapBetweenTapsInterval {
                    // Second quick tap — this is the double-tap.
                    handsFreeLastTapAt = .distantPast
                    shortcutTransitionPublisher.send(.doubleTapped(.handsFreeDictate))
                } else {
                    // First tap; wait to see if a second one follows.
                    handsFreeLastTapAt = now
                }
            }
            handsFreeTapCandidateActive = false
        }

        handsFreeModifierWasDown = modifierIsDown
    }
}
