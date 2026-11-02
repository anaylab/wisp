//
//  WispDemoSeed.swift
//  leanring-buddy
//
//  Fills an empty demo folder with the sample day (`WispDemoSampleData`), once:
//  the starter buddies with their chats, the Briefer handing its brief to the
//  Writer, a few automations and a few recent answers. It goes through the
//  stores' own methods, so the files are exactly what the app writes itself.
//  `scripts/demo.sh --reset` deletes the folder to start over.
//

import Foundation

@MainActor
enum WispDemoSeed {
    private static var seededMarkerURL: URL {
        WispDemoMode.demoHomeURL.appendingPathComponent(".demo-seeded")
    }

    static func seedIfNeeded(now: Date = Date()) {
        guard WispDemoMode.isOn,
              !FileManager.default.fileExists(atPath: seededMarkerURL.path) else { return }

        let buddyStore = BuddyStore.shared
        buddyStore.ensureStarterBuddies(
            userDefaults: UserDefaults(suiteName: WispDemoMode.demoUserDefaultsSuiteName) ?? .standard
        )
        func starter(_ kind: StarterBuddyKind) -> WispBuddy? {
            buddyStore.buddies.first { $0.starterKind == kind }
        }

        let threadStore = BuddyThreadStore.shared
        func addExchange(to buddy: WispBuddy?, at startedAt: Date, origin: BuddyThreadExchange.Origin,
                         question: String, answer: String, requesterName: String? = nil) {
            guard let buddy else { return }
            let taskID = UUID()
            threadStore.beginExchange(forBuddyWithID: buddy.id, taskID: taskID, origin: origin,
                                      userText: question, requesterName: requesterName, startedAt: startedAt)
            threadStore.completeExchange(forBuddyWithID: buddy.id, taskID: taskID, answerText: answer)
        }

        // The morning: the Briefer's job, handed on to the Writer, then the rest of the team.
        let morning = now.addingTimeInterval(-3 * 3600)
        if let briefer = starter(.briefer) {
            buddyStore.updateSchedule(ofBuddyWithID: briefer.id, to: .daily(hour: 9, minute: 0))
            buddyStore.setPinned(buddyWithID: briefer.id, isPinned: true)
            addExchange(to: briefer, at: morning, origin: .job, question: briefer.instruction,
                        answer: WispDemoSampleData.morningBrief)
            if let writer = starter(.writer) {
                _ = buddyStore.addHandOffLink(fromBuddyWithID: briefer.id, toBuddyWithID: writer.id)
                addExchange(
                    to: writer, at: morning.addingTimeInterval(40), origin: .delegated,
                    question: BuddyFlowPolicy.handOffMessage(
                        inputs: [(briefer.name, WispDemoSampleData.morningBrief)], targetJob: writer.instruction
                    ),
                    answer: WispDemoSampleData.writerPlan, requesterName: briefer.name
                )
            }
        }
        if let planner = starter(.planner) {
            addExchange(to: planner, at: morning.addingTimeInterval(-90 * 60), origin: .job,
                        question: WispDemoSampleData.plannerJob, answer: WispDemoSampleData.plannerAnswer)
        }
        addExchange(to: starter(.inbox), at: now.addingTimeInterval(-90 * 60), origin: .message,
                    question: WispDemoSampleData.inboxQuestion, answer: WispDemoSampleData.inboxAnswer)
        addExchange(to: starter(.researcher), at: now.addingTimeInterval(-40 * 60), origin: .message,
                    question: WispDemoSampleData.researcherQuestion, answer: WispDemoSampleData.researcherAnswer)

        // Automations, from the gallery, owned by the buddy each template suggests.
        // The morning brief is the Briefer's own 9:00 schedule above, so it isn't one of these.
        for templateID in [AutomationTemplateID.dailyChecklist, .weeklyReview, .meetingPrep] {
            let template = AutomationTemplates.template(withID: templateID)
            let draft = AutomationDraft(template: template, buddyID: starter(template.suggestedStarterBuddy)?.id)
            _ = AutomationStore.shared.add(draft.makeAutomation(id: UUID(), now: now))
        }

        // A few questions asked from the notch.
        for (question, answer) in WispDemoSampleData.recentAnswers {
            let taskID = AgentTaskRegistry.shared.beginTask(title: question)
            AgentTaskRegistry.shared.finishTask(taskID, status: .succeeded, finalText: answer)
        }

        try? FileManager.default.createDirectory(at: WispDemoMode.demoHomeURL, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: seededMarkerURL.path, contents: Data())
    }
}
