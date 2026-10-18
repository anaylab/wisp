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
//  The window has four sections by default (Today, Chat, Buddies, Settings) and
//  eight with Advanced features on (`WispSection`). Buddies are first-class:
//  they never hide, and they host Automations and the Canvas setup (the old
//  Jobs page) as pages of their own. Nothing is deleted: with Advanced off,
//  Routines, History and the Connections pages are reached as Settings pages
//  and only the Brain pages are hidden (Advanced also hides buddy delegation,
//  per-buddy models and sharing, but that is inside the Buddies views). A section with several pages
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
        // The messenger, the automations buddies own, and the Canvas setup that
        // used to be the Jobs section (the Planner buddy's feeds).
        case .buddies: return [.buddies, .automations, .canvas]
        // What Wisp knows, how it got there, and how to steer it. The old
        // History → Memory page (memory.md facts + conversation history) folded
        // into Brain: the user's page is Pages → Me, history lives in Settings.
        case .brain: return [.brainPages, .brainGraph, .brainInbox, .brainHealth, .brainLog, .brainSettings]
        case .routines: return [.routines]
        case .history: return [.timeline]
        case .connections: return [.marketplace, .tools, .sources]
        case .settings: return [.general, .shortcuts, .dictation, .agent, .model]
        }
    }

    /// Pages that are their own sections when Advanced is on, and fold into
    /// Settings when it is off, so the bar can stay at four sections without
    /// anything becoming unreachable.
    static let pagesFoldedIntoSettingsWhenAdvancedIsOff: [WispPage] = [
        .routines, .timeline, .marketplace, .tools, .sources
    ]

    /// The bar's contents. Advanced off: Today, Chat, Buddies, Settings.
    static func visibleSections(advancedEnabled: Bool) -> [WispSection] {
        advancedEnabled ? allCases : [.home, .chat, .buddies, .settings]
    }

    /// The pages shown in the section's strip. Settings gains the folded pages
    /// (after its own) while Advanced is off.
    func pages(advancedEnabled: Bool) -> [WispPage] {
        if self == .settings && !advancedEnabled {
            return pages + Self.pagesFoldedIntoSettingsWhenAdvancedIsOff
        }
        return pages
    }
}

/// One page of the Wisp window.
enum WispPage: String, CaseIterable, Identifiable {
    case home
    case chat
    case buddies
    case automations
    /// The old Jobs page (Canvas feed link, daily checklist, study blocks).
    case canvas
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
    case agent
    case model

    var id: String { rawValue }

    /// The section this page lives under in the sidebar.
    var section: WispSection {
        WispSection.allCases.first { $0.pages.contains(self) } ?? .home
    }

    /// The section the bar highlights for this page. Differs from `section`
    /// only while Advanced is off, when Routines, History and Connections pages
    /// live under Settings.
    func visibleSection(advancedEnabled: Bool) -> WispSection {
        if !advancedEnabled && WispSection.pagesFoldedIntoSettingsWhenAdvancedIsOff.contains(self) {
            return .settings
        }
        return section
    }

    /// Only the Brain pages have no home while Advanced is off; buddies are
    /// first-class.
    var isHiddenWhenAdvancedIsOff: Bool {
        switch self {
        case .brainPages, .brainGraph, .brainInbox, .brainHealth, .brainLog, .brainSettings:
            return true
        default:
            return false
        }
    }

    /// The page's name in the toolbar's segmented control.
    var title: String {
        switch self {
        case .home: return "Today"
        case .chat: return "Chat"
        case .buddies: return "Buddies"
        case .automations: return "Automations"
        case .canvas: return "Canvas"
        case .routines: return "Routines"
        case .brainPages: return "Pages"
        case .brainGraph: return "Graph"
        case .brainInbox: return "Inbox"
        case .brainHealth: return "Health"
        case .brainLog: return "Log"
        case .brainSettings: return "Settings"
        case .timeline: return "History"
        case .marketplace: return "Marketplace"
        case .tools: return "Servers & Tools"
        case .sources: return "Sources"
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .dictation: return "Dictation"
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

    /// A buddy another page asked the Buddies page to show (Today's Buddies
    /// tile). The Buddies page takes it and clears it.
    @Published var buddyIDToOpen: UUID?
    /// Today's "+" asked the Buddies page to open the new-buddy form.
    @Published var isNewBuddyFormRequested = false

    /// An automation the Today tile, the notch or a buddy's page asked the
    /// Automations page to open. The page takes it and clears it.
    @Published var automationIDToOpen: UUID?
    /// "New automation" was chosen (menu bar, Buddies "+"). The page takes it
    /// and clears it.
    @Published var isNewAutomationRequested = false
    /// A parsed draft (quick add, "save as automation") for the page to show
    /// pre-filled. The page takes it and clears it.
    @Published var pendingAutomationDraft: AutomationDraft?
    /// Asks the window to show the first-run setup over Today.
    @Published var isFirstRunSetupRequested = false

    func presentAutomationDraft(_ draft: AutomationDraft) {
        pendingAutomationDraft = draft
        select(.automations)
    }

    func presentNewAutomation() {
        isNewAutomationRequested = true
        select(.automations)
    }

    /// The page last open in each section, so returning to Settings lands on
    /// Dictation again rather than resetting to the section's first page.
    private var lastPageBySection: [WispSection: WispPage] = [:]

    /// Whether Advanced features are on, read live so the window reacts the
    /// moment the switch moves (views also observe the preference itself).
    private var advancedEnabled: Bool { WispAdvancedFeaturesPreference.isEnabledNow }

    var selectedSection: WispSection {
        selectedPage.visibleSection(advancedEnabled: advancedEnabled)
    }

    /// The strip under the bar for the open section.
    var pagesInSelectedSection: [WispPage] {
        selectedSection.pages(advancedEnabled: advancedEnabled)
    }

    /// Where a request for `requested` actually lands: Brain pages
    /// fall back to Settings while Advanced is off. Everything else, including
    /// the pages folded into Settings, is reachable and returned as asked.
    func resolvedPage(_ requested: WispPage, advancedEnabled: Bool) -> WispPage {
        if !advancedEnabled && requested.isHiddenWhenAdvancedIsOff {
            return .general
        }
        return requested
    }

    func select(_ page: WispPage) {
        let landingPage = resolvedPage(page, advancedEnabled: advancedEnabled)
        selectedPage = landingPage
        lastPageBySection[landingPage.visibleSection(advancedEnabled: advancedEnabled)] = landingPage
    }

    func select(_ section: WispSection) {
        select(lastPageBySection[section] ?? section.pages(advancedEnabled: advancedEnabled)[0])
    }

    /// Called when the Advanced switch moves, so a page that just became hidden
    /// is not left on screen.
    func reconcileWithAdvancedSetting() {
        select(selectedPage)
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
