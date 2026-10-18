//
//  AutomationQuickAddRouter.swift
//  leanring-buddy
//
//  "Remind me tomorrow at 6 to submit the form", "every weekday at 8 tell me what's due",
//  "when a new Canvas item shows up, tell me": spoken, typed in the composer or typed in Today's
//  ask bar, they all reach `sendTranscriptToClaudeWithScreenshot`, which asks this router first.
//  A hit opens the editable draft card in the Automations page; nothing is saved or run until
//  the user presses Save. A miss returns false and the turn goes on to the model untouched.
//

import Foundation

@MainActor
enum AutomationQuickAddRouter {
    /// Returns true when the turn was consumed by opening the draft card.
    static func route(_ transcript: String, buddyStore: BuddyStore, now: Date) -> Bool {
        let buddyReferences = buddyStore.buddies.map { buddy in
            AutomationBuddyReference(id: buddy.id, name: buddy.name, specialty: buddy.specialty)
        }
        let decision = AutomationQuickAddPlanner.decide(
            transcript: transcript,
            now: now,
            calendar: .current,
            buddies: buddyReferences
        )
        guard case .openDraft(let draftToReview) = decision else { return false }

        WispWindowRouter.shared.presentAutomationDraft(draftToReview)
        WispWindowNavigator.open(.automations)
        return true
    }
}
