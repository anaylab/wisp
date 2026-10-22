//
//  CompanionManager+ChromePageReading.swift
//  leanring-buddy
//
//  "Summarize this tab" / "what's the price on this page" in Chrome: the turn
//  sends the page's text, read by the Wisp Tabs extension, instead of the
//  screenshot (phase 02).
//
//  Why: encoding a screenshot costs the local model ~4s, and a screenshot only
//  holds what is on screen, read back from pixels. The page's text is cheaper,
//  reaches below the fold, and has prices and names exactly.
//
//  Every condition has to hold, and anything short of all of them keeps
//  today's screenshot turn: the question is about the page's content and not
//  its look (`ChromePageContentRequestClassifier`, biased toward no), the user
//  is in Chrome, the extension there is connected and may read pages, the read
//  comes back within a few seconds, and the page has enough words to be worth
//  reading (a web app or a video page is better seen).
//

import Foundation

extension CompanionManager {

    /// The page-text block to send in place of the screenshot, or nil to keep
    /// the screenshot. Records the choice in History and the perf log.
    func chromePageTextReplacingScreenshot(
        for transcript: String,
        isLocalModel: Bool,
        taskID: UUID
    ) async -> String? {
        guard ChromePageContentRequestClassifier.isAboutPageContent(transcript) else { return nil }
        // The app the user was in — not Wisp, which a typed question activates.
        guard let frontmostBundleIdentifier = FrontmostAppTracker.shared.lastExternalApplication?.bundleIdentifier,
              ChromePageReader.isConnectedExtension(inBrowserWithBundleIdentifier: frontmostBundleIdentifier),
              ChromePageReader.canReadPages else { return nil }

        let characterBudget = ChromePageTextPrompt.characterBudget(isLocalModel: isLocalModel)
        let readStartedAt = Date()
        let pageText: ChromePageText
        do {
            pageText = try await ChromePageReader.readPage(
                tabID: nil,
                maximumCharacters: characterBudget,
                timeoutSeconds: ChromePageReader.turnReadTimeoutSeconds
            )
        } catch {
            print("👁️ Chrome page text unavailable, keeping the screenshot — \(error.localizedDescription)")
            return nil
        }
        guard pageText.wordCount >= ChromePageTextPrompt.minimumWordsToReplaceScreenshot else {
            print("👁️ Chrome page has \(pageText.wordCount) words, keeping the screenshot")
            return nil
        }

        let readDurationSeconds = Date().timeIntervalSince(readStartedAt)
        PerfMetricsRecorder.shared.recordScreenshotDecision(didAttach: false)
        AgentTaskRegistry.shared.appendStep(
            AgentStepRecord(
                kind: .tool(name: "chrome"),
                summary: "Read the Chrome tab's text instead of a screenshot",
                detail: "\(pageText.wordCount) words\(pageText.truncated ? " (cut to fit)" : "") · \(pageText.url)",
                startedAt: readStartedAt,
                durationSeconds: readDurationSeconds
            ),
            to: taskID
        )
        print("👁️ Chrome page text used instead of the screenshot: \(pageText.wordCount) words in \(Int(readDurationSeconds * 1000))ms")
        return ChromePageTextPrompt.promptText(for: pageText, characterBudget: characterBudget)
    }
}
