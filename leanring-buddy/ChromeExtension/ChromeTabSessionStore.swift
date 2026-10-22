//
//  ChromeTabSessionStore.swift
//  leanring-buddy
//
//  The saved tab sessions (phase 04), in
//  `~/Library/Application Support/Wisp/chrome-tab-sessions.json` (0600).
//  The pure rules (building, codec, cap, names) are in `ChromeTabSession.swift`.
//
//  Optionally, a session the user saves also becomes a Brain `source` page
//  listing its tabs as links. That is off by default (a switch on the Tab
//  sessions row) and only happens while the brain is on. The sweeper's safety
//  copies never go to the brain: they're an undo, not something the user chose
//  to keep.
//

import Combine
import Foundation

@MainActor
final class ChromeTabSessionStore: ObservableObject {

    static let shared = ChromeTabSessionStore()

    @Published private(set) var sessions: [ChromeTabSession] = []

    @Published var addsSavedSessionsToBrain: Bool {
        didSet { UserDefaults.standard.set(addsSavedSessionsToBrain, forKey: Self.addsSavedSessionsToBrainDefaultsKey) }
    }

    private static let addsSavedSessionsToBrainDefaultsKey = "chromeTabSessions.addsSavedSessionsToBrain"

    private let sessionsFileURL: URL
    /// Set when the file on disk couldn't be read. It's moved aside before the
    /// next write, so a damaged or newer-format file is never silently replaced.
    private var unreadableFileNeedsMovingAside = false

    init(sessionsFileURL: URL = ChromeTabSessionStore.defaultSessionsFileURL) {
        self.sessionsFileURL = sessionsFileURL
        self.addsSavedSessionsToBrain = UserDefaults.standard.bool(forKey: Self.addsSavedSessionsToBrainDefaultsKey)
        loadFromDisk()
    }

    nonisolated static var defaultSessionsFileURL: URL {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return applicationSupportURL
            .appendingPathComponent("Wisp", isDirectory: true)
            .appendingPathComponent("chrome-tab-sessions.json", isDirectory: false)
    }

    var sessionNames: [String] { sessions.map(\.name) }

    // MARK: - Routing without the main actor

    /// The saved names, readable from `ChromeTabCommandRouter` (nonisolated),
    /// so "reopen thesis research" can be recognised without the word
    /// "session". Updated whenever the list changes.
    nonisolated static var savedSessionNamesForRouting: [String] {
        savedSessionNamesLock.lock()
        defer { savedSessionNamesLock.unlock() }
        return savedSessionNamesStorage
    }

    nonisolated private static let savedSessionNamesLock = NSLock()
    nonisolated(unsafe) private static var savedSessionNamesStorage: [String] = []

    private func publish(_ updatedSessions: [ChromeTabSession]) {
        sessions = updatedSessions
        Self.savedSessionNamesLock.lock()
        Self.savedSessionNamesStorage = updatedSessions.map(\.name)
        Self.savedSessionNamesLock.unlock()
    }

    // MARK: - Changing the list

    /// Saves a session, replacing one with the same name. `mayAddToBrain`
    /// is false for the sweeper's safety copies.
    @discardableResult
    func save(_ newSession: ChromeTabSession, mayAddToBrain: Bool) -> ChromeTabSessionList.SaveEffect {
        let (updatedSessions, saveEffect) = ChromeTabSessionList.saving(newSession, into: sessions)
        publish(updatedSessions)
        writeToDisk()
        if mayAddToBrain && addsSavedSessionsToBrain && BrainPreferences.shared.isBrainEnabled {
            addToBrain(newSession)
        }
        return saveEffect
    }

    func rename(sessionWithID sessionID: UUID, to newName: String) -> ChromeTabSessionList.RenameResult {
        let renameResult = ChromeTabSessionList.renaming(sessionWithID: sessionID, to: newName, in: sessions)
        if case .renamed(let renamedSessions) = renameResult {
            publish(renamedSessions)
            writeToDisk()
        }
        return renameResult
    }

    /// Callers ask first (the Tab sessions row confirms before calling this).
    func delete(sessionWithID sessionID: UUID) {
        publish(sessions.filter { $0.id != sessionID })
        writeToDisk()
    }

    // MARK: - Disk

    private func loadFromDisk() {
        guard let fileData = try? Data(contentsOf: sessionsFileURL) else {
            publish([])
            return
        }
        if let decodedSessions = ChromeTabSessionCodec.decode(fileData) {
            publish(decodedSessions)
        } else {
            print("⚠️ Tab sessions: couldn't read \(sessionsFileURL.lastPathComponent); it will be kept aside on the next save")
            unreadableFileNeedsMovingAside = true
            publish([])
        }
    }

    private func writeToDisk() {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: sessionsFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if unreadableFileNeedsMovingAside, fileManager.fileExists(atPath: sessionsFileURL.path) {
                let movedAsideURL = sessionsFileURL.deletingPathExtension()
                    .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try fileManager.moveItem(at: sessionsFileURL, to: movedAsideURL)
            }
            unreadableFileNeedsMovingAside = false

            let encodedData = try ChromeTabSessionCodec.encode(sessions)
            try encodedData.write(to: sessionsFileURL, options: .atomic)
            // Page titles and addresses are private browsing history.
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sessionsFileURL.path)
        } catch {
            print("⚠️ Tab sessions: couldn't save: \(error.localizedDescription)")
        }
    }

    // MARK: - Brain

    /// A `source` page "Tab session: <name>" with the tabs as links. The user
    /// chose to save these tabs, so it's `.userAuthored`, through the same
    /// planner (and undo) as every brain write.
    private func addToBrain(_ savedSession: ChromeTabSession) {
        let linkLines = savedSession.allTabs.map { savedTab -> String in
            let linkTitle = ChromeTabLifeCardText.shortTitle(savedTab.title)
                .replacingOccurrences(of: "[", with: "(")
                .replacingOccurrences(of: "]", with: ")")
            let linkAddress = savedTab.url
                .replacingOccurrences(of: " ", with: "%20")
                .replacingOccurrences(of: "(", with: "%28")
                .replacingOccurrences(of: ")", with: "%29")
            return "- [\(linkTitle)](\(linkAddress))"
        }
        guard !linkLines.isEmpty else { return }
        let proposal = BrainEditProposal(
            operation: .append,
            pageTitle: "Tab session: \(savedSession.name)",
            pageKind: .source,
            section: "Tabs",
            content: linkLines.joined(separator: "\n"),
            summary: "Chrome tabs saved as a session, \(ChromeTabSessionDescriptions.tabCountText(savedSession.tabCount))."
        )
        BrainStore.shared.apply(
            proposals: [proposal],
            provenance: BrainEditProvenance(origin: .user, label: "tab session", trust: .userAuthored)
        )
    }
}
