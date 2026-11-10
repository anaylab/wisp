// Adapted from Sentient OS's DoubleTap controller (AGPL-3.0).
//
// The run behind ⌃⌥D: with the cursor in a reply box, Wisp screenshots the display under the
// pointer, asks the local vision model for a reply in the user's voice, and pastes it into the
// focused field as an unsent draft. A screenshot that isn't an email or message reply box pastes
// nothing. The paste is ordinary pasteboard + ⌘V (a typed Return would SEND in most chat apps),
// and the user's clipboard is put back afterwards.
//
// Not ported from the original: the caret light, the knowledge-base vault and writing-style
// samples, other providers, and the right-⌘ double-tap gesture itself.

import AppKit
import Observation

@MainActor @Observable
final class DoubleTap {
    static let shared = DoubleTap()

    enum Result { case pasted, notAMessage, stopped, failed(String) }

    private var task: Task<Void, Never>?
    private static let deadline: Duration = .seconds(60)

    /// Apps where a reply box is plausible: messaging, email and browsers (webmail, web chat).
    /// The small local model cannot reliably tell a reply box from, say, a document, so the
    /// check starts with the app. TextEdit, editors and terminals never get a pasted draft.
    static let replyCapableBundleIdentifiers: Set<String> = [
        "com.apple.MobileSMS", "com.apple.mail", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram",
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.microsoft.Outlook", "com.microsoft.teams2",
        "com.readdle.smartemail-Mac", "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
        "com.microsoft.edgemac", "org.mozilla.firefox", "com.brave.Browser", "company.thebrowser.dia",
    ]

    /// True from the shortcut until the paste has settled. A second press meanwhile is ignored.
    var isDrafting: Bool { task != nil }

    /// Runs once. `completion` arrives on the main actor exactly once.
    func start(completion: @escaping @MainActor (Result) -> Void) {
        guard !isDrafting, !Proofread.shared.isRunning else { return }
        // Read the frontmost app now, before anything of ours can take focus.
        let frontmostProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        let work = Task { [weak self] in
            guard let self else { return }
            let result = await self.perform(frontmostProcessID: frontmostProcessID)
            self.task = nil
            completion(result)
        }
        task = work

        Task {
            try? await Task.sleep(for: Self.deadline)
            if !work.isCancelled, self.task != nil { work.cancel() }
        }
    }

    func cancel() { task?.cancel() }

    private func perform(frontmostProcessID: pid_t?) async -> Result {
        guard AXIsProcessTrusted() else { return .failed("Wisp needs Accessibility to paste a draft.") }
        guard let frontmostProcessID else { return .stopped }
        let frontmostBundleIdentifier = NSRunningApplication(processIdentifier: frontmostProcessID)?.bundleIdentifier ?? ""
        guard Self.replyCapableBundleIdentifiers.contains(frontmostBundleIdentifier) else {
            return .failed("Draft Reply only works in messaging, email and browser apps.")
        }

        let captures: [CompanionScreenCapture]
        do { captures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG() }
        catch { return .failed("Wisp couldn’t capture the screen. Check Screen Recording permission.") }
        guard let capture = captures.first(where: { $0.isCursorScreen }) ?? captures.first else { return .stopped }
        if Task.isCancelled { return .stopped }

        do {
            let aboutTheUser = MemoryStore.shared.promptInstructions()
            let verdict = try await DoubleTapInference.draft(screenshotJPEG: capture.imageData, aboutTheUser: aboutTheUser)
            if Task.isCancelled { return .stopped }
            switch verdict {
            case .notAMessage:
                return .notAMessage
            case .reply(let replyText):
                // The user must still be in the same app, or the paste would land somewhere else.
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmostProcessID else { return .stopped }
                return await Self.paste(replyText) ? .pasted : .failed("Wisp couldn’t paste the draft.")
            }
        } catch is CancellationError {
            return .stopped
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? "Couldn’t draft a reply.")
        }
    }

    /// Pasteboard + one ⌘V, then the user's previous clipboard is restored if nothing else changed it.
    private static func paste(_ text: String) async -> Bool {
        guard let clipboard = ProofreadClipboard.capture() else { return false }
        let pasteboard = NSPasteboard.general
        let source = CGEventSource(stateID: .combinedSessionState)
        let virtualKeyForV: CGKeyCode = 9
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyForV, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyForV, keyDown: false) else { return false }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            clipboard.restore(ifOwned: pasteboard.changeCount)
            return false
        }
        let ownedChangeCount = pasteboard.changeCount
        for event in [keyDown, keyUp] {
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
        // Give the target app time to read the clipboard before it is put back.
        try? await Task.sleep(for: .milliseconds(500))
        clipboard.restore(ifOwned: ownedChangeCount)
        return true
    }
}
