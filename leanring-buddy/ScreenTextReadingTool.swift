//
//  ScreenTextReadingTool.swift
//  leanring-buddy
//
//  The `read_screen_text` agent tool: the text on the user's screen right now,
//  read by on-device OCR. For "copy that error", "what does this say", "read
//  me the address in that window" — requests where the answer is the exact
//  text, which the small vision model paraphrases or misreads.
//
//  Read-only and local: it captures the screen the same way a turn does
//  (which, for an unchanged screen, reuses the turn's frame and therefore its
//  already-finished recognition) and returns plain text. No ids or boxes —
//  pointing uses the turn's own snapshot, and ids from a second, separate
//  snapshot would not match it.
//

import Foundation

extension AgentToolRegistry {
    /// Most lines returned. Larger than the per-turn prompt cap because the
    /// user asked for the text itself, but still bounded: the result goes back
    /// into a context window shared with a screenshot.
    static let readScreenTextMaximumLineCount = 150
    /// Most characters of text returned, across all lines.
    static let readScreenTextMaximumCharacterCount = 4000

    func registerScreenTextTools() {
        register(
            BuddyToolDefinition(
                name: "read_screen_text",
                description: "Read the exact text currently visible on the user's screen, using on-device text recognition. Use when the user wants the precise words on screen — to copy an error, quote a message, or ask what something says.",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
                metadata: .reading(.localMachine)
            )
        ) { _ in
            let screenCaptures: [CompanionScreenCapture]
            do {
                screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            } catch {
                return "couldn't capture the screen to read it (\(error.localizedDescription)). screen recording permission may be off."
            }

            guard let screenTextSnapshot = await ScreenTextRecognizer.shared.snapshot(
                for: screenCaptures,
                waitingAtMost: ScreenTextRecognizer.toolWaitBudgetSeconds,
                maximumLineCount: Self.readScreenTextMaximumLineCount,
                maximumCharacterCount: Self.readScreenTextMaximumCharacterCount
            ) else {
                return "no readable text was found on screen."
            }

            let returnedLineCount = screenTextSnapshot.entries.count
            var toolResultText = screenTextSnapshot.plainText()
            if returnedLineCount >= Self.readScreenTextMaximumLineCount {
                toolResultText += "\n…(truncated at \(returnedLineCount) lines)"
            }
            return toolResultText
        }
    }
}
