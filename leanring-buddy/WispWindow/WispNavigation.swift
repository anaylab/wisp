//
//  WispNavigation.swift
//  leanring-buddy
//
//  Where things live in the Wisp window, and how the rest of the app asks for
//  one of them.
//
//  Wisp is notch-first: the notch is where you use it, and this one window is
//  where you manage it. It replaced three surfaces that had grown to overlap —
//  the dashboard, the pop-out conversation window and the settings pages inside
//  the notch — so every setting now has exactly one home.
//
//  The sidebar has eight sections (`WispSection`). A section with several pages
//  (`WispPage`) shows them as a segmented control in the toolbar. Anything that
//  wants the window open at a particular page — the notch's gear, the menu bar
//  menu, Today's "Review" button — calls `WispWindowNavigator.open(_:)`.
//

import Combine
import SwiftUI

extension Notification.Name {
    /// Collapses the notch's quick panel and any other transient surface, e.g.
    /// when push-to-talk starts or the Wisp window opens.
    static let wispDismissPanel = Notification.Name("wispDismissPanel")
    /// Closes the chat workspace in the notch, if it's open.
    static let wispCloseNotchWorkspace = Notification.Name("wispCloseNotchWorkspace")
}

/// The Wisp window's sidebar destinations, in sidebar order.
enum WispSection: String, CaseIterable, Identifiable {
    case home
    case chat
    case buddies
    case brain
    case routines
    case history
    case connections
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Today"
        case .chat: return "Chat"
        case .buddies: return "Buddies"
        case .brain: return "Brain"
        case .routines: return "Routines"
        case .history: return "History"
        case .connections: return "Connections"
        case .settings: return "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .home: return "sun.max"
        case .chat: return "bubble.left.and.bubble.right"
        case .buddies: return "person.2"
        case .brain: return "brain"
        case .routines: return "bolt"
        case .history: return "clock.arrow.circlepath"
        case .connections: return "powerplug"
        case .settings: return "gearshape"
        }
    }

    /// The section's pages, in toolbar order. The first is the default.
    var pages: [WispPage] {
        switch self {
        case .home: return [.home]
        case .chat: return [.chat]
        case .buddies: return [.buddies]
        // What Wisp knows, how it got there, and how to steer it. The old
        // History → Memory page (memory.md facts + conversation history) folded
        // into Brain: the user's page is Pages → Me, history lives in Settings.
        case .brain: return [.brainPages, .brainGraph, .brainInbox, .brainHealth, .brainLog, .brainSettings]
        case .routines: return [.routines]
        case .history: return [.timeline]
        case .connections: return [.marketplace, .tools, .sources]
        case .settings: return [.general, .shortcuts, .dictation, .cursor, .agent, .model]
        }
    }

    /// Sidebar groups: using Wisp, then managing it.
    static let useSections: [WispSection] = [.home, .chat, .buddies, .brain, .routines, .history]
    static let manageSections: [WispSection] = [.connections, .settings]
}

/// One page of the Wisp window.
enum WispPage: String, CaseIterable, Identifiable {
    case home
    case chat
    case buddies
    case routines
    case brainPages
    case brainGraph
    case brainInbox
    case brainHealth
    case brainLog
    case brainSettings
    case timeline
    case marketplace
    case tools
    case sources
    case general
    case shortcuts
    case dictation
    case cursor
    case agent
    case model

    var id: String { rawValue }

    /// The section this page lives under in the sidebar.
    var section: WispSection {
        WispSection.allCases.first { $0.pages.contains(self) } ?? .home
    }

    /// The page's name in the toolbar's segmented control.
    var title: String {
        switch self {
        case .home: return "Today"
        case .chat: return "Chat"
        case .buddies: return "Buddies"
        case .routines: return "Routines"
        case .brainPages: return "Pages"
        case .brainGraph: return "Graph"
        case .brainInbox: return "Inbox"
        case .brainHealth: return "Health"
        case .brainLog: return "Log"
        case .brainSettings: return "Settings"
        case .timeline: return "Timeline"
        case .marketplace: return "Marketplace"
        case .tools: return "Servers & Tools"
        case .sources: return "Sources"
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .dictation: return "Dictation"
        case .cursor: return "Cursor"
        case .agent: return "Agent"
        case .model: return "Model"
        }
    }
}

/// The window's current page, shared so anything can move it.
@MainActor
final class WispWindowRouter: ObservableObject {
    static let shared = WispWindowRouter()

    @Published private(set) var selectedPage: WispPage = .home

    /// The page last open in each section, so returning to Settings lands on
    /// Dictation again rather than resetting to the section's first page.
    private var lastPageBySection: [WispSection: WispPage] = [:]

    var selectedSection: WispSection { selectedPage.section }

    func select(_ page: WispPage) {
        selectedPage = page
        lastPageBySection[page.section] = page
    }

    func select(_ section: WispSection) {
        select(lastPageBySection[section] ?? section.pages[0])
    }
}

/// Opens the Wisp window at a page, from anywhere in the app.
@MainActor
enum WispWindowNavigator {
    static func open(_ page: WispPage) {
        // The notch's quick panel and chat workspace get out of the way: the
        // window is now where the user is working.
        NotificationCenter.default.post(name: .wispDismissPanel, object: nil)
        NotificationCenter.default.post(name: .wispCloseNotchWorkspace, object: nil)
        WispWindowRouter.shared.select(page)
        WispWindowController.shared?.showWindow()
    }
}
