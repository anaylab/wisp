//
//  CompanionManager+ChromePageWatch.swift
//  leanring-buddy
//
//  Where a spoken "tell me when …" goes once `ScreenWatchRequestParser` has
//  recognised it (phase 08): the Chrome tab the user is in, or the screen
//  (`ChromePageWatchRouter` decides), and "stop watching" stops both kinds.
//  Also where a page watch's ending is shown, the same way a screen watch's is.
//
//  Kept out of CompanionManager.swift, which only asks for the reply here, so
//  the shared file stays easy to merge.
//

import Foundation

extension CompanionManager {
    /// What a watch request did, for the notch, History and speech.
    struct DirectWatchReply {
        let replyText: String
        let didSucceed: Bool
        let historySummary: String
    }

    /// Starts or stops the watch a spoken request asked for and says how it went.
    func directWatchReply(for screenWatchRequest: ScreenWatchRequest, transcript: String) async -> DirectWatchReply {
        let watchRoute = ChromePageWatchRouter.route(
            for: screenWatchRequest,
            transcript: transcript,
            isChromeInFrontWithExtension: ChromePageWatchStore.isChromeInFrontWithExtension,
            canReadPagesInChrome: ChromePageReader.canReadPages
        )

        switch watchRoute {
        case .watchScreen(let condition):
            switch ScreenWatcherStore.shared.startWatching(condition) {
            case .started:
                return DirectWatchReply(
                    replyText: "okay — i'll watch your screen and tell you when \(condition.summaryText).",
                    didSucceed: true,
                    historySummary: "Screen watch — no model call"
                )
            case .alreadyWatching:
                return DirectWatchReply(replyText: "i'm already watching for \(condition.summaryText).", didSucceed: true, historySummary: "Screen watch — no model call")
            case .tooManyWatchers:
                let replyText = "i'm already watching \(ScreenWatcherStore.maximumActiveWatcherCount) things — say \"stop watching\" first."
                return DirectWatchReply(replyText: replyText, didSucceed: false, historySummary: "Screen watch: \(replyText)")
            }

        case .watchChromeTab(let condition, let reloadEveryMinutes):
            do {
                switch try await ChromePageWatchStore.shared.startWatching(condition, reloadEveryMinutes: reloadEveryMinutes) {
                case .started(let startedWatch):
                    return DirectWatchReply(
                        replyText: ChromePageWatchWording.startedReply(for: startedWatch),
                        didSucceed: true,
                        historySummary: "Chrome page watch on \(startedWatch.tabDisplayName) — no model call"
                    )
                case .alreadyWatching:
                    return DirectWatchReply(replyText: "i'm already watching this tab for \(condition.summaryText).", didSucceed: true, historySummary: "Chrome page watch — no model call")
                case .tooManyWatches:
                    let replyText = "i'm already watching \(ChromePageWatchStore.maximumActiveWatchCount) tabs — say \"stop watching\" first."
                    return DirectWatchReply(replyText: replyText, didSucceed: false, historySummary: "Chrome page watch: \(replyText)")
                }
            } catch {
                let replyText = error.localizedDescription
                return DirectWatchReply(replyText: replyText, didSucceed: false, historySummary: "Chrome page watch: \(replyText)")
            }

        case .stopAllWatching:
            let stoppedWatchCount = ScreenWatcherStore.shared.stopAllWatching() + ChromePageWatchStore.shared.stopAllWatching()
            let replyText: String
            switch stoppedWatchCount {
            case 0: replyText = "i wasn't watching anything."
            case 1: replyText = "okay, i stopped watching."
            default: replyText = "okay, i stopped all \(stoppedWatchCount) watches."
            }
            return DirectWatchReply(replyText: replyText, didSucceed: true, historySummary: "Stopped watching — no model call")
        }
    }

    /// Called once from `start()`: page watches end in the notch, like screen watches.
    func configureChromePageWatchers() {
        ChromePageWatchStore.shared.onWatchEnded = { [weak self] endedWatch, ending in
            self?.presentChromePageWatchEnding(endedWatch, ending: ending)
        }
        ChromePageWatchStore.shared.start()
    }

    /// A page watch ended on its own: flash the island (success plays the cue)
    /// and — only while Wisp is idle, so a turn in progress is never talked over
    /// — show the line in the notch and say it in voice mode. The store posts
    /// the system notification either way.
    private func presentChromePageWatchEnding(_ endedWatch: ActiveChromePageWatch, ending: ChromePageWatchEnding) {
        flashIsland(ending.isConditionMet ? .success : .error)
        guard voiceState == .idle else { return }
        let endingMessage = ChromePageWatchWording.endingMessage(for: endedWatch, ending: ending)
        currentReplyText = endingMessage
        if VoiceOutputPreference.shared.isReplySpeechEnabled {
            speakAutomationLine(endingMessage)
        }
    }
}
