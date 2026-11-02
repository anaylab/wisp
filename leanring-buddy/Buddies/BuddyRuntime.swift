//
//  BuddyRuntime.swift
//  leanring-buddy
//
//  What carries out a buddy's runs (phase 1 of docs/openbot-buddies-plan.md).
//
//  Until now every buddy ran through Wisp's own agent loop, and each run sent
//  the model the buddy's last few exchanges again as history. A buddy can now
//  instead keep **its own Claude Code session**, one per conversation (its main
//  thread, each side thread, each group it's in), the way OpenBot backs every
//  agent with a long-lived CLI session. The session remembers the conversation
//  itself, so a run sends only what is new, and the buddy isn't limited to the
//  last six exchanges.
//
//  Two things do not change. The agent loop still runs above the provider, so
//  every tool call goes through `AgentToolRegistry.invoke`, the confirmation
//  cards and `ToolCallSafety`. And the CLI stays a bare model: its own tools,
//  MCP servers and settings are switched off (`ClaudeSubscriptionProvider`), so
//  it can't act on the Mac by itself. OpenBot's full-access, never-ask mode is
//  deliberately not copied.
//
//  The session runs in the buddy's own workspace folder, so the CLI files its
//  session under that folder's project and finds no CLAUDE.md or project files
//  of the user's.
//

import Foundation

/// How a buddy's runs are carried out. Nil on a buddy means `.wispLoop`, so
/// buddies.json files from before this existed load unchanged.
nonisolated enum BuddyRuntimeKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Wisp's own agent loop on the buddy's model, with the thread's recent
    /// exchanges resent as history on every run.
    case wispLoop
    /// A Claude Code session per conversation, through the user's own signed-in
    /// `claude` CLI (their subscription). Off this Mac.
    case claudeCodeSession

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wispLoop: return "Wisp"
        case .claudeCodeSession: return "Its own Claude Code session"
        }
    }

    var sendsDataOffThisMachine: Bool { self == .claudeCodeSession }
}

/// One conversation's session: the buddy, plus which conversation (a side
/// thread or a group chat; nil is the buddy's main thread).
nonisolated struct BuddySessionKey: Hashable, Codable, Sendable {
    let buddyID: UUID
    let conversationID: UUID?
}

/// What the store remembers about a session. The transcript itself lives in
/// the CLI's own session file; Wisp keeps only the id it chose.
nonisolated struct BuddySessionRecord: Codable, Equatable, Sendable {
    let sessionID: UUID
    let createdAt: Date
    var lastUsedAt: Date
    /// Model calls answered in this session, for the settings page.
    var answeredCallCount: Int
    /// The prompt size of the last call (fresh + cached input), which is how
    /// much of the context the conversation now fills. Nil until reported, and
    /// in files from before this was kept.
    var lastContextTokens: Int?
    /// How many tokens the model's context holds, as the CLI reports it.
    var contextWindowTokens: Int?
    /// How many times this conversation was started over in a new session
    /// because the old one was full. Nil is never.
    var restartCount: Int?
}

/// The pure rules for talking to a kept session. Tested by `Tests/BuddyRuntime`.
nonisolated enum BuddySessionPolicy {
    /// Which conversation a run belongs to: a group's runs are filed under the
    /// group, otherwise the side thread, otherwise the main thread (nil).
    static func conversationID(threadID: UUID?, groupID: UUID?) -> UUID? {
        groupID ?? threadID
    }

    /// The part of a request the session hasn't seen yet.
    ///
    /// Everything up to and including the last assistant message is already in
    /// the session: earlier exchanges from previous runs, and within a run each
    /// reply the CLI itself wrote. What follows it is new — the user's message
    /// on a run's first pass, the tool results on later passes. A request with
    /// no assistant message at all is new from the start.
    static func messagesNotYetInSession(_ messages: [BuddyChatMessage]) -> [BuddyChatMessage] {
        guard let lastAssistantIndex = messages.lastIndex(where: { if case .assistant = $0.role { return true } else { return false } }) else {
            return messages
        }
        return Array(messages[(lastAssistantIndex + 1)...])
    }

    /// How full a session's context was on its last call, 0…1, or nil when
    /// the CLI hasn't said.
    static func contextFillFraction(of record: BuddySessionRecord) -> Double? {
        guard let lastContextTokens = record.lastContextTokens,
              let contextWindowTokens = record.contextWindowTokens, contextWindowTokens > 0 else { return nil }
        return min(1, Double(lastContextTokens) / Double(contextWindowTokens))
    }

    /// The CLI compacts a session by itself as it fills, so a session this
    /// full on its last call means that didn't happen. Wisp then starts the
    /// conversation over in a new session (with the recent history as its
    /// handoff) rather than send one more call that would overflow.
    static let restartFillFraction = 0.95

    static func shouldStartOverBeforeResuming(_ record: BuddySessionRecord) -> Bool {
        (contextFillFraction(of: record) ?? 0) >= restartFillFraction
    }

    /// Whether a call failed because the conversation no longer fits the
    /// model's context. Substring matching, as the CLI and the API report it
    /// as prose.
    static func isContextOverflowFailure(_ failureText: String) -> Bool {
        let lowercasedText = failureText.lowercased()
        return lowercasedText.contains("prompt is too long")
            || lowercasedText.contains("context window")
            || lowercasedText.contains("context length")
            || lowercasedText.contains("too many tokens")
    }

    /// Whether the CLI refused to resume because the session is gone (its
    /// file was deleted, or it was made by another machine). Wisp then starts
    /// a fresh session and hands it the history instead. Substring matching
    /// because the CLI reports this as prose.
    static func isMissingSessionFailure(_ failureText: String) -> Bool {
        let lowercasedText = failureText.lowercased()
        return lowercasedText.contains("no conversation found")
            || lowercasedText.contains("session not found")
            || lowercasedText.contains("no session found")
    }
}

/// The one line the buddy's settings show about its kept sessions:
/// "2 conversations kept · the fullest is 34% full · started over once".
nonisolated enum BuddySessionSummary {
    static func text(for records: [BuddySessionRecord]) -> String {
        guard !records.isEmpty else { return "Its first run starts a session." }
        var parts = ["\(records.count) conversation\(records.count == 1 ? "" : "s") kept"]
        if let fullestFraction = records.compactMap(BuddySessionPolicy.contextFillFraction(of:)).max() {
            let percent = Int((fullestFraction * 100).rounded())
            parts.append(records.count == 1 ? "\(percent)% full" : "the fullest is \(percent)% full")
        }
        let restartTotal = records.compactMap(\.restartCount).reduce(0, +)
        if restartTotal == 1 {
            parts.append("started over once when full")
        } else if restartTotal > 1 {
            parts.append("started over \(restartTotal) times when full")
        }
        return parts.joined(separator: " · ") + "."
    }
}

/// The session ids Wisp chose for each buddy conversation, in
/// `~/Library/Application Support/Wisp/buddy-sessions.json` (0600).
///
/// Lock-guarded rather than main-actor because the provider that reads and
/// writes it runs off the main actor.
nonisolated final class BuddySessionStore: @unchecked Sendable {
    static let shared = BuddySessionStore(
        fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wisp", isDirectory: true)
            .appendingPathComponent("buddy-sessions.json")
    )

    private let fileURL: URL
    private let lock = NSLock()
    private var recordsByKey: [BuddySessionKey: BuddySessionRecord]
    /// Called with the ids of sessions the store just forgot, so the CLI's
    /// own copy of the conversation goes too. Injected so tests don't touch
    /// `~/.claude`.
    private let removeForgottenSessionFiles: @Sendable ([UUID]) -> Void

    init(
        fileURL: URL,
        removeForgottenSessionFiles: @escaping @Sendable ([UUID]) -> Void = { ClaudeCodeSessionFiles.removeFiles(forSessionIDs: $0) }
    ) {
        self.fileURL = fileURL
        self.recordsByKey = Self.loadRecords(from: fileURL)
        self.removeForgottenSessionFiles = removeForgottenSessionFiles
    }

    func record(for key: BuddySessionKey) -> BuddySessionRecord? {
        lock.withLock { recordsByKey[key] }
    }

    /// The buddy's sessions, for its settings page.
    func records(ofBuddyWithID buddyID: UUID) -> [BuddySessionKey: BuddySessionRecord] {
        lock.withLock { recordsByKey.filter { $0.key.buddyID == buddyID } }
    }

    /// Records one more answered call, creating the record for a session that
    /// just started. `restartCount` carries over how often this conversation
    /// was started over before (only read for a new session).
    func noteAnsweredCall(
        in key: BuddySessionKey,
        sessionID: UUID,
        contextTokens: Int? = nil,
        contextWindowTokens: Int? = nil,
        restartCount: Int? = nil,
        at date: Date = Date()
    ) {
        lock.withLock {
            var record: BuddySessionRecord
            if let existingRecord = recordsByKey[key], existingRecord.sessionID == sessionID {
                record = existingRecord
                record.lastUsedAt = date
                record.answeredCallCount += 1
            } else {
                record = BuddySessionRecord(
                    sessionID: sessionID, createdAt: date, lastUsedAt: date, answeredCallCount: 1,
                    restartCount: restartCount
                )
            }
            // A call that reported nothing keeps the last known fill.
            if let contextTokens { record.lastContextTokens = contextTokens }
            if let contextWindowTokens { record.contextWindowTokens = contextWindowTokens }
            recordsByKey[key] = record
            saveLocked()
        }
    }

    /// Forgets one conversation's session, so its next run starts a new one.
    func forgetSession(for key: BuddySessionKey) {
        let forgottenRecord: BuddySessionRecord? = lock.withLock {
            guard let removedRecord = recordsByKey.removeValue(forKey: key) else { return nil }
            saveLocked()
            return removedRecord
        }
        if let forgottenRecord { removeForgottenSessionFiles([forgottenRecord.sessionID]) }
    }

    /// Forgets every session of a buddy: its conversation was cleared, it
    /// was deleted, or it switched runtime.
    func forgetSessions(ofBuddyWithID buddyID: UUID) {
        let forgottenSessionIDs: [UUID] = lock.withLock {
            let forgottenSessionIDs = recordsByKey.filter { $0.key.buddyID == buddyID }.map(\.value.sessionID)
            guard !forgottenSessionIDs.isEmpty else { return [] }
            recordsByKey = recordsByKey.filter { $0.key.buddyID != buddyID }
            saveLocked()
            return forgottenSessionIDs
        }
        removeForgottenSessionFiles(forgottenSessionIDs)
    }

    // MARK: - File

    private struct StoredEntry: Codable {
        let key: BuddySessionKey
        let record: BuddySessionRecord
    }

    private static func loadRecords(from fileURL: URL) -> [BuddySessionKey: BuddySessionRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([StoredEntry].self, from: data) else { return [:] }
        var recordsByKey: [BuddySessionKey: BuddySessionRecord] = [:]
        for entry in entries { recordsByKey[entry.key] = entry.record }
        return recordsByKey
    }

    /// Called with the lock held.
    private func saveLocked() {
        let entries = recordsByKey.map { StoredEntry(key: $0.key, record: $0.value) }
            .sorted { $0.record.createdAt < $1.record.createdAt }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard (try? data.write(to: fileURL, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

/// A buddy's own folder, `~/Library/Application Support/Wisp/buddy-workspaces/<id>/`
/// (0700). The Claude Code session runs here.
nonisolated enum BuddyWorkspace {
    static func folderURL(forBuddyWithID buddyID: UUID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wisp", isDirectory: true)
            .appendingPathComponent("buddy-workspaces", isDirectory: true)
            .appendingPathComponent(buddyID.uuidString, isDirectory: true)
    }

    /// The folder, created if needed.
    static func preparedFolderURL(forBuddyWithID buddyID: UUID) -> URL {
        let folderURL = folderURL(forBuddyWithID: buddyID)
        if !FileManager.default.fileExists(atPath: folderURL.path) {
            try? FileManager.default.createDirectory(
                at: folderURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        return folderURL
    }

    static func deleteFolder(ofBuddyWithID buddyID: UUID) {
        try? FileManager.default.removeItem(at: folderURL(forBuddyWithID: buddyID))
    }
}

/// The CLI's own files for sessions Wisp started, so clearing or deleting a
/// buddy doesn't leave its conversation behind in `~/.claude/projects/`.
/// Only files named with a session id Wisp chose are ever removed.
nonisolated enum ClaudeCodeSessionFiles {
    static func removeFiles(forSessionIDs sessionIDs: [UUID]) {
        guard !sessionIDs.isEmpty else { return }
        let configDirectoryPath = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
        let projectsURL = URL(fileURLWithPath: configDirectoryPath).appendingPathComponent("projects", isDirectory: true)
        guard let projectFolderURLs = try? FileManager.default.contentsOfDirectory(
            at: projectsURL, includingPropertiesForKeys: nil
        ) else { return }
        let sessionFileNames = Set(sessionIDs.map { $0.uuidString.lowercased() + ".jsonl" })
        for projectFolderURL in projectFolderURLs {
            for sessionFileName in sessionFileNames {
                let sessionFileURL = projectFolderURL.appendingPathComponent(sessionFileName)
                if FileManager.default.fileExists(atPath: sessionFileURL.path) {
                    try? FileManager.default.removeItem(at: sessionFileURL)
                }
            }
            // The CLI names a project after its folder; a buddy workspace's
            // project left empty is Wisp's own and goes too.
            if projectFolderURL.lastPathComponent.contains("Wisp-buddy-workspaces-"),
               (try? FileManager.default.contentsOfDirectory(atPath: projectFolderURL.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: projectFolderURL)
            }
        }
    }
}
