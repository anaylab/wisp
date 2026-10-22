//
//  The tab types from leanring-buddy/ChromeTabOrganizer.swift, copied because that
//  file reaches the bridge and the model and can't compile on its own. Keep these
//  in step with the originals (same fields, same names).
//

import Foundation

nonisolated struct ChromeTab: Decodable, Equatable, Sendable {
    let id: Int
    let windowId: Int
    let index: Int
    let title: String
    let url: String
    let pinned: Bool
    let active: Bool
    let audible: Bool
    let muted: Bool?
    let groupId: Int
    let lastAccessed: Double

    static let noGroupID = -1

    var isInGroup: Bool { groupId != Self.noGroupID }
}

nonisolated struct ChromeTabGroup: Decodable, Equatable, Sendable {
    let id: Int
    let windowId: Int
    let title: String
    let color: String
    let collapsed: Bool
}

nonisolated struct ChromeTabsSnapshot: Decodable, Equatable, Sendable {
    let tabs: [ChromeTab]
    let groups: [ChromeTabGroup]
    let focusedWindowId: Int?
}
