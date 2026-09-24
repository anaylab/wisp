//
//  AgentTaskHistoryStore.swift
//  leanring-buddy
//
//  Keeps the dashboard's history (every `AgentTaskRecord`) on disk so it
//  survives a relaunch. Before this the registry lived only in memory, so
//  quitting Wisp — or a crash — wiped everything it had done.
//
//  The file is `~/Library/Application Support/Wisp/task-history.json`, beside
//  `ConversationHistoryStore`'s conversation file, readable only by the current
//  user (0600). It holds questions and answers in
//  plain text, which is why it stays on this machine and is pruned: records older
//  than `retentionPeriodSeconds` are dropped on load, on top of the registry's own
//  count cap.
//

import Foundation

enum AgentTaskHistoryStore {
    /// How long a finished record is kept before it is pruned on load.
    static let retentionPeriodSeconds: TimeInterval = 30 * 24 * 60 * 60

    static var historyFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wisp/task-history.json")
    }

    /// Serial queue so overlapping saves land in the order they were made — a
    /// later, fuller snapshot must never be overwritten by an earlier one.
    private static let writeQueue = DispatchQueue(label: "wisp.agentTaskHistory.write", qos: .utility)

    /// The version of the on-disk shape, so a future change to the record format
    /// can migrate or discard old files instead of failing to decode them.
    private static let currentFileFormatVersion = 1

    private struct HistoryFile: Codable {
        let formatVersion: Int
        let records: [AgentTaskRecord]
    }

    /// Reads the saved history, newest first. Records that were still running
    /// when the app last quit are marked `.interrupted` — their work is gone, so
    /// showing them as running forever would be a lie. Anything past the
    /// retention period is dropped. A missing or unreadable file yields an empty
    /// history rather than an error: losing history is not worth blocking launch.
    static func loadRecords() -> [AgentTaskRecord] {
        guard let fileData = try? Data(contentsOf: historyFileURL) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let historyFile = try? decoder.decode(HistoryFile.self, from: fileData),
              historyFile.formatVersion == currentFileFormatVersion else {
            print("⚠️ AgentTaskHistoryStore: could not read \(historyFileURL.path); starting with empty history")
            return []
        }

        let oldestRetainedDate = Date().addingTimeInterval(-retentionPeriodSeconds)
        return historyFile.records.compactMap { savedRecord in
            var loadedRecord = savedRecord
            if !loadedRecord.status.isTerminal {
                loadedRecord.status = .interrupted
                loadedRecord.finishedAt = loadedRecord.finishedAt ?? loadedRecord.startedAt
            }
            let recordDate = loadedRecord.finishedAt ?? loadedRecord.startedAt
            return recordDate >= oldestRetainedDate ? loadedRecord : nil
        }
    }

    /// Writes the history off the main thread. Encoding happens on the caller's
    /// thread so the snapshot is exactly the records passed in.
    static func saveRecords(_ recordsToSave: [AgentTaskRecord]) {
        guard let encodedHistory = encode(recordsToSave) else { return }
        writeQueue.async {
            writeToDisk(encodedHistory)
        }
    }

    /// Writes the history before returning. Used on quit, where an async write
    /// could be cut off by the process exiting.
    static func saveRecordsImmediately(_ recordsToSave: [AgentTaskRecord]) {
        guard let encodedHistory = encode(recordsToSave) else { return }
        writeQueue.sync {
            writeToDisk(encodedHistory)
        }
    }

    private static func encode(_ recordsToEncode: [AgentTaskRecord]) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            return try encoder.encode(HistoryFile(formatVersion: currentFileFormatVersion, records: recordsToEncode))
        } catch {
            print("⚠️ AgentTaskHistoryStore: failed to encode history: \(error)")
            return nil
        }
    }

    private static func writeToDisk(_ encodedHistory: Data) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: historyFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encodedHistory.write(to: historyFileURL, options: .atomic)
            // The file holds the user's questions and answers — owner-only.
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyFileURL.path)
        } catch {
            print("⚠️ AgentTaskHistoryStore: failed to write history: \(error)")
        }
    }
}
