//
//  BrainIngestProposalMerger.swift
//  leanring-buddy
//
//  The pure half of `BrainKnowledgeExtractor`: combining the edits proposed
//  for each chunk of a source into one batch, keeping that batch inside the
//  planner's limits, and building the source's own `sources/` page. No model,
//  no file system — testable on its own.
//
//  Why merging matters: a long source is read chunk by chunk, and each chunk
//  sees only itself, so the model proposes "Atlas · Facts" three times with
//  overlapping bullets. Applying those as separate edits would waste the
//  batch's 24-edit budget and repeat facts; merged, they are one edit.
//

import Foundation

enum BrainIngestProposalMerger {
    /// Most key points on a source page.
    static let maximumKeyPoints = 7
    /// Most `[[links]]` in a source page's "Related" section.
    static let maximumRelatedLinks = 12
    static let keyPointsSectionHeading = "Key points"
    static let relatedSectionHeading = "Related"

    // MARK: Merging

    /// Combines proposals that target the same page and section: appended
    /// lines are joined and de-duplicated, aliases and tags are unioned, the
    /// first summary wins, and every proposal for one page carries the same
    /// kind (the most specific one proposed). Order of first appearance is kept.
    static func merge(_ proposals: [BrainEditProposal]) -> [BrainEditProposal] {
        var mergedProposals: [BrainEditProposal] = []
        var indexByMergeKey: [String: Int] = [:]
        var kindByPageKey: [String: BrainPageKind] = [:]
        var summaryByPageKey: [String: String] = [:]

        for proposal in proposals {
            let title = BrainEditPlanner.cleanedTitle(proposal.pageTitle)
            guard !title.isEmpty else { continue }
            let pageKey = pageKey(forTitle: title, kind: proposal.pageKind)

            if let proposedKind = proposal.pageKind {
                let currentKind = kindByPageKey[pageKey]
                if currentKind == nil || (currentKind == .note && proposedKind != .note) {
                    kindByPageKey[pageKey] = proposedKind
                }
            }
            if summaryByPageKey[pageKey] == nil,
               let proposedSummary = proposal.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !proposedSummary.isEmpty {
                summaryByPageKey[pageKey] = proposedSummary
            }

            let mergeKey: String
            switch proposal.operation {
            case .append, .replace:
                let sectionKey = BrainSlug.comparableName(BrainEditPlanner.cleanedSection(proposal.section))
                mergeKey = "\(pageKey)|\(proposal.operation.rawValue)|\(sectionKey)"
            case .summarize, .alias, .tag:
                mergeKey = "\(pageKey)|\(proposal.operation.rawValue)"
            }

            guard let existingIndex = indexByMergeKey[mergeKey] else {
                var firstProposal = proposal
                firstProposal.pageTitle = title
                if firstProposal.operation == .append || firstProposal.operation == .replace {
                    firstProposal.content = uniqueLines(of: [proposal.content]).joined(separator: "\n")
                }
                indexByMergeKey[mergeKey] = mergedProposals.count
                mergedProposals.append(firstProposal)
                continue
            }

            var mergedProposal = mergedProposals[existingIndex]
            switch proposal.operation {
            case .append:
                mergedProposal.content = uniqueLines(of: [mergedProposal.content, proposal.content]).joined(separator: "\n")
            case .replace:
                // Two chunks each rewriting the same section: the later one
                // saw more of the source, so it wins.
                mergedProposal.content = proposal.content
            case .summarize:
                break
            case .alias, .tag:
                mergedProposal.content = uniqueCommaSeparatedItems(of: [mergedProposal.content, proposal.content]).joined(separator: ", ")
            }
            mergedProposals[existingIndex] = mergedProposal
        }

        // Unify kinds and put the page's summary on its first proposal only.
        var pageKeysGivenSummary = Set<String>()
        return mergedProposals.map { mergedProposal in
            var finalProposal = mergedProposal
            let pageKey = pageKey(forTitle: finalProposal.pageTitle, kind: finalProposal.pageKind)
            if let unifiedKind = kindByPageKey[pageKey] { finalProposal.pageKind = unifiedKind }
            if finalProposal.operation == .summarize {
                finalProposal.summary = nil
            } else if pageKeysGivenSummary.insert(pageKey).inserted {
                finalProposal.summary = summaryByPageKey[pageKey]
            } else {
                finalProposal.summary = nil
            }
            if finalProposal.operation == .append || finalProposal.operation == .replace {
                finalProposal.content = contentTrimmedToWholeLines(finalProposal.content)
            }
            return finalProposal
        }
    }

    /// Same-page identity for merging: the cleaned, comparable title, with
    /// every "me" page folded together.
    static func pageKey(forTitle title: String, kind: BrainPageKind?) -> String {
        if kind == .me { return "me" }
        return BrainSlug.comparableName(BrainEditPlanner.cleanedTitle(title))
    }

    /// Lines across the contents, in order, without repeats (ignoring case,
    /// bullet markers and punctuation) and without blank lines.
    static func uniqueLines(of contents: [String]) -> [String] {
        var seenComparableLines = Set<String>()
        var lines: [String] = []
        for content in contents {
            for line in content.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
                let comparable = comparableLine(line)
                guard !comparable.isEmpty, seenComparableLines.insert(comparable).inserted else { continue }
                var keptLine = line
                while keptLine.last?.isWhitespace == true { keptLine.removeLast() }
                lines.append(keptLine)
            }
        }
        return lines
    }

    static func comparableLine(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        for bulletPrefix in ["- ", "* ", "+ ", "• "] where text.hasPrefix(bulletPrefix) {
            text = String(text.dropFirst(bulletPrefix.count))
        }
        return text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func uniqueCommaSeparatedItems(of contents: [String]) -> [String] {
        var seenComparableItems = Set<String>()
        var items: [String] = []
        for content in contents {
            for rawItem in content.split(whereSeparator: { $0 == "," || $0 == "\n" }) {
                let item = rawItem.trimmingCharacters(in: CharacterSet(charactersIn: " -*\"'"))
                let comparableItem = BrainSlug.comparableName(item)
                guard !item.isEmpty, seenComparableItems.insert(comparableItem).inserted else { continue }
                items.append(item)
            }
        }
        return items
    }

    /// The planner truncates content at its limit mid-line; trimming whole
    /// lines here keeps every kept fact intact.
    static func contentTrimmedToWholeLines(_ content: String, maximumCharacters: Int = BrainEditPlanner.maximumContentCharacters) -> String {
        guard content.count > maximumCharacters else { return content }
        var keptLines: [String] = []
        var characterCount = 0
        for line in content.components(separatedBy: "\n") {
            let addedCharacterCount = line.count + (keptLines.isEmpty ? 0 : 1)
            guard characterCount + addedCharacterCount <= maximumCharacters else { break }
            keptLines.append(line)
            characterCount += addedCharacterCount
        }
        return keptLines.isEmpty ? String(content.prefix(maximumCharacters)) : keptLines.joined(separator: "\n")
    }

    // MARK: Batch limits

    struct FittedBatch: Equatable {
        var proposals: [BrainEditProposal]
        /// Pages whose edits didn't fit (lowest-ranked first to go).
        var droppedPageTitles: [String]
    }

    /// Keeps the batch inside the planner's limits by dropping whole pages,
    /// least important first, instead of letting the planner cut off whatever
    /// happens to come last. The priority page (the source's own page) always
    /// stays; then pages are ranked by how much the source said about them.
    static func fitToBatchLimits(
        _ proposals: [BrainEditProposal],
        priorityPageTitle: String?,
        isExistingPage: (String) -> Bool,
        maximumProposals: Int = BrainEditPlanner.maximumProposalsPerBatch,
        maximumNewPages: Int = BrainEditPlanner.maximumPagesCreatedPerBatch
    ) -> FittedBatch {
        struct PageGroup {
            var pageKey: String
            var title: String
            var proposals: [BrainEditProposal]
            var firstAppearance: Int
            var isPriority: Bool
            var isExisting: Bool
            var weight: Int {
                proposals.reduce(0) { total, proposal in
                    total + 1 + proposal.content.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
                }
            }
        }

        let priorityPageKey = priorityPageTitle.map { pageKey(forTitle: $0, kind: nil) }
        var groups: [PageGroup] = []
        var groupIndexByPageKey: [String: Int] = [:]
        for proposal in proposals {
            let key = pageKey(forTitle: proposal.pageTitle, kind: proposal.pageKind)
            if let groupIndex = groupIndexByPageKey[key] {
                groups[groupIndex].proposals.append(proposal)
            } else {
                groupIndexByPageKey[key] = groups.count
                groups.append(PageGroup(
                    pageKey: key,
                    title: proposal.pageTitle,
                    proposals: [proposal],
                    firstAppearance: groups.count,
                    isPriority: key == priorityPageKey,
                    isExisting: key == "me" ? isExistingPage("me") : isExistingPage(proposal.pageTitle)
                ))
            }
        }

        let rankedGroups = groups.sorted { lhs, rhs in
            if lhs.isPriority != rhs.isPriority { return lhs.isPriority }
            if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
            return lhs.firstAppearance < rhs.firstAppearance
        }

        var keptProposals: [BrainEditProposal] = []
        var newPageCount = 0
        var droppedPageTitles: [String] = []
        for group in rankedGroups {
            let fitsProposalBudget = keptProposals.count + group.proposals.count <= maximumProposals
            let fitsNewPageBudget = group.isExisting || newPageCount < maximumNewPages
            if group.isPriority || (fitsProposalBudget && fitsNewPageBudget) {
                // A priority page too big for the budget keeps what fits.
                let proposalsToKeep = group.isPriority
                    ? Array(group.proposals.prefix(max(0, maximumProposals - keptProposals.count)))
                    : group.proposals
                keptProposals.append(contentsOf: proposalsToKeep)
                if !group.isExisting { newPageCount += 1 }
            } else {
                droppedPageTitles.append(group.title)
            }
        }
        return FittedBatch(proposals: keptProposals, droppedPageTitles: droppedPageTitles)
    }

    // MARK: The source's own page

    /// The title of the `sources/` page for a material: its title without a
    /// known file extension ("atlas-spec.pdf" → "atlas-spec").
    static func sourcePageTitle(forMaterialTitle materialTitle: String) -> String {
        let cleanTitle = BrainEditPlanner.cleanedTitle(materialTitle)
        let fileExtension = (cleanTitle as NSString).pathExtension.lowercased()
        guard !fileExtension.isEmpty, BrainIngestFileRules.isSupported(fileExtension: fileExtension) else {
            return cleanTitle.isEmpty ? "Untitled source" : cleanTitle
        }
        let titleWithoutExtension = (cleanTitle as NSString).deletingPathExtension.trimmingCharacters(in: .whitespaces)
        return titleWithoutExtension.isEmpty ? cleanTitle : titleWithoutExtension
    }

    /// Points every `source`-kind proposal, and any proposal naming the
    /// material itself, at the material's one source page. The schema says a
    /// source gets exactly one `sources/` page; a chunk that invents its own
    /// ("Atlas spec, part 2") would otherwise leave near-duplicates.
    static func retargetingSourceProposals(
        _ proposals: [BrainEditProposal],
        materialTitle: String,
        sourcePageTitle: String
    ) -> [BrainEditProposal] {
        let materialNames = Set([materialTitle, sourcePageTitle].map { BrainSlug.comparableName(BrainEditPlanner.cleanedTitle($0)) })
        return proposals.map { proposal in
            let proposalPageName = BrainSlug.comparableName(BrainEditPlanner.cleanedTitle(proposal.pageTitle))
            guard proposal.pageKind == .source || materialNames.contains(proposalPageName) else { return proposal }
            var retargetedProposal = proposal
            retargetedProposal.pageTitle = sourcePageTitle
            retargetedProposal.pageKind = .source
            return retargetedProposal
        }
    }

    /// The source page's own edits: summary, key points, and links to the
    /// other pages this source added to (so the wiki graph connects).
    static func sourcePageProposals(
        sourcePageTitle: String,
        summary: String,
        keyPoints: [String],
        relatedPageTitles: [String]
    ) -> [BrainEditProposal] {
        var proposals: [BrainEditProposal] = []
        let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyPointLines = keyPoints
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " -*•\t\n")) }
            .filter { !$0.isEmpty }
            .prefix(maximumKeyPoints)
            .map { "- \($0)" }
        if !keyPointLines.isEmpty || !cleanSummary.isEmpty {
            proposals.append(BrainEditProposal(
                operation: .append,
                pageTitle: sourcePageTitle,
                pageKind: .source,
                section: keyPointsSectionHeading,
                content: keyPointLines.isEmpty ? "- \(cleanSummary)" : keyPointLines.joined(separator: "\n"),
                summary: cleanSummary.isEmpty ? nil : cleanSummary
            ))
        }
        if !cleanSummary.isEmpty {
            proposals.append(BrainEditProposal(operation: .summarize, pageTitle: sourcePageTitle, pageKind: .source, content: cleanSummary))
        }
        let sourcePageName = BrainSlug.comparableName(sourcePageTitle)
        var seenRelatedNames = Set<String>([sourcePageName, "me"])
        let relatedLinkLines = relatedPageTitles.compactMap { relatedTitle -> String? in
            let cleanRelatedTitle = BrainEditPlanner.cleanedTitle(relatedTitle)
            guard !cleanRelatedTitle.isEmpty,
                  seenRelatedNames.insert(BrainSlug.comparableName(cleanRelatedTitle)).inserted else { return nil }
            return "- [[\(cleanRelatedTitle)]]"
        }.prefix(maximumRelatedLinks)
        if !relatedLinkLines.isEmpty {
            proposals.append(BrainEditProposal(
                operation: .append,
                pageTitle: sourcePageTitle,
                pageKind: .source,
                section: relatedSectionHeading,
                content: relatedLinkLines.joined(separator: "\n")
            ))
        }
        return proposals
    }

    /// Reads `{"summary": "...", "key_points": ["...", ...]}` (leniently —
    /// other key spellings, a bare array of points, prose around it).
    static func parseSourceDigest(fromModelReply reply: String) -> (summary: String, keyPoints: [String])? {
        guard let jsonValue = BrainEditProposalParser.firstJSONValue(in: reply) else { return nil }
        func strings(from value: Any?) -> [String] {
            if let stringValues = value as? [String] { return stringValues }
            if let anyValues = value as? [Any] {
                return anyValues.compactMap { item in
                    if let text = item as? String { return text }
                    if let fields = item as? [String: Any] {
                        return (fields["point"] ?? fields["text"] ?? fields["content"]) as? String
                    }
                    return nil
                }
            }
            if let text = value as? String {
                return text.components(separatedBy: "\n")
            }
            return []
        }
        var summary = ""
        var keyPoints: [String] = []
        if let fields = jsonValue as? [String: Any] {
            summary = (fields["summary"] ?? fields["description"] ?? fields["what"]) as? String ?? ""
            for key in ["key_points", "keyPoints", "key points", "points", "keypoints", "facts", "bullets"] {
                let foundPoints = strings(from: fields[key])
                if !foundPoints.isEmpty {
                    keyPoints = foundPoints
                    break
                }
            }
        } else {
            keyPoints = strings(from: jsonValue)
        }
        keyPoints = keyPoints
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " -*•\t\n")) }
            .filter { !$0.isEmpty }
        summary = BrainEditPlanner.cleanedSummary(summary)
        guard !summary.isEmpty || !keyPoints.isEmpty else { return nil }
        return (summary, Array(keyPoints.prefix(maximumKeyPoints)))
    }

    /// A summary and key points taken straight from the text, for when the
    /// model can't produce them: the first real sentence, then the section
    /// headings (or the opening sentences of the first paragraphs).
    static func deterministicSourceDigest(fromText text: String) -> (summary: String, keyPoints: [String]) {
        let blocks = BrainTextChunker.textBlocks(in: text, targetChunkCharacters: 4000)
        let headings = blocks.compactMap(BrainTextChunker.headingText(ofBlock:))
        let paragraphs = blocks.filter { BrainTextChunker.headingText(ofBlock: $0) == nil && $0.count >= 30 }

        func firstSentence(of paragraph: String, maximumCharacters: Int) -> String {
            let flattenedParagraph = paragraph.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            let sentence = BrainTextChunker.sentences(in: flattenedParagraph).first?
                .trimmingCharacters(in: .whitespaces) ?? flattenedParagraph
            return sentence.count > maximumCharacters ? String(sentence.prefix(maximumCharacters - 1)) + "…" : sentence
        }

        let summary = paragraphs.first.map { firstSentence(of: $0, maximumCharacters: BrainEditPlanner.maximumSummaryCharacters) } ?? ""
        var keyPoints: [String]
        if headings.count >= 2 {
            keyPoints = headings.prefix(maximumKeyPoints).map { "Covers: \($0)" }
        } else {
            keyPoints = paragraphs.dropFirst().prefix(maximumKeyPoints - 2).map { firstSentence(of: $0, maximumCharacters: 160) }
        }
        if keyPoints.isEmpty && !summary.isEmpty { keyPoints = [summary] }
        return (summary, keyPoints)
    }
}
