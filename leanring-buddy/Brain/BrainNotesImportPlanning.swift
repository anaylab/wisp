//
//  BrainNotesImportPlanning.swift
//  leanring-buddy
//
//  The pure side of notes import: which files in a folder count as notes,
//  where each lands under `raw/notes/`, what was already imported (by content
//  hash, persisted in `~/.wisp/brain/.brain/imported-notes.json` so a second
//  import only brings what's new or changed), and how an Apple Note becomes a
//  file. `nonisolated` because the folder walk and hashing run off the main
//  actor — a vault can hold thousands of files.
//

import CryptoKit
import Foundation

/// What earlier imports brought in.
nonisolated struct BrainNotesImportState: Codable, Equatable, Sendable {
    /// One Apple Note as last imported.
    struct AppleNoteRecord: Codable, Equatable, Sendable {
        var modificationDate: Date
        var contentHash: String
        /// File name under `raw/notes/Apple Notes/`, kept so an edited note
        /// replaces its own file rather than claiming a new name.
        var fileName: String
    }

    /// SHA-256 (hex) of every imported file's bytes. A file whose content is
    /// here is skipped wherever it lives, so re-importing a vault, or a
    /// second export of the same notes, costs nothing.
    var importedContentHashes: Set<String> = []
    /// Apple Notes by the note's id (`x-coredata://…`).
    var appleNotesByNoteID: [String: AppleNoteRecord] = [:]
}

/// A candidate file found in a folder being imported.
nonisolated struct BrainScannedNoteFile: Equatable, Sendable {
    var fileURL: URL
    /// Path inside the imported folder, "/"-separated ("Projects/Atlas.md").
    var relativePath: String
    var byteCount: Int
}

/// A file chosen for import, with its hash.
nonisolated struct BrainNoteFileToImport: Equatable, Sendable {
    var scannedFile: BrainScannedNoteFile
    var contentHash: String
}

/// The outcome of deciding what to import from a folder.
nonisolated struct BrainNotesFolderImportPlan: Equatable, Sendable {
    var filesToImport: [BrainNoteFileToImport]
    /// Unchanged since an earlier import (or a duplicate within this folder).
    var alreadyImportedFileCount: Int
    /// New files beyond the per-run cap, left for the next run.
    var deferredFileCount: Int
}

/// One note as Apple Notes lists it (before its body is fetched).
nonisolated struct AppleNoteListingEntry: Equatable, Sendable {
    var noteID: String
    var name: String
    var modificationDate: Date
    var isPasswordProtected: Bool
    var isInRecentlyDeleted: Bool
}

nonisolated enum BrainNotesImportPlanner {
    /// Most files one run imports — each becomes a model job, so a huge vault
    /// is taken in instalments rather than queueing thousands at once.
    static let maximumFilesPerRun = 500
    /// Bigger files are almost never notes (exports, attachments, dumps).
    static let maximumFileByteCount = 2 * 1024 * 1024
    /// Stops a walk that wandered into something enormous.
    static let maximumScannedFileCount = 20_000

    /// Folders never walked into: app state (Obsidian's settings, its trash),
    /// dependencies, and macOS zip debris. Hidden folders are skipped too.
    static let skippedDirectoryNames: Set<String> = [".obsidian", ".trash", "node_modules", "__MACOSX", ".git"]

    static func shouldSkipDirectory(named directoryName: String) -> Bool {
        directoryName.hasPrefix(".") || skippedDirectoryNames.contains(directoryName)
    }

    static func shouldConsiderFile(named fileName: String, byteCount: Int, supportedFileExtensions: Set<String>) -> Bool {
        guard !fileName.hasPrefix(".") else { return false }
        let pathExtension = (fileName as NSString).pathExtension.lowercased()
        guard supportedFileExtensions.contains(pathExtension) else { return false }
        return byteCount > 0 && byteCount <= maximumFileByteCount
    }

    /// `child`'s path relative to `root`, or nil if it isn't inside it.
    static func relativePath(of childURL: URL, insideFolder rootURL: URL) -> String? {
        let rootPath = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        let childPath = childURL.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard childPath.hasPrefix(rootPrefix) else { return nil }
        let relativePath = String(childPath.dropFirst(rootPrefix.count))
        return relativePath.isEmpty ? nil : relativePath
    }

    /// Walks a folder for note files. Blocking — call off the main actor.
    static func scanFolder(_ folderURL: URL, supportedFileExtensions: Set<String>) -> [BrainScannedNoteFile] {
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsPackageDescendants]
        ) else { return [] }

        var scannedFiles: [BrainScannedNoteFile] = []
        var visitedFileCount = 0
        for case let itemURL as URL in enumerator {
            visitedFileCount += 1
            if visitedFileCount > maximumScannedFileCount { break }
            let resourceValues = try? itemURL.resourceValues(forKeys: Set(resourceKeys))
            let itemName = itemURL.lastPathComponent
            if resourceValues?.isDirectory == true {
                if shouldSkipDirectory(named: itemName) || resourceValues?.isHidden == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            // Symlinks and other non-regular items are left alone: a link can
            // point anywhere, including outside the folder the user chose.
            guard resourceValues?.isRegularFile == true, resourceValues?.isHidden != true else { continue }
            let byteCount = resourceValues?.fileSize ?? 0
            guard shouldConsiderFile(named: itemName, byteCount: byteCount, supportedFileExtensions: supportedFileExtensions),
                  let relativePath = relativePath(of: itemURL, insideFolder: folderURL) else { continue }
            scannedFiles.append(BrainScannedNoteFile(fileURL: itemURL, relativePath: relativePath, byteCount: byteCount))
        }
        return scannedFiles.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    static func contentHash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func contentHash(of text: String) -> String {
        contentHash(of: Data(text.utf8))
    }

    /// Picks what to import: files whose hash isn't known (first copy only
    /// when two files are identical), at most `maximumFileCount`.
    static func planFolderImport(
        hashedFiles: [BrainNoteFileToImport],
        state: BrainNotesImportState,
        maximumFileCount: Int = maximumFilesPerRun
    ) -> BrainNotesFolderImportPlan {
        var filesToImport: [BrainNoteFileToImport] = []
        var hashesSeenThisRun = Set<String>()
        var alreadyImportedFileCount = 0
        var deferredFileCount = 0
        for hashedFile in hashedFiles {
            if state.importedContentHashes.contains(hashedFile.contentHash)
                || !hashesSeenThisRun.insert(hashedFile.contentHash).inserted {
                alreadyImportedFileCount += 1
                continue
            }
            if filesToImport.count >= maximumFileCount {
                deferredFileCount += 1
                continue
            }
            filesToImport.append(hashedFile)
        }
        return BrainNotesFolderImportPlan(
            filesToImport: filesToImport,
            alreadyImportedFileCount: alreadyImportedFileCount,
            deferredFileCount: deferredFileCount
        )
    }

    /// A name usable as one path component: no slashes, colons or control
    /// characters, no leading dots, not empty, at most 80 characters.
    static func safePathComponent(_ rawName: String, fallback: String = "Untitled") -> String {
        let disallowedCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        var safeName = rawName.components(separatedBy: disallowedCharacters).joined(separator: " ")
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        while safeName.hasPrefix(".") { safeName.removeFirst() }
        if safeName.count > 80 { safeName = String(safeName.prefix(80)).trimmingCharacters(in: .whitespaces) }
        return safeName.isEmpty ? fallback : safeName
    }

    /// Where a folder file lands, relative to `raw/`:
    /// `notes/<folder name>/<relative path>`, every component made safe.
    static func rawDestinationRelativePath(importedFolderName: String, fileRelativePath: String) -> String {
        let safeComponents = fileRelativePath.split(separator: "/").map { safePathComponent(String($0)) }
        return (["notes", safePathComponent(importedFolderName, fallback: "Notes")] + safeComponents).joined(separator: "/")
    }

    /// The clear line shown when a run was capped.
    static func cappedRunMessage(importedFileCount: Int, deferredFileCount: Int) -> String {
        "imported \(importedFileCount) of \(importedFileCount + deferredFileCount) new notes — the limit is \(maximumFilesPerRun) per import. import the same folder again for the rest."
    }

    // MARK: Apple Notes

    /// The notes worth fetching bodies for: not locked, not in Recently
    /// Deleted, and new or modified since they were last imported.
    static func appleNotesToFetch(
        listing: [AppleNoteListingEntry],
        state: BrainNotesImportState
    ) -> [AppleNoteListingEntry] {
        listing.filter { entry in
            guard !entry.isPasswordProtected, !entry.isInRecentlyDeleted else { return false }
            guard let importedRecord = state.appleNotesByNoteID[entry.noteID] else { return true }
            // Notes' dates are whole seconds after an Apple Event round trip.
            return entry.modificationDate.timeIntervalSince(importedRecord.modificationDate) >= 1
        }
    }

    /// A file name for a note: its title made safe, with " 2", " 3"… when
    /// another note already owns that name. A note keeps the name it had.
    static func fileName(
        forAppleNote entry: AppleNoteListingEntry,
        state: BrainNotesImportState,
        namesClaimedThisRun: Set<String>
    ) -> String {
        if let existingFileName = state.appleNotesByNoteID[entry.noteID]?.fileName {
            return existingFileName
        }
        let takenNames = Set(state.appleNotesByNoteID.values.map { $0.fileName.lowercased() })
            .union(namesClaimedThisRun.map { $0.lowercased() })
        let baseName = safePathComponent(entry.name)
        var candidateName = baseName + ".html"
        var duplicateNumber = 2
        while takenNames.contains(candidateName.lowercased()) {
            candidateName = "\(baseName) \(duplicateNumber).html"
            duplicateNumber += 1
        }
        return candidateName
    }

    /// The saved file: a small HTML document around the note's own HTML body,
    /// with the title and modification date the body doesn't carry.
    static func appleNoteHTMLDocument(title: String, bodyHTML: String, modificationDate: Date) -> String {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate]
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(escapedHTML(title))</title>
        <meta name="modified" content="\(dateFormatter.string(from: modificationDate))"></head>
        <body>
        \(bodyHTML)
        </body></html>

        """
    }

    static func escapedHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
