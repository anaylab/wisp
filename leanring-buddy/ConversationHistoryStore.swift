//
//  ConversationHistoryStore.swift
//  leanring-buddy
//
//  Keeps the recent conversation across relaunches, on this Mac only.
//
//  `CompanionManager` owns the live `ConversationTranscript`, and until now it
//  lived only in memory: quitting Wisp (or a crash, or a reboot) forgot every
//  exchange. This store mirrors the transcript's turns to
//  `~/Library/Application Support/Wisp/conversation.json` and hands them back on
//  the next launch.
//
//  Three rules shape it:
//
//  1. **The stored record stays the source; requests stay projections.** What is
//     persisted is the turn record itself (user text, assistant prose, tool calls
//     and tool results, in order). What a request carries is still decided where
//     the request is built (`messagesForFollowUpRequest`) — nothing here edits the
//     history to suit one request.
//
//  2. **No screenshots on disk.** Images are dropped when a turn is persisted.
//     The transcript already stores them stripped (`withoutImages`), but this is
//     enforced again here so a future caller that records an image can never
//     leave a picture of the user's screen sitting in a JSON file.
//
//  3. **Stale history is kept, not resumed.** Only turns from the last few hours
//     are fed back into the model's context on launch. An exchange from yesterday
//     about "this page" or "that error" refers to a screen the user is no longer
//     looking at; replaying it invites the small local model to answer today's
//     question about yesterday's context, and every resumed turn is paid for in
//     prompt tokens on every request. Older turns stay in the file (and in the
//     dashboard's count) for reference until they age out of the 20-turn window
//     or the user clears them.
//

import AppKit
import Combine
import Foundation

// MARK: - On-disk shape

/// One content block as written to disk. Deliberately has no image case: the
/// codec drops images on the way in, so the file format cannot express one.
enum PersistedContentBlock: Codable, Equatable {
    case text(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseID: String, toolName: String, content: String, isError: Bool)

    private enum CodingKeys: String, CodingKey {
        case kind, text, id, name, input, toolUseID, toolName, content, isError
    }

    private enum Kind: String, Codable {
        case text, toolUse, toolResult
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .toolUse:
            self = .toolUse(
                id: try container.decode(String.self, forKey: .id),
                name: try container.decode(String.self, forKey: .name),
                input: try container.decode(JSONValue.self, forKey: .input)
            )
        case .toolResult:
            self = .toolResult(
                toolUseID: try container.decode(String.self, forKey: .toolUseID),
                toolName: try container.decode(String.self, forKey: .toolName),
                content: try container.decode(String.self, forKey: .content),
                isError: try container.decode(Bool.self, forKey: .isError)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(text, forKey: .text)
        case .toolUse(let id, let name, let input):
            try container.encode(Kind.toolUse, forKey: .kind)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(input, forKey: .input)
        case .toolResult(let toolUseID, let toolName, let content, let isError):
            try container.encode(Kind.toolResult, forKey: .kind)
            try container.encode(toolUseID, forKey: .toolUseID)
            try container.encode(toolName, forKey: .toolName)
            try container.encode(content, forKey: .content)
            try container.encode(isError, forKey: .isError)
        }
    }
}

struct PersistedChatMessage: Codable, Equatable {
    /// "user" or "assistant". A string rather than `BuddyChatMessage.Role` so the
    /// runtime enum never has to become Codable just to be saved.
    let role: String
    let blocks: [PersistedContentBlock]
}

struct PersistedConversationTurn: Codable, Equatable {
    let id: UUID
    let startedAt: Date
    let messages: [PersistedChatMessage]
}

/// The whole `conversation.json` file. Versioned so a future change to the
/// shape can be recognised rather than mis-decoded.
struct PersistedConversationHistoryFile: Codable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let savedAt: Date
    let turns: [PersistedConversationTurn]
}

// MARK: - Pure conversion and policy

/// Everything about persisting history that does not touch the disk, kept
/// separate so it can be tested without a file system or the main actor.
enum ConversationHistoryCodec {
    /// How many turns the file keeps. Twice the live transcript's ten, so the
    /// file still has recent context for reference after the live window moves on.
    static let maximumPersistedTurnCount = 20

    /// How many restored turns go back into the live transcript on launch —
    /// matches the live transcript's own trim.
    static let maximumResumedTurnCount = 10

    /// Turns older than this are kept on disk but not fed back to the model on
    /// launch. See rule 3 in the file header for why.
    static let maximumResumedTurnAge: TimeInterval = 6 * 60 * 60

    /// A tool result can be thousands of characters (a whole web page, a file).
    /// The follow-up projection never replays them, so the persisted copy keeps
    /// only enough to read what happened, which keeps the file small.
    static let maximumPersistedToolResultCharacters = 2000

    // MARK: Runtime → disk

    static func persistedTurn(from turn: ConversationTranscript.Turn) -> PersistedConversationTurn {
        let persistedMessages: [PersistedChatMessage] = turn.messages.compactMap { message in
            let persistedBlocks = message.blocks.compactMap(persistedBlock(from:))
            // A message that was nothing but a screenshot has nothing left to
            // keep; dropping it avoids an empty message the providers reject.
            guard !persistedBlocks.isEmpty else { return nil }
            return PersistedChatMessage(
                role: message.role == .user ? "user" : "assistant",
                blocks: persistedBlocks
            )
        }
        return PersistedConversationTurn(id: turn.id, startedAt: turn.startedAt, messages: persistedMessages)
    }

    /// Returns nil for images and provider replay blocks — the kinds of block
    /// that are never written.
    private static func persistedBlock(from block: BuddyContentBlock) -> PersistedContentBlock? {
        switch block {
        case .text(let text):
            return .text(text)
        case .image:
            return nil
        case .providerReplay:
            // Only valid inside the tool loop that produced it.
            return nil
        case .toolUse(let id, let name, let input):
            return .toolUse(id: id, name: name, input: input)
        case .toolResult(let toolUseID, let toolName, let content, let isError):
            let storedContent = content.count > maximumPersistedToolResultCharacters
                ? String(content.prefix(maximumPersistedToolResultCharacters)) + "…"
                : content
            return .toolResult(toolUseID: toolUseID, toolName: toolName, content: storedContent, isError: isError)
        }
    }

    // MARK: Disk → runtime

    static func transcriptTurn(from persistedTurn: PersistedConversationTurn) -> ConversationTranscript.Turn {
        let restoredMessages = persistedTurn.messages.map { persistedMessage in
            BuddyChatMessage(
                role: persistedMessage.role == "user" ? .user : .assistant,
                blocks: persistedMessage.blocks.map(runtimeBlock(from:))
            )
        }
        return ConversationTranscript.Turn(
            id: persistedTurn.id,
            startedAt: persistedTurn.startedAt,
            messages: restoredMessages
        )
    }

    private static func runtimeBlock(from persistedBlock: PersistedContentBlock) -> BuddyContentBlock {
        switch persistedBlock {
        case .text(let text):
            return .text(text)
        case .toolUse(let id, let name, let input):
            return .toolUse(id: id, name: name, input: input)
        case .toolResult(let toolUseID, let toolName, let content, let isError):
            return .toolResult(toolUseID: toolUseID, toolName: toolName, content: content, isError: isError)
        }
    }

    // MARK: Encoding

    static func encode(turns: [ConversationTranscript.Turn], savedAt: Date) throws -> Data {
        let historyFile = PersistedConversationHistoryFile(
            formatVersion: PersistedConversationHistoryFile.currentFormatVersion,
            savedAt: savedAt,
            turns: turns.map(persistedTurn(from:))
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(historyFile)
    }

    /// Decodes a history file. A file written by a newer, unknown format version
    /// decodes to nothing rather than being guessed at.
    static func decodeTurns(from data: Data) throws -> [ConversationTranscript.Turn] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let historyFile = try decoder.decode(PersistedConversationHistoryFile.self, from: data)
        guard historyFile.formatVersion <= PersistedConversationHistoryFile.currentFormatVersion else {
            return []
        }
        return historyFile.turns.map(transcriptTurn(from:))
    }

    // MARK: Policy

    /// Folds the live transcript's turns into the persisted list.
    ///
    /// Merged by turn id rather than replaced, because the live transcript trims
    /// itself to ten turns while the file keeps twenty: replacing would throw the
    /// older ten away every time the live window moved. A turn already present is
    /// updated in place; new ones are appended in order; the result is capped to
    /// the most recent `limit`.
    static func mergedTurns(
        persistedTurns: [ConversationTranscript.Turn],
        liveTurns: [ConversationTranscript.Turn],
        limit: Int = maximumPersistedTurnCount
    ) -> [ConversationTranscript.Turn] {
        var mergedTurns = persistedTurns
        for liveTurn in liveTurns {
            if let existingIndex = mergedTurns.firstIndex(where: { $0.id == liveTurn.id }) {
                mergedTurns[existingIndex] = liveTurn
            } else {
                mergedTurns.append(liveTurn)
            }
        }
        if mergedTurns.count > limit {
            mergedTurns.removeFirst(mergedTurns.count - limit)
        }
        return mergedTurns
    }

    /// The restored turns worth putting back in front of the model: recent ones
    /// only, capped, oldest first.
    static func turnsToResume(
        from persistedTurns: [ConversationTranscript.Turn],
        now: Date,
        maximumAge: TimeInterval = maximumResumedTurnAge,
        maximumCount: Int = maximumResumedTurnCount
    ) -> [ConversationTranscript.Turn] {
        let freshTurns = persistedTurns.filter { turn in
            now.timeIntervalSince(turn.startedAt) <= maximumAge
        }
        return Array(freshTurns.suffix(maximumCount))
    }
}

extension ConversationTranscript {
    /// A transcript seeded with turns restored from disk.
    ///
    /// Built through `append` rather than by assigning `turns`, which stays
    /// privately settable so there is still exactly one way turns get in.
    init(restoringTurns restoredTurns: [Turn]) {
        self.init()
        for restoredTurn in restoredTurns {
            append(restoredTurn)
        }
    }
}

// MARK: - Store

@MainActor
final class ConversationHistoryStore: ObservableObject {
    static let shared = ConversationHistoryStore()

    /// Every turn the file holds, oldest first. Published for the dashboard.
    @Published private(set) var persistedTurns: [ConversationTranscript.Turn] = []

    /// `~/Library/Application Support/Wisp/conversation.json`.
    let historyFileURL: URL

    /// Called after the user clears history, so the owner of the live transcript
    /// can empty it too — otherwise the next turn would write the cleared turns
    /// straight back.
    var onConversationHistoryCleared: (() -> Void)?

    /// Waits for a burst of transcript changes (append then trim, for one turn)
    /// to settle before writing, so one exchange is one write.
    private var pendingSaveTask: Task<Void, Never>?
    private static let saveDebounceNanoseconds: UInt64 = 1_000_000_000

    private var applicationWillTerminateObserver: NSObjectProtocol?

    private init() {
        let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        historyFileURL = applicationSupportDirectory
            .appendingPathComponent("Wisp", isDirectory: true)
            .appendingPathComponent("conversation.json", isDirectory: false)

        loadFromDisk()

        // A debounced save still pending at quit would lose the last exchange,
        // so write it out synchronously on the way down.
        applicationWillTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushPendingSave()
            }
        }
    }

    /// The restored turns to seed the live transcript with on launch.
    func turnsWorthResumingOnLaunch(now: Date = Date()) -> [ConversationTranscript.Turn] {
        ConversationHistoryCodec.turnsToResume(from: persistedTurns, now: now)
    }

    /// Mirrors the live transcript into the persisted record and schedules a save.
    func recordTranscriptTurns(_ liveTurns: [ConversationTranscript.Turn]) {
        let mergedTurns = ConversationHistoryCodec.mergedTurns(
            persistedTurns: persistedTurns,
            liveTurns: liveTurns
        )
        // Nothing new (e.g. a trim, which only removes from the live window):
        // skip the write rather than rewriting an identical file.
        let persistedTurnIDs = persistedTurns.map(\.id)
        let mergedTurnIDs = mergedTurns.map(\.id)
        let liveTurnsChangedAnExistingTurn = liveTurns.contains { liveTurn in
            guard let existingTurn = persistedTurns.first(where: { $0.id == liveTurn.id }) else { return false }
            return existingTurn.messages.count != liveTurn.messages.count
        }
        guard persistedTurnIDs != mergedTurnIDs || liveTurnsChangedAnExistingTurn else { return }

        persistedTurns = mergedTurns
        scheduleSave()
    }

    /// Deletes the history file and the in-memory record, and tells the live
    /// transcript's owner to forget too.
    func clearHistory() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        persistedTurns = []
        try? FileManager.default.removeItem(at: historyFileURL)
        onConversationHistoryCleared?()
    }

    /// Shows the history file in Finder, or its folder if nothing is saved yet.
    func revealHistoryFileInFinder() {
        if FileManager.default.fileExists(atPath: historyFileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([historyFileURL])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([historyFileURL.deletingLastPathComponent()])
        }
    }

    // MARK: - Disk

    private func loadFromDisk() {
        guard let historyData = try? Data(contentsOf: historyFileURL) else {
            persistedTurns = []
            return
        }
        do {
            persistedTurns = try ConversationHistoryCodec.decodeTurns(from: historyData)
        } catch {
            // A corrupt file is not worth failing launch over; start fresh and
            // let the next exchange overwrite it.
            print("⚠️ Conversation history: couldn't read \(historyFileURL.path): \(error.localizedDescription)")
            persistedTurns = []
        }
    }

    private func scheduleSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.saveDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            self?.writeToDisk()
            self?.pendingSaveTask = nil
        }
    }

    private func flushPendingSave() {
        guard pendingSaveTask != nil else { return }
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        writeToDisk()
    }

    /// Written on the main actor: the file is at most twenty turns of text, so
    /// encoding and an atomic write take well under a millisecond or two.
    private func writeToDisk() {
        do {
            let historyData = try ConversationHistoryCodec.encode(turns: persistedTurns, savedAt: Date())
            try FileManager.default.createDirectory(
                at: historyFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try historyData.write(to: historyFileURL, options: [.atomic])
        } catch {
            print("⚠️ Conversation history: couldn't save: \(error.localizedDescription)")
        }
    }
}
