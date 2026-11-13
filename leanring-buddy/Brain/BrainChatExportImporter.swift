//
//  BrainChatExportImporter.swift
//  leanring-buddy
//
//  Brings the user's chats with other AIs (a ChatGPT or Claude data export)
//  into the brain. Each conversation becomes one markdown transcript under
//  `raw/chats/<ChatGPT|Claude>/` — the original words, never edited — and is
//  handed to `BrainIngestQueue` with `.notesImport` provenance (trust
//  `.derivedFromUser`: these are the user's own words, so the planner may
//  add to their pages but never replace them). The transcript's header tells
//  the reading model which lines are the user's and which the AI's.
//
//  The user picks the export's `conversations.json`, the unzipped export
//  folder, or the .zip itself (unpacked with `ditto` into a temporary folder).
//
//  Imports are incremental: `.brain/imported-chats.json` keeps a content hash
//  per conversation id, so importing a newer export only reads the chats that
//  are new or that grew since. A chat is recorded there only once the queue
//  has read it (`startWatchingQueue`); until then it is "pending", and a chat
//  whose job failed is queued again by the next import.
//

import Combine
import Foundation

@MainActor
final class BrainChatExportImporter: ObservableObject {
    static let shared = BrainChatExportImporter()

    struct ImportRun: Identifiable, Equatable, Sendable {
        var id: UUID
        var sourceName: String
        var startedDate: Date
        var statusMessage: String?
        var isFinished: Bool = false
    }

    @Published private(set) var runs: [ImportRun] = []
    @Published private(set) var isImporting = false
    @Published private(set) var lastErrorMessage: String?

    private var stateFileURL: URL {
        BrainStore.shared.vaultURL
            .appendingPathComponent(".brain", isDirectory: true)
            .appendingPathComponent("imported-chats.json")
    }

    private var queueSubscription: AnyCancellable?

    private init() {}

    /// Confirms chats as imported when the queue finishes reading them.
    /// Started with the brain's services at launch, so jobs left queued by a
    /// quit are confirmed when they finish after the relaunch.
    func startWatchingQueue() {
        guard queueSubscription == nil else { return }
        queueSubscription = BrainIngestQueue.shared.$jobs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] jobs in self?.confirmFinishedChats(in: jobs) }
    }

    private func confirmFinishedChats(in jobs: [BrainIngestJob]) {
        var importState = loadState()
        guard let pendingPaths = importState.pendingChatsByTranscriptPath, !pendingPaths.isEmpty else { return }
        var didConfirmAny = false
        for job in jobs {
            guard case .finished = job.state, case .file(let fileURL) = job.source else { continue }
            if importState.confirmRead(transcriptPath: fileURL.standardizedFileURL.path) { didConfirmAny = true }
        }
        if didConfirmAny { saveState(importState) }
    }

    /// Imports from a `conversations.json`, an unzipped export folder, or the
    /// export's .zip.
    func importExport(at chosenURL: URL) {
        guard BrainPreferences.shared.isBrainEnabled else {
            lastErrorMessage = "the brain is switched off — turn it on to import chats."
            return
        }
        guard !isImporting else {
            lastErrorMessage = "an import is already running — wait for it to finish."
            return
        }
        isImporting = true
        lastErrorMessage = nil
        let runID = UUID()
        runs.insert(ImportRun(id: runID, sourceName: chosenURL.lastPathComponent, startedDate: Date()), at: 0)
        let importState = loadState()

        Task { [weak self] in
            let readOutcome: Result<(provider: BrainChatExportProvider, chats: [BrainImportedChat]), Error> = await Task.detached(priority: .utility) {
                do {
                    let exportData = try Self.readConversationsFile(from: chosenURL)
                    return .success(try BrainChatExportParser.parse(exportData))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            switch readOutcome {
            case .failure(let error):
                self.finish(runID: runID, statusMessage: "couldn't read the export.", errorMessage: error.localizedDescription)
            case .success(let parsedExport):
                self.carryOutImport(parsedExport, runID: runID, importState: importState)
            }
        }
    }

    private func carryOutImport(
        _ parsedExport: (provider: BrainChatExportProvider, chats: [BrainImportedChat]),
        runID: UUID,
        importState: BrainChatImportState
    ) {
        let providerName = parsedExport.provider.displayName
        let importPlan = BrainChatImportPlanner.plan(chats: parsedExport.chats, state: importState)
        var updatedState = importState
        var queuedChatCount = 0
        for chatToImport in importPlan.chatsToImport {
            guard BrainPreferences.shared.isBrainEnabled else { break }
            do {
                let savedTranscriptURL = try BrainStore.shared.storeRawText(
                    chatToImport.transcriptMarkdown,
                    fileName: chatToImport.fileName,
                    subfolder: "chats/\(providerName)"
                )
                BrainIngestQueue.shared.enqueue(fileURL: savedTranscriptURL, origin: .notesImport)
                if updatedState.pendingChatsByTranscriptPath == nil { updatedState.pendingChatsByTranscriptPath = [:] }
                updatedState.pendingChatsByTranscriptPath?[savedTranscriptURL.standardizedFileURL.path] = BrainChatImportState.PendingChat(
                    conversationKey: chatToImport.conversationKey,
                    transcriptHash: chatToImport.transcriptHash
                )
                queuedChatCount += 1
            } catch {
                print("⚠️ Brain chats: couldn't save \(chatToImport.fileName): \(error.localizedDescription)")
            }
        }
        saveState(updatedState)
        let statusMessage = BrainChatImportPlanner.statusMessage(for: importPlan, providerName: providerName, queuedChatCount: queuedChatCount)
        finish(runID: runID, statusMessage: statusMessage, errorMessage: nil)
    }

    private func finish(runID: UUID, statusMessage: String, errorMessage: String?) {
        if let runIndex = runs.firstIndex(where: { $0.id == runID }) {
            runs[runIndex].statusMessage = statusMessage
            runs[runIndex].isFinished = true
        }
        isImporting = false
        if let errorMessage { lastErrorMessage = errorMessage }
    }

    // MARK: - Reading the export

    /// The bytes of `conversations.json`, wherever the user pointed.
    /// Blocking — call off the main actor.
    nonisolated private static func readConversationsFile(from chosenURL: URL) throws -> Data {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: chosenURL.path, isDirectory: &isDirectory) else {
            throw BrainChatExportParseError.unrecognisedFormat
        }
        if isDirectory.boolValue {
            return try Data(contentsOf: try conversationsFile(inFolder: chosenURL))
        }
        if chosenURL.pathExtension.lowercased() == "zip" {
            let unpackFolderURL = fileManager.temporaryDirectory.appendingPathComponent("wisp-chat-export-\(UUID().uuidString)", isDirectory: true)
            defer { try? fileManager.removeItem(at: unpackFolderURL) }
            try fileManager.createDirectory(at: unpackFolderURL, withIntermediateDirectories: true)
            // ditto ships with macOS and understands the zips both exports use.
            let unzipProcess = Process()
            unzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzipProcess.arguments = ["-x", "-k", chosenURL.path, unpackFolderURL.path]
            try unzipProcess.run()
            unzipProcess.waitUntilExit()
            guard unzipProcess.terminationStatus == 0 else { throw BrainChatExportParseError.unrecognisedFormat }
            return try Data(contentsOf: try conversationsFile(inFolder: unpackFolderURL))
        }
        return try Data(contentsOf: chosenURL)
    }

    /// `conversations.json` at the top of a folder or one level down (a zip
    /// sometimes unpacks into a folder of its own).
    nonisolated private static func conversationsFile(inFolder folderURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let directFileURL = folderURL.appendingPathComponent("conversations.json")
        if fileManager.fileExists(atPath: directFileURL.path) { return directFileURL }
        let childURLs = (try? fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for childURL in childURLs {
            let nestedFileURL = childURL.appendingPathComponent("conversations.json")
            if fileManager.fileExists(atPath: nestedFileURL.path) { return nestedFileURL }
        }
        throw BrainChatExportParseError.unrecognisedFormat
    }

    // MARK: - State file

    private func loadState() -> BrainChatImportState {
        guard let stateData = try? Data(contentsOf: stateFileURL) else { return BrainChatImportState() }
        return (try? JSONDecoder().decode(BrainChatImportState.self, from: stateData)) ?? BrainChatImportState()
    }

    private func saveState(_ importState: BrainChatImportState) {
        guard let stateData = try? JSONEncoder().encode(importState) else { return }
        try? FileManager.default.createDirectory(at: stateFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? stateData.write(to: stateFileURL, options: .atomic)
    }
}
