//
//  Chrome focus mode suite (phase 09): planner decisions, the study-block rule,
//  and spoken-phrase parsing.
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

func makeTab(
    _ id: Int,
    title: String,
    url: String,
    groupId: Int = -1,
    pinned: Bool = false,
    audible: Bool = false,
    muted: Bool = false,
    windowId: Int = 1
) -> ChromeTab {
    ChromeTab(
        id: id, windowId: windowId, index: id, title: title, url: url, pinned: pinned, active: false,
        audible: audible, muted: muted, groupId: groupId, lastAccessed: 0
    )
}

// MARK: - Planner

let snapshot = ChromeTabsSnapshot(
    tabs: [
        makeTab(1, title: "Inbox", url: "https://mail.google.com/mail", pinned: true),
        makeTab(2, title: "Essay outline – Google Docs", url: "https://docs.google.com/document/d/1", groupId: 10),
        makeTab(3, title: "Sources for the essay", url: "https://jstor.org/stable/1", groupId: 10),
        makeTab(4, title: "Running shoes", url: "https://shop.example.com/shoes", groupId: 11),
        makeTab(5, title: "Flights to Lisbon", url: "https://flights.example.com", groupId: 12),
        makeTab(6, title: "Essays on Modernism", url: "https://en.wikipedia.org/wiki/Modernism"),
        makeTab(7, title: "Thesaurus", url: "https://thesaurus.com/browse/good"),
        makeTab(8, title: "lofi hip hop radio", url: "https://www.youtube.com/watch?v=jfKfPfyJRdk", audible: true),
        makeTab(9, title: "r/all", url: "https://reddit.com/r/all"),
        makeTab(13, title: "Podcast", url: "https://podcasts.example.com/ep1", audible: true),
        makeTab(14, title: "Already muted video", url: "https://vimeo.com/1", audible: true, muted: true),
        makeTab(15, title: "Pinned YouTube", url: "https://youtube.com/", pinned: true, audible: true),
    ],
    groups: [
        ChromeTabGroup(id: 10, windowId: 1, title: "School", color: "blue", collapsed: false),
        ChromeTabGroup(id: 11, windowId: 1, title: "Shopping", color: "red", collapsed: false),
        ChromeTabGroup(id: 12, windowId: 1, title: "Trip", color: "pink", collapsed: true),
    ],
    focusedWindowId: 1
)

let essayPlan = ChromeFocusPlanner.plan(
    snapshot: snapshot,
    topic: "my essay",
    allowListedHosts: ["thesaurus.com"],
    distractingHosts: ChromeFocusPlanner.defaultDistractingHosts,
    movesDistractingTabsToLaterWindow: true
)
check(essayPlan.keepTabIDs == [2, 3, 6, 7], "on-task: titles sharing 'essay' (plural folded) plus the allow-listed site")
check(essayPlan.keepGroupIDs == [10], "a group holding an on-task tab stays open")
check(essayPlan.collapseGroupIDs == [11], "off-task expanded groups collapse; an already-collapsed one isn't listed")
check(essayPlan.muteTabIDs == [8, 13, 15], "every off-task tab playing sound is muted, not the already-muted one")
check(essayPlan.focusGroupTabIDs == [6, 7], "only loose, unpinned on-task tabs go into Focus")
check(essayPlan.distractingTabIDs == [8, 9], "distracting sites move, but never a pinned tab")
check(!essayPlan.keepTabIDs.contains(1) && !essayPlan.distractingTabIDs.contains(1) && !essayPlan.muteTabIDs.contains(1),
      "an unsure tab (pinned mail) is left exactly alone")
check(!essayPlan.distractingTabIDs.contains(13), "an unknown site is unsure, so it stays put (only muted)")
check(!essayPlan.changesNothing, "the essay plan changes something")

let namedGroupPlan = ChromeFocusPlanner.plan(
    snapshot: snapshot,
    topic: "trip planning",
    allowListedHosts: [],
    distractingHosts: [],
    movesDistractingTabsToLaterWindow: false
)
check(namedGroupPlan.keepGroupIDs.contains(12), "a group whose name matches the topic stays")
check(namedGroupPlan.collapseGroupIDs.sorted() == [10, 11], "the others collapse")
check(namedGroupPlan.distractingTabIDs.isEmpty, "with no distraction list nothing is distracting")

let noTopicPlan = ChromeFocusPlanner.plan(
    snapshot: snapshot,
    topic: "",
    allowListedHosts: [],
    distractingHosts: ChromeFocusPlanner.defaultDistractingHosts,
    movesDistractingTabsToLaterWindow: false
)
check(noTopicPlan.keepTabIDs.isEmpty, "no topic and no allow-list: nothing is on-task")
check(noTopicPlan.collapseGroupIDs.sorted() == [10, 11], "no topic: every expanded group collapses")
check(noTopicPlan.focusGroupTabIDs.isEmpty, "no topic: no Focus group")

let alreadyFocused = ChromeTabsSnapshot(
    tabs: [makeTab(1, title: "Essay draft", url: "https://docs.google.com/1", groupId: 5)],
    groups: [ChromeTabGroup(id: 5, windowId: 1, title: "Focus", color: "green", collapsed: false)],
    focusedWindowId: 1
)
check(ChromeFocusPlanner.plan(snapshot: alreadyFocused, topic: "essay", allowListedHosts: [], distractingHosts: [], movesDistractingTabsToLaterWindow: true).changesNothing,
      "a layout that's already focused changes nothing")

// Topic words
check(ChromeFocusPlanner.contentWords(in: "focus on my history essays") == ["history", "essay"], "stop words dropped, plural folded")
check(ChromeFocusPlanner.contentWords(in: "AI") == [], "words under three letters are too loose to match")
check(ChromeFocusPlanner.contentWords(in: "class") == ["class"], "a double-s word keeps its s")

// Hosts
check(ChromeFocusPlanner.hostMatchesAny(urlString: "https://m.youtube.com/watch", hosts: ["youtube.com"]), "subdomain matches")
check(ChromeFocusPlanner.hostMatchesAny(urlString: "https://youtu.be/abc", hosts: ["youtube.com"]), "youtu.be is YouTube")
check(ChromeFocusPlanner.hostMatchesAny(urlString: "https://twitter.com/home", hosts: ["x.com"]), "twitter.com is X")
check(!ChromeFocusPlanner.hostMatchesAny(urlString: "https://notyoutube.com/", hosts: ["youtube.com"]), "a lookalike domain doesn't match")
check(!ChromeFocusPlanner.hostMatchesAny(urlString: "https://box.com/", hosts: ["x.com"]), "x.com doesn't match box.com")
check(!ChromeFocusPlanner.hostMatchesAny(urlString: "chrome://newtab", hosts: ["newtab"]), "non-web pages never match")
check(ChromeFocusPlanner.hosts(fromListText: "https://www.Reddit.com/r/x, youtube.com\nreddit.com ,") == ["reddit.com", "youtube.com"],
      "a typed list is normalised and de-duplicated")

// Description
check(ChromeFocusPlanner.describe(collapsedGroupCount: 2, mutedTabCount: 1, focusGroupedTabCount: 0, movedTabCount: 3)
      == "collapsed 2 groups, muted 1 tab and moved 3 tabs to a Later window", "description lists what changed")
check(ChromeFocusPlanner.describe(collapsedGroupCount: 0, mutedTabCount: 0, focusGroupedTabCount: 0, movedTabCount: 0)
      == "your tabs already look focused", "nothing changed reads as already focused")

// MARK: - Study blocks

let blockStart = Date(timeIntervalSince1970: 1_000_000)
let essayBlock = ChromeFocusStudyBlockPolicy.Block(
    id: "study-a-1", title: "Study: Essay draft", courseCode: "ENGL101",
    start: blockStart, end: blockStart.addingTimeInterval(3600)
)
let laterBlock = ChromeFocusStudyBlockPolicy.Block(
    id: "study-b-1", title: "Study: Lab report", courseCode: nil,
    start: blockStart.addingTimeInterval(7200), end: blockStart.addingTimeInterval(10800)
)
let tenMinutesIn = blockStart.addingTimeInterval(600)

check(ChromeFocusStudyBlockPolicy.blockToStartFocus(
    blocks: [laterBlock, essayBlock], now: tenMinutesIn, focusesEveryApprovedBlock: true,
    optedInBlockIDs: [], alreadyFocusedBlockIDs: []) == essayBlock, "the switch focuses the block under way")
check(ChromeFocusStudyBlockPolicy.blockToStartFocus(
    blocks: [essayBlock], now: tenMinutesIn, focusesEveryApprovedBlock: false,
    optedInBlockIDs: [], alreadyFocusedBlockIDs: []) == nil, "without the switch or the chip, nothing starts")
check(ChromeFocusStudyBlockPolicy.blockToStartFocus(
    blocks: [essayBlock], now: tenMinutesIn, focusesEveryApprovedBlock: false,
    optedInBlockIDs: ["study-a-1"], alreadyFocusedBlockIDs: []) == essayBlock, "the chip opts one block in")
check(ChromeFocusStudyBlockPolicy.blockToStartFocus(
    blocks: [essayBlock], now: tenMinutesIn, focusesEveryApprovedBlock: true,
    optedInBlockIDs: [], alreadyFocusedBlockIDs: ["study-a-1"]) == nil, "a block is focused once, not again after stop")
check(ChromeFocusStudyBlockPolicy.blockToStartFocus(
    blocks: [essayBlock], now: blockStart.addingTimeInterval(-60), focusesEveryApprovedBlock: true,
    optedInBlockIDs: [], alreadyFocusedBlockIDs: []) == nil, "not before the block starts")
check(ChromeFocusStudyBlockPolicy.blockToStartFocus(
    blocks: [essayBlock], now: blockStart.addingTimeInterval(3570), focusesEveryApprovedBlock: true,
    optedInBlockIDs: [], alreadyFocusedBlockIDs: []) == nil, "not in its last minute")
check(ChromeFocusStudyBlockPolicy.topic(for: essayBlock) == "Essay draft ENGL101", "topic is the block's work and course")
check(ChromeFocusStudyBlockPolicy.minutesRemaining(in: essayBlock, now: tenMinutesIn) == 50, "runs to the end of the block")

// MARK: - Phrases

let startPhrases: [(String, ChromeFocusCommand)] = [
    ("focus on my essay for 45 minutes", .start(topic: "my essay", minutes: 45)),
    ("Hey Wisp, focus on my history essay for an hour.", .start(topic: "my history essay", minutes: 60)),
    ("focus on chemistry for half an hour", .start(topic: "chemistry", minutes: 30)),
    ("focus on studying for my exam for 2 hours", .start(topic: "studying for my exam", minutes: 120)),
    ("focus on the lab report for 1 hour 30 minutes", .start(topic: "the lab report", minutes: 90)),
    ("focus mode for 25 minutes", .start(topic: "", minutes: 25)),
    ("start focus mode on biology", .start(topic: "biology", minutes: 45)),
    ("focus chrome", .start(topic: "", minutes: 45)),
    ("focus chrome on my thesis for forty five minutes", .start(topic: "my thesis", minutes: 45)),
    ("can you focus on calculus for 20 mins please", .start(topic: "calculus", minutes: 20)),
    ("45 minute focus on my essay", .start(topic: "my essay", minutes: 45)),
    ("a 30-minute focus session on spanish", .start(topic: "spanish", minutes: 30)),
]
for (phrase, expectedCommand) in startPhrases {
    let parsedCommand = ChromeFocusCommandParser.command(for: phrase)
    check(parsedCommand == expectedCommand, "\"\(phrase)\" → \(expectedCommand), got \(String(describing: parsedCommand))")
}

for stopPhrase in ["stop focus", "Stop focus mode.", "end focus", "hey wisp, end focus mode", "I'm done focusing", "cancel focus"] {
    check(ChromeFocusCommandParser.command(for: stopPhrase) == .stop, "\"\(stopPhrase)\" stops focus")
}

let phrasesThatAreNotCommands = [
    "focus on the search field",                         // a screen thing, no duration
    "focus on my essay",                                 // no duration and no "focus mode": could be advice
    "how do i focus on my essay for an hour",            // a question
    "what is focus mode",                                // a question
    "i can't focus on anything for more than 5 minutes", // a sentence about focus
    "focus on the search box for 5 minutes",             // a screen thing
    "focus on my essay for 500 minutes",                 // too long
    "focus on my essay for english",                     // "for" isn't a duration
    "focused on my essay for 45 minutes",                // a statement, not a command
    "set a timer for 45 minutes",                        // a timer, not focus
    "organize my tabs",                                  // a different tab command
    "focus mode is great",                               // not a topic
    "focus mode",                                        // most likely macOS Focus
    "turn on focus mode",                                // most likely macOS Focus
    "turn off focus mode",                               // most likely macOS Focus
    "stop focusing on the negatives and help me write this email for 10 minutes", // too long
]
for phrase in phrasesThatAreNotCommands {
    let parsedCommand = ChromeFocusCommandParser.command(for: phrase)
    check(parsedCommand == nil, "\"\(phrase)\" is not a focus command, got \(String(describing: parsedCommand))")
}

check(ChromeFocusCommandParser.minutes(fromDurationText: "1.5 hours") == 90, "decimal hours")
check(ChromeFocusCommandParser.minutes(fromDurationText: "an hour and a half") == 90, "an hour and a half")
check(ChromeFocusCommandParser.minutes(fromDurationText: "0 minutes") == nil, "zero is no duration")

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
