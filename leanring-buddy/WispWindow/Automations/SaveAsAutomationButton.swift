//
//  SaveAsAutomationButton.swift
//  leanring-buddy
//
//  "Teach by example": turns a question the user already asked (a History answer) into an
//  automation draft. The question becomes the instruction; when it should run is left for the
//  user to pick, so nothing starts repeating by accident. Routine, skill, buddy and dictation
//  runs are labels rather than questions, so the button hides for them.
//

import SwiftUI

struct SaveAsAutomationButton: View {
    let taskRecord: AgentTaskRecord

    var body: some View {
        if taskRecord.isUsersOwnQuestion {
            Button {
                let draftFromQuestion = AutomationDraft.fromAnswerRecord(originalQuestion: taskRecord.title)
                WispWindowRouter.shared.presentAutomationDraft(draftFromQuestion)
                WispWindowNavigator.open(.automations)
            } label: {
                Label("Save as automation", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(WispPillButtonStyle(isProminent: false))
            .controlSize(.small)
            .pointerCursor()
        }
    }
}
