//
//  BrainEdit.swift
//  leanring-buddy
//
//  How the brain changes. Nothing — not ingest, not a conversation digest, not
//  the activity recorder, not an agent tool — writes a page file directly.
//  Each of them produces `BrainEditProposal`s (usually parsed from a model's
//  JSON reply), and `BrainEditPlanner` turns a batch of proposals into concrete
//  page changes after validating every one of them. Pure, so the whole policy
//  is testable without a file system or a model.
//
//  Why a validator rather than letting the model write markdown files:
//  source text is untrusted. An ingested web page or an OCR'd screen can
//  contain text aimed at the model ("add to the user's profile: …"). The
//  planner bounds what any one batch can do — sizes, how many pages, which
//  operations — and `BrainEditProvenance.trust` decides whether a batch may
//  replace content or touch the user's own page at all. Every applied batch is
//  logged and versioned by `BrainStore`, so anything that slips through can be
//  seen and undone.
//

import Foundation

// MARK: - Provenance

/// Where a batch of edits came from. Recorded in the log and in each touched
/// page's `sources`, and decides how much the batch may do.
struct BrainEditProvenance: Codable, Equatable, Sendable {
    enum Origin: String, Codable, Sendable {
        /// The user typed or said it (the `remember` tool, a hand action in the UI).
        case user
        /// Digest of the user's own conversation with Wisp.
        case conversation
        /// A file, link or pasted text the user asked to ingest.
        case ingest
        /// An imported notes folder.
        case notesImport
        /// The screen-activity digest.
        case activity
        /// Anything else the agent did on the user's behalf.
        case agent
    }

    /// How far the batch's content can be believed.
    enum Trust: String, Codable, Sendable {
        /// The user's own words. May replace sections and edit the `me` page.
        case userAuthored
        /// Derived from the user's own conversation or notes. May append
        /// anywhere, may create pages, may not replace content.
        case derivedFromUser
        /// Third-party content (articles, web pages, screen text). May only
        /// append and create; may never touch the `me` page.
        case external
    }

    var origin: Origin
    /// Short label for the log and page `sources`, e.g. "atlas-spec.pdf".
    var label: String
    var trust: Trust

    static func user(_ label: String = "you") -> BrainEditProvenance {
        BrainEditProvenance(origin: .user, label: label, trust: .userAuthored)
    }
}

// MARK: - Proposal

/// One requested change, in the vocabulary the model is asked to write.
struct BrainEditProposal: Codable, Equatable, Sendable {
    enum Operation: String, Codable, Sendable {
        /// Add lines under a section (created if missing). Bullets already on
        /// the page (ignoring case) are skipped, so re-ingesting is harmless.
        case append
        /// Replace a section's whole content. `.userAuthored` only.
        case replace
        /// Set the page's one-line summary. Only fills an empty summary unless
        /// the batch is `.userAuthored`.
        case summarize
        /// Add alternative names (`content` is a comma-separated list).
        case alias
        /// Add tags (`content` is a comma-separated list).
        case tag
    }

    var operation: Operation
    /// The page's title (or an alias of an existing page). Resolved to an
    /// existing page first; otherwise a new page is created.
    var pageTitle: String
    /// Kind for a new page. Ignored when the page already exists.
    var pageKind: BrainPageKind?
    /// Section heading for `append` / `replace`. Defaults to "Notes".
    var section: String?
    var content: String
    /// Optional summary for a newly created page.
    var summary: String?

    init(
        operation: Operation,
        pageTitle: String,
        pageKind: BrainPageKind? = nil,
        section: String? = nil,
        content: String,
        summary: String? = nil
    ) {
        self.operation = operation
        self.pageTitle = pageTitle
        self.pageKind = pageKind
        self.section = section
        self.content = content
        self.summary = summary
    }
}

// MARK: - Model reply parsing

enum BrainEditProposalParser {
    /// Reads proposals from a model reply. Lenient about the wrapper — a bare
    /// array, `{"edits": [...]}`, a ```json fence, prose around it — and about
    /// key spelling (`page`/`title`/`pageTitle`, `kind`/`type`, `op`), because
    /// the local model is not reliable at exact JSON shapes. Items it can't
    /// read are dropped, not fatal.
    static func parseProposals(fromModelReply reply: String) -> [BrainEditProposal] {
        // The local 3B model regularly ends a long array without its closing
        // `]` (measured: six good edits, no bracket). A plain first-value scan
        // would then find only the first object, so an array that doesn't
        // parse is read object by object instead.
        if let unclosedArrayObjects = objectsOfUnclosedArray(in: reply) {
            return unclosedArrayObjects.compactMap(proposal(from:))
        }
        guard let jsonValue = firstJSONValue(in: reply) else { return [] }
        let items: [Any]
        if let array = jsonValue as? [Any] {
            items = array
        } else if let object = jsonValue as? [String: Any] {
            let wrappedItems = ["edits", "changes", "proposals", "updates", "pages"].lazy
                .compactMap { object[$0] as? [Any] }
                .first
            items = wrappedItems ?? [object]
        } else {
            return []
        }
        return items.compactMap { item in
            guard let fields = item as? [String: Any] else { return nil }
            return proposal(from: fields)
        }
    }

    private static func proposal(from fields: [String: Any]) -> BrainEditProposal? {
        func string(_ keys: String...) -> String? {
            for key in keys {
                if let value = fields[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
                if let values = fields[key] as? [String], !values.isEmpty {
                    return values.map { "- \($0)" }.joined(separator: "\n")
                }
            }
            return nil
        }
        guard let pageTitle = string("page", "title", "pageTitle", "page_title", "name") else { return nil }
        let rawOperation = (string("operation", "op", "action") ?? "append").lowercased()
        let operation: BrainEditProposal.Operation
        switch rawOperation {
        case "append", "add", "create", "upsert", "insert", "note": operation = .append
        case "replace", "rewrite", "set", "update": operation = .replace
        case "summarize", "summary", "describe": operation = .summarize
        case "alias", "aliases", "rename": operation = .alias
        case "tag", "tags": operation = .tag
        default: operation = .append
        }
        let summary = string("summary", "description")
        let content = string("content", "text", "facts", "lines", "body")
            ?? (operation == .summarize ? summary : nil)
        guard let content else { return nil }
        return BrainEditProposal(
            operation: operation,
            pageTitle: pageTitle,
            pageKind: string("kind", "type", "pageKind", "category").flatMap(BrainPageKind.lenient),
            section: string("section", "heading"),
            content: content,
            summary: operation == .summarize ? nil : summary
        )
    }

    /// When the reply's first bracket opens an array that never parses as a
    /// whole, every complete top-level `{…}` inside it; nil otherwise (no
    /// array, or an array that parses fine).
    static func objectsOfUnclosedArray(in text: String) -> [[String: Any]]? {
        let characters = Array(text)
        guard let arrayOpenIndex = characters.firstIndex(where: { $0 == "[" || $0 == "{" }),
              characters[arrayOpenIndex] == "[" else { return nil }
        if let closeIndex = matchingCloseIndex(in: characters, from: arrayOpenIndex),
           let data = String(characters[arrayOpenIndex...closeIndex]).data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return nil
        }
        var objects: [[String: Any]] = []
        var scanIndex = arrayOpenIndex + 1
        while scanIndex < characters.count {
            guard characters[scanIndex] == "{" else {
                if characters[scanIndex] == "]" { break }
                scanIndex += 1
                continue
            }
            guard let objectCloseIndex = matchingCloseIndex(in: characters, from: scanIndex) else { break }
            if let data = String(characters[scanIndex...objectCloseIndex]).data(using: .utf8),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                objects.append(object)
            }
            scanIndex = objectCloseIndex + 1
        }
        return objects.isEmpty ? nil : objects
    }

    /// The first parseable JSON array or object in the text.
    static func firstJSONValue(in text: String) -> Any? {
        let characters = Array(text)
        var startIndex = 0
        while startIndex < characters.count {
            guard characters[startIndex] == "[" || characters[startIndex] == "{" else {
                startIndex += 1
                continue
            }
            if let endIndex = matchingCloseIndex(in: characters, from: startIndex) {
                let candidate = String(characters[startIndex...endIndex])
                if let data = candidate.data(using: .utf8),
                   let value = try? JSONSerialization.jsonObject(with: data) {
                    return value
                }
            }
            startIndex += 1
        }
        return nil
    }

    /// Index of the bracket closing the one at `openIndex`, string-aware.
    private static func matchingCloseIndex(in characters: [Character], from openIndex: Int) -> Int? {
        var depth = 0
        var isInsideString = false
        var previousWasEscape = false
        for index in openIndex..<characters.count {
            let character = characters[index]
            if isInsideString {
                if previousWasEscape { previousWasEscape = false }
                else if character == "\\" { previousWasEscape = true }
                else if character == "\"" { isInsideString = false }
                continue
            }
            switch character {
            case "\"": isInsideString = true
            case "[", "{": depth += 1
            case "]", "}":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
        }
        return nil
    }
}

// MARK: - Plan

/// What applying a batch would do: the pages to write, and why anything was
/// refused. Produced by `BrainEditPlanner`, carried out by `BrainStore`.
struct BrainEditPlan: Equatable, Sendable {
    /// New or changed pages, keyed by slug, fully rendered-ready.
    var pagesToWrite: [BrainPage]
    /// Slugs among `pagesToWrite` that don't exist yet.
    var createdSlugs: Set<String>
    /// Human-readable lines, one per applied change ("added 2 facts to Sarah Chen").
    var changeDescriptions: [String]
    /// Human-readable lines, one per refused proposal and why.
    var refusals: [String]

    var isEmpty: Bool { pagesToWrite.isEmpty }
}

enum BrainEditPlanner {
    /// Most proposals one batch may carry. A source that "needs" more is either
    /// huge (chunk it) or a model looping.
    static let maximumProposalsPerBatch = 24
    /// Most distinct pages one batch may create.
    static let maximumPagesCreatedPerBatch = 10
    /// Longest `content` of one proposal.
    static let maximumContentCharacters = 2000
    static let maximumTitleCharacters = 80
    static let maximumSectionCharacters = 60
    static let maximumSummaryCharacters = 200
    /// A page body is never allowed to grow past this; appends beyond it are
    /// refused, which is the cue for a lint pass to split the page.
    static let maximumPageBodyCharacters = 24_000
    static let defaultSectionHeading = "Notes"

    /// Validates and applies a batch against the current pages.
    ///
    /// - Parameters:
    ///   - resolvePage: finds an existing page by title/alias/slug (the store's
    ///     link resolution).
    ///   - today: the date stamped into `updated` / `created`.
    static func plan(
        proposals: [BrainEditProposal],
        provenance: BrainEditProvenance,
        resolvePage: (String) -> BrainPage?,
        today: Date
    ) -> BrainEditPlan {
        var workingPagesBySlug: [String: BrainPage] = [:]
        var slugOrder: [String] = []
        var createdSlugs = Set<String>()
        var changeDescriptions: [String] = []
        var refusals: [String] = []

        let acceptedProposals = Array(proposals.prefix(maximumProposalsPerBatch))
        if proposals.count > maximumProposalsPerBatch {
            refusals.append("dropped \(proposals.count - maximumProposalsPerBatch) edits over the \(maximumProposalsPerBatch)-per-batch limit")
        }

        for proposal in acceptedProposals {
            let title = cleanedTitle(proposal.pageTitle)
            guard !title.isEmpty else {
                refusals.append("an edit had no page title")
                continue
            }

            // Find the page: already touched in this batch, existing, or new.
            let comparableTitle = BrainSlug.comparableName(title)
            let pageAlreadyInBatch = workingPagesBySlug.values.first { page in
                page.allNames.contains { BrainSlug.comparableName($0) == comparableTitle }
            }
            let isAboutTheUser = proposal.pageKind == .me || comparableTitle == "me"
            var page: BrainPage
            var isNewPage = false
            if let pageAlreadyInBatch {
                page = pageAlreadyInBatch
            } else if let existingPage = isAboutTheUser ? resolvePage("me") : resolvePage(title) {
                // An earlier edit in this batch may already have changed this
                // page under a name this edit doesn't use (the me page retitled,
                // an alias) — build on that copy, not the one on disk.
                page = workingPagesBySlug[existingPage.slug] ?? existingPage
            } else if let batchPageWithSameSlug = workingPagesBySlug[BrainSlug.make(title: title, kind: isAboutTheUser ? .me : (proposal.pageKind ?? .note))] {
                page = batchPageWithSameSlug
            } else {
                let kind: BrainPageKind = isAboutTheUser ? .me : (proposal.pageKind ?? .note)
                let slug = BrainSlug.make(title: title, kind: kind)
                guard BrainSlug.isSafe(slug) else {
                    refusals.append("\"\(title)\" isn't a usable page name")
                    continue
                }
                guard createdSlugs.count < maximumPagesCreatedPerBatch || createdSlugs.contains(slug) else {
                    refusals.append("didn't create \"\(title)\": \(maximumPagesCreatedPerBatch)-new-pages-per-batch limit")
                    continue
                }
                page = BrainPage(
                    slug: slug,
                    title: kind == .me ? "Me" : title,
                    kind: kind,
                    summary: "",
                    aliases: [],
                    tags: [],
                    sources: [],
                    createdDate: today,
                    updatedDate: today,
                    isLocked: false,
                    body: ""
                )
                isNewPage = true
            }

            // Policy checks.
            if page.isLocked {
                refusals.append("\"\(page.title)\" is locked")
                continue
            }
            if page.kind == .me && provenance.trust == .external {
                refusals.append("outside content can't change your own page")
                continue
            }
            if proposal.operation == .replace && provenance.trust != .userAuthored {
                // Downgrade rather than drop: the information is still wanted,
                // it just may not overwrite what's there.
                var appendProposal = proposal
                appendProposal.operation = .append
                if let updatedPage = applying(appendProposal, to: page, changeDescriptions: &changeDescriptions, refusals: &refusals, provenance: provenance) {
                    page = updatedPage
                } else {
                    continue
                }
            } else if let updatedPage = applying(proposal, to: page, changeDescriptions: &changeDescriptions, refusals: &refusals, provenance: provenance) {
                page = updatedPage
            } else {
                continue
            }

            // A new page gets the proposal's summary if it brought one.
            if isNewPage, page.summary.isEmpty, let proposedSummary = proposal.summary {
                page.summary = cleanedSummary(proposedSummary)
            }
            let sourceLabel = FrontmatterSafe.listItem(provenance.label)
            if !page.sources.contains(sourceLabel) && !sourceLabel.isEmpty {
                page.sources.append(sourceLabel)
                if page.sources.count > 12 { page.sources.removeFirst(page.sources.count - 12) }
            }
            page.updatedDate = today

            if isNewPage { createdSlugs.insert(page.slug) }
            if workingPagesBySlug[page.slug] == nil { slugOrder.append(page.slug) }
            workingPagesBySlug[page.slug] = page
        }

        return BrainEditPlan(
            pagesToWrite: slugOrder.compactMap { workingPagesBySlug[$0] },
            createdSlugs: createdSlugs,
            changeDescriptions: coalescedChangeDescriptions(changeDescriptions),
            refusals: refusals
        )
    }

    /// One proposal applied to one page, or nil (with a refusal recorded) if
    /// it changed nothing or wasn't allowed.
    private static func applying(
        _ proposal: BrainEditProposal,
        to page: BrainPage,
        changeDescriptions: inout [String],
        refusals: inout [String],
        provenance: BrainEditProvenance
    ) -> BrainPage? {
        var updatedPage = page
        switch proposal.operation {
        case .append, .replace:
            let content = cleanedContent(proposal.content)
            guard !content.isEmpty else { return nil }
            let heading = cleanedSection(proposal.section)
            var sections = BrainPageSections.parse(page.body)
            let sectionIndex: Int
            if let existingIndex = BrainPageSections.indexOfSection(named: heading, in: sections) {
                sectionIndex = existingIndex
            } else {
                sections.append(BrainPageSection(heading: heading, content: ""))
                sectionIndex = sections.count - 1
            }
            if proposal.operation == .replace {
                guard sections[sectionIndex].content != content else { return nil }
                sections[sectionIndex].content = content
                changeDescriptions.append("rewrote \(heading) on \(page.title)")
            } else {
                let newLines = linesNotAlreadyOnPage(content, page: page)
                guard !newLines.isEmpty else { return nil }
                let existingContent = sections[sectionIndex].content
                sections[sectionIndex].content = existingContent.isEmpty
                    ? newLines.joined(separator: "\n")
                    : existingContent + "\n" + newLines.joined(separator: "\n")
                let bulletCount = newLines.filter { $0.hasPrefix("- ") }.count
                changeDescriptions.append(
                    bulletCount > 0
                        ? "added \(bulletCount) \(bulletCount == 1 ? "fact" : "facts") to \(page.title)"
                        : "added to \(heading) on \(page.title)"
                )
            }
            let newBody = BrainPageSections.render(sections)
            guard newBody.count <= maximumPageBodyCharacters else {
                refusals.append("\(page.title) is full — it needs splitting before it can grow")
                return nil
            }
            updatedPage.body = newBody

        case .summarize:
            let summary = cleanedSummary(proposal.content)
            guard !summary.isEmpty, summary != page.summary else { return nil }
            guard page.summary.isEmpty || provenance.trust == .userAuthored else {
                return nil
            }
            updatedPage.summary = summary
            changeDescriptions.append("summarised \(page.title)")

        case .alias, .tag:
            let newItems = FrontmatterSafe.listItems(fromCommaSeparated: proposal.content)
            let existingItems = proposal.operation == .alias ? page.allNames : page.tags
            let existingComparable = Set(existingItems.map(BrainSlug.comparableName))
            let addedItems = newItems.filter { !existingComparable.contains(BrainSlug.comparableName($0)) }
            guard !addedItems.isEmpty else { return nil }
            if proposal.operation == .alias {
                updatedPage.aliases.append(contentsOf: addedItems.prefix(8))
                changeDescriptions.append("\(page.title) is also known as \(addedItems.joined(separator: ", "))")
            } else {
                updatedPage.tags.append(contentsOf: addedItems.prefix(8))
                changeDescriptions.append("tagged \(page.title) \(addedItems.joined(separator: ", "))")
            }
        }
        return updatedPage
    }

    /// One line per page for fact additions ("added 5 facts to Offline maps"
    /// instead of five "added 1 fact" lines — a model often sends one edit
    /// per fact), other lines kept once, in first-seen order.
    static func coalescedChangeDescriptions(_ descriptions: [String]) -> [String] {
        var orderedKeys: [String] = []
        var factCountsByPageTitle: [String: Int] = [:]
        var seenOtherDescriptions = Set<String>()
        for description in descriptions {
            let words = description.split(separator: " ", maxSplits: 3).map(String.init)
            if words.count == 4, words[0] == "added", let factCount = Int(words[1]),
               words[2] == "fact" || words[2] == "facts", words[3].hasPrefix("to ") {
                let pageTitle = String(words[3].dropFirst(3))
                if factCountsByPageTitle[pageTitle] == nil { orderedKeys.append("facts:" + pageTitle) }
                factCountsByPageTitle[pageTitle, default: 0] += factCount
            } else if seenOtherDescriptions.insert(description).inserted {
                orderedKeys.append("other:" + description)
            }
        }
        return orderedKeys.map { key in
            if key.hasPrefix("facts:") {
                let pageTitle = String(key.dropFirst(6))
                let factCount = factCountsByPageTitle[pageTitle] ?? 0
                return "added \(factCount) \(factCount == 1 ? "fact" : "facts") to \(pageTitle)"
            }
            return String(key.dropFirst(6))
        }
    }

    /// Lines of `content` whose bullet text isn't already somewhere on the page.
    static func linesNotAlreadyOnPage(_ content: String, page: BrainPage) -> [String] {
        let existingComparableLines = Set(
            page.body.components(separatedBy: "\n").map(comparableLine).filter { !$0.isEmpty }
        )
        var seenInThisContent = Set<String>()
        return content.components(separatedBy: "\n").filter { line in
            let comparable = comparableLine(line)
            guard !comparable.isEmpty else { return false }
            guard !existingComparableLines.contains(comparable) else { return false }
            return seenInThisContent.insert(comparable).inserted
        }
    }

    private static func comparableLine(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        for bulletPrefix in ["- ", "* ", "+ "] where text.hasPrefix(bulletPrefix) {
            text = String(text.dropFirst(bulletPrefix.count))
        }
        return text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: Cleaning

    static func cleanedTitle(_ rawTitle: String) -> String {
        var title = FrontmatterSafe.singleLine(rawTitle)
            .replacingOccurrences(of: "[[", with: "")
            .replacingOccurrences(of: "]]", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " #*_`\"'"))
        if title.count > maximumTitleCharacters { title = String(title.prefix(maximumTitleCharacters)) }
        return title
    }

    static func cleanedSection(_ rawSection: String?) -> String {
        var heading = FrontmatterSafe.singleLine(rawSection ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " #*_`\"'"))
        if heading.count > maximumSectionCharacters { heading = String(heading.prefix(maximumSectionCharacters)) }
        return heading.isEmpty ? defaultSectionHeading : heading
    }

    static func cleanedSummary(_ rawSummary: String) -> String {
        var summary = FrontmatterSafe.singleLine(rawSummary)
        if summary.count > maximumSummaryCharacters { summary = String(summary.prefix(maximumSummaryCharacters)) + "…" }
        return summary
    }

    /// Content with anything that could break the page's structure removed:
    /// frontmatter fences and level-1/2 headings (they would split sections)
    /// are neutralised, lines are right-trimmed, blank runs collapsed.
    static func cleanedContent(_ rawContent: String) -> String {
        var cleanedLines: [String] = []
        var previousLineWasBlank = true
        for rawLine in rawContent.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            var line = rawLine
            while line.last?.isWhitespace == true { line.removeLast() }
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine == "---" { continue }
            if trimmedLine.hasPrefix("# ") || trimmedLine.hasPrefix("## ") {
                line = "### " + trimmedLine.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            }
            let isBlank = trimmedLine.isEmpty
            if isBlank && previousLineWasBlank { continue }
            cleanedLines.append(line)
            previousLineWasBlank = isBlank
        }
        while cleanedLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cleanedLines.removeLast() }
        var content = cleanedLines.joined(separator: "\n")
        if content.count > maximumContentCharacters { content = String(content.prefix(maximumContentCharacters)) }
        return content
    }
}

/// Keeps model-written text from breaking frontmatter.
enum FrontmatterSafe {
    static func singleLine(_ text: String) -> String {
        BrainPageFormat.singleLine(text)
    }

    static func listItem(_ text: String) -> String {
        singleLine(text)
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
    }

    static func listItems(fromCommaSeparated text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { listItem(String($0)).trimmingCharacters(in: CharacterSet(charactersIn: " -*\"'")) }
            .filter { !$0.isEmpty && $0.count <= BrainEditPlanner.maximumTitleCharacters }
    }
}
