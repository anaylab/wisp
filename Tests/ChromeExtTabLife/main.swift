//
//  Chrome extension tab-life suite (phase 04): sessions (building, codec, cap,
//  rename, name matching, restore requests), stale-tab rules, triage ordering
//  and the spoken-command router.
//

import Foundation

var failureCount = 0
var checkCount = 0

func check(_ condition: Bool, _ description: String) {
    checkCount += 1
    if !condition {
        failureCount += 1
        print("FAIL: \(description)")
    }
}

let millisecondsPerDay = 24.0 * 60 * 60 * 1000
let nowMilliseconds = 1_800_000_000_000.0

func makeTab(
    _ id: Int,
    window windowID: Int = 1,
    index: Int? = nil,
    url: String? = nil,
    title: String? = nil,
    pinned: Bool = false,
    active: Bool = false,
    audible: Bool = false,
    group groupID: Int = ChromeTab.noGroupID,
    daysUnused: Double = 30
) -> ChromeTab {
    ChromeTab(
        id: id,
        windowId: windowID,
        index: index ?? id,
        title: title ?? "Tab \(id)",
        url: url ?? "https://site\(id).example/page",
        pinned: pinned,
        active: active,
        audible: audible,
        muted: false,
        groupId: groupID,
        lastAccessed: daysUnused < 0 ? 0 : nowMilliseconds - daysUnused * millisecondsPerDay
    )
}

let fixedDate = Date(timeIntervalSince1970: 1_790_000_000)

// MARK: - Building a session

let windowWithTwoGroups = ChromeTabsSnapshot(
    tabs: [
        makeTab(1, index: 0, url: "https://mail.example/", pinned: true),
        makeTab(2, index: 1, url: "https://a.example/1", group: 70),
        makeTab(3, index: 2, url: "https://a.example/2", group: 70),
        makeTab(4, index: 3, url: "https://loose.example/"),
        makeTab(5, index: 4, url: "https://b.example/1", group: 71),
        makeTab(6, index: 5, url: "chrome://newtab/"),
        makeTab(7, index: 6, url: "file:///Users/me/notes.txt"),
        makeTab(8, window: 2, index: 0, url: "https://other-window.example/"),
    ],
    groups: [
        ChromeTabGroup(id: 70, windowId: 1, title: "Thesis", color: "purple", collapsed: false),
        ChromeTabGroup(id: 71, windowId: 1, title: "Reading", color: "blue", collapsed: true),
    ],
    focusedWindowId: 1
)

let savedWindowSession = ChromeTabSessionBuilder.session(
    named: "  Thesis research. ", from: windowWithTwoGroups, scope: .focusedWindow, createdAt: fixedDate
)
check(savedWindowSession?.name == "Thesis research", "a name is trimmed of spaces and trailing punctuation")
check(savedWindowSession?.windows.count == 1, "focused window only")
check(savedWindowSession?.tabCount == 5, "new tab page and file:// aren't saved")
check(savedWindowSession?.groupCount == 2, "both groups are kept")
let savedSections = savedWindowSession?.windows.first?.sections ?? []
check(savedSections.map { $0.group?.title } == [nil, "Thesis", nil, "Reading"], "sections keep the window's order")
check(savedSections.first?.isPinned == true, "pinned tabs are their own section")
check(savedSections[safe: 1]?.group == ChromeSavedGroup(title: "Thesis", color: "purple"), "group title and colour are kept")
check(savedSections[safe: 1]?.tabs.map(\.url) == ["https://a.example/1", "https://a.example/2"], "group tabs in order")

let allWindowsSession = ChromeTabSessionBuilder.session(named: "all", from: windowWithTwoGroups, scope: .allWindows, createdAt: fixedDate)
check(allWindowsSession?.windows.count == 2, "all windows")
check(allWindowsSession?.windows.first?.sections.first?.tabs.first?.url == "https://mail.example/", "the focused window comes first")

let pickedTabsSession = ChromeTabSessionBuilder.session(named: "x", from: windowWithTwoGroups, scope: .tabs(withIDs: [4, 8]), createdAt: fixedDate)
check(pickedTabsSession?.tabCount == 2, "exactly the given tabs")
check(
    ChromeTabSessionBuilder.session(named: "x", from: windowWithTwoGroups, scope: .tabs(withIDs: [6, 7]), createdAt: fixedDate) == nil,
    "nothing savable → no session"
)

let sessionEncodedText = String(data: (try? ChromeTabSessionCodec.encode([savedWindowSession!])) ?? Data(), encoding: .utf8) ?? ""
check(!sessionEncodedText.contains("\"id\" : 2") && !sessionEncodedText.contains("windowId") && !sessionEncodedText.contains("groupId"),
      "no Chrome tab, window or group ids are persisted")

check(ChromeTabSessionBuilder.isSavableURL("https://a.example/"), "https is savable")
check(ChromeTabSessionBuilder.isSavableURL("chrome://settings/"), "chrome pages are savable")
check(!ChromeTabSessionBuilder.isSavableURL("chrome://newtab/"), "a new tab isn't")
check(!ChromeTabSessionBuilder.isSavableURL("javascript:alert(1)"), "javascript: isn't")
check(!ChromeTabSessionBuilder.isSavableURL("https://a.example/" + String(repeating: "x", count: 5000)), "a huge address isn't")

// MARK: - Names

check(ChromeTabSessionNameMatcher.normalizedName("Thesis-Research!") == "thesis research", "punctuation ignored")
check(ChromeTabSessionNameMatcher.normalizedName("Café  Notes") == "cafe notes", "accents folded, spaces collapsed")

var utcCalendar = Calendar(identifier: .gregorian)
utcCalendar.timeZone = TimeZone(identifier: "UTC")!
let october21 = utcCalendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12))!
check(ChromeTabSessionBuilder.datedName(prefix: "Cleanup", on: october21, calendar: utcCalendar) == "Cleanup Oct 21", "dated cleanup name")
check(ChromeTabSessionBuilder.uniqueName("Cleanup Oct 21", existingNames: []) == "Cleanup Oct 21", "free name kept")
check(ChromeTabSessionBuilder.uniqueName("Cleanup Oct 21", existingNames: ["cleanup oct 21"]) == "Cleanup Oct 21 (2)", "taken name gets (2)")
check(
    ChromeTabSessionBuilder.uniqueName("Cleanup Oct 21", existingNames: ["Cleanup Oct 21", "Cleanup Oct 21 (2)"]) == "Cleanup Oct 21 (3)",
    "and then (3)"
)

func session(_ name: String, createdDaysAgo: Double = 0, tabCount: Int = 2) -> ChromeTabSession {
    ChromeTabSession(
        id: UUID(),
        name: name,
        createdAt: fixedDate.addingTimeInterval(-createdDaysAgo * 86_400),
        windows: [ChromeSavedWindow(sections: [ChromeSavedSection(
            group: nil,
            tabs: (0..<tabCount).map { ChromeSavedTab(url: "https://t\($0).example/", title: "T\($0)", pinned: false) }
        )])]
    )
}

let thesisSession = session("Thesis Research")
let tripSession = session("Trip: Japan")
let savedSessions = [thesisSession, tripSession, session("Thesis")]

check(ChromeTabSessionNameMatcher.match(spokenPhrase: "thesis research", in: savedSessions) == .found(thesisSession), "exact name")
check(ChromeTabSessionNameMatcher.match(spokenPhrase: "THESIS-research", in: savedSessions) == .found(thesisSession), "case and punctuation ignored")
check(ChromeTabSessionNameMatcher.match(spokenPhrase: "my thesis research tabs", in: savedSessions) == .found(thesisSession), "spoken wrapping dropped")
check(ChromeTabSessionNameMatcher.match(spokenPhrase: "the trip japan session", in: savedSessions) == .found(tripSession), "session wrapper dropped")
check(ChromeTabSessionNameMatcher.match(spokenPhrase: "thesis researc", in: savedSessions) == .notFound, "never fuzzy: a typo matches nothing")
check(ChromeTabSessionNameMatcher.match(spokenPhrase: "research", in: savedSessions) == .notFound, "never fuzzy: part of a name matches nothing")
check(ChromeTabSessionNameMatcher.match(spokenPhrase: "thesis", in: savedSessions) == .found(savedSessions[2]), "a shorter exact name is its own session")
let lookAlikeSessions = [session("Thesis Research"), session("thesis-research", createdDaysAgo: 1)]
if case .ambiguous(let ambiguousSessions) = ChromeTabSessionNameMatcher.match(spokenPhrase: "thesis research", in: lookAlikeSessions) {
    check(ambiguousSessions.count == 2, "two look-alike names → ambiguous")
} else {
    check(false, "two look-alike names → ambiguous")
}

// MARK: - Keeping the list

let (afterReplacing, replaceEffect) = ChromeTabSessionList.saving(session("thesis research!", tabCount: 5), into: savedSessions)
check(replaceEffect == .replacedSessionWithSameName, "saving the same name again replaces it")
check(afterReplacing.count == 3 && afterReplacing.first?.tabCount == 5, "the new one is first")

let manySessions = (0..<ChromeTabSessionLimits.maximumSessions).map { session("Session \($0)", createdDaysAgo: Double($0) + 1) }
let (afterAddingToFullList, addEffect) = ChromeTabSessionList.saving(session("Newest"), into: manySessions)
check(addEffect == .added, "a new name is added")
check(afterAddingToFullList.count == 200, "capped at 200")
check(afterAddingToFullList.first?.name == "Newest", "newest first")
check(!afterAddingToFullList.contains { $0.name == "Session 199" }, "the oldest is dropped")

if case .renamed(let renamedSessions) = ChromeTabSessionList.renaming(sessionWithID: tripSession.id, to: " Kyoto trip ", in: savedSessions) {
    check(renamedSessions.first { $0.id == tripSession.id }?.name == "Kyoto trip", "rename")
} else {
    check(false, "rename")
}
check(ChromeTabSessionList.renaming(sessionWithID: tripSession.id, to: "thesis", in: savedSessions) == .nameTaken, "rename to a taken name refused")
check(ChromeTabSessionList.renaming(sessionWithID: tripSession.id, to: "  !! ", in: savedSessions) == .emptyName, "rename to nothing refused")
check(ChromeTabSessionList.renaming(sessionWithID: UUID(), to: "x", in: savedSessions) == .notFound, "rename of a missing session")
check(
    ChromeTabSessionList.renaming(sessionWithID: tripSession.id, to: "Trip – JAPAN", in: savedSessions) != .nameTaken,
    "renaming a session to its own name with new casing is fine"
)

// MARK: - Codec

if let encodedData = try? ChromeTabSessionCodec.encode([savedWindowSession!, thesisSession]),
   let decodedSessions = ChromeTabSessionCodec.decode(encodedData) {
    check(decodedSessions.count == 2, "round trip keeps both")
    check(decodedSessions.contains(savedWindowSession!), "round trip keeps every field")
    check(decodedSessions.first?.createdAt == thesisSession.createdAt, "decoded newest first")
} else {
    check(false, "codec round trip")
}
check(ChromeTabSessionCodec.decode(Data("not json".utf8)) == nil, "a damaged file reads as nil, not empty")
check(ChromeTabSessionCodec.decode(Data(#"{"version":99,"sessions":[]}"#.utf8)) == nil, "a newer file format isn't overwritten")
check(ChromeTabSessionCodec.decode(Data(#"{"version":1,"sessions":[]}"#.utf8)) == [], "an empty file is empty")

// MARK: - Restoring

let restoreRequests = ChromeTabRestorePlanner.openRequests(for: allWindowsSession!)
check(restoreRequests.count == 5, "one request per section: pinned, Thesis, loose, Reading, other window")
check(restoreRequests.map(\.opensNewWindow) == [true, false, false, false, true], "each saved window opens a new window")
check(restoreRequests.map(\.windowOffset) == [0, 0, 0, 0, 1], "requests know their window")
check(restoreRequests.first?.pinned == true && restoreRequests.first?.groupTitle == nil, "pinned section is pinned, ungrouped")
check(restoreRequests[safe: 1]?.groupTitle == "Thesis" && restoreRequests[safe: 1]?.groupColor == "purple", "group comes back named and coloured")

let bigSession = session("Big", tabCount: 130)
let bigRestoreRequests = ChromeTabRestorePlanner.openRequests(for: bigSession)
check(bigRestoreRequests.map { $0.urls.count } == [60, 60, 10], "big sections split at the extension's 60-tab cap")
check(bigRestoreRequests.map(\.opensNewWindow) == [true, false, false], "split pieces stay in one window")

var oddColourSession = session("Odd")
oddColourSession.windows[0].sections[0].group = ChromeSavedGroup(title: "X", color: "#ff0000")
check(ChromeTabRestorePlanner.openRequests(for: oddColourSession).first?.groupColor == nil, "an unknown colour isn't sent")

check(!ChromeTabRestorePlanner.asksBeforeRestoring(session("s", tabCount: 9)), "9 tabs restore without asking")
check(ChromeTabRestorePlanner.asksBeforeRestoring(session("s", tabCount: 10)), "10 tabs ask first")

check(ChromeTabSessionDescriptions.listText(for: []).contains("no saved tab sessions"), "empty list says so")
let listText = ChromeTabSessionDescriptions.listText(for: savedSessions)
check(listText.contains("3 saved tab sessions") && listText.contains("Trip: Japan (2 tabs"), "list names each session")

// MARK: - Stale tabs

let staleSnapshot = ChromeTabsSnapshot(
    tabs: [
        makeTab(10, daysUnused: 30),
        makeTab(11, pinned: true, daysUnused: 60),
        makeTab(12, audible: true, daysUnused: 60),
        makeTab(13, active: true, daysUnused: 60),
        makeTab(14, group: 90, daysUnused: 60),
        makeTab(15, url: "chrome://settings/", daysUnused: 60),
        makeTab(16, url: "file:///tmp/a.html", daysUnused: 60),
        makeTab(17, daysUnused: 3),
        makeTab(18, daysUnused: -1),
        makeTab(19, daysUnused: 90),
        makeTab(20, url: "chrome-extension://abc/options.html", daysUnused: 60),
    ],
    groups: [ChromeTabGroup(id: 90, windowId: 1, title: "Mine", color: "red", collapsed: false)],
    focusedWindowId: 1
)
let defaultStaleTabIDs = ChromeStaleTabFinder.staleTabs(in: staleSnapshot, nowMilliseconds: nowMilliseconds, rules: .standard).map(\.id)
check(defaultStaleTabIDs == [19, 10], "only loose, unpinned, silent, background web tabs past 14 days, oldest first")
let withChromePagesIDs = ChromeStaleTabFinder.staleTabs(
    in: staleSnapshot, nowMilliseconds: nowMilliseconds, rules: ChromeStaleTabRules(includesChromePages: true)
).map(\.id)
check(withChromePagesIDs.contains(15), "chrome pages only when asked")
check(!withChromePagesIDs.contains(16) && !withChromePagesIDs.contains(20), "file and extension pages never")
check(
    ChromeStaleTabFinder.staleTabs(in: staleSnapshot, nowMilliseconds: nowMilliseconds, rules: ChromeStaleTabRules(minimumDaysUnused: 2)).map(\.id).contains(17),
    "a shorter age reaches newer tabs"
)
check(ChromeStaleTabRules(minimumDaysUnused: 0).minimumDaysUnused == 1, "minimum age is at least a day")
check(ChromeStaleTabRules(minimumDaysUnused: 9999).minimumDaysUnused == 365, "and at most a year")
check(ChromeStaleTabFinder.nothingStaleText(rules: .standard).contains("14 days"), "nothing-stale reply names the age")

// MARK: - Triage

let triageSnapshot = ChromeTabsSnapshot(
    tabs: [
        makeTab(30, index: 0, url: "https://github.com/a", active: true, daysUnused: 0),
        makeTab(31, index: 1, url: "https://github.com/a", daysUnused: 40),      // duplicate (and stale)
        makeTab(32, index: 2, url: "https://github.com/b", daysUnused: 1),
        makeTab(33, index: 3, url: "https://docs.example.com/x", daysUnused: 1),
        makeTab(34, index: 4, url: "https://docs.example.com/y", daysUnused: 2),
        makeTab(35, index: 5, url: "https://old.example.com/", daysUnused: 50),  // stale
        makeTab(36, index: 6, url: "https://lonely.example.org/", daysUnused: 1),
    ],
    groups: [],
    focusedWindowId: 1
)
let triagePlan = ChromeTabTriagePlanner.plan(for: triageSnapshot, nowMilliseconds: nowMilliseconds, staleRules: .standard, topicGroups: [])
check(triagePlan.duplicateTabs.map(\.id) == [31], "duplicates found")
check(triagePlan.staleTabs.map(\.id) == [35], "a duplicate isn't counted again as stale")
check(Set(triagePlan.groupingPlan.plannedGroups.map(\.title)) == ["GitHub", "Example"], "site groups from what's left")
check(!triagePlan.groupingPlan.plannedGroups.flatMap(\.tabIDs).contains(31), "a closing tab is never grouped")
check(triagePlan.steps.count == 3, "three steps")
if case .closeDuplicates(let duplicateCount)? = triagePlan.steps.first {
    check(duplicateCount == 1, "duplicates first")
} else {
    check(false, "duplicates first")
}
if case .closeStaleTabs(let staleCount, let days)? = triagePlan.steps[safe: 1] {
    check(staleCount == 1 && days == 14, "then stale tabs")
} else {
    check(false, "then stale tabs")
}
if case .makeGroups(_, let groupedCount)? = triagePlan.steps[safe: 2] {
    check(groupedCount == triagePlan.groupedTabCount && groupedCount == 4, "then groups, with the count that will happen")
} else {
    check(false, "then groups")
}
check(triagePlan.closedTabCount == 2, "closed count")

let topicTriagePlan = ChromeTabTriagePlanner.plan(
    for: triageSnapshot, nowMilliseconds: nowMilliseconds, staleRules: .standard,
    topicGroups: [(title: "Work", tabIDs: [32, 33, 31, 35])]
)
check(topicTriagePlan.groupingPlan.plannedGroups.map(\.tabIDs) == [[32, 33]], "topic groups win, minus tabs being closed")

let restrictedPlan = ChromeTabTriagePlanner.restricted(triagePlan, toOpenTabIDs: [32, 33, 34, 35, 36])
check(restrictedPlan.duplicateTabs.isEmpty, "a tab closed meanwhile is dropped")
check(restrictedPlan.groupingPlan.plannedGroups.map(\.title) == ["Example"], "a group left with one tab is dropped")
check(restrictedPlan.staleTabs.map(\.id) == [35], "tabs still open stay in the plan")

let tidySnapshot = ChromeTabsSnapshot(tabs: [makeTab(40, url: "https://only.example/", daysUnused: 1)], groups: [], focusedWindowId: 1)
check(ChromeTabTriagePlanner.plan(for: tidySnapshot, nowMilliseconds: nowMilliseconds, staleRules: .standard, topicGroups: []).isEmpty, "nothing to do → empty")
check(
    ChromeTabTriagePlanner.resultText(for: triagePlan, savedSessionName: "Cleanup Oct 21")
        == "closed 1 duplicate, 1 tab you hadn't used (saved as \"Cleanup Oct 21\") and grouped 4 tabs into 2 groups.",
    "result text"
)

// MARK: - Card wording

let cardTabs = (1...11).map { ChromeTabLifeCardText.ListedTab(title: "Tab \($0)", url: "https://www.site\($0).example/x") }
let staleCardText = ChromeTabLifeCardText.closeStaleTabs(sessionName: "Cleanup Oct 21", minimumDaysUnused: 14, closingTabs: cardTabs)
check(staleCardText.headline == "Close 11 tabs · saved as 'Cleanup Oct 21' first", "stale card headline")
check(staleCardText.rows.count == 8 && staleCardText.rows.first == .init(key: "Tab 1", value: "site1.example"), "8 rows of titles with their site")
check(staleCardText.moreText == "and 3 more", "the rest are counted")
check(staleCardText.footnote.contains("restore Cleanup Oct 21"), "the card says how to undo")

let triageCardText = ChromeTabLifeCardText.triage(
    duplicateTabs: Array(cardTabs.prefix(3)), staleTabs: Array(cardTabs.suffix(2)), sessionName: "Cleanup Oct 21",
    minimumDaysUnused: 14, groupTitles: ["GitHub", "Docs"], groupedTabCount: 6
)
check(triageCardText.headline == "Triage · Close 5 tabs, group 6", "triage headline counts match the plan")
check(triageCardText.rows.prefix(3).map(\.key) == ["Close duplicates", "Close unused 14+ days", "Make 2 groups"], "triage steps in order")
check(triageCardText.rows[safe: 1]?.value == "2 tabs · saved as 'Cleanup Oct 21' first", "stale step names the safety copy")
check(triageCardText.rows.count == 8 && triageCardText.moreText == nil, "3 steps + the 5 closing titles fit in 8 rows")
let bigTriageCardText = ChromeTabLifeCardText.triage(
    duplicateTabs: cardTabs, staleTabs: [], sessionName: nil, minimumDaysUnused: 14, groupTitles: [], groupedTabCount: 0
)
check(bigTriageCardText.rows.count == 8 && bigTriageCardText.moreText == "and 4 more", "titles fill the rows the steps leave")

let restoreCardText = ChromeTabLifeCardText.restoreSession(sessionName: "Thesis research", windowCount: 1, groupCount: 2, restoringTabs: cardTabs)
check(restoreCardText.headline == "Open 11 tabs · 'Thesis research'", "restore headline")
check(restoreCardText.footnote.contains("a new window, with its 2 groups"), "restore says where")

check(ChromeTabLifeCardText.shortTitle(String(repeating: "x", count: 100)).count == 60, "long titles are cut")
check(ChromeTabLifeCardText.shortTitle("  \n ") == "(untitled)", "empty titles say so")
check(ChromeTabLifeCardText.siteText(forURL: "chrome://settings/privacy") == "chrome://settings", "chrome page site")

// MARK: - Router

let knownSessionNames = ["Thesis Research", "gmail"]
func route(_ transcript: String) -> ChromeTabLifeCommand? {
    ChromeTabLifeCommandRouter.command(for: transcript, savedSessionNames: knownSessionNames)
}

let positivePhrases: [(String, ChromeTabLifeCommand)] = [
    ("Save these tabs as thesis research", .saveSession(sessionName: "thesis research", scope: .focusedWindow)),
    ("save this window", .saveSession(sessionName: nil, scope: .focusedWindow)),
    ("hey wisp, save this window as Trip planning.", .saveSession(sessionName: "trip planning", scope: .focusedWindow)),
    ("save all my tabs as backup", .saveSession(sessionName: "backup", scope: .allWindows)),
    ("save my tabs for later", .saveSession(sessionName: nil, scope: .focusedWindow)),
    ("restore thesis research", .restoreSession(spokenName: "thesis research")),
    ("reopen my thesis research tabs", .restoreSession(spokenName: "my thesis research tabs")),
    ("bring back the japan trip session", .restoreSession(spokenName: "the japan trip session")),
    ("open my gmail tabs", .restoreSession(spokenName: "my gmail tabs")),
    ("what tab sessions do i have", .listSessions),
    ("list my tab sessions", .listSessions),
    ("show me my saved tabs", .listSessions),
    ("clean up old tabs", .closeStaleTabs(.standard)),
    ("close my stale chrome tabs", .closeStaleTabs(.standard)),
    ("close tabs i haven't used in 2 weeks", .closeStaleTabs(ChromeStaleTabRules(minimumDaysUnused: 14))),
    ("clean up tabs older than 30 days", .closeStaleTabs(ChromeStaleTabRules(minimumDaysUnused: 30))),
    ("close old tabs including chrome pages", .closeStaleTabs(ChromeStaleTabRules(includesChromePages: true))),
    ("get rid of tabs i haven't used in a month", .closeStaleTabs(ChromeStaleTabRules(minimumDaysUnused: 30))),
    ("please clean up my unused tabs", .closeStaleTabs(.standard)),
    ("triage my tabs", .triage(.standard)),
    ("Triage Chrome", .triage(.standard)),
]
for (phrase, expectedCommand) in positivePhrases {
    check(route(phrase) == expectedCommand, "routes: \"\(phrase)\" (got \(String(describing: route(phrase))))")
}

let negativePhrases = [
    "organize my tabs",                          // the existing organizer's
    "clean up my tabs",                          // organize, not a sweep
    "close duplicate tabs",
    "close tabs",
    "close this tab",
    "how do i clean up old tabs",
    "what are my old tabs",
    "open gmail",                                // a site, even with a "gmail" session
    "reopen the last closed tab",
    "restore my window size",
    "save this page",
    "save this file as report",
    "save these",
    "save the tabs to my bookmarks",
    "what's in my thesis tab session",
    "triage my email",
    "triage",
    "i should really clean up my old tabs at some point when i have a free afternoon",
    "remember to close old tabs",
    "close tabs in 2 weeks",
    "close the youtube tabs older than me",
]
for phrase in negativePhrases {
    check(route(phrase) == nil, "leaves alone: \"\(phrase)\" (got \(String(describing: route(phrase))))")
}

check(ChromeTabLifeCommandRouter.days(inDurationText: "2 weeks") == 14, "2 weeks")
check(ChromeTabLifeCommandRouter.days(inDurationText: "a month") == 30, "a month")
check(ChromeTabLifeCommandRouter.days(inDurationText: "ten days") == 10, "ten days")
check(ChromeTabLifeCommandRouter.days(inDurationText: "a while") == nil, "a while isn't a duration")

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
