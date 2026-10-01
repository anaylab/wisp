//
//  BrainNotesImporter.swift
//  leanring-buddy
//
//  Brings the user's existing notes into the brain: a folder (an Obsidian
//  vault, a folder of markdown or text, a Bear or Notes export) or Apple Notes
//  directly. Each note is copied under `raw/notes/` — the evidence behind
//  whatever pages it produces — and handed to `BrainIngestQueue` with
//  `.notesImport` provenance, so reading it with the model happens the same
//  way as any other ingest, one job at a time in the background.
//
//  Imports are incremental: every imported file's content hash (and each
//  Apple Note's modification date) is kept in `.brain/imported-notes.json`,
//  so importing the same vault again only brings what's new or changed.
//
//  The app isn't sandboxed (see leanring-buddy.entitlements), so a folder the
//  user picked is read with plain file access — no security-scoped bookmark.
//

import Combine
import Foundation

@MainActor
final class BrainNotesImporter: ObservableObject {
    static let shared = BrainNotesImporter()

    struct ImportRun: Identifiable, Equatable, Sendable {
        var id: UUID
        var sourceName: String
        var totalFileCount: Int
        var enqueuedFileCount: Int
        var skippedFileCount: Int
        var startedDate: Date
        /// A line for the UI once the run ends: what happened, or that the
        /// per-run cap left notes for the next import.
        var statusMessage: String? = nil
        var isFinished: Bool = false
    }

    /// Every import this session, newest first.
    @Published private(set) var runs: [ImportRun] = []
    /// True while a folder or Apple Notes import is running (one at a time).
    @Published private(set) var isImporting = false
    /// Why the last import couldn't run or stopped (Automation denied, the
    /// brain switched off, a folder inside the brain…). Cleared when the next
    /// import starts.
    @Published private(set) var lastErrorMessage: String?

    /// Files copied and enqueued between progress updates.
    private static let filesPerProgressBatch = 25
    /// Apple Notes bodies fetched per AppleScript call.
    private static let appleNotesPerBodyBatch = 20

    private var stateFileURL: URL {
        BrainStore.shared.vaultURL
            .appendingPathComponent(".brain", isDirectory: true)
            .appendingPathComponent("imported-notes.json")
    }

    private init() {}

    // MARK: - Folder import

    /// Imports a folder of notes (Obsidian vault, markdown/text folder,
    /// Bear/Notes export): copies files to `raw/notes/` and enqueues each.
    func importFolder(_ folderURL: URL) {
        guard beginImport() else { return }
        let brainVaultPath = BrainStore.shared.vaultURL.standardizedFileURL.resolvingSymlinksInPath().path
        let chosenFolderPath = folderURL.standardizedFileURL.resolvingSymlinksInPath().path
        if chosenFolderPath == brainVaultPath || chosenFolderPath.hasPrefix(brainVaultPath + "/")
            || brainVaultPath.hasPrefix(chosenFolderPath + "/") {
            // Importing the brain (or a folder holding it) would feed Wisp's
            // own pages back to it as notes.
            endImport(errorMessage: "that folder holds your brain itself — pick a notes folder outside ~/.wisp/brain.")
            return
        }

        let importedFolderName = folderURL.lastPathComponent
        let runID = startRun(sourceName: importedFolderName)
        let supportedFileExtensions = BrainIngestQueue.supportedFileExtensions
        let rawFolderURL = BrainStore.shared.rawURL
        let importState = loadState()

        Task { [weak self] in
            let importPlan = await Task.detached(priority: .utility) {
                let scannedFiles = BrainNotesImportPlanner.scanFolder(folderURL, supportedFileExtensions: supportedFileExtensions)
                let hashedFiles = scannedFiles.compactMap { scannedFile -> BrainNoteFileToImport? in
                    guard let fileData = try? Data(contentsOf: scannedFile.fileURL) else { return nil }
                    return BrainNoteFileToImport(scannedFile: scannedFile, contentHash: BrainNotesImportPlanner.contentHash(of: fileData))
                }
                return BrainNotesImportPlanner.planFolderImport(hashedFiles: hashedFiles, state: importState)
            }.value
            await self?.carryOutFolderImport(
                importPlan,
                runID: runID,
                importedFolderName: importedFolderName,
                rawFolderURL: rawFolderURL
            )
        }
    }

    private func carryOutFolderImport(
        _ importPlan: BrainNotesFolderImportPlan,
        runID: UUID,
        importedFolderName: String,
        rawFolderURL: URL
    ) async {
        let foundFileCount = importPlan.filesToImport.count + importPlan.alreadyImportedFileCount + importPlan.deferredFileCount
        updateRun(runID) { run in
            run.totalFileCount = foundFileCount
            run.skippedFileCount = importPlan.alreadyImportedFileCount
        }
        guard foundFileCount > 0 else {
            finishRun(runID, statusMessage: "no notes found — supported types are \(BrainIngestQueue.supportedFileExtensions.sorted().joined(separator: ", ")).")
            endImport(errorMessage: nil)
            return
        }

        var importState = loadState()
        var enqueuedFileCount = 0
        var failedFileCount = 0
        var fileBatchStartIndex = 0
        while fileBatchStartIndex < importPlan.filesToImport.count {
            guard BrainPreferences.shared.isBrainEnabled else {
                finishRun(runID, statusMessage: "stopped: the brain was switched off.")
                endImport(errorMessage: "the import stopped because the brain was switched off.")
                return
            }
            let fileBatch = Array(importPlan.filesToImport[fileBatchStartIndex..<min(fileBatchStartIndex + Self.filesPerProgressBatch, importPlan.filesToImport.count)])
            fileBatchStartIndex += fileBatch.count

            let copyOutcomes = await Task.detached(priority: .utility) {
                fileBatch.map { fileToImport -> (fileToImport: BrainNoteFileToImport, copiedFileURL: URL?) in
                    let destinationRelativePath = BrainNotesImportPlanner.rawDestinationRelativePath(
                        importedFolderName: importedFolderName,
                        fileRelativePath: fileToImport.scannedFile.relativePath
                    )
                    let copiedFileURL = try? Self.copyNoteFile(
                        from: fileToImport.scannedFile.fileURL,
                        toRawRelativePath: destinationRelativePath,
                        rawFolderURL: rawFolderURL
                    )
                    return (fileToImport, copiedFileURL)
                }
            }.value

            for copyOutcome in copyOutcomes {
                guard let copiedFileURL = copyOutcome.copiedFileURL else {
                    failedFileCount += 1
                    continue
                }
                BrainIngestQueue.shared.enqueue(fileURL: copiedFileURL, origin: .notesImport)
                importState.importedContentHashes.insert(copyOutcome.fileToImport.contentHash)
                enqueuedFileCount += 1
            }
            // Saved per batch, so quitting mid-import doesn't re-enqueue
            // what was already queued.
            saveState(importState)
            updateRun(runID) { run in
                run.enqueuedFileCount = enqueuedFileCount
                run.skippedFileCount = importPlan.alreadyImportedFileCount + failedFileCount
            }
        }

        var statusMessage: String
        if importPlan.deferredFileCount > 0 {
            statusMessage = BrainNotesImportPlanner.cappedRunMessage(
                importedFileCount: enqueuedFileCount,
                deferredFileCount: importPlan.deferredFileCount
            )
        } else if enqueuedFileCount == 0 && failedFileCount == 0 {
            statusMessage = "nothing new — all \(importPlan.alreadyImportedFileCount) notes were imported before."
        } else {
            statusMessage = "queued \(enqueuedFileCount) \(enqueuedFileCount == 1 ? "note" : "notes") for reading"
            if importPlan.alreadyImportedFileCount > 0 {
                statusMessage += " (\(importPlan.alreadyImportedFileCount) already imported)"
            }
            statusMessage += "."
        }
        if failedFileCount > 0 {
            statusMessage += " \(failedFileCount) couldn't be copied."
        }
        finishRun(runID, statusMessage: statusMessage)
        endImport(errorMessage: nil)
    }

    /// Copies one note into `raw/`, replacing an older copy at the same path
    /// (the note changed since the last import). Blocking — off the main actor.
    nonisolated private static func copyNoteFile(from sourceFileURL: URL, toRawRelativePath rawRelativePath: String, rawFolderURL: URL) throws -> URL {
        let destinationURL = rawFolderURL.appendingPathComponent(rawRelativePath, isDirectory: false)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceFileURL, to: destinationURL)
        return destinationURL
    }

    // MARK: - Apple Notes import

    /// Imports Apple Notes directly (asks for Automation → Notes).
    func importAppleNotes() {
        guard beginImport() else { return }
        let runID = startRun(sourceName: "Apple Notes")
        Task { [weak self] in
            await self?.carryOutAppleNotesImport(runID: runID)
        }
    }

    private func carryOutAppleNotesImport(runID: UUID) async {
        let listing: [AppleNoteListingEntry]
        do {
            listing = try await AppleNotesScriptBridge.listNotes()
        } catch {
            finishRun(runID, statusMessage: "couldn't read Apple Notes.")
            endImport(errorMessage: error.localizedDescription)
            return
        }

        var importState = loadState()
        let readableNotes = listing.filter { !$0.isPasswordProtected && !$0.isInRecentlyDeleted }
        let changedNotes = BrainNotesImportPlanner.appleNotesToFetch(listing: listing, state: importState)
        let notesToFetch = Array(changedNotes.prefix(BrainNotesImportPlanner.maximumFilesPerRun))
        let deferredNoteCount = changedNotes.count - notesToFetch.count
        let unchangedNoteCount = readableNotes.count - changedNotes.count
        updateRun(runID) { run in
            run.totalFileCount = readableNotes.count
            run.skippedFileCount = unchangedNoteCount
        }

        var enqueuedNoteCount = 0
        var sameContentNoteCount = 0
        var fileNamesClaimedThisRun = Set<String>()
        var noteBatchStartIndex = 0
        while noteBatchStartIndex < notesToFetch.count {
            guard BrainPreferences.shared.isBrainEnabled else {
                finishRun(runID, statusMessage: "stopped: the brain was switched off.")
                endImport(errorMessage: "the import stopped because the brain was switched off.")
                return
            }
            let noteBatch = Array(notesToFetch[noteBatchStartIndex..<min(noteBatchStartIndex + Self.appleNotesPerBodyBatch, notesToFetch.count)])
            noteBatchStartIndex += noteBatch.count

            let bodiesByNoteID: [String: String]
            do {
                bodiesByNoteID = try await AppleNotesScriptBridge.fetchBodies(noteIDs: noteBatch.map(\.noteID))
            } catch {
                saveState(importState)
                finishRun(runID, statusMessage: "stopped after \(enqueuedNoteCount) notes.")
                endImport(errorMessage: error.localizedDescription)
                return
            }

            for noteEntry in noteBatch {
                guard let bodyHTML = bodiesByNoteID[noteEntry.noteID] else { continue }
                let bodyContentHash = BrainNotesImportPlanner.contentHash(of: bodyHTML)
                let fileName = BrainNotesImportPlanner.fileName(
                    forAppleNote: noteEntry,
                    state: importState,
                    namesClaimedThisRun: fileNamesClaimedThisRun
                )
                fileNamesClaimedThisRun.insert(fileName)
                // Touched but not changed (moved folder, pinned): remember the
                // new date so it isn't fetched again, but don't re-read it.
                if importState.appleNotesByNoteID[noteEntry.noteID]?.contentHash == bodyContentHash {
                    importState.appleNotesByNoteID[noteEntry.noteID]?.modificationDate = noteEntry.modificationDate
                    sameContentNoteCount += 1
                    continue
                }
                let noteDocument = BrainNotesImportPlanner.appleNoteHTMLDocument(
                    title: noteEntry.name,
                    bodyHTML: bodyHTML,
                    modificationDate: noteEntry.modificationDate
                )
                do {
                    let savedNoteURL = try BrainStore.shared.storeRawText(noteDocument, fileName: fileName, subfolder: "notes/Apple Notes")
                    BrainIngestQueue.shared.enqueue(fileURL: savedNoteURL, origin: .notesImport)
                    importState.appleNotesByNoteID[noteEntry.noteID] = BrainNotesImportState.AppleNoteRecord(
                        modificationDate: noteEntry.modificationDate,
                        contentHash: bodyContentHash,
                        fileName: fileName
                    )
                    enqueuedNoteCount += 1
                } catch {
                    print("⚠️ Brain notes: couldn't save \(fileName): \(error.localizedDescription)")
                }
            }
            saveState(importState)
            updateRun(runID) { run in
                run.enqueuedFileCount = enqueuedNoteCount
                run.skippedFileCount = unchangedNoteCount + sameContentNoteCount
            }
        }

        let statusMessage: String
        if deferredNoteCount > 0 {
            statusMessage = BrainNotesImportPlanner.cappedRunMessage(importedFileCount: enqueuedNoteCount, deferredFileCount: deferredNoteCount)
                .replacingOccurrences(of: "import the same folder again", with: "import Apple Notes again")
        } else if readableNotes.isEmpty {
            statusMessage = "no notes to import (locked notes and Recently Deleted are left out)."
        } else if enqueuedNoteCount == 0 {
            statusMessage = "nothing new — your notes haven't changed since the last import."
        } else {
            statusMessage = "queued \(enqueuedNoteCount) \(enqueuedNoteCount == 1 ? "note" : "notes") for reading."
        }
        finishRun(runID, statusMessage: statusMessage)
        endImport(errorMessage: nil)
    }

    // MARK: - Runs

    /// Claims the one import slot; false (with a message) if it's taken or
    /// the brain is off.
    private func beginImport() -> Bool {
        guard BrainPreferences.shared.isBrainEnabled else {
            lastErrorMessage = "the brain is switched off — turn it on to import notes."
            return false
        }
        guard !isImporting else {
            lastErrorMessage = "an import is already running — wait for it to finish."
            return false
        }
        isImporting = true
        lastErrorMessage = nil
        return true
    }

    private func endImport(errorMessage: String?) {
        isImporting = false
        if let errorMessage { lastErrorMessage = errorMessage }
    }

    private func startRun(sourceName: String) -> UUID {
        let run = ImportRun(
            id: UUID(),
            sourceName: sourceName,
            totalFileCount: 0,
            enqueuedFileCount: 0,
            skippedFileCount: 0,
            startedDate: Date()
        )
        runs.insert(run, at: 0)
        return run.id
    }

    private func updateRun(_ runID: UUID, _ change: (inout ImportRun) -> Void) {
        guard let runIndex = runs.firstIndex(where: { $0.id == runID }) else { return }
        change(&runs[runIndex])
    }

    private func finishRun(_ runID: UUID, statusMessage: String) {
        updateRun(runID) { run in
            run.statusMessage = statusMessage
            run.isFinished = true
        }
    }

    // MARK: - State file

    private func loadState() -> BrainNotesImportState {
        guard let stateData = try? Data(contentsOf: stateFileURL) else { return BrainNotesImportState() }
        return (try? JSONDecoder().decode(BrainNotesImportState.self, from: stateData)) ?? BrainNotesImportState()
    }

    private func saveState(_ importState: BrainNotesImportState) {
        guard let stateData = try? JSONEncoder().encode(importState) else { return }
        try? FileManager.default.createDirectory(at: stateFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? stateData.write(to: stateFileURL, options: .atomic)
    }
}
