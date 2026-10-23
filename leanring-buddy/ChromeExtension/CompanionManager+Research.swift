//
//  CompanionManager+Research.swift
//  leanring-buddy
//
//  Research mode's notch line (phase 11). A run finishes in the background at a
//  moment of its own choosing, so — like a screen watch ending — its short
//  answer goes to the notch only while Wisp is idle, with "Open report" beside
//  it (NotchHUDView matches `notchLineForLatestReport` against the reply). The
//  full report is on the Chat page, with clickable citations.
//

import Foundation

extension CompanionManager {

    func configureResearchMode() {
        ResearchSessionController.shared.presentFinishedResearch = { [weak self] notchLine in
            self?.presentFinishedResearch(notchLine)
        }
    }

    private func presentFinishedResearch(_ notchLine: String) {
        flashIsland(.success)
        guard voiceState == .idle else { return }
        currentReplyText = notchLine
        scheduleTransientHideIfNeeded()
    }

    /// The notch's "Open report": the Chat page, scrolled to the report.
    func openLatestResearchReport() {
        guard let latestReport = ResearchSessionController.shared.reports.first else { return }
        ResearchSessionController.shared.reportIDToReveal = latestReport.id
        WispWindowNavigator.open(.chat)
    }
}
