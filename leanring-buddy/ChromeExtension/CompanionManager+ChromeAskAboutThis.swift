//
//  CompanionManager+ChromeAskAboutThis.swift
//  leanring-buddy
//
//  The turn side of "Ask Wisp about this" (phase 06): while a part of a Chrome
//  page is the subject (`ChromeAskAboutThisRouter.focusedPagePart`), each
//  question carries it — the selection's text, the downloaded image, the
//  link's words and address, or the page's text — and the part decides
//  whether the screenshot goes too (`ChromeAskAboutThisContext`).
//
//  Called once per turn from `sendTranscriptToClaudeWithScreenshot`, beside
//  the screen capture, so the reads and the download overlap it.
//

import Foundation

/// What a turn about a Chrome page part carries.
struct ChromeAskAboutThisTurnInput {
    let promptText: String
    let attachesScreenshot: Bool
    /// The downloaded image, sent after the screenshots.
    let images: [(data: Data, label: String)]
}

extension CompanionManager {

    /// The picture the local model is sent is capped like a screenshot, for
    /// the same reason: vision encoding is what a local turn waits on.
    private static let localModelImageEdgePixels: CGFloat = 896
    private static let cloudModelImageEdgePixels: CGFloat = 1568

    /// The context for this turn's question, or nil when no Chrome page part
    /// is the subject (the turn then goes on exactly as before).
    func chromeAskAboutThisTurnInput(
        for transcript: String,
        isLocalModel: Bool,
        questionRefersToScreen: Bool,
        taskID: UUID
    ) async -> ChromeAskAboutThisTurnInput? {
        guard let pagePart = ChromeAskAboutThisRouter.shared.focusedPagePart else { return nil }
        let characterBudget = ChromePageTextPrompt.characterBudget(isLocalModel: isLocalModel)
        let startedAt = Date()

        let turnPlan: ChromeAskAboutThisTurnPlan
        var images: [(data: Data, label: String)] = []
        var stepDetail = ""

        switch pagePart {
        case .selection(let selection):
            turnPlan = ChromeAskAboutThisContext.plan(forSelection: selection, question: transcript, characterBudget: characterBudget)
            stepDetail = "\(selection.selectedText.split(separator: " ").count) words · \(selection.url)"

        case .image(let tab, let imageURL, let imageURLWasCutOff):
            let imageData = await ChromeAskAboutThisRouter.shared.downloadedImageForModel(
                imageURL: imageURL,
                imageURLWasCutOff: imageURLWasCutOff,
                longestEdgePixels: isLocalModel ? Self.localModelImageEdgePixels : Self.cloudModelImageEdgePixels
            )
            if let imageData {
                images = [(data: imageData, label: ChromeAskAboutThisContext.downloadedImageLabel)]
            }
            turnPlan = ChromeAskAboutThisContext.plan(forImageURL: imageURL, tab: tab, wasDownloaded: imageData != nil)
            stepDetail = tab.pageURL

        case .link(let tab, let linkURL, let knownLinkText):
            var linkText = knownLinkText
            if linkText.isEmpty {
                linkText = await ChromeAskAboutThisRouter.shared.linkTextFromPage(linkURL: linkURL, tabID: tab.tabID)
                if !linkText.isEmpty {
                    ChromeAskAboutThisRouter.shared.updateFocusedPagePart(.link(tab, linkURL: linkURL, linkText: linkText))
                }
            }
            turnPlan = ChromeAskAboutThisContext.plan(forLinkURL: linkURL, linkText: linkText, tab: tab, question: transcript)
            stepDetail = linkURL

        case .page(let tab, let isFromAddressBar):
            var pageText: ChromePageText?
            if ChromeAskAboutThisContext.wantsPageText(isFromAddressBar: isFromAddressBar, question: transcript),
               ChromePageReader.canReadPages {
                do {
                    pageText = try await ChromePageReader.readPage(
                        tabID: tab.tabID,
                        maximumCharacters: characterBudget,
                        timeoutSeconds: ChromePageReader.turnReadTimeoutSeconds
                    )
                } catch {
                    print("🙋 Ask Wisp about this: couldn't read the page's text, using the screenshot — \(error.localizedDescription)")
                }
            }
            turnPlan = ChromeAskAboutThisContext.plan(
                forPageText: pageText,
                tab: tab,
                isFromAddressBar: isFromAddressBar,
                question: transcript,
                questionRefersToScreen: questionRefersToScreen,
                characterBudget: characterBudget
            )
            stepDetail = pageText.map { "\($0.wordCount) words\($0.truncated ? " (cut to fit)" : "") · \($0.url)" } ?? tab.pageURL
        }

        PerfMetricsRecorder.shared.recordScreenshotDecision(didAttach: turnPlan.attachesScreenshot)
        AgentTaskRegistry.shared.appendStep(
            AgentStepRecord(
                kind: .tool(name: "chrome"),
                summary: turnPlan.historyStepSummary,
                detail: stepDetail,
                startedAt: startedAt,
                durationSeconds: Date().timeIntervalSince(startedAt)
            ),
            to: taskID
        )
        return ChromeAskAboutThisTurnInput(
            promptText: turnPlan.promptText,
            attachesScreenshot: turnPlan.attachesScreenshot,
            images: images
        )
    }

    /// A short line in the notch for something that ran without a model turn
    /// (added to the brain, a selection that couldn't be read). Like other
    /// ambient updates, it doesn't talk over a turn in progress.
    func presentChromeAskAboutThisReply(_ replyText: String, didSucceed: Bool) {
        flashIsland(didSucceed ? .success : .error)
        guard voiceState == .idle else { return }
        currentReplyText = replyText
        scheduleTransientHideIfNeeded()
    }
}
