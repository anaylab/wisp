//
//  BrainPageSplitter.swift
//  leanring-buddy
//
//  Deterministic split of a page that has grown close to the planner's body
//  cap (`BrainEditPlanner.maximumPageBodyCharacters`), past which every append
//  is refused. Pure: the page in, one `BrainEditPlan` out.
//
//  The largest `## Section`s move to child pages titled "<Title> — <Section>"
//  (same kind), and each is replaced in the parent by a link line, so nothing
//  is lost and the parent still points at everything. A page whose bulk is one
//  section (the default "Notes" section usually) has that section's earlier
//  lines moved instead, newest lines staying on the parent where appends land.
//

import Foundation

enum BrainPageSplitter {
    /// A split stops once the parent body is at or below this share of the cap,
    /// leaving room to grow before the next split.
    static let targetFractionOfMaximumBody = 0.5
    static let provenanceLabel = "brain check"
    /// Separator between the parent title and the section in a child title.
    static let childTitleSeparator = " — "

    static var targetParentBodyCharacters: Int {
        Int(Double(BrainEditPlanner.maximumPageBodyCharacters) * targetFractionOfMaximumBody)
    }

    /// Whether `split` can produce anything: an unlocked page with at least
    /// one headed section that has content (or one section with several lines).
    static func canSplit(_ page: BrainPage) -> Bool {
        guard !page.isLocked else { return false }
        let movableSections = page.sections.filter { !$0.heading.isEmpty && !$0.content.isEmpty }
        if movableSections.count >= 2 { return true }
        guard let onlySection = movableSections.first else { return false }
        return nonBlankLines(onlySection.content).count >= 2
    }

    /// The kind child pages get. The user's page has exactly one slug ("me"),
    /// so its children become notes.
    static func childKind(forParentKind parentKind: BrainPageKind) -> BrainPageKind {
        parentKind == .me ? .note : parentKind
    }

    /// "Sarah Chen — Meetings", shortened to the planner's title limit.
    static func childTitle(parentTitle: String, sectionHeading: String) -> String {
        let fullTitle = parentTitle + childTitleSeparator + sectionHeading
        guard fullTitle.count > BrainEditPlanner.maximumTitleCharacters else { return fullTitle }
        return String(fullTitle.prefix(BrainEditPlanner.maximumTitleCharacters)).trimmingCharacters(in: .whitespaces)
    }

    /// The split as one plan (parent + children), or nil if nothing can move.
    ///
    /// - Parameter resolvePage: link resolution over the current pages, so a
    ///   child page left by an earlier split is extended rather than clobbered.
    static func split(
        _ page: BrainPage,
        resolvePage: (String) -> BrainPage?,
        today: Date
    ) -> BrainEditPlan? {
        guard canSplit(page) else { return nil }
        var parentSections = page.sections
        let movableSectionIndices = parentSections.indices
            .filter { !parentSections[$0].heading.isEmpty && !parentSections[$0].content.isEmpty }

        var childPagesBySlug: [String: BrainPage] = [:]
        var childSlugOrder: [String] = []
        var createdSlugs = Set<String>()
        var changeDescriptions: [String] = []

        func addToChildPage(title: String, sectionHeading: String, content: String) -> String {
            let childPage = childPageWithSection(
                title: title,
                sectionHeading: sectionHeading,
                content: content,
                parent: page,
                existingChildPage: childPagesBySlug.values.first { BrainSlug.comparableName($0.title) == BrainSlug.comparableName(title) }
                    ?? resolvePage(title).flatMap { $0.isLocked || $0.slug == page.slug ? nil : $0 },
                reservedSlugs: Set(childSlugOrder).union([page.slug]),
                today: today
            )
            if resolvePage(childPage.title)?.slug != childPage.slug && childPagesBySlug[childPage.slug] == nil {
                createdSlugs.insert(childPage.slug)
            }
            if childPagesBySlug[childPage.slug] == nil { childSlugOrder.append(childPage.slug) }
            childPagesBySlug[childPage.slug] = childPage
            return childPage.title
        }

        if movableSectionIndices.count >= 2 {
            // Largest sections first, until the parent is small enough — but
            // always leave at least one section with its content in place.
            let indicesBySizeDescending = movableSectionIndices.sorted {
                parentSections[$0].content.count > parentSections[$1].content.count
            }
            for sectionIndex in indicesBySizeDescending.dropLast() {
                guard BrainPageSections.render(parentSections).count > targetParentBodyCharacters
                        || childSlugOrder.isEmpty else { break }
                let section = parentSections[sectionIndex]
                let title = childTitle(parentTitle: page.title, sectionHeading: section.heading)
                let childTitleUsed = addToChildPage(title: title, sectionHeading: section.heading, content: section.content)
                parentSections[sectionIndex].content = "See [[\(childTitleUsed)]]."
                changeDescriptions.append("moved \(section.heading) from \(page.title) to \(childTitleUsed)")
            }
        } else if let onlySectionIndex = movableSectionIndices.first {
            // One big section: move its earlier lines, keep the recent ones.
            let section = parentSections[onlySectionIndex]
            let lines = nonBlankLines(section.content)
            let title = childTitle(parentTitle: page.title, sectionHeading: "Earlier \(section.heading)")
            var movedLineCount = 0
            // Count the link line the parent gains, so it still ends under the target.
            var remainingCharacters = BrainPageSections.render(parentSections).count + "Earlier: [[\(title)]]\n".count
            while movedLineCount < lines.count - 1 && (remainingCharacters > targetParentBodyCharacters || movedLineCount == 0) {
                remainingCharacters -= lines[movedLineCount].count + 1
                movedLineCount += 1
            }
            let childTitleUsed = addToChildPage(
                title: title,
                sectionHeading: section.heading,
                content: lines.prefix(movedLineCount).joined(separator: "\n")
            )
            let keptLines = ["Earlier: [[\(childTitleUsed)]]"] + lines.dropFirst(movedLineCount)
            parentSections[onlySectionIndex].content = keptLines.joined(separator: "\n")
            changeDescriptions.append("moved \(movedLineCount) earlier lines of \(section.heading) from \(page.title) to \(childTitleUsed)")
        }

        guard !childSlugOrder.isEmpty else { return nil }
        var splitParentPage = page
        splitParentPage.body = BrainPageSections.render(parentSections)
        splitParentPage.updatedDate = today
        return BrainEditPlan(
            pagesToWrite: [splitParentPage] + childSlugOrder.compactMap { childPagesBySlug[$0] },
            createdSlugs: createdSlugs,
            changeDescriptions: changeDescriptions,
            refusals: []
        )
    }

    /// A child page holding one section: a new page, or `existingChildPage`
    /// with the section's new lines appended under the same heading.
    private static func childPageWithSection(
        title: String,
        sectionHeading: String,
        content: String,
        parent: BrainPage,
        existingChildPage: BrainPage?,
        reservedSlugs: Set<String>,
        today: Date
    ) -> BrainPage {
        if var existingChildPage {
            existingChildPage.body = BrainPageMerger.mergedBody(
                keptBody: existingChildPage.body,
                removedBody: "## \(sectionHeading)\n\(content)"
            )
            existingChildPage.updatedDate = today
            if !existingChildPage.sources.contains(provenanceLabel) { existingChildPage.sources.append(provenanceLabel) }
            return existingChildPage
        }

        let kind = childKind(forParentKind: parent.kind)
        var uniqueTitle = title
        var slug = BrainSlug.make(title: uniqueTitle, kind: kind)
        // Two long titles can truncate to the same file name; number them apart
        // (title too, so each child still resolves by its own name).
        var collisionNumber = 2
        while reservedSlugs.contains(slug) {
            let numberSuffix = " \(collisionNumber)"
            uniqueTitle = String(title.prefix(BrainEditPlanner.maximumTitleCharacters - numberSuffix.count)) + numberSuffix
            let fileNameStem = BrainSlug.fileName(fromTitle: title).prefix(BrainSlug.maximumFileNameLength - numberSuffix.count)
            slug = "\(kind.directoryName)/\(fileNameStem)-\(collisionNumber)"
            collisionNumber += 1
        }
        return BrainPage(
            slug: slug,
            title: uniqueTitle,
            kind: kind,
            summary: BrainEditPlanner.cleanedSummary("\(sectionHeading) from \(parent.title)"),
            aliases: [],
            tags: parent.tags,
            sources: Array((parent.sources.filter { $0 != provenanceLabel } + [provenanceLabel]).suffix(BrainPageMerger.maximumSourcesPerPage)),
            createdDate: today,
            updatedDate: today,
            isLocked: false,
            body: "## \(sectionHeading)\n\(content)"
        )
    }

    private static func nonBlankLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
