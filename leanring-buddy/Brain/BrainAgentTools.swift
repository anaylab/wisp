//
//  BrainAgentTools.swift
//  leanring-buddy
//
//  The agent's brain tools: read-only `search_brain`, `read_brain_page` and
//  `recall` (graph-aware, cognee-style: words + meaning + relations), and the
//  confirmation-gated `add_to_brain`, `ingest_into_brain` and
//  `forget_from_brain`.
//
//  Reads are free: they only look at the user's own wiki on this Mac. Writes
//  ask, because a page the model files feeds later prompts (per-turn brain
//  context) — a fact the model invents, or one planted by a page it read,
//  would otherwise quietly shape later answers. `add_to_brain` goes through
//  `BrainStore.apply` like every other writer, so the planner's limits apply
//  and the change is logged and undoable. `ingest_into_brain` only queues the
//  source; reading it happens in the background via `BrainIngestQueue`.
//
//  The pure parts — note shaping, source parsing and page-name routing — are
//  tested in Tests/BrainCore.
//

import Foundation

enum BrainToolNames {
    static let searchBrain = "search_brain"
    static let readBrainPage = "read_brain_page"
    static let addToBrain = "add_to_brain"
    static let ingestIntoBrain = "ingest_into_brain"
    static let recall = "recall"
    static let forgetFromBrain = "forget_from_brain"

    static let all: Set<String> = [searchBrain, readBrainPage, addToBrain, ingestIntoBrain, recall, forgetFromBrain]
    /// The ones that answer "what do I know about X" — boosted when a request
    /// names a page.
    static let reading: Set<String> = [recall, readBrainPage]
}

// MARK: - Pure helpers

enum BrainAgentToolFormatting {
    /// Most characters of a page's markdown `read_brain_page` hands back. The
    /// result shares a context window with a screenshot on a small model.
    static let maximumPageCharacters = 3000
    static let maximumBacklinkTitles = 12
    static let maximumSearchResults = 6
    /// Where `add_to_brain` writes are recorded as coming from: the model
    /// filing something from the user's own conversation, which the user
    /// then approved on the confirmation card.
    static let addToBrainProvenance = BrainEditProvenance(origin: .agent, label: "wisp chat", trust: .derivedFromUser)

    /// A note as the lines appended to a page: every plain line becomes a
    /// bullet (one fact per bullet is the brain's convention), lines that are
    /// already bullets, headings or blank are kept as they are.
    static func bulletedNoteContent(_ note: String) -> String {
        note.replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: "\n")
            .map { rawLine -> String in
                let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)
                if trimmedLine.isEmpty { return "" }
                let alreadyStructured = ["- ", "* ", "+ ", "#"].contains { trimmedLine.hasPrefix($0) }
                return alreadyStructured ? trimmedLine : "- \(trimmedLine)"
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The proposal `add_to_brain` applies. Nil when there is no page or note.
    static func addToBrainProposal(
        pageTitle: String,
        pageKindName: String?,
        note: String,
        section: String?,
        summary: String?
    ) -> BrainEditProposal? {
        let trimmedPageTitle = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteContent = bulletedNoteContent(note)
        guard !trimmedPageTitle.isEmpty, !noteContent.isEmpty else { return nil }
        let trimmedSection = section?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSummary = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        return BrainEditProposal(
            operation: .append,
            pageTitle: trimmedPageTitle,
            pageKind: pageKindName.flatMap(BrainPageKind.lenient),
            section: (trimmedSection?.isEmpty ?? true) ? "Facts" : trimmedSection,
            content: noteContent,
            summary: (trimmedSummary?.isEmpty ?? true) ? nil : trimmedSummary
        )
    }

    /// Search results as short lines for the model.
    static func searchResultsText(_ searchResults: [BrainSearchResult], query: String) -> String {
        guard !searchResults.isEmpty else {
            return "nothing in the user's brain matches \"\(query)\"."
        }
        var lines = ["pages in the user's brain about \"\(query)\" (call read_brain_page for one):"]
        for searchResult in searchResults {
            var line = "- \(searchResult.title) (\(searchResult.kind.rawValue))"
            if !searchResult.summary.isEmpty { line += ": \(searchResult.summary)" }
            if !searchResult.snippet.isEmpty && searchResult.snippet != searchResult.summary {
                line += " — \(searchResult.snippet)"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// A page as the model reads it: its markdown (capped), then the titles
    /// of pages that link to it.
    static func pageText(_ page: BrainPage, backlinkTitles: [String]) -> String {
        var pageMarkdown = BrainPageFormat.render(page)
        if pageMarkdown.count > maximumPageCharacters {
            pageMarkdown = String(pageMarkdown.prefix(maximumPageCharacters))
                + "\n…(truncated — the page is \(pageMarkdown.count) characters)"
        }
        guard !backlinkTitles.isEmpty else { return pageMarkdown }
        let shownBacklinkTitles = backlinkTitles.prefix(maximumBacklinkTitles)
        var backlinkLine = "\nlinked from: " + shownBacklinkTitles.joined(separator: ", ")
        if backlinkTitles.count > shownBacklinkTitles.count {
            backlinkLine += " and \(backlinkTitles.count - shownBacklinkTitles.count) more"
        }
        return pageMarkdown + backlinkLine
    }
}

/// `forget_from_brain`'s choice of lines: the bullets on a page holding every
/// word the model gave (case, punctuation and link brackets ignored).
enum BrainFactRemoval {
    /// More matches than this means the description was too vague to act on.
    static let maximumLinesPerRemoval = 3

    static func matchingBulletLines(in body: String, describedBy description: String) -> [String] {
        let wantedWords = Set(BrainSearchTokenizer.tokens(in: description))
        guard !wantedWords.isEmpty else { return [] }
        return body.components(separatedBy: "\n").filter { line in
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard ["- ", "* ", "+ "].contains(where: { trimmedLine.hasPrefix($0) }) else { return false }
            let lineWords = Set(BrainSearchTokenizer.tokens(in: BrainSemanticFacts.plainText(trimmedLine)))
            return wantedWords.isSubset(of: lineWords)
        }
    }

    /// The body without those lines (each removed once, in place).
    static func body(_ body: String, removing removedLines: [String]) -> String {
        var remainingRemovals = removedLines
        let keptLines = body.components(separatedBy: "\n").filter { line in
            if let removalIndex = remainingRemovals.firstIndex(of: line) {
                remainingRemovals.remove(at: removalIndex)
                return false
            }
            return true
        }
        return keptLines.joined(separator: "\n")
    }
}

/// What `ingest_into_brain` was handed.
enum BrainIngestSourceParser {
    enum Source: Equatable {
        case webPage(URL)
        case file(URL)
    }

    /// A web address (`https://…`, or a bare `www.…` / `example.com/…`) or a
    /// file path (`/…`, `~/…`, `file://…`). Nil for anything else — the tool
    /// then says what it needs instead of guessing.
    static func source(from rawSource: String) -> Source? {
        let trimmedSource = rawSource.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`<>")))
        guard !trimmedSource.isEmpty else { return nil }
        let lowercasedSource = trimmedSource.lowercased()

        if lowercasedSource.hasPrefix("http://") || lowercasedSource.hasPrefix("https://") {
            guard let webURL = URL(string: trimmedSource), webURL.host != nil else { return nil }
            return .webPage(webURL)
        }
        if lowercasedSource.hasPrefix("file://") {
            guard let fileURL = URL(string: trimmedSource), fileURL.isFileURL else { return nil }
            return .file(fileURL.standardizedFileURL)
        }
        if trimmedSource.hasPrefix("/") || trimmedSource.hasPrefix("~") {
            let expandedPath = (trimmedSource as NSString).expandingTildeInPath
            return .file(URL(fileURLWithPath: expandedPath).standardizedFileURL)
        }
        // A bare domain: letters, a dot, a known-looking TLD, no spaces.
        let bareDomainPattern = "^(www\\.)?[a-z0-9-]+(\\.[a-z0-9-]+)*\\.[a-z]{2,}(/\\S*)?$"
        if lowercasedSource.range(of: bareDomainPattern, options: .regularExpression) != nil,
           let webURL = URL(string: "https://" + trimmedSource) {
            return .webPage(webURL)
        }
        return nil
    }
}

/// Whether a request is about a page the user already has — by name. Used to
/// boost the reading tools for "how's atlas going?", which shares no
/// vocabulary with any scope.
enum BrainToolRouting {
    /// Names shorter than this (comparable form) are ignored: "ai", "me" and
    /// the like would match half of all requests.
    static let minimumComparableNameLength = 4

    static func requestNamesAPage(_ request: String, pageNames: [String]) -> Bool {
        let comparableRequest = "-" + BrainSlug.comparableName(request) + "-"
        return pageNames.contains { pageName in
            let comparablePageName = BrainSlug.comparableName(pageName)
            guard comparablePageName.count >= minimumComparableNameLength, comparablePageName != "untitled" else { return false }
            // Dash-bounded so "rust" doesn't match inside "trust".
            return comparableRequest.contains("-" + comparablePageName + "-")
        }
    }
}

// MARK: - Registration

extension AgentToolRegistry {

    /// Registers the six brain tools.
    func registerBrainTools() {
        register(
            BuddyToolDefinition(
                name: BrainToolNames.searchBrain,
                description: "Search the user's brain — their personal wiki of people, projects, topics and notes that Wisp keeps — for pages about something. Use when the user asks what they know, noted or saved about something.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["query": .object([
                        "type": .string("string"),
                        "description": .string("A few words naming what to look for, e.g. \"sarah chen\" or \"atlas launch\"")
                    ])]),
                    "required": .array([.string("query")])
                ]),
                metadata: .reading(.localMachine)
            )
        ) { input in
            guard BrainPreferences.shared.isBrainEnabled else { return Self.brainIsOffResult }
            guard case .object(let arguments) = input,
                  case .string(let query)? = arguments["query"],
                  !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "i need something to search for."
            }
            let searchResults = BrainStore.shared.search(query, limit: BrainAgentToolFormatting.maximumSearchResults)
            return BrainAgentToolFormatting.searchResultsText(searchResults, query: query)
        }

        register(
            BuddyToolDefinition(
                name: BrainToolNames.readBrainPage,
                description: "Read one page of the user's brain (their personal wiki) in full, by its title.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["page": .object([
                        "type": .string("string"),
                        "description": .string("The page's title, e.g. \"Sarah Chen\", or \"me\" for the page about the user")
                    ])]),
                    "required": .array([.string("page")])
                ]),
                metadata: .reading(.localMachine)
            )
        ) { input in
            guard BrainPreferences.shared.isBrainEnabled else { return Self.brainIsOffResult }
            guard case .object(let arguments) = input,
                  case .string(let pageName)? = arguments["page"],
                  !pageName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "i need the page's title."
            }
            let brainStore = BrainStore.shared
            guard let page = brainStore.resolvePage(named: pageName) else {
                let closestTitles = brainStore.search(pageName, limit: 3).map(\.title)
                return closestTitles.isEmpty
                    ? "there's no page called \"\(pageName)\" in the user's brain."
                    : "there's no page called \"\(pageName)\". closest: \(closestTitles.joined(separator: ", "))."
            }
            let backlinkTitles = brainStore.backlinks(to: page).map(\.title)
            return BrainAgentToolFormatting.pageText(page, backlinkTitles: backlinkTitles)
        }

        register(
            BuddyToolDefinition(
                name: BrainToolNames.addToBrain,
                description: "File a note in the user's brain (their personal wiki) on the page for a person, project, topic or thing — created if new. Use when the user asks you to note, save or add something to their brain. The user is asked first.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "page": .object([
                            "type": .string("string"),
                            "description": .string("The page's title — the thing's usual name, e.g. \"Sarah Chen\" or \"Atlas\"")
                        ]),
                        "kind": .object([
                            "type": .string("string"),
                            "description": .string("For a new page: person, project, topic, organization, place, event or note")
                        ]),
                        "note": .object([
                            "type": .string("string"),
                            "description": .string("What to add: short facts, one per line, with [[links]] to other pages. A relationship can be one line as \"relation:: [[Other page]]\", e.g. \"works at:: [[Orbit]]\"")
                        ]),
                        "section": .object([
                            "type": .string("string"),
                            "description": .string("Optional section, e.g. Facts, Decisions, Timeline. Defaults to Facts.")
                        ])
                    ]),
                    "required": .array([.string("page"), .string("note")])
                ]),
                // A recoverable local write: logged and undoable in the brain.
                metadata: .writing(.localMachine)
            )
        ) { input in
            guard BrainPreferences.shared.isBrainEnabled else { return Self.brainIsOffResult }
            guard case .object(let arguments) = input,
                  case .string(let pageTitle)? = arguments["page"],
                  case .string(let note)? = arguments["note"] else {
                return "i need the page and the note to add."
            }
            var pageKindName: String?
            if case .string(let rawKind)? = arguments["kind"] { pageKindName = rawKind }
            var section: String?
            if case .string(let rawSection)? = arguments["section"] { section = rawSection }
            var summary: String?
            if case .string(let rawSummary)? = arguments["summary"] { summary = rawSummary }

            guard let proposal = BrainAgentToolFormatting.addToBrainProposal(
                pageTitle: pageTitle, pageKindName: pageKindName, note: note, section: section, summary: summary
            ) else {
                return "i need the page and the note to add."
            }
            let applyResult = BrainStore.shared.apply(
                proposals: [proposal],
                provenance: BrainAgentToolFormatting.addToBrainProvenance
            )
            if applyResult.didChangeAnything {
                return applyResult.changeDescriptions.joined(separator: "; ") + "."
            }
            if !applyResult.refusals.isEmpty {
                return "couldn't add that: " + applyResult.refusals.joined(separator: "; ") + "."
            }
            return "that's already in the user's brain."
        }

        register(
            BuddyToolDefinition(
                name: BrainToolNames.recall,
                description: "Recall what the user's brain (their personal wiki) holds about something: finds pages by words and by meaning, then follows how they're related (\"works at\", \"part of\"…) to bring connected pages along. Use for \"what do I know about…\", \"what was that…\", or any question their notes might answer.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["query": .object([
                        "type": .string("string"),
                        "description": .string("The question or topic in plain words, e.g. \"my wind turbine project\"")
                    ])]),
                    "required": .array([.string("query")])
                ]),
                metadata: .reading(.localMachine)
            )
        ) { input in
            guard BrainPreferences.shared.isBrainEnabled else { return Self.brainIsOffResult }
            guard case .object(let arguments) = input,
                  case .string(let query)? = arguments["query"],
                  !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "i need something to recall."
            }
            let recallHits = BrainStore.shared.recall(query, limit: BrainAgentToolFormatting.maximumSearchResults)
            return BrainRecallPlanner.toolText(for: recallHits, query: query)
        }

        register(
            BuddyToolDefinition(
                name: BrainToolNames.forgetFromBrain,
                description: "Remove a fact from one page of the user's brain (their personal wiki) when they ask you to forget or delete it. Describe the fact with a few words that appear in it. The user is asked first, and it can be undone in the Brain's log.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "page": .object([
                            "type": .string("string"),
                            "description": .string("The page's title, e.g. \"Sarah Chen\"")
                        ]),
                        "fact": .object([
                            "type": .string("string"),
                            "description": .string("Words from the fact to remove, e.g. \"moved to berlin\"")
                        ])
                    ]),
                    "required": .array([.string("page"), .string("fact")])
                ]),
                // Deletes text the user may have written; undoable from the log.
                metadata: ToolMetadata(readOnly: false, destructive: true, dataSource: .localMachine)
            )
        ) { input in
            guard BrainPreferences.shared.isBrainEnabled else { return Self.brainIsOffResult }
            guard case .object(let arguments) = input,
                  case .string(let pageName)? = arguments["page"],
                  case .string(let factDescription)? = arguments["fact"] else {
                return "i need the page and the fact to forget."
            }
            let brainStore = BrainStore.shared
            guard let page = brainStore.resolvePage(named: pageName) else {
                return "there's no page called \"\(pageName)\" in the user's brain."
            }
            guard !page.isLocked else { return "\(page.title) is locked — the user can edit it by hand in the Brain page." }
            let matchingLines = BrainFactRemoval.matchingBulletLines(in: page.body, describedBy: factDescription)
            if matchingLines.isEmpty {
                return "nothing on \(page.title) matches \"\(factDescription)\"."
            }
            if matchingLines.count > BrainFactRemoval.maximumLinesPerRemoval {
                return "that matches \(matchingLines.count) facts on \(page.title) — ask the user which one they mean."
            }
            var editedPage = page
            editedPage.body = BrainFactRemoval.body(page.body, removing: matchingLines)
            // The user approved this exact removal on the confirmation card,
            // so it is saved as their edit: versioned and undoable.
            brainStore.savePageEditedByUser(editedPage)
            let removedFacts = matchingLines.map { $0.trimmingCharacters(in: .whitespaces) }
            return "removed from \(page.title): " + removedFacts.joined(separator: "; ")
        }

        register(
            BuddyToolDefinition(
                name: BrainToolNames.ingestIntoBrain,
                description: "Have Wisp read a file or web page and file what's in it into the user's brain (their personal wiki), in the background. Use when the user asks to add, ingest or save a document, PDF or link to their brain. The user is asked first.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["source": .object([
                        "type": .string("string"),
                        "description": .string("A web address (https://…) or a file path (/Users/… or ~/…)")
                    ])]),
                    "required": .array([.string("source")])
                ]),
                // Fetches a web page for a URL; writes pages once it's read.
                metadata: ToolMetadata(readOnly: false, dataSource: .network)
            )
        ) { input in
            guard BrainPreferences.shared.isBrainEnabled else { return Self.brainIsOffResult }
            guard case .object(let arguments) = input,
                  case .string(let rawSource)? = arguments["source"] else {
                return "i need a web address or a file path."
            }
            switch BrainIngestSourceParser.source(from: rawSource) {
            case .webPage(let webPageURL):
                BrainIngestQueue.shared.enqueue(webPageURL: webPageURL)
                return "reading \(webPageURL.absoluteString) into the user's brain in the background."
            case .file(let fileURL):
                return Self.enqueueFileForBrainIngest(fileURL).resultText
            case nil:
                return "\"\(rawSource)\" isn't a web address or a file path."
            }
        }
    }

    static let brainIsOffResult = "the user's brain is turned off. tell them they can switch it on in the Brain page."

    /// Queues one file, or says why it can't be read. `resultText` reads
    /// well both as a tool result and as a notch reply.
    static func enqueueFileForBrainIngest(_ fileURL: URL) -> (didQueue: Bool, resultText: String) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            return (false, "there's no file at \(fileURL.path).")
        }
        guard !isDirectory.boolValue else {
            return (false, "that's a folder — you can import a whole folder of notes from the Brain page.")
        }
        guard BrainIngestQueue.supportedFileExtensions.contains(fileURL.pathExtension.lowercased()) else {
            return (false, "i can't read .\(fileURL.pathExtension) files into the brain yet.")
        }
        BrainIngestQueue.shared.enqueue(fileURL: fileURL)
        return (true, "reading \(fileURL.lastPathComponent) into the brain in the background.")
    }
}
