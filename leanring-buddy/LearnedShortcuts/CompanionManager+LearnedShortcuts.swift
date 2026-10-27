//
//  CompanionManager+LearnedShortcuts.swift
//  leanring-buddy
//
//  Glue: after a user's own agent turn, hold an offer to save it as a learned shortcut, and save
//  it when they click the notch's "Save as shortcut" button (nothing is saved without the user's
//  click on the save card); and find the shortcut a request matches for replay (the replay itself
//  is `runLearnedShortcut` in CompanionManager.swift, which needs the manager's private state).
//

import Foundation

extension CompanionManager {
    /// Called once an agent turn has finished. `historyTitle` is non-nil for routine, skill and
    /// dictation turns, whose prompt isn't the user's own words.
    func holdLearnedShortcutOfferIfPossible(
        transcript: String,
        historyTitle: String?,
        agentOutcome: AgentTurnRunner.Outcome
    ) {
        let phraseTemplatesAlreadySaved = Set(
            LearnedShortcutStore.shared.shortcuts.compactMap { $0.parsedPhraseTemplate?.canonicalText }
        )
        learnedShortcutOffer = LearnedShortcutOfferPolicy.offer(
            transcript: transcript,
            isUsersOwnQuestion: historyTitle == nil,
            hitIterationCap: agentOutcome.hitIterationCap,
            toolCalls: agentOutcome.executedToolCalls,
            existingPhraseTemplates: phraseTemplatesAlreadySaved
        )
    }

    /// The learned shortcut a request is, if replay is switched on in Settings → Agent. Apps named
    /// in a blank must be exactly one running app, as for the window-layout commands.
    func matchLearnedShortcutForReplay(transcript: String) -> LearnedShortcutMatchResult {
        guard LearnedShortcutPreference.shared.isReplayEnabled else { return .noMatch }
        let runningApplicationNames = WindowLayoutExecutor.runningApplicationNamesForMatching()
        return LearnedShortcutStore.shared.match(
            transcript: transcript,
            applicationNameResolver: { spokenApplicationName in
                WindowLayoutApplicationNameMatcher.uniqueApplicationName(
                    matching: spokenApplicationName,
                    among: runningApplicationNames
                )
            }
        )
    }

    /// Shows the save card for the held offer. True only if a shortcut was saved.
    @discardableResult
    func saveLearnedShortcutFromOffer() -> Bool {
        guard let offer = learnedShortcutOffer,
              let shortcutToSave = LearnedShortcutSaveCard.ask(for: offer) else { return false }

        switch LearnedShortcutStore.shared.add(shortcutToSave) {
        case .added:
            learnedShortcutOffer = nil
            flashIsland(.success)
            return true
        case .duplicatePhrase:
            LearnedShortcutSaveCard.showNotice("You already have a shortcut for that phrase.")
        case .invalidShortcut:
            LearnedShortcutSaveCard.showNotice("That phrase can't be saved as a shortcut.")
        case .tooManyShortcuts:
            LearnedShortcutSaveCard.showNotice("You have the most shortcuts Wisp keeps. Delete one first.")
        }
        return false
    }
}
