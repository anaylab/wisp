//
//  BuddyToolAccess.swift
//  leanring-buddy
//
//  Which tools one buddy may use. A buddy takes one job, and a job rarely needs
//  everything Wisp can do: a Hacker News digest has no business texting people
//  or touching the brain, and the more tools a small model is shown the worse it
//  picks. So a buddy can be limited to a few *groups* — Browser, Screen,
//  Messages, … plus one group per connected MCP server — and a buddy with no
//  limit (`toolAccess == nil`, what every buddy had before this) keeps every
//  tool, so nothing changes for existing buddies.
//
//  Groups rather than individual tools because the tool list isn't fixed: MCP
//  servers come and go, and a stored list of tool names would silently go stale
//  or, worse, let a newly installed tool through. Anything not in an allowed
//  group is refused, including tools that didn't exist when the buddy was made.
//
//  Enforced twice by `AgentTurnRunner` (via `AgentRunToolkit`): tools outside
//  the allow-list are never shown to the model, and a call to one by name is
//  refused — a model can call a tool it was never offered.
//

import Foundation

/// A family of built-in tools a buddy can be given or denied together.
enum BuddyToolGroup: String, CaseIterable, Identifiable {
    case browser
    case screen
    case messaging
    case reminders
    case shortcuts
    case coding
    case brain
    case memory
    case delegation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .browser: return "Browser"
        case .screen: return "Screen"
        case .messaging: return "Messages & Contacts"
        case .reminders: return "Reminders"
        case .shortcuts: return "Shortcuts"
        case .coding: return "Coding agent"
        case .brain: return "Brain"
        case .memory: return "Your memory"
        case .delegation: return "Other buddies"
        }
    }

    var summary: String {
        switch self {
        case .browser: return "Drive your Chrome or Safari"
        case .screen: return "Read your screen, windows and clipboard; arrange windows"
        case .messaging: return "Text people and look them up"
        case .reminders: return "Add reminders"
        case .shortcuts: return "Run your Apple Shortcuts"
        case .coding: return "Hand work to Claude Code"
        case .brain: return "Search and add to your wiki"
        case .memory: return "Remember and forget facts about you"
        case .delegation: return "Ask your other buddies for help"
        }
    }

    var symbolName: String {
        switch self {
        case .browser: return "globe"
        case .screen: return "display"
        case .messaging: return "message"
        case .reminders: return "checklist"
        case .shortcuts: return "bolt"
        case .coding: return "chevron.left.forwardslash.chevron.right"
        case .brain: return "brain"
        case .memory: return "person.crop.circle"
        case .delegation: return "person.2"
        }
    }

    /// Whether this group holds what Wisp knows about the user. A buddy on a
    /// cloud model never gets these, whatever its allow-list says
    /// (`BuddyRunToolPolicy`).
    var isPrivateKnowledge: Bool {
        self == .brain || self == .memory
    }

    /// The built-in group a registered tool belongs to, or nil for a tool that
    /// is in none (a connected server's tools are grouped by server instead).
    static func group(forToolNamed toolName: String) -> BuddyToolGroup? {
        switch toolName {
        case "browser_task", "read_page", "click_element", "open_url":
            return .browser
        case _ where toolName.hasPrefix("chrome_"):
            return .browser
        case "read_screen_text", "list_windows", "read_clipboard", WindowManagementToolNames.arrangeWindows:
            return .screen
        case MessagingToolNames.sendIMessage, MessagingToolNames.findContact:
            return .messaging
        case "create_reminder":
            return .reminders
        case "list_shortcuts", "run_shortcut":
            return .shortcuts
        case "delegate_coding_task":
            return .coding
        case _ where BrainToolNames.all.contains(toolName):
            return .brain
        case "remember", "forget":
            return .memory
        case BuddyDelegationToolNames.askBuddy:
            return .delegation
        default:
            return nil
        }
    }
}

/// The groups a limited buddy may use. Group ids are a `BuddyToolGroup`'s raw
/// value, or `mcp:<server>` for a connected server (`BuddyToolAccessPolicy`).
struct BuddyToolAccess: Codable, Equatable {
    var allowedGroupIDs: Set<String>

    func allows(_ group: BuddyToolGroup) -> Bool {
        allowedGroupIDs.contains(group.rawValue)
    }

    func allowsServer(named serverName: String) -> Bool {
        allowedGroupIDs.contains(BuddyToolAccessPolicy.groupID(forServerNamed: serverName))
    }

    /// The access with one group switched on or off.
    func setting(groupID: String, isAllowed: Bool) -> BuddyToolAccess {
        var updatedGroupIDs = allowedGroupIDs
        if isAllowed { updatedGroupIDs.insert(groupID) } else { updatedGroupIDs.remove(groupID) }
        return BuddyToolAccess(allowedGroupIDs: updatedGroupIDs)
    }

    /// What a buddy limited to nothing starts as: no group, just the basics.
    static let nothing = BuddyToolAccess(allowedGroupIDs: [])
}

/// The pure rule for "may this buddy use this tool", tested without the app.
enum BuddyToolAccessPolicy {
    /// Harmless tools every buddy keeps, even a fully limited one: the clock, and
    /// the skills index (open-ended, user-written reference).
    static let alwaysPermittedToolNames: Set<String> = ["get_current_time", "load_skill"]

    /// Never available to a buddy. `do_in_background` starts a separate task on
    /// Wisp's own model and in its own (empty) conversation — outside this
    /// buddy's thread, notes, tool limits and chosen model — so a local buddy
    /// could use it to put its request in front of a cloud model, or a limited
    /// buddy to get around its allow-list.
    static let neverPermittedToolNames: Set<String> = ["do_in_background"]

    static let mcpGroupPrefix = "mcp:"

    static func groupID(forServerNamed serverName: String) -> String {
        mcpGroupPrefix + serverName
    }

    /// The id of the group a tool is in: a built-in group, `mcp:<server>` for a
    /// namespaced `server__tool`, or nil for a tool in no group.
    static func groupID(forToolNamed toolName: String) -> String? {
        if let builtInGroup = BuddyToolGroup.group(forToolNamed: toolName) {
            return builtInGroup.rawValue
        }
        if let separatorRange = toolName.range(of: "__"), separatorRange.lowerBound != toolName.startIndex {
            return groupID(forServerNamed: String(toolName[..<separatorRange.lowerBound]))
        }
        return nil
    }

    /// The connected servers that have a tool in `toolNames`, sorted.
    static func serverNames(inToolNames toolNames: Set<String>) -> [String] {
        let namesOfServers = toolNames.compactMap { toolName -> String? in
            guard BuddyToolGroup.group(forToolNamed: toolName) == nil,
                  let groupIDOfTool = groupID(forToolNamed: toolName),
                  groupIDOfTool.hasPrefix(mcpGroupPrefix) else { return nil }
            return String(groupIDOfTool.dropFirst(mcpGroupPrefix.count))
        }
        return Set(namesOfServers).sorted()
    }

    /// Whether a buddy may see and call `toolName`.
    ///
    /// - Parameter access: The buddy's allow-list; nil means no limit.
    /// - Parameter modelSendsDataOffThisMachine: A cloud buddy never gets the
    ///   brain or the user's own memory, however its allow-list reads.
    static func isPermitted(
        toolNamed toolName: String,
        access: BuddyToolAccess?,
        modelSendsDataOffThisMachine: Bool
    ) -> Bool {
        if neverPermittedToolNames.contains(toolName) { return false }
        if modelSendsDataOffThisMachine && BuddyRunToolPolicy.privateKnowledgeToolNames.contains(toolName) {
            return false
        }
        if alwaysPermittedToolNames.contains(toolName) { return true }
        guard let access else { return true }
        // A tool in no group (nothing says what it is) is refused to a limited
        // buddy rather than assumed safe.
        guard let toolGroupID = groupID(forToolNamed: toolName) else { return false }
        return access.allowedGroupIDs.contains(toolGroupID)
    }

    /// "All tools", "No extra tools", or "Browser, Screen +1".
    static func summary(of access: BuddyToolAccess?) -> String {
        guard let access else { return "All tools" }
        let allowedTitles = BuddyToolGroup.allCases.filter(access.allows).map(\.title)
            + access.allowedGroupIDs.filter { $0.hasPrefix(mcpGroupPrefix) }
                .map { String($0.dropFirst(mcpGroupPrefix.count)) }.sorted()
        guard let firstTitle = allowedTitles.first else { return "No extra tools" }
        switch allowedTitles.count {
        case 1: return firstTitle
        case 2: return "\(firstTitle), \(allowedTitles[1])"
        default: return "\(firstTitle), \(allowedTitles[1]) +\(allowedTitles.count - 2)"
        }
    }
}
