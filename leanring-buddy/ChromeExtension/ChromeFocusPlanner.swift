//
//  ChromeFocusPlanner.swift
//  leanring-buddy
//
//  Focus mode's decisions (phase 09), pure: given the tabs Chrome reports, the
//  focus topic, an allow-list and a distraction list, which tabs and groups stay
//  in view and which are collapsed, muted or moved to a "Later" window. The
//  extension (`handlers/focus-mode.js`) only carries the plan out and puts it
//  back.
//
//  The bias is toward keeping things in view. A tab is *on-task* when its site is
//  allow-listed or its title/URL shares a content word with the topic. A tab is
//  *distracting* only when its site is on the distraction list. Everything else
//  is "unsure", and an unsure tab is left exactly where it is (it is only muted
//  if it is playing sound). Hiding the one tab the user needed would make focus
//  mode something they turn off.
//

import Foundation

nonisolated struct ChromeFocusPlan: Equatable, Sendable {
    /// On-task tabs: never collapsed away, muted or moved.
    let keepTabIDs: [Int]
    /// Groups holding an on-task tab, or whose name matches the topic.
    let keepGroupIDs: [Int]
    /// Every other group that is expanded now.
    let collapseGroupIDs: [Int]
    /// Tabs making sound that aren't on-task.
    let muteTabIDs: [Int]
    /// Loose, unpinned on-task tabs, grouped as "Focus" (one group per window).
    let focusGroupTabIDs: [Int]
    /// Unpinned tabs on a distracting site. Moved only when the user wants it.
    let distractingTabIDs: [Int]
    let movesDistractingTabsToLaterWindow: Bool

    var changesNothing: Bool {
        collapseGroupIDs.isEmpty && muteTabIDs.isEmpty && focusGroupTabIDs.isEmpty
            && (distractingTabIDs.isEmpty || !movesDistractingTabsToLaterWindow)
    }
}

nonisolated enum ChromeFocusPlanner {

    /// Sites that pull attention by design. Editable in Settings → Agent → Chrome Tabs.
    static let defaultDistractingHosts = ["youtube.com", "reddit.com", "x.com", "instagram.com", "tiktok.com", "netflix.com"]

    /// Words that say nothing about what the user is working on: "focus on *my* essay".
    private static let topicStopWords: Set<String> = [
        "a", "an", "the", "my", "our", "your", "this", "that", "these", "those", "on", "for", "of", "to", "in",
        "and", "or", "with", "about", "at", "by", "from", "some", "work", "working", "study", "studying",
        "stuff", "things", "thing", "it", "i", "me", "minutes", "minute", "hour", "hours", "focus", "chrome",
        "tab", "tabs", "please", "now", "just", "new", "page", "home",
    ]

    /// A topic word shorter than this matches too much ("ai" is inside "mail").
    private static let minimumTopicWordLength = 3

    static func plan(
        snapshot: ChromeTabsSnapshot,
        topic: String,
        allowListedHosts: [String],
        distractingHosts: [String],
        movesDistractingTabsToLaterWindow: Bool
    ) -> ChromeFocusPlan {
        let topicWords = contentWords(in: topic)

        var onTaskTabIDs: Set<Int> = []
        var distractingTabIDs: [Int] = []
        for tab in snapshot.tabs {
            if isOnTask(tab: tab, topicWords: topicWords, allowListedHosts: allowListedHosts) {
                onTaskTabIDs.insert(tab.id)
            } else if !tab.pinned, hostMatchesAny(urlString: tab.url, hosts: distractingHosts) {
                distractingTabIDs.append(tab.id)
            }
        }

        var keepGroupIDs: [Int] = []
        var collapseGroupIDs: [Int] = []
        for group in snapshot.groups {
            let groupHoldsOnTaskTab = snapshot.tabs.contains { $0.groupId == group.id && onTaskTabIDs.contains($0.id) }
            let groupNameMatchesTopic = !contentWords(in: group.title).isDisjoint(with: topicWords)
            if groupHoldsOnTaskTab || groupNameMatchesTopic {
                keepGroupIDs.append(group.id)
            } else if !group.collapsed {
                collapseGroupIDs.append(group.id)
            }
        }

        let keepTabIDs = snapshot.tabs.map(\.id).filter { onTaskTabIDs.contains($0) }
        let muteTabIDs = snapshot.tabs
            .filter { $0.audible && $0.muted != true && !onTaskTabIDs.contains($0.id) }
            .map(\.id)
        let focusGroupTabIDs = snapshot.tabs
            .filter { onTaskTabIDs.contains($0.id) && !$0.pinned && !$0.isInGroup }
            .map(\.id)

        return ChromeFocusPlan(
            keepTabIDs: keepTabIDs,
            keepGroupIDs: keepGroupIDs,
            collapseGroupIDs: collapseGroupIDs,
            muteTabIDs: muteTabIDs,
            focusGroupTabIDs: focusGroupTabIDs,
            distractingTabIDs: distractingTabIDs,
            movesDistractingTabsToLaterWindow: movesDistractingTabsToLaterWindow
        )
    }

    static func isOnTask(tab: ChromeTab, topicWords: Set<String>, allowListedHosts: [String]) -> Bool {
        if hostMatchesAny(urlString: tab.url, hosts: allowListedHosts) { return true }
        guard !topicWords.isEmpty else { return false }
        let tabWords = contentWords(in: tab.title).union(contentWords(in: urlWordsText(tab.url)))
        return !tabWords.isDisjoint(with: topicWords)
    }

    /// Lowercased words, stop words dropped, a plural "s" folded ("essays" = "essay").
    static func contentWords(in text: String) -> Set<String> {
        let rawWords = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        var words: Set<String> = []
        for rawWord in rawWords where rawWord.count >= minimumTopicWordLength && !topicStopWords.contains(rawWord) {
            words.insert(singularized(rawWord))
        }
        return words
    }

    private static func singularized(_ word: String) -> String {
        guard word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") else { return word }
        return String(word.dropLast())
    }

    /// The host and path of a URL as words; the query is left out (tracking noise).
    private static func urlWordsText(_ urlString: String) -> String {
        guard let urlComponents = URLComponents(string: urlString) else { return "" }
        return [urlComponents.host ?? "", urlComponents.path].joined(separator: " ")
    }

    /// "youtube.com" matches youtube.com, www.youtube.com, m.youtube.com and music.youtube.com.
    static func hostMatchesAny(urlString: String, hosts: [String]) -> Bool {
        guard let urlComponents = URLComponents(string: urlString),
              let scheme = urlComponents.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let tabHost = urlComponents.host?.lowercased(), !tabHost.isEmpty else { return false }
        for listedHost in hosts.map(normalizedHost) where !listedHost.isEmpty {
            if tabHost == listedHost || tabHost.hasSuffix("." + listedHost) { return true }
            // youtu.be and twitter.com are the same sites under another name.
            if listedHost == "youtube.com" && tabHost == "youtu.be" { return true }
            if listedHost == "x.com" && (tabHost == "twitter.com" || tabHost.hasSuffix(".twitter.com")) { return true }
        }
        return false
    }

    /// What a user typed into the list ("https://www.Reddit.com/r/x") → "reddit.com".
    static func normalizedHost(_ typedHost: String) -> String {
        var host = typedHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where host.hasPrefix(scheme) {
            host = String(host.dropFirst(scheme.count))
        }
        if let pathStart = host.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            host = String(host[..<pathStart])
        }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host
    }

    /// "youtube.com, reddit.com" (or one per line) → normalised, de-duplicated hosts.
    static func hosts(fromListText listText: String) -> [String] {
        var hosts: [String] = []
        for piece in listText.components(separatedBy: CharacterSet(charactersIn: ",\n ")) {
            let host = normalizedHost(piece)
            if !host.isEmpty, !hosts.contains(host) { hosts.append(host) }
        }
        return hosts
    }

    /// "collapsed 2 groups, muted 1 tab and moved 2 tabs to a Later window."
    static func describe(
        collapsedGroupCount: Int,
        mutedTabCount: Int,
        focusGroupedTabCount: Int,
        movedTabCount: Int
    ) -> String {
        var parts: [String] = []
        if collapsedGroupCount > 0 { parts.append("collapsed \(counted(collapsedGroupCount, "group"))") }
        if mutedTabCount > 0 { parts.append("muted \(counted(mutedTabCount, "tab"))") }
        if focusGroupedTabCount > 0 { parts.append("put \(counted(focusGroupedTabCount, "tab")) in Focus") }
        if movedTabCount > 0 { parts.append("moved \(counted(movedTabCount, "tab")) to a Later window") }
        guard !parts.isEmpty else { return "your tabs already look focused" }
        if parts.count == 1 { return parts[0] }
        return parts.dropLast().joined(separator: ", ") + " and " + (parts.last ?? "")
    }

    private static func counted(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}

// MARK: - Study blocks

/// When an approved study block should start Chrome focus on its own. Pure, so the
/// rule (once per block, only while it's under way, and only if asked) is tested.
nonisolated enum ChromeFocusStudyBlockPolicy {

    struct Block: Equatable, Sendable {
        let id: String
        let title: String
        let courseCode: String?
        let start: Date
        let end: Date
    }

    /// A block shorter than this when it is noticed isn't worth rearranging Chrome for.
    static let minimumRemainingSeconds: TimeInterval = 60

    /// The block to focus now: under way, opted in (by the automation switch or its
    /// own chip), not already focused, with at least a minute left. Earliest first.
    static func blockToStartFocus(
        blocks: [Block],
        now: Date,
        focusesEveryApprovedBlock: Bool,
        optedInBlockIDs: Set<String>,
        alreadyFocusedBlockIDs: Set<String>
    ) -> Block? {
        blocks
            .filter { block in
                (focusesEveryApprovedBlock || optedInBlockIDs.contains(block.id))
                    && !alreadyFocusedBlockIDs.contains(block.id)
                    && block.start <= now
                    && block.end.timeIntervalSince(now) >= minimumRemainingSeconds
            }
            .min { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    /// "Study: Essay draft" with course "ENGL101" → "Essay draft ENGL101", so both
    /// the assignment's words and the course code can match tabs.
    static func topic(for block: Block) -> String {
        var title = block.title
        if title.lowercased().hasPrefix("study:") {
            title = String(title.dropFirst("study:".count))
        }
        return [title.trimmingCharacters(in: .whitespaces), block.courseCode ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Whole minutes until the block ends, at least one.
    static func minutesRemaining(in block: Block, now: Date) -> Int {
        max(1, Int((block.end.timeIntervalSince(now) / 60).rounded(.down)))
    }
}
