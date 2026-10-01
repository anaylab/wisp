//
//  BrainPage.swift
//  leanring-buddy
//
//  One page of the user's brain — Wisp's LLM-maintained personal wiki at
//  `~/.wisp/brain/wiki/`. Pure: parsing and rendering a page as text, slugs,
//  and `[[links]]`, so all of it is testable without a file system.
//
//  A page is plain markdown with a small frontmatter header, so the vault is a
//  valid Obsidian vault and every page stays readable and hand-editable:
//
//      ---
//      title: Sarah Chen
//      kind: person
//      summary: Design lead on the Atlas project; prefers async updates.
//      aliases: [Sarah, S. Chen]
//      tags: [work]
//      sources: [conversation 2026-09-29]
//      created: 2026-09-29
//      updated: 2026-09-29
//      ---
//
//      ## Facts
//      - Leads design for [[Atlas]].
//
//  The body is organised into `## Section` blocks. Model-written changes
//  always target a section (see `BrainEdit.swift`), so a page grows in
//  predictable places instead of being rewritten wholesale.
//

import Foundation

// MARK: - Kind

/// What a page is about. Decides the folder it lives in and how it is listed.
enum BrainPageKind: String, CaseIterable, Codable, Sendable {
    /// The single page about the user themselves (`wiki/me.md`).
    case me
    case person
    case project
    case topic
    case organization
    case place
    case event
    /// A digest of one ingested source (an article, a PDF, a note).
    case source
    /// Anything that fits nowhere else.
    case note

    /// Folder under `wiki/`, or "" for the root (only `me`).
    var directoryName: String {
        switch self {
        case .me: return ""
        case .person: return "people"
        case .project: return "projects"
        case .topic: return "topics"
        case .organization: return "organizations"
        case .place: return "places"
        case .event: return "events"
        case .source: return "sources"
        case .note: return "notes"
        }
    }

    var displayName: String {
        switch self {
        case .me: return "Me"
        case .person: return "Person"
        case .project: return "Project"
        case .topic: return "Topic"
        case .organization: return "Organization"
        case .place: return "Place"
        case .event: return "Event"
        case .source: return "Source"
        case .note: return "Note"
        }
    }

    var pluralDisplayName: String {
        switch self {
        case .me: return "Me"
        case .person: return "People"
        case .project: return "Projects"
        case .topic: return "Topics"
        case .organization: return "Organizations"
        case .place: return "Places"
        case .event: return "Events"
        case .source: return "Sources"
        case .note: return "Notes"
        }
    }

    /// SF Symbol used wherever pages are listed.
    var symbolName: String {
        switch self {
        case .me: return "person.crop.circle"
        case .person: return "person"
        case .project: return "hammer"
        case .topic: return "lightbulb"
        case .organization: return "building.2"
        case .place: return "mappin.and.ellipse"
        case .event: return "calendar"
        case .source: return "doc.text"
        case .note: return "note.text"
        }
    }

    /// Lenient reading of a model- or hand-written kind ("People", "company").
    static func lenient(_ rawKind: String) -> BrainPageKind? {
        let comparableKind = rawKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exactKind = BrainPageKind(rawValue: comparableKind) { return exactKind }
        switch comparableKind {
        case "people", "persons", "contact", "friend", "colleague": return .person
        case "projects", "product", "app", "repo", "codebase": return .project
        case "topics", "concept", "idea", "subject", "skill": return .topic
        case "organizations", "organisation", "company", "org", "team", "school": return .organization
        case "places", "location", "city": return .place
        case "events", "meeting", "trip": return .event
        case "sources", "article", "document", "paper", "book", "video": return .source
        case "notes", "misc", "other": return .note
        case "user", "self", "myself": return .me
        default: return nil
        }
    }
}

// MARK: - Page

struct BrainPage: Identifiable, Equatable, Sendable {
    /// Path under `wiki/` without the `.md` extension, e.g. `people/sarah-chen`.
    /// Stable identity: links and edits resolve to it.
    var slug: String
    var title: String
    var kind: BrainPageKind
    /// One line: what this page is, for the index and the prompt.
    var summary: String
    var aliases: [String]
    var tags: [String]
    /// Where the page's content came from, newest last ("conversation
    /// 2026-09-29", "article.pdf"). Provenance the user can check.
    var sources: [String]
    var createdDate: Date?
    var updatedDate: Date?
    /// A locked page is never changed by model-written edits — only by hand.
    var isLocked: Bool
    /// Markdown after the frontmatter.
    var body: String

    var id: String { slug }

    /// Every `[[link]]` target in the body, in order, de-duplicated.
    var outgoingLinkTargets: [String] {
        BrainLinkParser.linkTargets(in: body)
    }

    /// The body's `## Section` blocks.
    var sections: [BrainPageSection] {
        BrainPageSections.parse(body)
    }

    /// Every name this page answers to, for link resolution and search.
    var allNames: [String] {
        [title] + aliases
    }
}

struct BrainPageSection: Equatable, Sendable {
    /// Heading text without the `## `, or "" for text before the first heading.
    var heading: String
    /// Lines under the heading, without the heading line itself.
    var content: String
}

// MARK: - Dates

enum BrainDateFormat {
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func dayString(from date: Date) -> String {
        dayFormatter.string(from: date)
    }

    static func date(fromDayString dayString: String) -> Date? {
        let trimmedDayString = dayString.trimmingCharacters(in: .whitespaces)
        if let dayDate = dayFormatter.date(from: trimmedDayString) { return dayDate }
        // Tolerate a full ISO 8601 timestamp written by hand or by another tool.
        return ISO8601DateFormatter().date(from: trimmedDayString)
    }
}

// MARK: - Slugs

enum BrainSlug {
    /// Longest slug file name (without folder). Keeps paths sane.
    static let maximumFileNameLength = 60

    /// `Sarah Chen` → `sarah-chen`. ASCII letters/digits and dashes only, so a
    /// slug is always a safe single path component.
    static func fileName(fromTitle title: String) -> String {
        let foldedTitle = title
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        var fileName = ""
        var previousCharacterWasDash = false
        for character in foldedTitle {
            if character.isASCII && (character.isLetter || character.isNumber) {
                fileName.append(character)
                previousCharacterWasDash = false
            } else if !previousCharacterWasDash && !fileName.isEmpty {
                fileName.append("-")
                previousCharacterWasDash = true
            }
        }
        while fileName.hasSuffix("-") { fileName.removeLast() }
        if fileName.count > maximumFileNameLength {
            fileName = String(fileName.prefix(maximumFileNameLength))
            while fileName.hasSuffix("-") { fileName.removeLast() }
        }
        return fileName.isEmpty ? "untitled" : fileName
    }

    /// The slug a new page with this title and kind would get.
    static func make(title: String, kind: BrainPageKind) -> String {
        if kind == .me { return "me" }
        return "\(kind.directoryName)/\(fileName(fromTitle: title))"
    }

    /// Whether a slug is safe to turn into a path under `wiki/`: at most one
    /// folder, no `..`, no absolute paths, only slug characters.
    static func isSafe(_ slug: String) -> Bool {
        guard !slug.isEmpty, !slug.hasPrefix("/"), !slug.contains("..") else { return false }
        let components = slug.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count <= 2, components.allSatisfy({ !$0.isEmpty }) else { return false }
        let allowedCharacters = CharacterSet.lowercaseLetters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: "-_"))
        return components.allSatisfy { component in
            component.unicodeScalars.allSatisfy { allowedCharacters.contains($0) && $0.isASCII }
        }
    }

    /// Case- and punctuation-insensitive form of a name, for matching links
    /// and model-written titles against existing pages.
    static func comparableName(_ name: String) -> String {
        fileName(fromTitle: name)
    }
}

// MARK: - Links

enum BrainLinkParser {
    /// Targets of every `[[target]]` / `[[target|shown text]]` / `[[target#heading]]`
    /// in the text, in order, de-duplicated (case-insensitive).
    static func linkTargets(in markdown: String) -> [String] {
        var targets: [String] = []
        var seenComparableTargets = Set<String>()
        var searchStart = markdown.startIndex
        while let openRange = markdown.range(of: "[[", range: searchStart..<markdown.endIndex),
              let closeRange = markdown.range(of: "]]", range: openRange.upperBound..<markdown.endIndex) {
            let inner = String(markdown[openRange.upperBound..<closeRange.lowerBound])
            searchStart = closeRange.upperBound
            guard !inner.contains("\n"), !inner.contains("[[") else { continue }
            let target = linkTarget(fromInnerText: inner)
            guard !target.isEmpty else { continue }
            let comparableTarget = BrainSlug.comparableName(target)
            if seenComparableTargets.insert(comparableTarget).inserted {
                targets.append(target)
            }
        }
        return targets
    }

    /// `Sarah Chen|Sarah` → `Sarah Chen`; `Atlas#Goals` → `Atlas`.
    static func linkTarget(fromInnerText inner: String) -> String {
        var target = inner
        if let pipeIndex = target.firstIndex(of: "|") { target = String(target[..<pipeIndex]) }
        if let hashIndex = target.firstIndex(of: "#") { target = String(target[..<hashIndex]) }
        return target.trimmingCharacters(in: .whitespaces)
    }

    /// The text a link shows: the alias after `|`, otherwise the target.
    static func displayText(fromInnerText inner: String) -> String {
        if let pipeIndex = inner.firstIndex(of: "|") {
            let shownText = inner[inner.index(after: pipeIndex)...].trimmingCharacters(in: .whitespaces)
            if !shownText.isEmpty { return shownText }
        }
        return linkTarget(fromInnerText: inner)
    }
}

// MARK: - Sections

enum BrainPageSections {
    /// Splits a body into sections at `## ` headings. Text before the first
    /// heading becomes a section with an empty heading (only if non-blank).
    static func parse(_ body: String) -> [BrainPageSection] {
        var sections: [BrainPageSection] = []
        var currentHeading = ""
        var currentLines: [String] = []

        func flushCurrentSection() {
            let content = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !currentHeading.isEmpty || !content.isEmpty {
                sections.append(BrainPageSection(heading: currentHeading, content: content))
            }
        }

        for line in body.components(separatedBy: "\n") {
            if let heading = headingText(onLine: line) {
                flushCurrentSection()
                currentHeading = heading
                currentLines = []
            } else {
                currentLines.append(line)
            }
        }
        flushCurrentSection()
        return sections
    }

    /// Joins sections back into a body.
    static func render(_ sections: [BrainPageSection]) -> String {
        sections.map { section in
            if section.heading.isEmpty { return section.content }
            return section.content.isEmpty
                ? "## \(section.heading)"
                : "## \(section.heading)\n\(section.content)"
        }
        .joined(separator: "\n\n")
    }

    /// `## Facts` → `Facts`. Only level-2 headings split sections; `###` and
    /// deeper stay inside their section.
    static func headingText(onLine line: String) -> String? {
        guard line.hasPrefix("## ") else { return nil }
        let heading = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
        return heading.isEmpty ? nil : heading
    }

    /// Index of the section whose heading matches, ignoring case and punctuation.
    static func indexOfSection(named heading: String, in sections: [BrainPageSection]) -> Int? {
        let comparableHeading = BrainSlug.comparableName(heading)
        return sections.firstIndex { BrainSlug.comparableName($0.heading) == comparableHeading && !$0.heading.isEmpty }
    }
}

// MARK: - Page file format

enum BrainPageFormat {
    /// Parses a page file. Never fails: a file with no frontmatter becomes a
    /// note titled from its slug, so a hand-dropped markdown file still shows up.
    static func parse(markdown: String, slug: String) -> BrainPage {
        let (fields, body) = splitFrontmatter(markdown)
        let fallbackTitle = slug.split(separator: "/").last.map { component in
            component.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        } ?? slug
        let kind = fields["kind"].flatMap(BrainPageKind.lenient)
            ?? (slug == "me" ? .me : kindFromSlugFolder(slug) ?? .note)
        return BrainPage(
            slug: slug,
            title: nonEmpty(fields["title"]) ?? fallbackTitle,
            kind: kind,
            summary: fields["summary"] ?? "",
            aliases: parseList(fields["aliases"]),
            tags: parseList(fields["tags"]),
            sources: parseList(fields["sources"]),
            createdDate: fields["created"].flatMap(BrainDateFormat.date(fromDayString:)),
            updatedDate: fields["updated"].flatMap(BrainDateFormat.date(fromDayString:)),
            isLocked: (fields["locked"] ?? "").lowercased() == "true",
            body: body.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func render(_ page: BrainPage) -> String {
        var lines = ["---"]
        lines.append("title: \(singleLine(page.title))")
        lines.append("kind: \(page.kind.rawValue)")
        lines.append("summary: \(singleLine(page.summary))")
        if !page.aliases.isEmpty { lines.append("aliases: \(renderList(page.aliases))") }
        if !page.tags.isEmpty { lines.append("tags: \(renderList(page.tags))") }
        if !page.sources.isEmpty { lines.append("sources: \(renderList(page.sources))") }
        if let createdDate = page.createdDate { lines.append("created: \(BrainDateFormat.dayString(from: createdDate))") }
        if let updatedDate = page.updatedDate { lines.append("updated: \(BrainDateFormat.dayString(from: updatedDate))") }
        if page.isLocked { lines.append("locked: true") }
        lines.append("---")
        lines.append("")
        lines.append(page.body.trimmingCharacters(in: .whitespacesAndNewlines))
        return lines.joined(separator: "\n") + "\n"
    }

    /// Frontmatter `key: value` pairs and the body after it.
    static func splitFrontmatter(_ markdown: String) -> (fields: [String: String], body: String) {
        var lines = markdown.components(separatedBy: "\n")[...]
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return ([:], markdown) }
        lines.removeFirst()
        var fields: [String: String] = [:]
        var foundClosingFence = false
        while let line = lines.first {
            lines.removeFirst()
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                foundClosingFence = true
                break
            }
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = line[..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            fields[key] = value
        }
        guard foundClosingFence else { return ([:], markdown) }
        return (fields, lines.joined(separator: "\n"))
    }

    /// `[a, b]`, `a, b` or a single value → items.
    static func parseList(_ rawList: String?) -> [String] {
        guard var listText = rawList?.trimmingCharacters(in: .whitespaces), !listText.isEmpty else { return [] }
        if listText.hasPrefix("[") && listText.hasSuffix("]") {
            listText = String(listText.dropFirst().dropLast())
        }
        return listText.split(separator: ",").map { item in
            var trimmedItem = item.trimmingCharacters(in: .whitespaces)
            if trimmedItem.count >= 2, trimmedItem.hasPrefix("\""), trimmedItem.hasSuffix("\"") {
                trimmedItem = String(trimmedItem.dropFirst().dropLast())
            }
            return trimmedItem
        }.filter { !$0.isEmpty }
    }

    static func renderList(_ items: [String]) -> String {
        "[" + items.map { singleLine($0).replacingOccurrences(of: ",", with: " ") }.joined(separator: ", ") + "]"
    }

    /// Frontmatter values are one line; a newline would end the field early.
    static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private static func kindFromSlugFolder(_ slug: String) -> BrainPageKind? {
        guard let folder = slug.split(separator: "/").first, slug.contains("/") else { return nil }
        return BrainPageKind.allCases.first { $0.directoryName == folder }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return text
    }
}
