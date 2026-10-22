//
//  ChromeTabSession.swift
//  leanring-buddy
//
//  Pure side of tab sessions (phase 04): a saved set of Chrome tabs the user
//  can bring back later ("save these tabs as thesis research", "restore thesis
//  research"), plus the stale-tab sweeper's safety copy.
//
//  A session stores only what survives a browser restart: URLs, titles, pinned
//  state and group titles/colours. Chrome's tab and window ids live only as long
//  as the browser session (contracts §1), so they are never kept.
//
//  Everything here is pure and tested by `Tests/ChromeExtTabLife`: building a
//  session from a `getTabs` snapshot, the file codec, the 200-session cap, the
//  "restore thesis research" name matching, and turning a session back into
//  `openTabs` requests.
//

import Foundation

// MARK: - The saved shape

/// One saved tab. `pinned` is kept per tab so a restore puts the pinned ones
/// back first, where Chrome keeps them.
nonisolated struct ChromeSavedTab: Codable, Equatable, Sendable {
    var url: String
    var title: String
    var pinned: Bool
}

nonisolated struct ChromeSavedGroup: Codable, Equatable, Sendable {
    var title: String
    var color: String
}

/// A run of neighbouring tabs that restore together: one tab group, the pinned
/// tabs, or a stretch of loose tabs between groups. Keeping runs in order is
/// what puts a restored window back the way it looked.
nonisolated struct ChromeSavedSection: Codable, Equatable, Sendable {
    /// Nil for pinned or loose tabs.
    var group: ChromeSavedGroup?
    var tabs: [ChromeSavedTab]

    var isPinned: Bool { group == nil && !tabs.isEmpty && tabs.allSatisfy(\.pinned) }
}

nonisolated struct ChromeSavedWindow: Codable, Equatable, Sendable {
    var sections: [ChromeSavedSection]

    var tabCount: Int { sections.reduce(0) { $0 + $1.tabs.count } }
}

nonisolated struct ChromeTabSession: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    let createdAt: Date
    var windows: [ChromeSavedWindow]

    var tabCount: Int { windows.reduce(0) { $0 + $1.tabCount } }
    var groupCount: Int { windows.reduce(0) { $0 + $1.sections.filter { $0.group != nil }.count } }
    var allTabs: [ChromeSavedTab] { windows.flatMap { $0.sections.flatMap(\.tabs) } }
}

// MARK: - Limits

nonisolated enum ChromeTabSessionLimits {
    /// Oldest sessions go first past this. Each sweep saves one, so a cap keeps
    /// a year of daily cleanups from growing the file without end.
    static let maximumSessions = 200
    /// A Chrome tab-group chip shows about this much; a spoken name is shorter.
    static let maximumNameLength = 60
    static let maximumTitleLength = 300
    /// Longer addresses are almost always tracking-laden redirects; they are
    /// skipped rather than cut, since a cut address goes nowhere.
    static let maximumURLLength = 4096
    /// Restoring this many tabs or more asks first: it's a lot of pages to load
    /// at once, and easy to trigger by saying the wrong name.
    static let tabCountThatAsksBeforeRestoring = 10
    /// The extension opens at most this many tabs per `openTabs` request.
    static let maximumTabsPerOpenRequest = 60
}

// MARK: - Building a session from Chrome

nonisolated enum ChromeTabSessionBuilder {

    enum Scope: Equatable, Sendable {
        /// The window the user is looking at ("save this window", "save these tabs").
        case focusedWindow
        /// Every normal window ("save all my tabs").
        case allWindows
        /// Exactly these tabs (the sweeper's safety copy).
        case tabs(withIDs: Set<Int>)
    }

    /// Web pages and Chrome's own pages. A blank new tab is nothing to go back
    /// to, and other schemes (file:, data:, extensions) are never restored.
    static func isSavableURL(_ urlString: String) -> Bool {
        guard urlString.count <= ChromeTabSessionLimits.maximumURLLength,
              let urlComponents = URLComponents(string: urlString),
              let scheme = urlComponents.scheme?.lowercased() else { return false }
        switch scheme {
        case "http", "https":
            return !(urlComponents.host ?? "").isEmpty
        case "chrome":
            let chromePageName = (urlComponents.host ?? "").lowercased()
            return !chromePageName.isEmpty && chromePageName != "newtab" && chromePageName != "new-tab-page"
        default:
            return false
        }
    }

    /// The session for `scope`, or nil when nothing in it can be saved.
    static func session(
        named sessionName: String,
        from snapshot: ChromeTabsSnapshot,
        scope: Scope,
        createdAt: Date,
        id: UUID = UUID()
    ) -> ChromeTabSession? {
        let groupsByID = Dictionary(snapshot.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let includedTabs: [ChromeTab]
        switch scope {
        case .focusedWindow:
            let focusedWindowID = snapshot.focusedWindowId ?? snapshot.tabs.first(where: \.active)?.windowId
            includedTabs = snapshot.tabs.filter { $0.windowId == focusedWindowID }
        case .allWindows:
            includedTabs = snapshot.tabs
        case .tabs(let tabIDs):
            includedTabs = snapshot.tabs.filter { tabIDs.contains($0.id) }
        }

        // The focused window first, so restoring a multi-window session brings
        // back the one the user was in before the others.
        let windowIDsInOrder = Array(Set(includedTabs.map(\.windowId))).sorted { lhs, rhs in
            if (lhs == snapshot.focusedWindowId) != (rhs == snapshot.focusedWindowId) {
                return lhs == snapshot.focusedWindowId
            }
            return lhs < rhs
        }

        var savedWindows: [ChromeSavedWindow] = []
        for windowID in windowIDsInOrder {
            let windowTabs = includedTabs
                .filter { $0.windowId == windowID && isSavableURL($0.url) }
                .sorted { $0.index < $1.index }
            var sections: [ChromeSavedSection] = []
            var currentSectionKey: (groupID: Int, pinned: Bool)?
            for windowTab in windowTabs {
                // Chrome never groups a pinned tab, but an older snapshot could
                // say so; pinned wins, as it does in Chrome.
                let effectiveGroupID = windowTab.pinned ? ChromeTab.noGroupID : windowTab.groupId
                let savedTab = ChromeSavedTab(
                    url: windowTab.url,
                    title: String(windowTab.title.prefix(ChromeTabSessionLimits.maximumTitleLength)),
                    pinned: windowTab.pinned
                )
                if let currentSectionKey, currentSectionKey.groupID == effectiveGroupID, currentSectionKey.pinned == windowTab.pinned {
                    sections[sections.count - 1].tabs.append(savedTab)
                    continue
                }
                var savedGroup: ChromeSavedGroup?
                if effectiveGroupID != ChromeTab.noGroupID, let tabGroup = groupsByID[effectiveGroupID] {
                    savedGroup = ChromeSavedGroup(title: tabGroup.title, color: tabGroup.color)
                }
                sections.append(ChromeSavedSection(group: savedGroup, tabs: [savedTab]))
                currentSectionKey = (effectiveGroupID, windowTab.pinned)
            }
            if !sections.isEmpty { savedWindows.append(ChromeSavedWindow(sections: sections)) }
        }

        guard !savedWindows.isEmpty else { return nil }
        return ChromeTabSession(
            id: id,
            name: cleanedName(sessionName),
            createdAt: createdAt,
            windows: savedWindows
        )
    }

    /// A name as stored: single line, trimmed, capped. Empty stays empty so the
    /// caller can choose a dated one.
    static func cleanedName(_ rawName: String) -> String {
        let singleLineName = rawName
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’.,!?"))
        return String(singleLineName.prefix(ChromeTabSessionLimits.maximumNameLength))
    }

    /// "Cleanup Oct 21" for the sweeper, "Tabs Oct 21" for an unnamed save.
    static func datedName(prefix: String, on date: Date, calendar: Calendar = .current) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.calendar = calendar
        dateFormatter.timeZone = calendar.timeZone
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "MMM d"
        return "\(prefix) \(dateFormatter.string(from: date))"
    }

    /// `baseName`, or "baseName (2)", "(3)"… when that is taken. Used for
    /// names Wisp makes up, so a second cleanup on the same day never replaces
    /// the first one's safety copy.
    static func uniqueName(_ baseName: String, existingNames: [String]) -> String {
        let takenNames = Set(existingNames.map(ChromeTabSessionNameMatcher.normalizedName))
        guard takenNames.contains(ChromeTabSessionNameMatcher.normalizedName(baseName)) else { return baseName }
        var suffixNumber = 2
        while takenNames.contains(ChromeTabSessionNameMatcher.normalizedName("\(baseName) (\(suffixNumber))")) {
            suffixNumber += 1
        }
        return "\(baseName) (\(suffixNumber))"
    }
}

// MARK: - Keeping the list

nonisolated enum ChromeTabSessionList {

    /// What saving did to the list.
    enum SaveEffect: Equatable, Sendable {
        case added
        /// A session with the same name (ignoring case and punctuation) was
        /// replaced — saving "thesis research" again updates it.
        case replacedSessionWithSameName
    }

    /// Adds `newSession` newest-first, replacing one with the same name and
    /// dropping the oldest past the cap.
    static func saving(_ newSession: ChromeTabSession, into sessions: [ChromeTabSession]) -> (sessions: [ChromeTabSession], effect: SaveEffect) {
        let newSessionKey = ChromeTabSessionNameMatcher.normalizedName(newSession.name)
        let remainingSessions = sessions.filter { ChromeTabSessionNameMatcher.normalizedName($0.name) != newSessionKey }
        let effect: SaveEffect = remainingSessions.count == sessions.count ? .added : .replacedSessionWithSameName
        let updatedSessions = ([newSession] + newestFirst(remainingSessions)).prefix(ChromeTabSessionLimits.maximumSessions)
        return (Array(updatedSessions), effect)
    }

    static func newestFirst(_ sessions: [ChromeTabSession]) -> [ChromeTabSession] {
        sessions.sorted { $0.createdAt > $1.createdAt }
    }

    enum RenameResult: Equatable, Sendable {
        case renamed([ChromeTabSession])
        case emptyName
        case nameTaken
        case notFound
    }

    static func renaming(sessionWithID sessionID: UUID, to newName: String, in sessions: [ChromeTabSession]) -> RenameResult {
        let cleanedNewName = ChromeTabSessionBuilder.cleanedName(newName)
        guard !ChromeTabSessionNameMatcher.normalizedName(cleanedNewName).isEmpty else { return .emptyName }
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) else { return .notFound }
        let newNameKey = ChromeTabSessionNameMatcher.normalizedName(cleanedNewName)
        let isTakenByAnotherSession = sessions.contains { otherSession in
            otherSession.id != sessionID && ChromeTabSessionNameMatcher.normalizedName(otherSession.name) == newNameKey
        }
        guard !isTakenByAnotherSession else { return .nameTaken }
        var renamedSessions = sessions
        renamedSessions[sessionIndex].name = cleanedNewName
        return .renamed(renamedSessions)
    }
}

// MARK: - The file

/// `chrome-tab-sessions.json`: `{"version":1,"sessions":[…]}`, dates ISO 8601.
nonisolated enum ChromeTabSessionCodec {
    static let currentVersion = 1

    private struct StoredFile: Codable {
        let version: Int
        let sessions: [ChromeTabSession]
    }

    static func encode(_ sessions: [ChromeTabSession]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(StoredFile(version: currentVersion, sessions: sessions))
    }

    /// The sessions in a file, newest first and capped. A damaged or
    /// newer-format file reads as nil, so the caller can leave it alone rather
    /// than overwrite the user's sessions with an empty list.
    static func decode(_ fileData: Data) -> [ChromeTabSession]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let storedFile = try? decoder.decode(StoredFile.self, from: fileData),
              storedFile.version <= currentVersion else { return nil }
        return Array(ChromeTabSessionList.newestFirst(storedFile.sessions).prefix(ChromeTabSessionLimits.maximumSessions))
    }
}

// MARK: - "Restore thesis research"

/// Finds the session a spoken or typed name means. Case- and
/// punctuation-insensitive, and exact after that: never fuzzy, because a
/// restore opens tabs and a near miss would open the wrong ones.
nonisolated enum ChromeTabSessionNameMatcher {

    enum Match: Equatable, Sendable {
        case found(ChromeTabSession)
        /// Two sessions whose names differ only by case or punctuation.
        case ambiguous([ChromeTabSession])
        case notFound
    }

    /// "Thesis-Research!" → "thesis research"; accents folded.
    static func normalizedName(_ rawName: String) -> String {
        let foldedName = rawName
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
        let wordCharacters = foldedName.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(wordCharacters).split(separator: " ").joined(separator: " ")
    }

    /// Spoken wrapping around a name, tried only when the words as said match
    /// nothing: "my thesis research tabs" → "thesis research".
    private static let leadingWrapperWords = ["my", "the", "our"]
    private static let trailingWrapperPhrases = ["tab session", "tabs session", "session", "tabs", "tab", "window"]

    /// The names a phrase could mean, most literal first.
    static func candidateNames(forSpokenPhrase spokenPhrase: String) -> [String] {
        let literalName = normalizedName(spokenPhrase)
        guard !literalName.isEmpty else { return [] }
        var candidates = [literalName]
        var unwrappedName = literalName
        for leadingWord in leadingWrapperWords where unwrappedName.hasPrefix(leadingWord + " ") {
            unwrappedName = String(unwrappedName.dropFirst(leadingWord.count + 1))
            break
        }
        if !candidates.contains(unwrappedName) { candidates.append(unwrappedName) }
        for trailingPhrase in trailingWrapperPhrases where unwrappedName.hasSuffix(" " + trailingPhrase) {
            let withoutTrailingPhrase = String(unwrappedName.dropLast(trailingPhrase.count + 1))
            if !withoutTrailingPhrase.isEmpty && !candidates.contains(withoutTrailingPhrase) {
                candidates.append(withoutTrailingPhrase)
            }
            break
        }
        return candidates
    }

    static func match(spokenPhrase: String, in sessions: [ChromeTabSession]) -> Match {
        for candidateName in candidateNames(forSpokenPhrase: spokenPhrase) {
            let matchingSessions = sessions.filter { normalizedName($0.name) == candidateName }
            if matchingSessions.count == 1, let onlySession = matchingSessions.first { return .found(onlySession) }
            if matchingSessions.count > 1 { return .ambiguous(ChromeTabSessionList.newestFirst(matchingSessions)) }
        }
        return .notFound
    }

    /// Whether any saved session answers to the phrase — what lets the router
    /// take "reopen thesis research" without the word "session".
    static func phraseNamesASavedSession(_ spokenPhrase: String, savedSessionNames: [String]) -> Bool {
        let savedNameKeys = Set(savedSessionNames.map(normalizedName))
        return candidateNames(forSpokenPhrase: spokenPhrase).contains { savedNameKeys.contains($0) }
    }
}

// MARK: - Restoring

/// One `openTabs` request: a section of a window, in order.
nonisolated struct ChromeTabOpenRequest: Equatable, Sendable {
    let urls: [String]
    /// The first request of each window opens a new window; the rest go into
    /// the window it made.
    let opensNewWindow: Bool
    /// Which saved window this request belongs to (0 = first).
    let windowOffset: Int
    let groupTitle: String?
    let groupColor: String?
    let pinned: Bool
}

nonisolated enum ChromeTabRestorePlanner {

    /// Chrome's tab group colours; anything else in an old file is dropped
    /// rather than sent (the extension would refuse it).
    static let chromeGroupColors: Set<String> = ["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"]

    /// Every saved window becomes a new window, so a restore never mixes with
    /// what the user has open now. Sections bigger than the extension's
    /// per-request cap are split, and the split keeps the group's name, so the
    /// extension makes one group per piece with the same title and colour.
    static func openRequests(for session: ChromeTabSession) -> [ChromeTabOpenRequest] {
        var openRequests: [ChromeTabOpenRequest] = []
        for (windowOffset, savedWindow) in session.windows.enumerated() {
            var isFirstRequestOfWindow = true
            for savedSection in savedWindow.sections {
                let restorableURLs = savedSection.tabs.map(\.url).filter(ChromeTabSessionBuilder.isSavableURL)
                guard !restorableURLs.isEmpty else { continue }
                let groupColor = savedSection.group.flatMap { chromeGroupColors.contains($0.color) ? $0.color : nil }
                var startIndex = 0
                while startIndex < restorableURLs.count {
                    let endIndex = min(startIndex + ChromeTabSessionLimits.maximumTabsPerOpenRequest, restorableURLs.count)
                    openRequests.append(ChromeTabOpenRequest(
                        urls: Array(restorableURLs[startIndex..<endIndex]),
                        opensNewWindow: isFirstRequestOfWindow,
                        windowOffset: windowOffset,
                        groupTitle: savedSection.group?.title,
                        groupColor: groupColor,
                        pinned: savedSection.isPinned
                    ))
                    isFirstRequestOfWindow = false
                    startIndex = endIndex
                }
            }
        }
        return openRequests
    }

    static func asksBeforeRestoring(_ session: ChromeTabSession) -> Bool {
        session.tabCount >= ChromeTabSessionLimits.tabCountThatAsksBeforeRestoring
    }
}

// MARK: - Words

nonisolated enum ChromeTabSessionDescriptions {

    static func tabCountText(_ tabCount: Int) -> String {
        ChromeTabLifeCardText.tabCountText(tabCount)
    }

    /// For "what tab sessions do i have": newest first, a few per line.
    static func listText(for sessions: [ChromeTabSession], maximumListed: Int = 12) -> String {
        guard !sessions.isEmpty else {
            return "you have no saved tab sessions. say \"save these tabs as …\" to make one."
        }
        let listedSessions = ChromeTabSessionList.newestFirst(sessions).prefix(maximumListed)
        var lines = ["you have \(sessions.count) saved tab session\(sessions.count == 1 ? "" : "s"):"]
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "MMM d"
        for listedSession in listedSessions {
            let groupText = listedSession.groupCount > 0
                ? ", \(listedSession.groupCount) group\(listedSession.groupCount == 1 ? "" : "s")"
                : ""
            lines.append("- \(listedSession.name) (\(tabCountText(listedSession.tabCount))\(groupText), \(dateFormatter.string(from: listedSession.createdAt)))")
        }
        if sessions.count > listedSessions.count {
            lines.append("…and \(sessions.count - listedSessions.count) older ones.")
        }
        return lines.joined(separator: "\n")
    }
}
