//
//  BuddySidebarPolicy.swift
//  leanring-buddy
//
//  The pure rules behind the sidebar's buddy list, in the shape of OpenBot's
//  sidebar: the one badge a row wears (what the buddy is doing, by precedence),
//  and the groups the list is split into — "Needs you" first, then Pinned, then
//  the rest, with hidden buddies set apart at the end. Kept free of the stores
//  so `Tests/BuddyThread` checks them without the app.
//

import Foundation

/// The single badge a buddy's row shows. A buddy with nothing to say has none.
enum BuddySidebarState: Equatable {
    /// Blocked on the user's approval; nothing moves until they act.
    case waiting
    case working
    /// The last run failed recently.
    case failed
    /// Just finished something (fades with the happy mood).
    case responded
    /// Has a finished run the user hasn't opened yet.
    case unread

    var accessibilityPhrase: String {
        switch self {
        case .waiting: return "needs your approval"
        case .working: return "working"
        case .failed: return "last run failed"
        case .responded: return "just finished"
        case .unread: return "unread"
        }
    }
}

enum BuddySidebarPolicy {
    /// What a row shows, by precedence. Waiting outranks everything because
    /// nothing moves until the user acts; working outranks a result because
    /// the result is about to change; a fresh success shows its check for the
    /// length of the happy mood, then settles into the unread dot.
    static func state(mood: BuddyMood, isUnread: Bool) -> BuddySidebarState? {
        switch mood {
        case .waiting: return .waiting
        case .working: return .working
        case .oops: return .failed
        case .happy: return .responded
        case .idle, .sleepy: return isUnread ? .unread : nil
        }
    }
}

/// The groups of the sidebar list, each in the order it was given.
struct BuddySidebarGroups<Item> {
    /// Buddies blocked on the user. They leave their other group while they wait.
    var needsYou: [Item] = []
    var pinned: [Item] = []
    var everyoneElse: [Item] = []
    /// Buddies the user tucked away. They leave every other group.
    var hidden: [Item] = []

    /// Every buddy in the order the list shows them, hidden ones last. This is
    /// what ⌘1–9 count over, so the shortcut matches the row it names.
    var inDisplayOrder: [Item] { needsYou + pinned + everyoneElse + hidden }
    var visibleInDisplayOrder: [Item] { needsYou + pinned + everyoneElse }
}

enum BuddySidebarGrouping {
    static func groups<Item>(
        of items: [Item],
        isHidden: (Item) -> Bool,
        isWaiting: (Item) -> Bool,
        isPinned: (Item) -> Bool
    ) -> BuddySidebarGroups<Item> {
        var groups = BuddySidebarGroups<Item>()
        for item in items {
            if isHidden(item) {
                groups.hidden.append(item)
            } else if isWaiting(item) {
                groups.needsYou.append(item)
            } else if isPinned(item) {
                groups.pinned.append(item)
            } else {
                groups.everyoneElse.append(item)
            }
        }
        return groups
    }
}
