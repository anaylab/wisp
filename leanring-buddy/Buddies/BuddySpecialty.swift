//
//  BuddySpecialty.swift
//  leanring-buddy
//
//  What a buddy is good at. Picking a specialty when summoning one presets
//  everything that makes a buddy good at a job without the user having to know
//  the knobs: the character's colour, the tool groups it is limited to (a
//  smaller toolbox means a small model picks better), the persona line added to
//  its prompt, starter jobs, and a sensible schedule. Everything stays editable
//  afterwards; `.general` is the old behaviour (every tool, no persona).
//
//  Data only and pure, so the templates are tested without the app.
//

import Foundation

enum BuddySpecialty: String, Codable, CaseIterable, Identifiable, Equatable {
    case researcher
    case inbox
    case planner
    case writer
    case coder
    case watcher
    case organizer
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .researcher: return "Researcher"
        case .inbox: return "Inbox"
        case .planner: return "Planner"
        case .writer: return "Writer"
        case .coder: return "Coder"
        case .watcher: return "Watcher"
        case .organizer: return "Organizer"
        case .general: return "All-rounder"
        }
    }

    var tagline: String {
        switch self {
        case .researcher: return "Digs through the web and reports back with sources"
        case .inbox: return "Keeps on top of your email and messages"
        case .planner: return "Your day, your calendar, your reminders"
        case .writer: return "Drafts, rewrites and polishes"
        case .coder: return "Hands real coding work to Claude Code"
        case .watcher: return "Keeps an eye on a screen or a page and tells you"
        case .organizer: return "Tidies files, windows and routines"
        case .general: return "Anything. Has every tool you've enabled"
        }
    }

    var symbolName: String {
        switch self {
        case .researcher: return "magnifyingglass"
        case .inbox: return "envelope.fill"
        case .planner: return "calendar"
        case .writer: return "pencil.and.outline"
        case .coder: return "chevron.left.forwardslash.chevron.right"
        case .watcher: return "eye.fill"
        case .organizer: return "square.grid.2x2.fill"
        case .general: return "sparkles"
        }
    }

    /// A palette index (`BuddyAppearance`) this specialty looks best in, so a
    /// row of buddies reads as a team of different roles at a glance.
    var preferredColorIndex: Int {
        switch self {
        case .researcher: return 4  // sky
        case .inbox: return 2       // coral
        case .planner: return 0     // mint
        case .writer: return 3      // pink
        case .coder: return 1       // violet
        case .watcher: return 5     // sun
        case .organizer: return 6   // teal
        case .general: return 7     // orchid
        }
    }

    /// Words used to name a new buddy of this kind when its job gives no better
    /// subject ("Research Buddy").
    var nameStem: String {
        switch self {
        case .researcher: return "Research"
        case .inbox: return "Inbox"
        case .planner: return "Planner"
        case .writer: return "Writer"
        case .coder: return "Coder"
        case .watcher: return "Watcher"
        case .organizer: return "Tidy"
        case .general: return "Helper"
        }
    }

    /// The tool groups this specialty is limited to, or nil for every tool.
    /// A connected Composio server is allowed for the roles that live in
    /// connected apps (mail, calendar, docs).
    var toolAccess: BuddyToolAccess? {
        let composioGroupID = BuddyToolAccessPolicy.groupID(forServerNamed: ComposioAccountStore.serverId)
        let groups: Set<String>
        switch self {
        case .researcher:
            groups = [BuddyToolGroup.browser.rawValue, BuddyToolGroup.brain.rawValue]
        case .inbox:
            groups = [BuddyToolGroup.messaging.rawValue, BuddyToolGroup.reminders.rawValue, composioGroupID]
        case .planner:
            groups = [BuddyToolGroup.reminders.rawValue, BuddyToolGroup.shortcuts.rawValue, composioGroupID]
        case .writer:
            groups = [BuddyToolGroup.browser.rawValue, BuddyToolGroup.brain.rawValue, composioGroupID]
        case .coder:
            groups = [BuddyToolGroup.coding.rawValue, BuddyToolGroup.screen.rawValue, BuddyToolGroup.browser.rawValue]
        case .watcher:
            groups = [BuddyToolGroup.screen.rawValue, BuddyToolGroup.browser.rawValue, BuddyToolGroup.reminders.rawValue]
        case .organizer:
            groups = [BuddyToolGroup.screen.rawValue, BuddyToolGroup.shortcuts.rawValue, BuddyToolGroup.brain.rawValue]
        case .general:
            return nil
        }
        return BuddyToolAccess(allowedGroupIDs: groups)
    }

    /// One line added to the buddy's system prompt so it works in character.
    var personaLine: String? {
        switch self {
        case .researcher: return "You are a careful researcher: find sources, cross-check claims, say where each fact came from, and say plainly when you are unsure."
        case .inbox: return "You are an inbox specialist: be brief, surface what needs the user's reply or decision first, and never send anything without approval."
        case .planner: return "You are a planner: think in terms of the user's time, calendar and reminders, and propose a concrete order of attack."
        case .writer: return "You are a writer: match the user's voice, offer a clean draft first and short notes on what you changed second."
        case .coder: return "You are a coding specialist: hand real code work to the coding agent, report what changed and what to check, and keep summaries short."
        case .watcher: return "You are a watcher: monitor what you are asked to, and report only what changed since last time."
        case .organizer: return "You are an organizer: propose a tidy structure, explain it in one line, and make reversible changes only."
        case .general: return nil
        }
    }

    /// Ready-made jobs for this specialty. Wording sets the schedule
    /// (`BuddySchedule.inferred`).
    var starterJobs: [String] {
        switch self {
        case .researcher:
            return ["Every morning, summarize the top stories on Hacker News",
                    "Every Monday, find the most interesting new Swift projects on GitHub trending",
                    "Research a topic I give you and report the three best sources"]
        case .inbox:
            return ["Every morning, summarize my unread email and flag what needs a reply",
                    "Every evening, list messages I haven't answered yet"]
        case .planner:
            return ["Every morning, tell me what's on my calendar today and what to prepare",
                    "Every evening, list my reminders that are due tomorrow",
                    "Every Sunday, help me plan the week ahead"]
        case .writer:
            return ["Draft a polite reply to whatever I paste or attach",
                    "Every Friday, turn my notes from this week into a short update"]
        case .coder:
            return ["Review the latest changes in my project and summarize what to check",
                    "Find and fix a bug I describe, then explain the change"]
        case .watcher:
            return ["Tell me when the build on my screen finishes",
                    "Every day, check a page I name and tell me what changed"]
        case .organizer:
            return ["Every evening, suggest how to tidy my Downloads folder",
                    "Help me set up a window layout for deep work"]
        case .general:
            return ["Every morning, tell me what I should know today"]
        }
    }
}
