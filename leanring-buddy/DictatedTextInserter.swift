//
//  DictatedTextInserter.swift
//  leanring-buddy
//
//  Puts dictated text into whatever field currently has focus.
//
//  There is no single way to do this that works everywhere, so there are two,
//  tried in order.
//
//  Accessibility first: set the focused element's selected text. This is the
//  clean route — it inserts at the caret, replaces a selection if there is one,
//  and touches nothing else. Native Cocoa text fields support it well.
//
//  Pasting second: put the text on the clipboard and synthesise Command-V.
//  This works essentially everywhere, including the Electron apps and web views
//  where the accessibility route silently does nothing.
//
//  It leaves the dictated text on the clipboard, deliberately. The obvious
//  refinement is to save the previous contents and restore them shortly after
//  pasting, and that was tried and removed: restoring races the target app's
//  read of the clipboard, and the race is not monotonic in the delay. Measured
//  against TextEdit, restoring after 400ms and 1200ms both worked while 800ms
//  silently lost the paste entirely. No fixed delay is safe, and the failure
//  mode is the user's dictated sentence vanishing — much worse than their
//  clipboard holding what they just said. Since the accessibility path handles
//  native fields without touching the clipboard at all, this cost is confined
//  to the apps that genuinely need pasting.
//

import AppKit
import ApplicationServices

@MainActor
enum DictatedTextInserter {
    enum InsertionMethod: Sendable {
        case accessibility
        case paste
        case failed
    }

    /// Inserts `text` at the caret in the frontmost app.
    @discardableResult
    static func insert(_ text: String) -> InsertionMethod {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed }

        if insertViaAccessibility(trimmed) {
            return .accessibility
        }
        if insertViaPaste(trimmed) {
            return .paste
        }
        return .failed
    }

    // MARK: - Accessibility

    private static func insertViaAccessibility(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement
        ) == .success, let element = focusedElement else { return false }

        let focused = element as! AXUIElement

        // Only attempt this on something that actually accepts text. Writing
        // selected text into a button or a list does nothing useful and, worse,
        // can report success.
        var isSettable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(
            focused, kAXSelectedTextAttribute as CFString, &isSettable
        ) == .success, isSettable.boolValue else { return false }

        return AXUIElementSetAttributeValue(
            focused, kAXSelectedTextAttribute as CFString, text as CFTypeRef
        ) == .success
    }

    // MARK: - Paste

    private static func insertViaPaste(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return synthesizeCommandV()
    }

    /// Synthesises Command-V into the frontmost app.
    private static func synthesizeCommandV() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }

        let virtualKeyV: CGKeyCode = 9
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyV, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyV, keyDown: false)
        else { return false }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        // Posted to the HID tap so the frontmost app receives it as a real
        // keystroke; a session-level post is not delivered to every app.
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Context

    /// The app text will land in, for the dashboard and for confirmation.
    static func frontmostApplicationName() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "the frontmost app"
    }
}
