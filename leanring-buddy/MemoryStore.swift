//
//  MemoryStore.swift
//  leanring-buddy
//
//  Wisp's long-term memory of the user: `~/.wisp/memory.md`.
//
//  A plain markdown file, one fact per bullet, so the user can read and edit
//  exactly what Wisp knows about them in any text editor — the same `~/.wisp/`
//  convention as `mcp.json`, `sources.json` and `skills/`. Nothing here leaves
//  the machine by itself: the facts reach a model only as part of the system
//  prompt, so they go wherever the selected provider goes (local by default).
//
//  The file is the source of truth. The store re-reads it whenever it changed
//  on disk, so a hand edit applies on the next turn without a restart. Writes
//  (the `remember` / `forget` tools and the dashboard's delete buttons) only
//  add or remove bullet lines and leave every other line — headings, notes the
//  user wrote — exactly as it was.
//
//  Only a compact slice reaches the prompt (`MemoryIndex`, ~800 characters of
//  the most recent facts), for the same reason the skill index is terse: it is
//  paid for on every turn, alongside a screenshot, on a small local model.
//

import AppKit
import Combine
import Foundation

// MARK: - File format (pure)

/// Parsing and editing `memory.md` as text. Pure, so it is testable without a
/// file system.
enum MemoryFileFormat {
    /// Longest a single remembered fact may be. A fact is a sentence about the
    /// user, not a document; anything longer is almost certainly the model
    /// pasting context it should not be storing.
    static let maximumFactCharacters = 280

    /// What a brand-new memory file starts with, so a user who opens it knows
    /// what it is and how to edit it.
    static let newFileHeader = """
    # Wisp memory

    Things Wisp remembers about you, one per bullet. Edit or delete freely — \
    Wisp re-reads this file before each reply. Lines that aren't bullets are ignored.


    """

    /// The fact text on a bullet line, or nil if the line is not a bullet.
    static func factText(onLine line: String) -> String? {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        for bulletPrefix in ["- ", "* ", "+ "] where trimmedLine.hasPrefix(bulletPrefix) {
            let factText = String(trimmedLine.dropFirst(bulletPrefix.count))
                .trimmingCharacters(in: .whitespaces)
            return factText.isEmpty ? nil : factText
        }
        return nil
    }

    /// Every fact in the file, in file order — oldest first, since new facts
    /// are appended at the end.
    static func parseFacts(from markdown: String) -> [String] {
        markdown.components(separatedBy: .newlines).compactMap(factText(onLine:))
    }

    /// A fact tidied for storage: one line, no bullet of its own, capped.
    /// Returns nil for a fact with nothing in it.
    static func normalizedFact(_ rawFact: String) -> String? {
        var singleLineFact = rawFact
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        // The model sometimes includes its own bullet; don't store "- - fact".
        while let bulletlessFact = factText(onLine: singleLineFact) {
            singleLineFact = bulletlessFact
        }
        guard !singleLineFact.isEmpty else { return nil }
        if singleLineFact.count > maximumFactCharacters {
            singleLineFact = String(singleLineFact.prefix(maximumFactCharacters))
        }
        return singleLineFact
    }

    /// Whether this fact is already in the file, ignoring case and spacing.
    static func containsFact(_ fact: String, in markdown: String) -> Bool {
        let comparableFact = fact.lowercased()
        return parseFacts(from: markdown).contains { $0.lowercased() == comparableFact }
    }

    /// The file with one more fact bullet at the end. A missing or empty file
    /// gets the explanatory header first.
    static func appendingFact(_ fact: String, to markdown: String) -> String {
        var updatedMarkdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? newFileHeader
            : markdown
        if !updatedMarkdown.hasSuffix("\n") {
            updatedMarkdown += "\n"
        }
        updatedMarkdown += "- \(fact)\n"
        return updatedMarkdown
    }

    /// The file with every fact bullet the predicate selects removed, plus the
    /// facts that were removed. Non-bullet lines are always kept.
    static func removingFacts(
        from markdown: String,
        where shouldRemoveFact: (String) -> Bool
    ) -> (updatedMarkdown: String, removedFacts: [String]) {
        var keptLines: [String] = []
        var removedFacts: [String] = []
        for line in markdown.components(separatedBy: "\n") {
            if let fact = factText(onLine: line), shouldRemoveFact(fact) {
                removedFacts.append(fact)
            } else {
                keptLines.append(line)
            }
        }
        return (keptLines.joined(separator: "\n"), removedFacts)
    }

    /// Removes facts that contain the query, ignoring case. Used by `forget`,
    /// where the model describes the fact rather than quoting it exactly.
    static func removingFacts(
        matching query: String,
        from markdown: String
    ) -> (updatedMarkdown: String, removedFacts: [String]) {
        let comparableQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !comparableQuery.isEmpty else { return (markdown, []) }
        return removingFacts(from: markdown) { fact in
            fact.lowercased().contains(comparableQuery)
        }
    }

    /// Facts that contain the query, ignoring case — what `forget` would remove.
    static func facts(matching query: String, in markdown: String) -> [String] {
        let comparableQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !comparableQuery.isEmpty else { return [] }
        return parseFacts(from: markdown).filter { $0.lowercased().contains(comparableQuery) }
    }
}

// MARK: - Prompt index (pure)

/// The compact block of facts appended to the system prompt.
enum MemoryIndex {
    /// Characters of fact text the prompt may carry. About 200 tokens: enough
    /// for a dozen or so short facts, small next to a ~1100-token screenshot.
    static let defaultCharacterBudget = 800

    /// The facts that fit the budget, newest preferred, returned oldest first.
    ///
    /// Walks back from the newest fact. A fact that would overflow the budget is
    /// skipped rather than ending the walk, so one long hand-written fact near
    /// the end of the file cannot crowd out every shorter one before it.
    static func factsFittingBudget(
        _ facts: [String],
        characterBudget: Int = defaultCharacterBudget
    ) -> [String] {
        var chosenFactsNewestFirst: [String] = []
        var charactersUsed = 0
        for fact in facts.reversed() {
            let renderedLineLength = renderedLine(for: fact).count
            guard charactersUsed + renderedLineLength <= characterBudget else { continue }
            chosenFactsNewestFirst.append(fact)
            charactersUsed += renderedLineLength
        }
        return chosenFactsNewestFirst.reversed()
    }

    /// Renders the index, or an empty string when there is nothing to say — a
    /// user with no memory file pays nothing for this feature.
    static func promptInstructions(
        for facts: [String],
        characterBudget: Int = defaultCharacterBudget
    ) -> String {
        let chosenFacts = factsFittingBudget(facts, characterBudget: characterBudget)
        guard !chosenFacts.isEmpty else { return "" }

        var lines = [
            "",
            "",
            "what you remember about the user (from their memory file). use it when it's relevant; don't recite it:"
        ]
        lines.append(contentsOf: chosenFacts.map(renderedLine(for:)))
        return lines.joined(separator: "\n")
    }

    private static func renderedLine(for fact: String) -> String {
        "- \(fact)"
    }
}

// MARK: - Store

@MainActor
final class MemoryStore: ObservableObject {
    static let shared = MemoryStore()

    /// What happened when asked to remember something.
    enum RememberOutcome: Equatable {
        case added(String)
        case alreadyKnown(String)
        case nothingToRemember
    }

    /// What happened when asked to forget something.
    enum ForgetOutcome: Equatable {
        case removed([String])
        case nothingMatched
        /// The description matched too many facts to be sure which was meant.
        /// Refused rather than deleting several facts on a vague description.
        case tooManyMatches([String])
    }

    /// Most facts a single `forget` may remove. A vague query ("my") that
    /// matches half the file is a model guessing, not the user asking.
    static let maximumFactsRemovedByOneForget = 3

    /// Every fact in the file, oldest first.
    @Published private(set) var facts: [String] = []

    /// `~/.wisp/memory.md`.
    let memoryFileURL: URL

    /// The modification date seen at the last read, so the prompt path can
    /// re-read only when the user actually edited the file.
    private var lastReadModificationDate: Date?

    private init() {
        memoryFileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wisp", isDirectory: true)
            .appendingPathComponent("memory.md", isDirectory: false)
        reload()
    }

    // MARK: Reading

    /// Re-reads the file. A missing file is simply no facts.
    func reload() {
        lastReadModificationDate = currentFileModificationDate()
        facts = MemoryFileFormat.parseFacts(from: readFileContents())
    }

    /// Re-reads only if the file changed since the last read. Cheap enough to
    /// call before every turn — one `stat`.
    func reloadIfFileChanged() {
        guard currentFileModificationDate() != lastReadModificationDate else { return }
        reload()
    }

    /// The memory block for the system prompt, current as of the file on disk.
    func promptInstructions() -> String {
        reloadIfFileChanged()
        return MemoryIndex.promptInstructions(for: facts)
    }

    // MARK: Writing

    func remember(_ rawFact: String) throws -> RememberOutcome {
        guard let fact = MemoryFileFormat.normalizedFact(rawFact) else { return .nothingToRemember }
        let currentMarkdown = readFileContents()
        guard !MemoryFileFormat.containsFact(fact, in: currentMarkdown) else { return .alreadyKnown(fact) }
        try writeFileContents(MemoryFileFormat.appendingFact(fact, to: currentMarkdown))
        return .added(fact)
    }

    func forget(matching query: String) throws -> ForgetOutcome {
        let currentMarkdown = readFileContents()
        let matchingFacts = MemoryFileFormat.facts(matching: query, in: currentMarkdown)
        guard !matchingFacts.isEmpty else { return .nothingMatched }
        guard matchingFacts.count <= Self.maximumFactsRemovedByOneForget else {
            return .tooManyMatches(matchingFacts)
        }
        let removal = MemoryFileFormat.removingFacts(matching: query, from: currentMarkdown)
        try writeFileContents(removal.updatedMarkdown)
        return .removed(removal.removedFacts)
    }

    /// Removes one exact fact — the dashboard's per-row delete button, where
    /// the user has pointed at precisely the line they mean.
    func removeFact(_ factToRemove: String) {
        let removal = MemoryFileFormat.removingFacts(from: readFileContents()) { fact in
            fact == factToRemove
        }
        guard !removal.removedFacts.isEmpty else { return }
        do {
            try writeFileContents(removal.updatedMarkdown)
        } catch {
            print("⚠️ Memory: couldn't update \(memoryFileURL.path): \(error.localizedDescription)")
        }
    }

    /// Shows memory.md in Finder, creating it (with its explanatory header)
    /// first so there is something to open and edit.
    func revealMemoryFileInFinder() {
        if !FileManager.default.fileExists(atPath: memoryFileURL.path) {
            try? writeFileContents(MemoryFileFormat.newFileHeader)
        }
        if FileManager.default.fileExists(atPath: memoryFileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([memoryFileURL])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([memoryFileURL.deletingLastPathComponent()])
        }
    }

    // MARK: Disk

    private func readFileContents() -> String {
        (try? String(contentsOf: memoryFileURL, encoding: .utf8)) ?? ""
    }

    private func writeFileContents(_ markdown: String) throws {
        try FileManager.default.createDirectory(
            at: memoryFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try markdown.write(to: memoryFileURL, atomically: true, encoding: .utf8)
        reload()
    }

    private func currentFileModificationDate() -> Date? {
        let fileAttributes = try? FileManager.default.attributesOfItem(atPath: memoryFileURL.path)
        return fileAttributes?[.modificationDate] as? Date
    }
}
