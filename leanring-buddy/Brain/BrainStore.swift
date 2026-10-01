//
//  BrainStore.swift
//  leanring-buddy
//
//  The user's brain on disk: `~/.wisp/brain/`, a folder of markdown pages
//  Wisp maintains (Karpathy's "LLM wiki" pattern). The folder is the source of
//  truth and a valid Obsidian vault; the store re-reads it whenever it changed,
//  so hand edits apply immediately.
//
//      ~/.wisp/brain/
//        SCHEMA.md      conventions every writer follows (seeded, user-editable)
//        index.md       generated catalog: one line per page
//        log.md         human-readable record of every change
//        wiki/          the pages (me.md, people/, projects/, topics/, …)
//        raw/           sources, never edited by Wisp: inbox/, notes/,
//                       conversations/, activity/, ingested/
//        .brain/        machine state: changes.json (undo records), versions/
//
//  Every write goes through `apply(_:provenance:)` with a validated
//  `BrainEditPlan` (see BrainEdit.swift). Before a page is overwritten its
//  previous text is saved under `.brain/versions/<change id>/`, and the change
//  is recorded, so any batch — a bad ingest, a wrong digest — can be undone
//  from the Brain page.
//

import AppKit
import Combine
import Foundation

// MARK: - Change record

/// One applied batch, for the change log and undo.
struct BrainChangeRecord: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var date: Date
    var provenance: BrainEditProvenance
    var changeDescriptions: [String]
    var refusals: [String]
    var createdSlugs: [String]
    var modifiedSlugs: [String]
    var deletedSlugs: [String]
    /// Content hash of each page as this change left it, so undo can tell
    /// whether something edited the page afterwards.
    var resultingContentHashes: [String: Int]
    var isUndone: Bool

    var touchedSlugs: [String] { createdSlugs + modifiedSlugs + deletedSlugs }
}

enum BrainUndoOutcome: Equatable {
    case undone
    /// These pages changed after the batch; undoing would lose that. Pass
    /// `force: true` to undo anyway.
    case conflicted(pageTitles: [String])
    case notFound
    case alreadyUndone
}

/// The result of applying a batch: what changed and what was refused.
struct BrainApplyResult: Equatable, Sendable {
    var changeID: UUID?
    var changeDescriptions: [String]
    var refusals: [String]
    var touchedSlugs: [String]

    var didChangeAnything: Bool { changeID != nil }

    static let nothing = BrainApplyResult(changeID: nil, changeDescriptions: [], refusals: [], touchedSlugs: [])
}

// MARK: - Store

@MainActor
final class BrainStore: ObservableObject {
    static let shared = BrainStore()

    /// Most change records kept for undo. Older versions are pruned with them.
    static let maximumChangeRecords = 400

    /// Every page, sorted by title.
    @Published private(set) var pages: [BrainPage] = []
    /// Applied changes, newest first.
    @Published private(set) var changeRecords: [BrainChangeRecord] = []

    let vaultURL: URL
    var wikiURL: URL { vaultURL.appendingPathComponent("wiki", isDirectory: true) }
    var rawURL: URL { vaultURL.appendingPathComponent("raw", isDirectory: true) }
    var inboxURL: URL { rawURL.appendingPathComponent("inbox", isDirectory: true) }
    var schemaFileURL: URL { vaultURL.appendingPathComponent("SCHEMA.md") }
    var indexFileURL: URL { vaultURL.appendingPathComponent("index.md") }
    var logFileURL: URL { vaultURL.appendingPathComponent("log.md") }
    private var machineStateURL: URL { vaultURL.appendingPathComponent(".brain", isDirectory: true) }
    private var changesFileURL: URL { machineStateURL.appendingPathComponent("changes.json") }
    private var versionsURL: URL { machineStateURL.appendingPathComponent("versions", isDirectory: true) }

    /// Raw subfolders created with the vault.
    static let rawSubfolderNames = ["inbox", "ingested", "notes", "conversations", "activity"]

    private var pagesBySlug: [String: BrainPage] = [:]
    /// Comparable name (title/alias/slug file name) → slug.
    private var slugsByComparableName: [String: String] = [:]
    private var cachedSearchIndex: BrainSearchIndex?
    /// Fingerprint of `wiki/` at the last read (file count + newest mtime).
    private var lastWikiFingerprint: String = ""

    private init() {
        vaultURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wisp", isDirectory: true)
            .appendingPathComponent("brain", isDirectory: true)
        ensureVaultExists()
        loadChangeRecords()
        reload()
    }

    // MARK: Vault layout

    /// Creates the folders and seeds SCHEMA.md / index.md on first use.
    /// Never overwrites a file that already exists.
    func ensureVaultExists() {
        let fileManager = FileManager.default
        var foldersToCreate = [vaultURL, wikiURL, rawURL, machineStateURL, versionsURL]
        foldersToCreate += Self.rawSubfolderNames.map { rawURL.appendingPathComponent($0, isDirectory: true) }
        for folderURL in foldersToCreate {
            try? fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        }
        if !fileManager.fileExists(atPath: schemaFileURL.path) {
            try? BrainSchema.defaultSchemaMarkdown.write(to: schemaFileURL, atomically: true, encoding: .utf8)
        }
        if !fileManager.fileExists(atPath: logFileURL.path) {
            try? "# Brain log\n\nEvery change Wisp makes to your brain, newest last.\n".write(to: logFileURL, atomically: true, encoding: .utf8)
        }
    }

    /// The user-editable conventions, read fresh (writers put it in prompts).
    func schemaText() -> String {
        (try? String(contentsOf: schemaFileURL, encoding: .utf8)) ?? BrainSchema.defaultSchemaMarkdown
    }

    // MARK: Reading

    /// Re-reads every page from `wiki/`.
    func reload() {
        var loadedPages: [BrainPage] = []
        for fileURL in markdownFilesInWiki() {
            guard let slug = slug(forFileURL: fileURL),
                  let markdown = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            loadedPages.append(BrainPageFormat.parse(markdown: markdown, slug: slug))
        }
        lastWikiFingerprint = currentWikiFingerprint()
        setPages(loadedPages)
    }

    /// Re-reads only if something in `wiki/` changed on disk (a hand edit,
    /// Obsidian, another process). One directory walk of `stat`s.
    func reloadIfChanged() {
        guard currentWikiFingerprint() != lastWikiFingerprint else { return }
        reload()
    }

    func page(withSlug slug: String) -> BrainPage? {
        reloadIfChanged()
        return pagesBySlug[slug]
    }

    /// The user's own page, if it exists yet.
    var mePage: BrainPage? { pagesBySlug["me"] }

    /// Resolves a `[[link]]` target, a title, an alias or a slug to a page.
    func resolvePage(named nameOrSlug: String) -> BrainPage? {
        reloadIfChanged()
        let trimmedName = nameOrSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exactSlugPage = pagesBySlug[trimmedName] { return exactSlugPage }
        let comparableName = BrainSlug.comparableName(trimmedName)
        if let slug = slugsByComparableName[comparableName] { return pagesBySlug[slug] }
        return nil
    }

    /// Pages whose body links to this page.
    func backlinks(to page: BrainPage) -> [BrainPage] {
        let namesOfPage = Set(page.allNames.map(BrainSlug.comparableName) + [BrainSlug.comparableName(page.slug), page.slug])
        return pages.filter { candidate in
            candidate.slug != page.slug && candidate.outgoingLinkTargets.contains { target in
                namesOfPage.contains(BrainSlug.comparableName(target)) || namesOfPage.contains(target)
            }
        }
    }

    /// Resolved outgoing links of a page (unresolved targets are dropped).
    func linkedPages(from page: BrainPage) -> [BrainPage] {
        page.outgoingLinkTargets.compactMap(resolvePage(named:)).filter { $0.slug != page.slug }
    }

    /// Link targets on this page that don't resolve to any page yet.
    func unresolvedLinkTargets(on page: BrainPage) -> [String] {
        page.outgoingLinkTargets.filter { resolvePage(named: $0) == nil }
    }

    var searchIndex: BrainSearchIndex {
        reloadIfChanged()
        if let cachedSearchIndex { return cachedSearchIndex }
        let builtIndex = BrainSearchIndex(pages: pages)
        cachedSearchIndex = builtIndex
        return builtIndex
    }

    func search(_ query: String, limit: Int = 8, kinds: Set<BrainPageKind>? = nil) -> [BrainSearchResult] {
        searchIndex.search(query, limit: limit, kinds: kinds)
    }

    /// Relevant-pages block for a turn's user message ("" when nothing is relevant).
    func promptContext(forRequest request: String) -> String {
        BrainPromptContext.promptText(for: request, index: searchIndex)
    }

    func fileURL(forSlug slug: String) -> URL {
        wikiURL.appendingPathComponent(slug + ".md", isDirectory: false)
    }

    // MARK: Writing

    /// Validates proposals and applies them as one undoable change.
    @discardableResult
    func apply(
        proposals: [BrainEditProposal],
        provenance: BrainEditProvenance
    ) -> BrainApplyResult {
        reloadIfChanged()
        let plan = BrainEditPlanner.plan(
            proposals: proposals,
            provenance: provenance,
            resolvePage: { [weak self] name in self?.resolvePage(named: name) },
            today: Date()
        )
        return apply(plan, provenance: provenance)
    }

    /// Writes a validated plan, versioning every page it overwrites, and
    /// optionally removes pages in the same change — so a merge (write the
    /// kept page, delete the duplicate) is one undo, not two.
    @discardableResult
    func apply(
        _ plan: BrainEditPlan,
        deletingSlugs slugsToDelete: [String] = [],
        provenance: BrainEditProvenance
    ) -> BrainApplyResult {
        guard !plan.isEmpty else {
            return BrainApplyResult(changeID: nil, changeDescriptions: [], refusals: plan.refusals, touchedSlugs: [])
        }
        let changeID = UUID()
        var createdSlugs: [String] = []
        var modifiedSlugs: [String] = []
        var resultingContentHashes: [String: Int] = [:]

        for page in plan.pagesToWrite {
            guard BrainSlug.isSafe(page.slug) else { continue }
            let pageFileURL = fileURL(forSlug: page.slug)
            if let previousText = try? String(contentsOf: pageFileURL, encoding: .utf8) {
                saveVersion(previousText, slug: page.slug, changeID: changeID)
                modifiedSlugs.append(page.slug)
            } else {
                createdSlugs.append(page.slug)
            }
            let renderedPage = BrainPageFormat.render(page)
            do {
                try FileManager.default.createDirectory(at: pageFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try renderedPage.write(to: pageFileURL, atomically: true, encoding: .utf8)
                resultingContentHashes[page.slug] = Self.stableHash(renderedPage)
            } catch {
                print("⚠️ Brain: couldn't write \(pageFileURL.path): \(error.localizedDescription)")
            }
        }

        var deletedSlugs: [String] = []
        var changeDescriptions = plan.changeDescriptions
        for slugToDelete in slugsToDelete where BrainSlug.isSafe(slugToDelete) && !resultingContentHashes.keys.contains(slugToDelete) {
            let pageFileURL = fileURL(forSlug: slugToDelete)
            guard let previousText = try? String(contentsOf: pageFileURL, encoding: .utf8) else { continue }
            saveVersion(previousText, slug: slugToDelete, changeID: changeID)
            do {
                try FileManager.default.removeItem(at: pageFileURL)
                deletedSlugs.append(slugToDelete)
                changeDescriptions.append("removed \(pagesBySlug[slugToDelete]?.title ?? slugToDelete)")
            } catch {
                print("⚠️ Brain: couldn't delete \(pageFileURL.path): \(error.localizedDescription)")
            }
        }

        let record = BrainChangeRecord(
            id: changeID,
            date: Date(),
            provenance: provenance,
            changeDescriptions: changeDescriptions,
            refusals: plan.refusals,
            createdSlugs: createdSlugs,
            modifiedSlugs: modifiedSlugs,
            deletedSlugs: deletedSlugs,
            resultingContentHashes: resultingContentHashes,
            isUndone: false
        )
        recordChange(record)
        reload()
        rebuildIndexFile()
        print("🧠 Brain: \(provenance.origin.rawValue) · \(provenance.label) — \(changeDescriptions.joined(separator: "; "))")
        return BrainApplyResult(
            changeID: changeID,
            changeDescriptions: changeDescriptions,
            refusals: plan.refusals,
            touchedSlugs: createdSlugs + modifiedSlugs + deletedSlugs
        )
    }

    /// Saves a page the user edited by hand in the Brain page's editor.
    /// Bypasses the planner (the user may do anything to their own brain) but
    /// is still versioned and undoable.
    @discardableResult
    func savePageEditedByUser(_ editedPage: BrainPage, previousSlug: String? = nil) -> BrainApplyResult {
        var page = editedPage
        page.updatedDate = Date()
        if page.createdDate == nil { page.createdDate = Date() }
        guard BrainSlug.isSafe(page.slug) else { return .nothing }
        let plan = BrainEditPlan(
            pagesToWrite: [page],
            createdSlugs: pagesBySlug[page.slug] == nil ? [page.slug] : [],
            changeDescriptions: ["you edited \(page.title)"],
            refusals: []
        )
        let result = apply(plan, provenance: .user())
        if let previousSlug, previousSlug != page.slug, pagesBySlug[previousSlug] != nil {
            deletePage(withSlug: previousSlug, reason: "renamed to \(page.title)")
        }
        return result
    }

    /// Creates an empty page by hand (the Brain page's "New page").
    @discardableResult
    func createPageByUser(title: String, kind: BrainPageKind) -> BrainPage? {
        let cleanTitle = BrainEditPlanner.cleanedTitle(title)
        guard !cleanTitle.isEmpty else { return nil }
        if let existingPage = resolvePage(named: cleanTitle) { return existingPage }
        let slug = BrainSlug.make(title: cleanTitle, kind: kind)
        guard BrainSlug.isSafe(slug), pagesBySlug[slug] == nil else { return pagesBySlug[slug] }
        let page = BrainPage(
            slug: slug, title: kind == .me ? "Me" : cleanTitle, kind: kind, summary: "",
            aliases: [], tags: [], sources: ["you"], createdDate: Date(), updatedDate: Date(),
            isLocked: false, body: "## Notes\n"
        )
        savePageEditedByUser(page)
        return pagesBySlug[slug]
    }

    /// Removes a page, keeping its text so the deletion can be undone.
    @discardableResult
    func deletePage(
        withSlug slug: String,
        reason: String = "you deleted it",
        provenance: BrainEditProvenance? = nil
    ) -> Bool {
        let provenance = provenance ?? .user()
        guard BrainSlug.isSafe(slug), let page = pagesBySlug[slug] else { return false }
        let pageFileURL = fileURL(forSlug: slug)
        guard let previousText = try? String(contentsOf: pageFileURL, encoding: .utf8) else { return false }
        let changeID = UUID()
        saveVersion(previousText, slug: slug, changeID: changeID)
        do {
            try FileManager.default.removeItem(at: pageFileURL)
        } catch {
            print("⚠️ Brain: couldn't delete \(pageFileURL.path): \(error.localizedDescription)")
            return false
        }
        recordChange(BrainChangeRecord(
            id: changeID, date: Date(), provenance: provenance,
            changeDescriptions: ["deleted \(page.title) (\(reason))"], refusals: [],
            createdSlugs: [], modifiedSlugs: [], deletedSlugs: [slug],
            resultingContentHashes: [:], isUndone: false
        ))
        reload()
        rebuildIndexFile()
        return true
    }

    // MARK: Undo

    /// Reverts one change: restores overwritten and deleted pages from their
    /// saved versions and removes pages the change created.
    func undo(changeID: UUID, force: Bool = false) -> BrainUndoOutcome {
        guard let recordIndex = changeRecords.firstIndex(where: { $0.id == changeID }) else { return .notFound }
        var record = changeRecords[recordIndex]
        guard !record.isUndone else { return .alreadyUndone }

        if !force {
            let conflictedTitles = (record.createdSlugs + record.modifiedSlugs).compactMap { slug -> String? in
                guard let expectedHash = record.resultingContentHashes[slug] else { return nil }
                let currentText = (try? String(contentsOf: fileURL(forSlug: slug), encoding: .utf8)) ?? ""
                return Self.stableHash(currentText) == expectedHash ? nil : (pagesBySlug[slug]?.title ?? slug)
            }
            if !conflictedTitles.isEmpty { return .conflicted(pageTitles: conflictedTitles) }
        }

        for slug in record.createdSlugs {
            try? FileManager.default.removeItem(at: fileURL(forSlug: slug))
        }
        for slug in record.modifiedSlugs + record.deletedSlugs {
            guard let savedText = savedVersion(slug: slug, changeID: changeID) else { continue }
            let pageFileURL = fileURL(forSlug: slug)
            try? FileManager.default.createDirectory(at: pageFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? savedText.write(to: pageFileURL, atomically: true, encoding: .utf8)
        }
        record.isUndone = true
        changeRecords[recordIndex] = record
        saveChangeRecords()
        appendToLogFile(heading: "undo · \(record.provenance.label)", lines: record.changeDescriptions.map { "reverted: \($0)" })
        reload()
        rebuildIndexFile()
        return .undone
    }

    // MARK: Opening

    func revealVaultInFinder() {
        ensureVaultExists()
        NSWorkspace.shared.activateFileViewerSelecting([vaultURL])
    }

    func revealPageInFinder(_ page: BrainPage) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL(forSlug: page.slug)])
    }

    func openPageInDefaultEditor(_ page: BrainPage) {
        NSWorkspace.shared.open(fileURL(forSlug: page.slug))
    }

    /// Whether Obsidian is installed (decides whether "Open in Obsidian" shows).
    var isObsidianInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") != nil
    }

    /// Opens the vault (or one page) in Obsidian via its URL scheme. The vault
    /// must have been opened in Obsidian once; otherwise Obsidian offers to.
    func openInObsidian(page: BrainPage? = nil) {
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        if let page {
            components.queryItems = [URLQueryItem(name: "path", value: fileURL(forSlug: page.slug).path)]
        } else {
            components.queryItems = [URLQueryItem(name: "path", value: vaultURL.path)]
        }
        if let obsidianURL = components.url {
            NSWorkspace.shared.open(obsidianURL)
        }
    }

    // MARK: Raw sources

    /// Copies a source into `raw/<subfolder>/`, returning where it landed.
    /// Raw files are the evidence behind pages; Wisp never edits them.
    @discardableResult
    func storeRawSource(fileURL sourceFileURL: URL, subfolder: String) throws -> URL {
        let folderURL = rawURL.appendingPathComponent(subfolder, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        var destinationURL = folderURL.appendingPathComponent(sourceFileURL.lastPathComponent)
        var duplicateNumber = 2
        while FileManager.default.fileExists(atPath: destinationURL.path) {
            let baseName = sourceFileURL.deletingPathExtension().lastPathComponent
            let pathExtension = sourceFileURL.pathExtension
            destinationURL = folderURL.appendingPathComponent(
                pathExtension.isEmpty ? "\(baseName) \(duplicateNumber)" : "\(baseName) \(duplicateNumber).\(pathExtension)"
            )
            duplicateNumber += 1
        }
        if sourceFileURL.standardizedFileURL.deletingLastPathComponent() == inboxURL.standardizedFileURL {
            try FileManager.default.moveItem(at: sourceFileURL, to: destinationURL)
        } else {
            try FileManager.default.copyItem(at: sourceFileURL, to: destinationURL)
        }
        return destinationURL
    }

    /// Writes text as a raw source file (a conversation transcript, an
    /// activity log, pasted text) under `raw/<subfolder>/`.
    @discardableResult
    func storeRawText(_ text: String, fileName: String, subfolder: String) throws -> URL {
        let folderURL = rawURL.appendingPathComponent(subfolder, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let safeFileName = fileName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let destinationURL = folderURL.appendingPathComponent(safeFileName)
        try text.write(to: destinationURL, atomically: true, encoding: .utf8)
        return destinationURL
    }

    // MARK: Private — pages

    private func setPages(_ loadedPages: [BrainPage]) {
        let sortedPages = loadedPages.sorted { lhs, rhs in
            if (lhs.kind == .me) != (rhs.kind == .me) { return lhs.kind == .me }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        var newPagesBySlug: [String: BrainPage] = [:]
        var newSlugsByComparableName: [String: String] = [:]
        for page in sortedPages {
            newPagesBySlug[page.slug] = page
        }
        // Slug file names first, then aliases, then titles — later writes win,
        // so a title always beats an alias that happens to match another page.
        for page in sortedPages {
            if let fileName = page.slug.split(separator: "/").last {
                newSlugsByComparableName[BrainSlug.comparableName(String(fileName))] = page.slug
            }
        }
        for page in sortedPages { for alias in page.aliases { newSlugsByComparableName[BrainSlug.comparableName(alias)] = page.slug } }
        for page in sortedPages { newSlugsByComparableName[BrainSlug.comparableName(page.title)] = page.slug }
        newSlugsByComparableName["me"] = newPagesBySlug["me"] != nil ? "me" : newSlugsByComparableName["me"]

        pagesBySlug = newPagesBySlug
        slugsByComparableName = newSlugsByComparableName
        cachedSearchIndex = nil
        if pages != sortedPages { pages = sortedPages }
    }

    private func markdownFilesInWiki() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: wikiURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var fileURLs: [URL] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "md" {
            fileURLs.append(fileURL)
        }
        return fileURLs
    }

    private func slug(forFileURL fileURL: URL) -> String? {
        let wikiPath = wikiURL.standardizedFileURL.path + "/"
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(wikiPath) else { return nil }
        let relativePath = String(filePath.dropFirst(wikiPath.count))
        let slug = String(relativePath.dropLast(3)) // ".md"
        // Hand-made files may have spaces or capitals; they still load, but
        // their slug is whatever the file is called.
        return slug.isEmpty ? nil : slug
    }

    private func currentWikiFingerprint() -> String {
        var newestModificationInterval: TimeInterval = 0
        var fileCount = 0
        for fileURL in markdownFilesInWiki() {
            fileCount += 1
            let modificationDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            newestModificationInterval = max(newestModificationInterval, modificationDate?.timeIntervalSince1970 ?? 0)
        }
        return "\(fileCount)-\(newestModificationInterval)"
    }

    // MARK: Private — index + log

    /// Regenerates `index.md`: every page grouped by kind, one line each.
    func rebuildIndexFile() {
        var lines = [
            "# Brain index",
            "",
            "Generated by Wisp — \(pages.count) pages. Edit pages, not this file.",
            ""
        ]
        for kind in BrainPageKind.allCases {
            let pagesOfKind = pages.filter { $0.kind == kind }
            guard !pagesOfKind.isEmpty else { continue }
            lines.append("## \(kind.pluralDisplayName)")
            for page in pagesOfKind {
                let summarySuffix = page.summary.isEmpty ? "" : " — \(page.summary)"
                lines.append("- [[\(page.slug)|\(page.title)]]\(summarySuffix)")
            }
            lines.append("")
        }
        try? lines.joined(separator: "\n").write(to: indexFileURL, atomically: true, encoding: .utf8)
    }

    private func appendToLogFile(heading: String, lines: [String]) {
        let timestampFormatter = DateFormatter()
        timestampFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        var entry = "\n## \(timestampFormatter.string(from: Date())) · \(heading)\n"
        entry += lines.map { "- \($0)" }.joined(separator: "\n") + "\n"
        if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
            fileHandle.seekToEndOfFile()
            fileHandle.write(Data(entry.utf8))
            try? fileHandle.close()
        } else {
            try? ("# Brain log\n" + entry).write(to: logFileURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Private — change records + versions

    private func recordChange(_ record: BrainChangeRecord) {
        changeRecords.insert(record, at: 0)
        if changeRecords.count > Self.maximumChangeRecords {
            let prunedRecords = changeRecords.suffix(from: Self.maximumChangeRecords)
            for prunedRecord in prunedRecords {
                try? FileManager.default.removeItem(at: versionsURL.appendingPathComponent(prunedRecord.id.uuidString, isDirectory: true))
            }
            changeRecords.removeLast(changeRecords.count - Self.maximumChangeRecords)
        }
        saveChangeRecords()
        var logLines = record.changeDescriptions
        logLines += record.refusals.map { "refused: \($0)" }
        appendToLogFile(heading: "\(record.provenance.origin.rawValue) · \(record.provenance.label)", lines: logLines)
    }

    private func loadChangeRecords() {
        guard let data = try? Data(contentsOf: changesFileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        changeRecords = (try? decoder.decode([BrainChangeRecord].self, from: data)) ?? []
    }

    private func saveChangeRecords() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(changeRecords) else { return }
        try? FileManager.default.createDirectory(at: machineStateURL, withIntermediateDirectories: true)
        try? data.write(to: changesFileURL, options: .atomic)
    }

    private func versionFileURL(slug: String, changeID: UUID) -> URL {
        versionsURL
            .appendingPathComponent(changeID.uuidString, isDirectory: true)
            .appendingPathComponent(slug.replacingOccurrences(of: "/", with: "__") + ".md")
    }

    private func saveVersion(_ text: String, slug: String, changeID: UUID) {
        let versionURL = versionFileURL(slug: slug, changeID: changeID)
        try? FileManager.default.createDirectory(at: versionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: versionURL, atomically: true, encoding: .utf8)
    }

    private func savedVersion(slug: String, changeID: UUID) -> String? {
        try? String(contentsOf: versionFileURL(slug: slug, changeID: changeID), encoding: .utf8)
    }

    /// A hash stable across launches (Swift's `hashValue` is seeded per process).
    static func stableHash(_ text: String) -> Int {
        var hash: UInt64 = 1469598103934665603
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return Int(truncatingIfNeeded: hash)
    }
}
