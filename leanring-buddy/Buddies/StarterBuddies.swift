//
//  StarterBuddies.swift
//  leanring-buddy
//
//  Three buddies a new user starts with, so the Buddies page and the notch are
//  not empty on day one: a Planner (Canvas deadlines and the daily checklist), a
//  Briefer (the morning brief and meeting prep) and a Focus buddy (study blocks).
//  Their ids are fixed so Automation templates and the migration can name a
//  starter before it exists. They are created once, on first run only; deleting
//  one sticks (`BuddyStore.ensureStarterBuddies`).
//

import Foundation

nonisolated enum StarterBuddyKind: String, Codable, CaseIterable, Sendable {
    /// Canvas and the checklist.
    case planner
    /// The morning brief.
    case briefer
    /// Study blocks.
    case focus
    /// Email triage.
    case inbox
    /// Essays and assignments.
    case writer
    /// Web research with sources.
    case researcher
}

nonisolated struct StarterBuddyDefinition: Identifiable, Equatable, Sendable {
    /// Fixed so an Automation can name a starter buddy before it is created.
    let id: UUID
    let kind: StarterBuddyKind
    let name: String
    let specialty: BuddySpecialty
    let defaultPersonality: BuddyPersonality
    let colorIndex: Int
    let jobInstruction: String
    /// Templates that start switched OFF on this buddy, ready for the user (or
    /// first-run setup step 4) to turn on.
    let readyAutomationTemplateIDs: [AutomationTemplateID]

    static let plannerBuddyID = UUID(uuidString: "6D1A0001-5EED-4B1D-9A10-0000000000A1")!
    static let brieferBuddyID = UUID(uuidString: "6D1A0001-5EED-4B1D-9A10-0000000000A2")!
    static let focusBuddyID = UUID(uuidString: "6D1A0001-5EED-4B1D-9A10-0000000000A3")!

    static let all: [StarterBuddyDefinition] = [
        StarterBuddyDefinition(
            id: plannerBuddyID,
            kind: .planner,
            name: "Planner",
            specialty: .planner,
            defaultPersonality: .coach,
            colorIndex: 0,
            jobInstruction: "Keep track of my Canvas deadlines and build my checklist for the day.",
            readyAutomationTemplateIDs: [.canvasDeadlines, .dailyChecklist]
        ),
        StarterBuddyDefinition(
            id: brieferBuddyID,
            kind: .briefer,
            name: "Briefer",
            specialty: .general,
            defaultPersonality: .chill,
            colorIndex: 4,
            jobInstruction: "Tell me what's on my calendar and what to prepare, briefly.",
            readyAutomationTemplateIDs: [.morningBrief, .meetingPrep, .weeklyReview]
        ),
        StarterBuddyDefinition(
            id: focusBuddyID,
            kind: .focus,
            name: "Focus",
            specialty: .planner,
            defaultPersonality: .teacher,
            colorIndex: 1,
            jobInstruction: "Help me find time to study and protect it on my calendar.",
            readyAutomationTemplateIDs: [.focusBlock, .studyPlan]
        ),
    ]

    static let inboxBuddyID = UUID(uuidString: "6D1A0001-5EED-4B1D-9A10-0000000000A4")!
    static let writerBuddyID = UUID(uuidString: "6D1A0001-5EED-4B1D-9A10-0000000000A5")!
    static let researcherBuddyID = UUID(uuidString: "6D1A0001-5EED-4B1D-9A10-0000000000A6")!

    /// Buddies with jobs unlike the three above (those all revolve around the
    /// calendar and Canvas). Seeded once under their own flag so people who
    /// already have the first three get these too.
    static let additional: [StarterBuddyDefinition] = [
        StarterBuddyDefinition(
            id: inboxBuddyID,
            kind: .inbox,
            name: "Inbox",
            specialty: .inbox,
            defaultPersonality: .deadpan,
            colorIndex: 2,
            jobInstruction: "Go through my email and tell me only what needs a reply or an action, with a draft reply for each.",
            readyAutomationTemplateIDs: []
        ),
        StarterBuddyDefinition(
            id: writerBuddyID,
            kind: .writer,
            name: "Writer",
            specialty: .writer,
            defaultPersonality: .teacher,
            colorIndex: 3,
            jobInstruction: "Help me outline, draft and tighten essays and assignments, and point out what to fix in my own writing.",
            readyAutomationTemplateIDs: []
        ),
        StarterBuddyDefinition(
            id: researcherBuddyID,
            kind: .researcher,
            name: "Researcher",
            specialty: .researcher,
            defaultPersonality: .chill,
            colorIndex: 6,
            jobInstruction: "Research a topic on the web and give me a short answer with the sources.",
            readyAutomationTemplateIDs: []
        ),
    ]

    static func definition(for kind: StarterBuddyKind) -> StarterBuddyDefinition {
        // `all` holds one definition per kind, so this always finds one.
        (all + additional).first { $0.kind == kind } ?? all[0]
    }
}
