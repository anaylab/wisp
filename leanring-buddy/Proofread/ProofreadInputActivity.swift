// Adapted from Sentient OS's ShortcutActivity (AGPL-3.0).
//
// Counts keystrokes, clicks and scrolls system-wide (counts only, never key values) so a
// proofread can tell whether the user touched anything while the model was working. If they
// did, the correction is no longer safe to paste over their selection.

import AppKit

struct ProofreadInputActivity: Equatable {
    var keyPresses: UInt32
    var clicks: UInt32
    var scrolls: UInt32

    static var current: Self {
        func count(_ eventType: CGEventType) -> UInt32 {
            CGEventSource.counterForEventType(.combinedSessionState, eventType: eventType)
        }
        return Self(
            keyPresses: count(.keyDown),
            clicks: count(.leftMouseDown) &+ count(.rightMouseDown) &+ count(.otherMouseDown),
            scrolls: count(.scrollWheel)
        )
    }
}
