//
//  ChromeTabOrganizerTests.swift
//  leanring-buddyTests
//
//  Proves the Chrome tab organizer plans the right thing before anything is
//  sent to Chrome: sites are named and grouped per window, the user's pinned
//  tabs and own groups are left alone, duplicates keep the right copy, a
//  model's topic reply can only name tabs it was shown, and plain spoken
//  commands are recognised while questions are left to the model.
//

import XCTest
@testable import Wisp

final class ChromeTabOrganizerTests: XCTestCase {

    // MARK: - Fixtures

    private func makeTab(
        id: Int,
        windowID: Int = 1,
        index: Int? = nil,
        title: String = "",
        url: String,
        pinned: Bool = false,
        active: Bool = false,
        audible: Bool = false,
        groupID: Int = ChromeTab.noGroupID,
        lastAccessed: Double = 0
    ) -> ChromeTab {
        ChromeTab(
            id: id, windowId: windowID, index: index ?? id, title: title, url: url,
            pinned: pinned, active: active, audible: audible, groupId: groupID, lastAccessed: lastAccessed
        )
    }

    private func makeSnapshot(_ tabs: [ChromeTab], groups: [ChromeTabGroup] = [], focusedWindowID: Int? = 1) -> ChromeTabsSnapshot {
        ChromeTabsSnapshot(tabs: tabs, groups: groups, focusedWindowId: focusedWindowID)
    }

    // MARK: - Site naming

    func testSiteNamesAndGroupingKeys() {
        XCTAssertEqual(ChromeSiteNamer.site(forURL: "https://github.com/anthropics/x")?.displayName, "GitHub")
        XCTAssertEqual(ChromeSiteNamer.site(forURL: "https://www.youtube.com/watch?v=1")?.groupingKey, "youtube.com")
        XCTAssertEqual(ChromeSiteNamer.site(forURL: "https://youtu.be/abc")?.groupingKey, "youtube.com")
        XCTAssertEqual(ChromeSiteNamer.site(forURL: "https://en.wikipedia.org/wiki/Swift")?.displayName, "Wikipedia")
        XCTAssertEqual(ChromeSiteNamer.site(forURL: "https://news.bbc.co.uk/story")?.groupingKey, "bbc.co.uk")
        XCTAssertEqual(ChromeSiteNamer.site(forURL: "https://mail.google.com/mail/u/0")?.displayName, "Gmail")
        XCTAssertEqual(ChromeSiteNamer.site(forURL: "https://docs.google.com/document/d/1")?.displayName, "Google Docs")
        XCTAssertEqual(ChromeSiteNamer.site(forURL: "http://localhost:3000/")?.displayName, "Local")
        XCTAssertEqual(ChromeSiteNamer.site(forURL: "http://127.0.0.1:8004/")?.groupingKey, "localhost")
    }

    func testNonWebPagesHaveNoSite() {
        XCTAssertNil(ChromeSiteNamer.site(forURL: "chrome://newtab/"))
        XCTAssertNil(ChromeSiteNamer.site(forURL: "file:///Users/me/notes.html"))
        XCTAssertNil(ChromeSiteNamer.site(forURL: ""))
    }

    // MARK: - Site grouping

    func testSiteGroupsNeedTwoTabsAndStayInTheirWindow() {
        let snapshot = makeSnapshot([
            makeTab(id: 1, url: "https://github.com/a"),
            makeTab(id: 2, url: "https://example.com/"),
            makeTab(id: 3, url: "https://github.com/b"),
            makeTab(id: 4, windowID: 2, url: "https://github.com/c"),
            makeTab(id: 5, windowID: 2, url: "https://github.com/d"),
            makeTab(id: 6, windowID: 2, url: "https://github.com/e", pinned: true),
        ])
        let plan = ChromeTabGroupingPlanner.planSiteGroups(for: snapshot)

        XCTAssertEqual(plan.plannedGroups.map(\.windowID), [1, 2])
        XCTAssertEqual(plan.plannedGroups.map(\.tabIDs), [[1, 3], [4, 5]])
        XCTAssertEqual(Set(plan.plannedGroups.map(\.title)), ["GitHub"])
        // The lone example.com tab and the pinned tab are left alone.
        XCTAssertEqual(plan.groupedTabCount, 4)
    }

    func testUsersOwnGroupsAreNotTouchedButAMatchingGroupIsReused() {
        let snapshot = makeSnapshot(
            [
                makeTab(id: 1, url: "https://github.com/a", groupID: 50),
                makeTab(id: 2, url: "https://github.com/b"),
                makeTab(id: 3, url: "https://reddit.com/r/swift", groupID: 60),
                makeTab(id: 4, url: "https://reddit.com/r/mac"),
            ],
            groups: [
                ChromeTabGroup(id: 50, windowId: 1, title: "GitHub", color: "grey", collapsed: false),
                ChromeTabGroup(id: 60, windowId: 1, title: "Weekend", color: "red", collapsed: false),
            ]
        )
        let plan = ChromeTabGroupingPlanner.planSiteGroups(for: snapshot)

        // Tab 2 joins the existing "GitHub" group even alone; tab 4 is a lone
        // Reddit tab and the user's "Weekend" group is not raided for company.
        XCTAssertEqual(plan.plannedGroups, [
            ChromeTabGroupingPlan.PlannedGroup(windowID: 1, title: "GitHub", color: "grey", tabIDs: [2], existingGroupID: 50),
        ])
    }

    func testGroupColourIsStableForAName() {
        XCTAssertEqual(
            ChromeTabGroupingPlanner.groupColor(forTitle: "GitHub"),
            ChromeTabGroupingPlanner.groupColor(forTitle: "github")
        )
        XCTAssertTrue(ChromeTabGroupingPlanner.groupColors.contains(ChromeTabGroupingPlanner.groupColor(forTitle: "Trip Planning")))
    }

    // MARK: - Duplicates

    func testDuplicatesKeepTheShowingTabAndIgnoreFragmentsAndTrailingSlash() {
        let snapshot = makeSnapshot([
            makeTab(id: 1, url: "https://example.com/page", lastAccessed: 900),
            makeTab(id: 2, url: "https://example.com/page#section", active: true),
            makeTab(id: 3, url: "https://example.com/page/", lastAccessed: 100),
            makeTab(id: 4, url: "https://example.com/page?q=other"),
        ])
        XCTAssertEqual(ChromeDuplicateTabFinder.tabIDsToClose(in: snapshot), [1, 3])
    }

    func testDuplicatesNeverClosePinnedOrAudibleTabs() {
        let snapshot = makeSnapshot([
            makeTab(id: 1, url: "https://music.example.com/", active: true),
            makeTab(id: 2, url: "https://music.example.com/", pinned: true),
            makeTab(id: 3, url: "https://music.example.com/", audible: true),
            makeTab(id: 4, url: "https://music.example.com/"),
        ])
        XCTAssertEqual(ChromeDuplicateTabFinder.tabIDsToClose(in: snapshot), [4])
    }

    func testNewTabPagesAreNotDuplicates() {
        let snapshot = makeSnapshot([
            makeTab(id: 1, url: "chrome://newtab/"),
            makeTab(id: 2, url: "chrome://newtab/"),
        ])
        XCTAssertEqual(ChromeDuplicateTabFinder.tabIDsToClose(in: snapshot), [])
    }

    // MARK: - Topic replies

    private var topicPromptTabs: [ChromeTab] {
        [
            makeTab(id: 101, title: "Flights to Lisbon", url: "https://google.com/travel"),
            makeTab(id: 102, title: "Lisbon hotels", url: "https://booking.com/lisbon"),
            makeTab(id: 103, title: "SwiftUI docs", url: "https://developer.apple.com/swiftui"),
            makeTab(id: 104, title: "Swift forums", url: "https://forums.swift.org/"),
        ]
    }

    func testTopicReplyMapsNumbersToTabIDs() {
        let modelReply = """
        here you go:
        ```json
        {"groups":[{"name":"Lisbon Trip","tabs":[1,2]},{"name":"Swift","tabs":["3", 4.0]}]}
        ```
        """
        let parsedGroups = ChromeTabTopicPrompt.parseTopicGroups(fromModelReply: modelReply, promptTabs: topicPromptTabs)
        XCTAssertEqual(parsedGroups.map(\.title), ["Lisbon Trip", "Swift"])
        XCTAssertEqual(parsedGroups.map(\.tabIDs), [[101, 102], [103, 104]])
    }

    func testTopicReplyCannotNameTabsItWasNotShownOrClaimOneTwice() {
        let modelReply = #"{"groups":[{"name":"A","tabs":[1,2,99,0]},{"name":"B","tabs":[2,3]},{"name":"C","tabs":[4]}]}"#
        let parsedGroups = ChromeTabTopicPrompt.parseTopicGroups(fromModelReply: modelReply, promptTabs: topicPromptTabs)
        // 99 and 0 are dropped; tab 2 stays in A, leaving B with one tab, so
        // B is dropped; C never had two.
        XCTAssertEqual(parsedGroups.map(\.title), ["A"])
        XCTAssertEqual(parsedGroups.map(\.tabIDs), [[101, 102]])
    }

    func testUnreadableTopicReplyIsEmpty() {
        XCTAssertTrue(ChromeTabTopicPrompt.parseTopicGroups(fromModelReply: "sure! i grouped them.", promptTabs: topicPromptTabs).isEmpty)
        XCTAssertTrue(ChromeTabTopicPrompt.parseTopicGroups(fromModelReply: "{not json}", promptTabs: topicPromptTabs).isEmpty)
    }

    func testTopicPromptListsFocusedWindowFirstAndSkipsNonWebTabs() {
        let snapshot = makeSnapshot(
            [
                makeTab(id: 1, windowID: 1, title: "Background", url: "https://a.com/"),
                makeTab(id: 2, windowID: 2, title: "Front", url: "https://b.com/"),
                makeTab(id: 3, windowID: 2, title: "New Tab", url: "chrome://newtab/"),
            ],
            focusedWindowID: 2
        )
        let promptTabs = ChromeTabTopicPrompt.tabsForPrompt(from: snapshot)
        XCTAssertEqual(promptTabs.map(\.id), [2, 1])
        XCTAssertEqual(ChromeTabTopicPrompt.userMessage(listing: promptTabs), "1. Front — b.com\n2. Background — a.com")
    }

    // MARK: - Spoken commands

    func testOrganizePhrasings() {
        for phrase in ["organize my tabs", "Hey Wisp, can you tidy up my tabs?", "group my chrome tabs",
                       "sort my tabs please", "clean up my tabs"] {
            XCTAssertEqual(ChromeTabCommandRouter.command(for: phrase), .organize(by: .topic), phrase)
        }
        XCTAssertEqual(ChromeTabCommandRouter.command(for: "group my tabs by site"), .organize(by: .site))
        XCTAssertEqual(ChromeTabCommandRouter.command(for: "organize tabs by domain"), .organize(by: .site))
    }

    func testDuplicateAndUngroupPhrasings() {
        XCTAssertEqual(ChromeTabCommandRouter.command(for: "close duplicate tabs"), .closeDuplicates)
        XCTAssertEqual(ChromeTabCommandRouter.command(for: "get rid of my duplicate tabs"), .closeDuplicates)
        XCTAssertEqual(ChromeTabCommandRouter.command(for: "ungroup my tabs"), .ungroupAll)
    }

    func testQuestionsAndUnrelatedRequestsAreLeftToTheModel() {
        for phrase in ["how do i group tabs in chrome", "what tabs do i have open", "close this tab",
                       "open a new tab", "organize my desktop",
                       "can you look at this tab and tell me what the article on the page is actually about"] {
            XCTAssertNil(ChromeTabCommandRouter.command(for: phrase), phrase)
        }
    }

    @MainActor
    func testBrowserRouterSendsTabOrganizingToTheExtension() {
        XCTAssertEqual(BrowserCommandRouter.route("organize my tabs"), .chromeTabs(.organize(by: .topic)))
        // Existing tab commands are unchanged.
        XCTAssertEqual(BrowserCommandRouter.route("close this tab"), .tabCommand(.closeTab))
    }

    // MARK: - Replies

    @MainActor
    func testReplyNamesEachGroupOnce() {
        let plan = ChromeTabGroupingPlan(plannedGroups: [
            .init(windowID: 1, title: "GitHub", color: "blue", tabIDs: [1, 2], existingGroupID: nil),
            .init(windowID: 2, title: "GitHub", color: "blue", tabIDs: [3, 4], existingGroupID: nil),
            .init(windowID: 1, title: "Docs", color: "green", tabIDs: [5, 6], existingGroupID: nil),
        ])
        XCTAssertEqual(
            ChromeTabOrganizer.describe(plan, fellBackToSiteGrouping: false),
            "grouped 6 tabs into 2 groups: GitHub and Docs."
        )
    }
}
