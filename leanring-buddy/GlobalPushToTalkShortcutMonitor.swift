//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Watches the keyboard system-wide for Wisp's talk gestures. A listen-only
//  CGEvent tap is used instead of an AppKit global monitor because only the
//  tap reliably sees modifier-only chords such as ctrl + option while another
//  app is frontmost.
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

    private static let escapeKeyCode: UInt16 = 53
    private static let rightArrowKeyCode: UInt16 = 124
    private static let leftArrowKeyCode: UInt16 = 123

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

    // MARK: - Event tap lifecycle

    func start() {
        // Already tapping: leave it alone. Restarting would reset
        // isShortcutCurrentlyPressed and cut the listening overlay off mid-press
        // whenever the permission poller calls start() again.
        guard globalEventTap == nil else { return }

        let watchedEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let watchedEventMask = watchedEventTypes.reduce(CGEventMask(0)) { mask, eventType in
            mask | (CGEventMask(1) << eventType.rawValue)
        }

        // A C callback can't capture, so `self` travels through userInfo.
        let tapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }

            let monitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()
            return monitor.handleGlobalEventTap(eventType: eventType, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: watchedEventMask,
            callback: tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        globalEventTap = tap
        globalEventTapRunLoopSource = runLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        isShortcutCurrentlyPressed = false

        if let runLoopSource = globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            globalEventTapRunLoopSource = nil
        }

        if let tap = globalEventTap {
            CFMachPortInvalidate(tap)
            globalEventTap = nil
        }
    }

    // MARK: - Event handling

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // macOS switches a slow or interrupted tap off; turn it back on.
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let tap = globalEventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        upgradeToDictationIfShiftJoinedLate(eventType: eventType, event: event)

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        publishLayeredKeyGesture(
            eventType: eventType,
            keyCode: eventKeyCode,
            isAutorepeat: isAutorepeat
        )

        let transition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )
        applyHoldTransition(transition)

        detectHandsFreeDoubleTap(eventType: eventType, event: event)

        return Unmanaged.passUnretained(event)
    }

    /// Shift arriving a beat after Ctrl+Option is normal, not an edge case: the
    /// chord is already satisfied by then, so without this every dictation
    /// attempt would be treated as a question.
    private func upgradeToDictationIfShiftJoinedLate(eventType: CGEventType, event: CGEvent) {
        guard isShortcutCurrentlyPressed,
              eventType == .flagsChanged,
              activeInvocationMode == .assistant else { return }

        let secondsSincePress = Date().timeIntervalSince(shortcutPressedAt)
        guard secondsSincePress < BuddyPushToTalkShortcut.invocationModeSettlingWindow else { return }

        let heldModifiers = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        guard heldModifiers.contains(.shift) else { return }

        activeInvocationMode = .dictation
        shortcutTransitionPublisher.send(.modeChanged(.dictation))
    }

    /// The keys that mean something on top of the held Talk chord (a routine
    /// digit, the arrows, the Ask / Save / radial letters), plus Escape, which
    /// is global. A gesture that fires marks the hold as consumed, so its
    /// release does nothing of its own.
    private func publishLayeredKeyGesture(eventType: CGEventType, keyCode: UInt16, isAutorepeat: Bool) {
        guard eventType == .keyDown else { return }

        // Escape works everywhere, chord or not, and is never swallowed.
        if keyCode == Self.escapeKeyCode && !isAutorepeat {
            escapeKeyPublisher.send()
        }

        guard isShortcutCurrentlyPressed, activeInvocationMode == .assistant else { return }

        // Arrows step through a worked solution; holding one keeps revealing,
        // so autorepeat is allowed for them only.
        if keyCode == Self.rightArrowKeyCode || keyCode == Self.leftArrowKeyCode {
            didFireRoutineShortcutDuringCurrentHold = true
            noteStepShortcutPublisher.send(keyCode == Self.rightArrowKeyCode ? 1 : -1)
            return
        }

        guard !isAutorepeat else { return }

        if let routineDigit = Self.digitByKeyCode[keyCode] {
            didFireRoutineShortcutDuringCurrentHold = true
            routineShortcutPublisher.send(routineDigit)
        } else if keyCode == Self.askAboutPartKeyCode {
            didFireRoutineShortcutDuringCurrentHold = true
            askAboutPartShortcutPublisher.send()
        } else if keyCode == Self.saveWorkedSolutionKeyCode {
            // If Save and Ask are bound to the same letter, Ask keeps it (checked above).
            didFireRoutineShortcutDuringCurrentHold = true
            saveWorkedSolutionShortcutPublisher.send()
        } else if keyCode == Self.radialMenuKeyCode {
            // A letter already bound to Ask or Save stays theirs (checked above).
            didFireRoutineShortcutDuringCurrentHold = true
            radialMenuShortcutPublisher.send()
        }
    }

    private func applyHoldTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .none, .modeChanged, .tapped, .doubleTapped:
            // The matcher only produces none/pressed/released. Mode changes come
            // from the late-shift check, and taps from the duration test below
            // and the double-tap recogniser.
            break

        case .pressed(let mode):
            isShortcutCurrentlyPressed = true
            didFireRoutineShortcutDuringCurrentHold = false
            activeInvocationMode = mode
            shortcutPressedAt = Date()
            shortcutTransitionPublisher.send(.pressed(mode))

        case .released:
            isShortcutCurrentlyPressed = false

            // A layered gesture fired during this hold and already tidied up the
            // recording it started, so the release has nothing left to do.
            if didFireRoutineShortcutDuringCurrentHold {
                didFireRoutineShortcutDuringCurrentHold = false
                return
            }

            // A quick press of the assistant chord opens the text composer rather
            // than sending a nearly empty spoken turn. Dictate never taps to type.
            let heldSeconds = Date().timeIntervalSince(shortcutPressedAt)
            let wasTap = activeInvocationMode == .assistant
                && heldSeconds < BuddyPushToTalkShortcut.tapMaxDuration
            shortcutTransitionPublisher.send(wasTap ? .tapped(.textComposer) : .released(activeInvocationMode))
        }
    }

    // MARK: - Hands-free double tap

    /// Recognises two quick taps of the configured bare modifier and publishes
    /// `.doubleTapped(.handsFreeDictate)`. A tap is that modifier going down and
    /// up alone, briefly. If any other modifier joins while it is down the tap
    /// is void, which is what keeps this from firing inside the hold chord
    /// (that chord always has a second modifier).
    private func detectHandsFreeDoubleTap(eventType: CGEventType, event: CGEvent) {
        guard eventType == .flagsChanged,
              let tappedModifier = BuddyPushToTalkShortcut.handsFreeDoubleTapModifier else { return }

        let modifiersOfInterest: NSEvent.ModifierFlags = [.control, .option, .command, .shift, .function]
        let heldModifiers = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            .intersection(modifiersOfInterest)

        let isDownNow = heldModifiers.contains(tappedModifier)
        let isAloneNow = heldModifiers == tappedModifier
        let wasDownBefore = handsFreeModifierWasDown
        defer { handsFreeModifierWasDown = isDownNow }

        if isDownNow && !wasDownBefore {
            // Just pressed: a candidate tap only if nothing else is held with it.
            handsFreeTapCandidateActive = isAloneNow
            if isAloneNow { handsFreeTapCandidateStartedAt = Date() }
            return
        }

        if isDownNow && wasDownBefore && !isAloneNow {
            // Another modifier joined: not a bare tap any more.
            handsFreeTapCandidateActive = false
            return
        }

        guard !isDownNow, wasDownBefore, handsFreeTapCandidateActive else { return }
        handsFreeTapCandidateActive = false

        // Just released: the tap completes if it was short enough.
        let releasedAt = Date()
        let tapSeconds = releasedAt.timeIntervalSince(handsFreeTapCandidateStartedAt)
        guard tapSeconds <= BuddyPushToTalkShortcut.doubleTapMaxTapDuration else { return }

        let secondsSinceLastTap = releasedAt.timeIntervalSince(handsFreeLastTapAt)
        if secondsSinceLastTap <= BuddyPushToTalkShortcut.doubleTapBetweenTapsInterval {
            handsFreeLastTapAt = .distantPast
            shortcutTransitionPublisher.send(.doubleTapped(.handsFreeDictate))
        } else {
            handsFreeLastTapAt = releasedAt
        }
    }
}
