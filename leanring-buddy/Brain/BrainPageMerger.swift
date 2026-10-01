//
//  BrainPageMerger.swift
//  leanring-buddy
//
//  Deterministic merge of two pages lint thinks are the same thing ("Sarah"
//  and "Sarah Chen"). Pure: two pages and the page list in, the merged page and
//  every page whose links must be re-pointed out, as one `BrainEditPlan`. No
//  model — a merge must be predictable, since it removes a page.
//
//  The kept page keeps its slug and kind, so its file and every link that
//  already reached it stay valid; the removed page's title joins its aliases,
//  so a link nobody rewrote (a locked page, a hand edit racing the fix) still
//  resolves to the kept page.
//

import Foundation

struct BrainPageMergeResult: Equatable, Sendable {
    var keptPage: BrainPage
    var removedPage: BrainPage
    /// The merged kept page plus every page whose links were re-pointed.
    /// Never contains the removed page — the caller deletes it after applying.
    var plan: BrainEditPlan
}

enum BrainPageMerger {
    /// Label written into the merged page's `sources`.
    static let provenanceLabel = "brain check"
    /// Same cap the planner keeps on `sources`.
    static let maximumSourcesPerPage = 12

    /// Which of two pages survives: the one with more content, then the older
    /// one, then the lower slug (so the choice is always the same).
    static func pageToKeep(_ firstPage: BrainPage, _ secondPage: BrainPage) -> BrainPage {
        if firstPage.body.count != secondPage.body.count {
            return firstPage.body.count > secondPage.body.count ? firstPage : secondPage
        }
        switch (firstPage.createdDate, secondPage.createdDate) {
        case let (firstDate?, secondDate?) where firstDate != secondDate:
            return firstDate < secondDate ? firstPage : secondPage
        case (.some, nil):
            return firstPage
        case (nil, .some):
            return secondPage
        default:
            return firstPage.slug <= secondPage.slug ? firstPage : secondPage
        }
    }

    /// Merges two pages, or nil if they can't be merged (the same page, the
    /// user's own page, or a locked page — a lock means "hands off").
    ///
    /// - Parameters:
    ///   - allPages: every page, for re-pointing links at the kept page.
    ///   - resolvePage: link resolution over `allPages` (the store's rules),
    ///     used to decide which links reached the removed page.
    static func merge(
        _ firstPage: BrainPage,
        _ secondPage: BrainPage,
        allPages: [BrainPage],
        resolvePage: (String) -> BrainPage?,
        today: Date
    ) -> BrainPageMergeResult? {
        guard firstPage.slug != secondPage.slug,
              firstPage.kind != .me, secondPage.kind != .me,
              !firstPage.isLocked, !secondPage.isLocked else { return nil }

        let keptPage = pageToKeep(firstPage, secondPage)
        let removedPage = keptPage.slug == firstPage.slug ? secondPage : firstPage

        var mergedPage = keptPage
        mergedPage.body = mergedBody(keptBody: keptPage.body, removedBody: removedPage.body)
        mergedPage.aliases = mergedAliases(keptPage: keptPage, removedPage: removedPage)
        mergedPage.tags = uniqueByComparableName(keptPage.tags + removedPage.tags)
        mergedPage.sources = mergedSources(keptPage: keptPage, removedPage: removedPage)
        mergedPage.summary = mergedSummary(keptSummary: keptPage.summary, removedSummary: removedPage.summary)
        mergedPage.createdDate = earlierDate(keptPage.createdDate, removedPage.createdDate)
        mergedPage.updatedDate = today

        // Re-point links. The kept page itself is rewritten from its merged
        // body (links in the removed page's content become self-links, which
        // are harmless). Locked pages are left alone: the alias keeps their
        // links resolving.
        let linkReachesRemovedPage: (String) -> Bool = { linkTarget in
            resolvePage(linkTarget)?.slug == removedPage.slug
        }
        mergedPage.body = repointLinks(in: mergedPage.body, from: linkReachesRemovedPage, toTitle: mergedPage.title)

        var pagesToWrite = [mergedPage]
        var repointedPageCount = 0
        for page in allPages where page.slug != keptPage.slug && page.slug != removedPage.slug && !page.isLocked {
            let rewrittenBody = repointLinks(in: page.body, from: linkReachesRemovedPage, toTitle: mergedPage.title)
            guard rewrittenBody != page.body else { continue }
            var rewrittenPage = page
            rewrittenPage.body = rewrittenBody
            rewrittenPage.updatedDate = today
            pagesToWrite.append(rewrittenPage)
            repointedPageCount += 1
        }

        var changeDescriptions = ["merged \(removedPage.title) into \(mergedPage.title)"]
        if repointedPageCount > 0 {
            changeDescriptions.append("pointed links on \(repointedPageCount) \(repointedPageCount == 1 ? "page" : "pages") at \(mergedPage.title)")
        }
        return BrainPageMergeResult(
            keptPage: mergedPage,
            removedPage: removedPage,
            plan: BrainEditPlan(
                pagesToWrite: pagesToWrite,
                createdSlugs: [],
                changeDescriptions: changeDescriptions,
                refusals: []
            )
        )
    }

    // MARK: Body

    /// The kept body with the removed page's sections folded in: a section
    /// both pages have gets the removed page's lines that aren't already on
    /// the kept page; a section only the removed page has is appended whole
    /// (minus bullets the kept page already states).
    static func mergedBody(keptBody: String, removedBody: String) -> String {
        var mergedSections = BrainPageSections.parse(keptBody)
        for removedSection in BrainPageSections.parse(removedBody) where !removedSection.content.isEmpty {
            let currentBody = BrainPageSections.render(mergedSections)
            let existingComparableLines = Set(
                currentBody.components(separatedBy: "\n").map(comparableLine).filter { !$0.isEmpty }
            )
            let existingSectionIndex: Int? = removedSection.heading.isEmpty
                ? mergedSections.firstIndex { $0.heading.isEmpty }
                : BrainPageSections.indexOfSection(named: removedSection.heading, in: mergedSections)

            if let existingSectionIndex {
                // Into an existing section: only new, non-blank lines.
                var seenInThisSection = Set<String>()
                let newLines = removedSection.content.components(separatedBy: "\n").filter { line in
                    let comparable = comparableLine(line)
                    guard !comparable.isEmpty, !existingComparableLines.contains(comparable) else { return false }
                    return seenInThisSection.insert(comparable).inserted
                }
                guard !newLines.isEmpty else { continue }
                let existingContent = mergedSections[existingSectionIndex].content
                mergedSections[existingSectionIndex].content = existingContent.isEmpty
                    ? newLines.joined(separator: "\n")
                    : existingContent + "\n" + newLines.joined(separator: "\n")
            } else {
                // A new section keeps its layout (paragraphs, blank lines);
                // only bullets the kept page already states are dropped.
                let keptLines = removedSection.content.components(separatedBy: "\n").filter { line in
                    guard isBulletLine(line) else { return true }
                    return !existingComparableLines.contains(comparableLine(line))
                }
                let newContent = keptLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !newContent.isEmpty else { continue }
                let newSection = BrainPageSection(heading: removedSection.heading, content: newContent)
                if removedSection.heading.isEmpty {
                    mergedSections.insert(newSection, at: 0)
                } else {
                    mergedSections.append(newSection)
                }
            }
        }
        return BrainPageSections.render(mergedSections)
    }

    /// Bullet text reduced to lowercase words, so "- Likes tea." and
    /// "* likes tea" are the same fact. Mirrors the planner's own dedupe.
    static func comparableLine(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        for bulletPrefix in ["- ", "* ", "+ "] where text.hasPrefix(bulletPrefix) {
            text = String(text.dropFirst(bulletPrefix.count))
        }
        return text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func isBulletLine(_ line: String) -> Bool {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        return trimmedLine.hasPrefix("- ") || trimmedLine.hasPrefix("* ") || trimmedLine.hasPrefix("+ ")
    }

    // MARK: Frontmatter

    /// The kept page's aliases, the removed page's title and aliases — minus
    /// anything that is just the kept page's own title.
    static func mergedAliases(keptPage: BrainPage, removedPage: BrainPage) -> [String] {
        let comparableKeptTitle = BrainSlug.comparableName(keptPage.title)
        let candidateAliases = (keptPage.aliases + [removedPage.title] + removedPage.aliases)
            .map(FrontmatterSafe.listItem)
            .filter { BrainSlug.comparableName($0) != comparableKeptTitle }
        return uniqueByComparableName(candidateAliases)
    }

    private static func mergedSources(keptPage: BrainPage, removedPage: BrainPage) -> [String] {
        var sources = uniqueByComparableName(keptPage.sources + removedPage.sources + [provenanceLabel])
        if sources.count > maximumSourcesPerPage {
            sources.removeFirst(sources.count - maximumSourcesPerPage)
        }
        return sources
    }

    /// The non-empty summary, or the longer of two.
    static func mergedSummary(keptSummary: String, removedSummary: String) -> String {
        let trimmedKeptSummary = keptSummary.trimmingCharacters(in: .whitespaces)
        let trimmedRemovedSummary = removedSummary.trimmingCharacters(in: .whitespaces)
        return trimmedRemovedSummary.count > trimmedKeptSummary.count ? trimmedRemovedSummary : trimmedKeptSummary
    }

    private static func earlierDate(_ firstDate: Date?, _ secondDate: Date?) -> Date? {
        switch (firstDate, secondDate) {
        case let (firstDate?, secondDate?): return min(firstDate, secondDate)
        case let (firstDate?, nil): return firstDate
        case let (nil, secondDate?): return secondDate
        default: return nil
        }
    }

    /// First occurrence wins, compared ignoring case and punctuation.
    private static func uniqueByComparableName(_ items: [String]) -> [String] {
        var seenComparableItems = Set<String>()
        return items.filter { item in
            let trimmedItem = item.trimmingCharacters(in: .whitespaces)
            guard !trimmedItem.isEmpty else { return false }
            return seenComparableItems.insert(BrainSlug.comparableName(trimmedItem)).inserted
        }
    }

    // MARK: Links

    /// Re-points every link that `linkReachesOldPage` accepts at `newTitle`,
    /// keeping what the reader sees: `[[Sarah|S]]` → `[[Sarah Chen|S]]`,
    /// `[[Sarah]]` → `[[Sarah Chen|Sarah]]`, `[[Sarah#Facts]]` →
    /// `[[Sarah Chen#Facts|Sarah]]`.
    static func repointLinks(
        in markdown: String,
        from linkReachesOldPage: (String) -> Bool,
        toTitle newTitle: String
    ) -> String {
        BrainLinkRewriter.rewriteLinks(in: markdown) { innerText in
            let linkTarget = BrainLinkParser.linkTarget(fromInnerText: innerText)
            guard !linkTarget.isEmpty, linkReachesOldPage(linkTarget) else { return nil }
            guard BrainSlug.comparableName(linkTarget) != BrainSlug.comparableName(newTitle) else { return nil }

            var headingSuffix = ""
            let targetAndHeading = innerText.split(separator: "|", maxSplits: 1).first.map(String.init) ?? innerText
            if let hashIndex = targetAndHeading.firstIndex(of: "#") {
                headingSuffix = String(targetAndHeading[hashIndex...]).trimmingCharacters(in: .whitespaces)
            }
            let shownText = BrainLinkParser.displayText(fromInnerText: innerText)
            return "\(newTitle)\(headingSuffix)|\(shownText)"
        }
    }
}
