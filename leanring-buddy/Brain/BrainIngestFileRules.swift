//
//  BrainIngestFileRules.swift
//  leanring-buddy
//
//  Which files ingest can read, and which files in `raw/inbox/` to leave
//  alone. Pure — no file system — so the decisions the inbox watcher and the
//  queue make are testable on their own.
//

import Foundation

nonisolated enum BrainIngestFileRules {
    /// How a file's text is read, decided by its extension.
    enum TextReadingMethod: Equatable, Sendable {
        /// The bytes are the text (markdown, plain text, JSON, CSV).
        case plainText
        case pdf
        /// HTML converted to readable markdown-ish text.
        case html
        /// Rich text read through `NSAttributedString` (RTF, DOCX).
        case attributedDocument
    }

    /// The reading method for a file extension, or nil when ingest can't read it.
    static func textReadingMethod(forFileExtension fileExtension: String) -> TextReadingMethod? {
        switch fileExtension.lowercased() {
        case "md", "markdown", "txt", "text", "json", "csv": return .plainText
        case "pdf": return .pdf
        case "html", "htm": return .html
        case "rtf", "docx": return .attributedDocument
        default: return nil
        }
    }

    static func isSupported(fileExtension: String) -> Bool {
        textReadingMethod(forFileExtension: fileExtension) != nil
    }

    /// Words for the prompt ("a PDF document"), so the model knows what it reads.
    static func materialDescription(forFileExtension fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "md", "markdown": return "a markdown document"
        case "txt", "text": return "a plain text document"
        case "json": return "a JSON file"
        case "csv": return "a CSV table"
        case "pdf": return "a PDF document"
        case "html", "htm": return "a saved web page"
        case "rtf": return "a rich text document"
        case "docx": return "a Word document"
        default: return "a document"
        }
    }

    /// What the inbox watcher does with one file name.
    enum InboxFileDecision: Equatable, Sendable {
        /// Never touched: hidden files, Finder metadata, downloads in progress.
        case ignore
        /// A real file ingest can't read — left in the inbox, logged once.
        case unsupported
        /// Ingest it once its size has stopped changing.
        case candidate
    }

    /// Extensions browsers and download tools use while a file is still arriving.
    static let partialDownloadExtensions: Set<String> = [
        "crdownload", "download", "part", "partial", "tmp", "temp", "opdownload", "filepart"
    ]

    static func inboxFileDecision(forFileName fileName: String) -> InboxFileDecision {
        let trimmedFileName = fileName.trimmingCharacters(in: .whitespaces)
        guard !trimmedFileName.isEmpty else { return .ignore }
        // Hidden files include `.DS_Store` and the `._name` AppleDouble files
        // that copies from non-Mac volumes leave behind.
        if trimmedFileName.hasPrefix(".") { return .ignore }
        // Office writes `~$name.docx` lock files next to a document being edited.
        if trimmedFileName.hasPrefix("~$") { return .ignore }
        if trimmedFileName.lowercased() == "icon\r" { return .ignore }
        let fileExtension = (trimmedFileName as NSString).pathExtension.lowercased()
        if partialDownloadExtensions.contains(fileExtension) { return .ignore }
        return isSupported(fileExtension: fileExtension) ? .candidate : .unsupported
    }
}

/// Size + modification date of one inbox file at one poll.
nonisolated struct BrainInboxFileObservation: Equatable, Sendable {
    var byteCount: Int64
    var modificationDate: Date
}

/// Decides when a file in the inbox has finished arriving: it must look the
/// same (size and modification date) on two polls in a row, and not be empty.
/// A browser writing a download, or Finder copying a large file, changes the
/// size between polls, so a half-written file is never read.
nonisolated struct BrainInboxStabilityTracker: Sendable {
    private var previousObservationsByPath: [String: BrainInboxFileObservation] = [:]
    /// Paths already handed to the queue. Forgotten when the file leaves the
    /// inbox, so a new file with the same name is ingested again.
    private var handedOffPaths: Set<String> = []

    init() {}

    /// Feeds one poll's observations; returns the paths that became ready.
    mutating func pathsReadyToIngest(
        currentObservationsByPath: [String: BrainInboxFileObservation]
    ) -> [String] {
        var readyPaths: [String] = []
        for (path, currentObservation) in currentObservationsByPath {
            guard !handedOffPaths.contains(path) else { continue }
            guard currentObservation.byteCount > 0,
                  let previousObservation = previousObservationsByPath[path],
                  previousObservation == currentObservation else { continue }
            readyPaths.append(path)
        }
        previousObservationsByPath = currentObservationsByPath
        handedOffPaths.formUnion(readyPaths)
        handedOffPaths.formIntersection(Set(currentObservationsByPath.keys))
        return readyPaths.sorted()
    }

    /// Lets a path be handed off again (after a failed enqueue).
    mutating func forgetHandOff(ofPath path: String) {
        handedOffPaths.remove(path)
    }
}
