//
//  BrainLintChecks.swift
//  leanring-buddy
//
//  The brain's health checks, pure: a list of pages in, a list of issues out.
//  No file system, no model, no store — so every rule (and every false
//  positive it must not produce) is testable. `BrainMaintenance` runs these on
//  `BrainStore.shared.pages` and carries out the fixes.
//
//  Checks: broken `[[links]]`, orphan pages (nothing links in or out), likely
//  duplicates, oversized pages (close to the planner's body cap, so appends
//  are about to be refused) and missing summaries.
//
//  Issue ids are built from the issue kind plus the slugs involved (and the
//  link target for a broken link), never from a counter or a UUID, so the same
//  problem keeps the same id across lint runs and the UI list doesn't flicker.
//

import Foundation

// MARK: - Issue

/// Lives here rather than in BrainLinter.swift so the pure checks (and their
/// standalone test suite) don't need the store or the model stack.
struct BrainLintIssue: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case brokenLink        // [[target]] that resolves to nothing
        case orphanPage        // no links in or out
        case likelyDuplicate   // two pages that are probably the same thing
        case oversizedPage     // near BrainEditPlanner.maximumPageBodyCharacters
        case missingSummary
        case staleFact         // flagged contradiction / outdated fact
    }

    var id: String
    var kind: Kind
    var pageSlugs: [String]
    /// One line for the UI ("[[Atlas v2]] on Sarah Chen links to nothing").
    var message: String
    /// Whether `BrainMaintenance.fix(_:)` can resolve it automatically.
    var isAutoFixable: Bool
    /// For `.brokenLink`: the link target exactly as written on the page, so
    /// the fix can create a page with that title.
    var brokenLinkTarget: String? = nil
}

// MARK: - Checks

enum BrainLintChecks {
    /// A page is "oversized" past this share of the planner's body cap: it
    /// still works, but it is close to the point where appends get refused.
    static let oversizedFractionOfMaximumBody = 0.8

    static var oversizedPageThresholdCharacters: Int {
        Int(Double(BrainEditPlanner.maximumPageBodyCharacters) * oversizedFractionOfMaximumBody)
    }

    /// Two multi-word titles of the same kind count as duplicates at or above
    /// this token overlap ("Japan Trip 2026" / "Trip to Japan 2026").
    static let duplicateTitleJaccardThreshold = 0.75

    /// Display order of issue kinds; within a kind, issues sort by id.
    private static let kindDisplayOrder: [BrainLintIssue.Kind] = [
        .brokenLink, .likelyDuplicate, .missingSummary, .oversizedPage, .orphanPage, .staleFact
    ]

    /// Every issue in the brain, in a stable order.
    static func issues(
        in pages: [BrainPage],
        resolvePage: (String) -> BrainPage?
    ) -> [BrainLintIssue] {
        var allIssues: [BrainLintIssue] = []
        allIssues += brokenLinkIssues(in: pages, resolvePage: resolvePage)
        allIssues += likelyDuplicateIssues(in: pages)
        allIssues += missingSummaryIssues(in: pages)
        allIssues += oversizedPageIssues(in: pages)
        allIssues += orphanPageIssues(in: pages, resolvePage: resolvePage)
        return allIssues.sorted { lhs, rhs in
            let lhsKindRank = kindDisplayOrder.firstIndex(of: lhs.kind) ?? kindDisplayOrder.count
            let rhsKindRank = kindDisplayOrder.firstIndex(of: rhs.kind) ?? kindDisplayOrder.count
            if lhsKindRank != rhsKindRank { return lhsKindRank < rhsKindRank }
            return lhs.id < rhs.id
        }
    }

    /// `kind:slug[:slug…]`, the stable identity of an issue.
    static func issueID(kind: BrainLintIssue.Kind, parts: [String]) -> String {
        ([kind.rawValue] + parts).joined(separator: ":")
    }

    // MARK: Resolver

    /// A pure stand-in for `BrainStore.resolvePage(named:)` over a page list,
    /// with the same precedence: exact slug, then title beats alias beats slug
    /// file name. Lint uses this instead of the store's resolver because the
    /// store's re-checks the disk on every call.
    static func makeResolver(pages: [BrainPage]) -> (String) -> BrainPage? {
        var pagesBySlug: [String: BrainPage] = [:]
        var slugsByComparableName: [String: String] = [:]
        for page in pages { pagesBySlug[page.slug] = page }
        for page in pages {
            if let fileName = page.slug.split(separator: "/").last {
                slugsByComparableName[BrainSlug.comparableName(String(fileName))] = page.slug
            }
        }
        for page in pages {
            for alias in page.aliases { slugsByComparableName[BrainSlug.comparableName(alias)] = page.slug }
        }
        for page in pages { slugsByComparableName[BrainSlug.comparableName(page.title)] = page.slug }
        if pagesBySlug["me"] != nil { slugsByComparableName["me"] = "me" }

        return { nameOrSlug in
            let trimmedName = nameOrSlug.trimmingCharacters(in: .whitespacesAndNewlines)
            if let exactSlugPage = pagesBySlug[trimmedName] { return exactSlugPage }
            guard let slug = slugsByComparableName[BrainSlug.comparableName(trimmedName)] else { return nil }
            return pagesBySlug[slug]
        }
    }

    // MARK: Broken links

    static func brokenLinkIssues(
        in pages: [BrainPage],
        resolvePage: (String) -> BrainPage?
    ) -> [BrainLintIssue] {
        var brokenLinkIssues: [BrainLintIssue] = []
        for page in pages {
            for linkTarget in page.outgoingLinkTargets where resolvePage(linkTarget) == nil {
                let comparableTarget = BrainSlug.comparableName(linkTarget)
                // A stub page can only be created for a title the planner accepts.
                let cleanedTargetTitle = BrainEditPlanner.cleanedTitle(linkTarget)
                let canCreateStubPage = !cleanedTargetTitle.isEmpty
                    && BrainSlug.isSafe(BrainSlug.make(title: cleanedTargetTitle, kind: .note))
                brokenLinkIssues.append(BrainLintIssue(
                    id: issueID(kind: .brokenLink, parts: [page.slug, comparableTarget]),
                    kind: .brokenLink,
                    pageSlugs: [page.slug],
                    message: "[[\(linkTarget)]] on \(page.title) links to nothing",
                    isAutoFixable: canCreateStubPage,
                    brokenLinkTarget: linkTarget
                ))
            }
        }
        return brokenLinkIssues
    }

    // MARK: Orphans

    /// Pages with no resolved link in or out. The user's own page is exempt —
    /// it is the brain's root, reachable without links.
    static func orphanPageIssues(
        in pages: [BrainPage],
        resolvePage: (String) -> BrainPage?
    ) -> [BrainLintIssue] {
        var linkedSlugs = Set<String>()
        for page in pages {
            for linkTarget in page.outgoingLinkTargets {
                guard let linkedPage = resolvePage(linkTarget), linkedPage.slug != page.slug else { continue }
                // Both ends of a real link are connected.
                linkedSlugs.insert(page.slug)
                linkedSlugs.insert(linkedPage.slug)
            }
        }
        return pages
            .filter { $0.kind != .me && !linkedSlugs.contains($0.slug) }
            .map { page in
                BrainLintIssue(
                    id: issueID(kind: .orphanPage, parts: [page.slug]),
                    kind: .orphanPage,
                    pageSlugs: [page.slug],
                    message: "\(page.title) isn't linked to or from any page",
                    isAutoFixable: false
                )
            }
    }

    // MARK: Oversized

    static func oversizedPageIssues(in pages: [BrainPage]) -> [BrainLintIssue] {
        pages
            .filter { $0.body.count > oversizedPageThresholdCharacters }
            .map { page in
                let percentOfMaximum = page.body.count * 100 / BrainEditPlanner.maximumPageBodyCharacters
                return BrainLintIssue(
                    id: issueID(kind: .oversizedPage, parts: [page.slug]),
                    kind: .oversizedPage,
                    pageSlugs: [page.slug],
                    message: "\(page.title) is \(percentOfMaximum)% full and should be split",
                    isAutoFixable: BrainPageSplitter.canSplit(page)
                )
            }
    }

    // MARK: Missing summary

    static func missingSummaryIssues(in pages: [BrainPage]) -> [BrainLintIssue] {
        pages
            .filter { $0.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { page in
                // Nothing to summarise from on an empty page, and the planner
                // refuses every edit to a locked one.
                let hasTextToSummarize = !BrainSummaryText.plainText(fromBody: page.body).isEmpty
                return BrainLintIssue(
                    id: issueID(kind: .missingSummary, parts: [page.slug]),
                    kind: .missingSummary,
                    pageSlugs: [page.slug],
                    message: "\(page.title) has no summary",
                    isAutoFixable: hasTextToSummarize && !page.isLocked
                )
            }
    }

    // MARK: Likely duplicates

    /// Words that don't distinguish one title from another ("the Atlas
    /// project" is Atlas). Used only by the prefix/subset and overlap rules.
    static let genericTitleWords: Set<String> = [
        "the", "a", "an", "of", "and", "to", "for", "in", "on", "at", "my", "our",
        "project", "app", "inc", "llc", "ltd", "corp", "co", "company", "team",
        "group", "page", "notes"
    ]

    /// Kinds where a subset title adds only generic words ("Acme" / "Acme Inc",
    /// "Atlas" / "Atlas Project") is the same thing. For people any extra word
    /// (a surname) still names the same person, see `personNameSubsetDuplicate`.
    static func likelyDuplicateIssues(in pages: [BrainPage]) -> [BrainLintIssue] {
        let candidatePages = pages.filter { $0.kind != .me }
        // `uniquingKeysWith` rather than `uniqueKeysWithValues`: slugs are unique
        // in the store, but a crash is the wrong answer if they ever aren't.
        let titleTokensBySlug = Dictionary(
            candidatePages.map { ($0.slug, titleTokens($0.title)) },
            uniquingKeysWith: { firstTokens, _ in firstTokens }
        )

        // A one-name person ("Sarah") matching several full names ("Sarah Chen",
        // "Sarah Kim") is ambiguous, not a duplicate — count matches first.
        var personSubsetMatchCountBySlug: [String: Int] = [:]
        let personPages = candidatePages.filter { $0.kind == .person }
        for shorterPage in personPages {
            for longerPage in personPages where longerPage.slug != shorterPage.slug {
                if isPersonNameSubset(
                    shorterTokens: titleTokensBySlug[shorterPage.slug] ?? [],
                    longerTokens: titleTokensBySlug[longerPage.slug] ?? []
                ) {
                    personSubsetMatchCountBySlug[shorterPage.slug, default: 0] += 1
                }
            }
        }

        var duplicateIssues: [BrainLintIssue] = []
        for firstIndex in candidatePages.indices {
            for secondIndex in candidatePages.indices where secondIndex > firstIndex {
                let firstPage = candidatePages[firstIndex]
                let secondPage = candidatePages[secondIndex]
                guard let reason = duplicateReason(
                    firstPage,
                    secondPage,
                    firstTitleTokens: titleTokensBySlug[firstPage.slug] ?? [],
                    secondTitleTokens: titleTokensBySlug[secondPage.slug] ?? [],
                    personSubsetMatchCountBySlug: personSubsetMatchCountBySlug
                ) else { continue }
                let sortedSlugs = [firstPage.slug, secondPage.slug].sorted()
                duplicateIssues.append(BrainLintIssue(
                    id: issueID(kind: .likelyDuplicate, parts: sortedSlugs),
                    kind: .likelyDuplicate,
                    pageSlugs: sortedSlugs,
                    message: "\(firstPage.title) and \(secondPage.title) look like the same \(sharedKindNoun(firstPage, secondPage)) (\(reason))",
                    isAutoFixable: !firstPage.isLocked && !secondPage.isLocked
                ))
            }
        }
        return duplicateIssues
    }

    /// Why two pages look like one thing, or nil. Public for tests.
    static func duplicateReason(_ firstPage: BrainPage, _ secondPage: BrainPage) -> String? {
        let firstTokens = titleTokens(firstPage.title)
        let secondTokens = titleTokens(secondPage.title)
        return duplicateReason(
            firstPage,
            secondPage,
            firstTitleTokens: firstTokens,
            secondTitleTokens: secondTokens,
            personSubsetMatchCountBySlug: [:]
        )
    }

    private static func duplicateReason(
        _ firstPage: BrainPage,
        _ secondPage: BrainPage,
        firstTitleTokens: [String],
        secondTitleTokens: [String],
        personSubsetMatchCountBySlug: [String: Int]
    ) -> String? {
        guard firstPage.kind != .me, secondPage.kind != .me else { return nil }

        // 1. Same name, any kind (a hand-made "Atlas" note next to the "Atlas" project).
        let firstComparableTitle = BrainSlug.comparableName(firstPage.title)
        let secondComparableTitle = BrainSlug.comparableName(secondPage.title)
        if firstComparableTitle == secondComparableTitle { return "same name" }

        // 2. One page's alias is the other's title.
        let firstComparableAliases = Set(firstPage.aliases.map(BrainSlug.comparableName))
        let secondComparableAliases = Set(secondPage.aliases.map(BrainSlug.comparableName))
        if firstComparableAliases.contains(secondComparableTitle) || secondComparableAliases.contains(firstComparableTitle) {
            return "one is an alias of the other"
        }

        // The remaining rules compare wording, which only means something
        // between pages of the same kind.
        guard firstPage.kind == secondPage.kind else { return nil }
        guard !firstTitleTokens.isEmpty, !secondTitleTokens.isEmpty else { return nil }

        // 3. One title is a word-subset of the other.
        let (shorterPage, shorterTokens, longerTokens) = firstTitleTokens.count <= secondTitleTokens.count
            ? (firstPage, firstTitleTokens, secondTitleTokens)
            : (secondPage, secondTitleTokens, firstTitleTokens)
        if firstPage.kind == .person {
            // Equal word counts ("Sarah C" / "Sarah Chen") can match either way round.
            let personSubsetDirections = firstTitleTokens.count == secondTitleTokens.count
                ? [(firstPage, firstTitleTokens, secondTitleTokens), (secondPage, secondTitleTokens, firstTitleTokens)]
                : [(shorterPage, shorterTokens, longerTokens)]
            for (subsetPage, subsetTokens, supersetTokens) in personSubsetDirections
            where isPersonNameSubset(shorterTokens: subsetTokens, longerTokens: supersetTokens) {
                let matchCount = personSubsetMatchCountBySlug[subsetPage.slug] ?? 1
                return matchCount <= 1 ? "one name is part of the other" : nil
            }
        } else if isGenericWordSubset(shorterTokens: shorterTokens, longerTokens: longerTokens) {
            return "one name is part of the other"
        }

        // 4. Mostly the same words ("Japan Trip 2026" / "Trip to Japan 2026").
        let firstMeaningfulTokens = Set(firstTitleTokens.filter { !genericTitleWords.contains($0) })
        let secondMeaningfulTokens = Set(secondTitleTokens.filter { !genericTitleWords.contains($0) })
        guard firstMeaningfulTokens.count >= 2, secondMeaningfulTokens.count >= 2 else { return nil }
        // Titles that differ by a number are different editions ("Q3 Review"
        // / "Q4 Review", "Atlas v1" / "Atlas v2"), however similar otherwise.
        let differingTokens = firstMeaningfulTokens.symmetricDifference(secondMeaningfulTokens)
        guard !differingTokens.contains(where: containsDigit) else { return nil }
        let sharedCount = Double(firstMeaningfulTokens.intersection(secondMeaningfulTokens).count)
        let unionCount = Double(firstMeaningfulTokens.union(secondMeaningfulTokens).count)
        guard unionCount > 0, sharedCount / unionCount >= duplicateTitleJaccardThreshold else { return nil }
        return "nearly the same name"
    }

    /// "Sarah" ⊂ "Sarah Chen", "Sarah C" ⊂ "Sarah Chen" (an initial matches a
    /// word it starts). Every word of the shorter name must match a distinct
    /// word of the longer one, and the shorter may not have more words.
    static func isPersonNameSubset(shorterTokens: [String], longerTokens: [String]) -> Bool {
        guard !shorterTokens.isEmpty, shorterTokens.count <= longerTokens.count else { return false }
        var unmatchedLongerTokens = longerTokens
        for shorterToken in shorterTokens {
            let matchIndex = unmatchedLongerTokens.firstIndex { longerToken in
                longerToken == shorterToken || (shorterToken.count == 1 && longerToken.hasPrefix(shorterToken))
            }
            guard let matchIndex else { return false }
            unmatchedLongerTokens.remove(at: matchIndex)
        }
        return true
    }

    /// "Acme" ⊂ "Acme Inc": the longer title adds only generic words. "Atlas"
    /// vs "Atlas v2" or "Swift" vs "Swift Concurrency" add a real word and are
    /// different things.
    static func isGenericWordSubset(shorterTokens: [String], longerTokens: [String]) -> Bool {
        let shorterMeaningfulTokens = shorterTokens.filter { !genericTitleWords.contains($0) }
        let longerMeaningfulTokens = longerTokens.filter { !genericTitleWords.contains($0) }
        guard !shorterMeaningfulTokens.isEmpty, shorterTokens.count < longerTokens.count else { return false }
        return shorterMeaningfulTokens.sorted() == longerMeaningfulTokens.sorted()
    }

    /// Lowercased ASCII-folded words of a title.
    static func titleTokens(_ title: String) -> [String] {
        BrainSlug.comparableName(title).split(separator: "-").map(String.init)
    }

    private static func containsDigit(_ token: String) -> Bool {
        token.contains { $0.isNumber }
    }

    private static func sharedKindNoun(_ firstPage: BrainPage, _ secondPage: BrainPage) -> String {
        firstPage.kind == secondPage.kind ? firstPage.kind.displayName.lowercased() : "thing"
    }

    // MARK: Stub kind inference

    /// Words on a linking line that say what the link target is. Checked as
    /// whole words so "in" inside "linked" doesn't count.
    static let kindContextWordsByKind: [(kind: BrainPageKind, words: Set<String>)] = [
        (.person, ["met", "friend", "colleague", "coworker", "manager", "boss", "cofounder", "founder",
                   "wife", "husband", "partner", "mom", "dad", "mother", "father", "brother", "sister",
                   "son", "daughter", "mentor", "teacher", "recruiter", "introduced", "emailed", "texted",
                   "called"]),
        (.organization, ["company", "startup", "works", "employer", "org", "organization", "organisation",
                         "university", "school", "college", "agency", "firm", "hired", "joined"]),
        (.project, ["project", "repo", "repository", "app", "building", "shipped", "codebase", "launch",
                    "roadmap", "feature", "prototype", "release"]),
        (.event, ["meeting", "conference", "event", "wedding", "party", "trip", "offsite", "workshop",
                  "summit", "appointment", "interview"]),
        (.place, ["city", "lives", "moved", "visited", "visit", "country", "neighborhood", "restaurant",
                  "cafe", "office"]),
        (.source, ["article", "book", "paper", "read", "reading", "podcast", "video", "blog", "post"]),
        (.topic, ["topic", "learning", "concept", "studying", "interested"])
    ]

    /// The kind a stub page for a broken link should get: the linking page's
    /// section heading first (a link under "## People" is a person — the
    /// structure is more reliable than wording), then words on the linking
    /// line, else `.note`.
    static func inferredKindForLinkTarget(_ linkTarget: String, onPage page: BrainPage) -> BrainPageKind {
        let comparableTarget = BrainSlug.comparableName(linkTarget)
        var currentHeading = ""
        var linkingLines: [(heading: String, line: String)] = []
        for line in page.body.components(separatedBy: "\n") {
            if let heading = BrainPageSections.headingText(onLine: line) {
                currentHeading = heading
                continue
            }
            let targetsOnLine = BrainLinkParser.linkTargets(in: line).map(BrainSlug.comparableName)
            if targetsOnLine.contains(comparableTarget) {
                linkingLines.append((currentHeading, line))
            }
        }

        for linkingLine in linkingLines {
            if let headingKind = kindNamedByHeading(linkingLine.heading) { return headingKind }
        }
        for linkingLine in linkingLines {
            if let wordKind = kindNamedByNearestContextWord(linkTarget: comparableTarget, line: linkingLine.line) {
                return wordKind
            }
        }
        return .note
    }

    /// The kind named by the context word closest to the link on its line, so
    /// "met Sarah at [[Blue Bottle]] cafe" reads "cafe", not "met". A tie goes
    /// to the earlier kind in `kindContextWordsByKind`.
    static func kindNamedByNearestContextWord(linkTarget comparableTarget: String, line: String) -> BrainPageKind? {
        let linkPlaceholderWord = "wisplinkplaceholder"
        let lineWithPlaceholder = BrainLinkRewriter.replaceLinks(in: line) { innerText in
            BrainSlug.comparableName(BrainLinkParser.linkTarget(fromInnerText: innerText)) == comparableTarget
                ? linkPlaceholderWord
                : BrainLinkParser.displayText(fromInnerText: innerText)
        }
        let lineWords = lineWithPlaceholder.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard let linkWordIndex = lineWords.firstIndex(of: linkPlaceholderWord) else { return nil }

        var nearestKind: BrainPageKind?
        var nearestDistance = Int.max
        for entry in kindContextWordsByKind {
            for (wordIndex, word) in lineWords.enumerated() where entry.words.contains(word) {
                let distanceToLink = abs(wordIndex - linkWordIndex)
                if distanceToLink < nearestDistance {
                    nearestDistance = distanceToLink
                    nearestKind = entry.kind
                }
            }
        }
        return nearestKind
    }

    /// "People" → person, "Colleagues" → person, "Projects" → project.
    static func kindNamedByHeading(_ heading: String) -> BrainPageKind? {
        let trimmedHeading = heading.trimmingCharacters(in: .whitespaces)
        guard !trimmedHeading.isEmpty else { return nil }
        var candidateNames = [trimmedHeading]
        if trimmedHeading.lowercased().hasSuffix("s") { candidateNames.append(String(trimmedHeading.dropLast())) }
        for candidateName in candidateNames {
            if let kind = BrainPageKind.lenient(candidateName), kind != .me, kind != .note { return kind }
        }
        return nil
    }
}

// MARK: - Summary text

/// Deterministic summary text: the fallback when the model can't write one,
/// and the cleanup of what it does write.
enum BrainSummaryText {
    /// Most characters of page text sent to the model for a summary.
    static let maximumModelInputCharacters = 1200

    /// The body as plain prose: no headings, no bullet markers, links shown as
    /// their display text.
    static func plainText(fromBody body: String) -> String {
        var plainLines: [String] = []
        for rawLine in body.components(separatedBy: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line == "---" || line.isEmpty { continue }
            for bulletPrefix in ["- [ ] ", "- [x] ", "- ", "* ", "+ ", "> "] where line.hasPrefix(bulletPrefix) {
                line = String(line.dropFirst(bulletPrefix.count))
                break
            }
            line = BrainLinkRewriter.replaceLinks(in: line) { innerText in
                BrainLinkParser.displayText(fromInnerText: innerText)
            }
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if !trimmedLine.isEmpty { plainLines.append(trimmedLine) }
        }
        return plainLines.joined(separator: "\n")
    }

    /// The page text a summary is written from, capped for a small model.
    static func modelInputText(for page: BrainPage) -> String {
        String(plainText(fromBody: page.body).prefix(maximumModelInputCharacters))
    }

    /// The first sentence of the page's text (or its first line), capped.
    static func firstSentenceSummary(for page: BrainPage) -> String {
        let text = plainText(fromBody: page.body)
        guard let firstLine = text.components(separatedBy: "\n").first(where: { !$0.isEmpty }) else { return "" }
        var sentence = firstLine
        // End at the first ". " / "! " / "? " so "Leads design. Likes tea." → "Leads design."
        for terminator in [". ", "! ", "? "] {
            if let terminatorRange = sentence.range(of: terminator) {
                sentence = String(sentence[..<terminatorRange.lowerBound]) + String(terminator.first!)
            }
        }
        return BrainEditPlanner.cleanedSummary(capitalizedFirstLetter(sentence))
    }

    /// A model reply reduced to one clean summary line, or "" if nothing usable.
    static func cleanedModelSummary(_ reply: String) -> String {
        let firstUsableLine = reply
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("```") } ?? ""
        var summary = firstUsableLine
        for preamble in ["summary:", "one-line summary:", "here is a summary:", "here's a summary:"]
        where summary.lowercased().hasPrefix(preamble) {
            summary = String(summary.dropFirst(preamble.count)).trimmingCharacters(in: .whitespaces)
        }
        summary = summary.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*“”- "))
        summary = summary.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
        // A summary shorter than a couple of words is the model failing, not summarising.
        guard summary.split(separator: " ").count >= 2 else { return "" }
        return BrainEditPlanner.cleanedSummary(summary)
    }

    private static func capitalizedFirstLetter(_ text: String) -> String {
        guard let firstCharacter = text.first else { return text }
        return firstCharacter.uppercased() + text.dropFirst()
    }
}

// MARK: - Link rewriting

enum BrainLinkRewriter {
    /// Replaces each `[[inner]]` in the text with `[[replacement]]` when
    /// `replacementInnerText` returns one (nil leaves the link untouched).
    /// Same scanning rules as `BrainLinkParser`: a link never spans lines.
    static func rewriteLinks(
        in markdown: String,
        replacementInnerText: (String) -> String?
    ) -> String {
        replaceLinks(in: markdown) { innerText in
            replacementInnerText(innerText).map { "[[\($0)]]" }
        }
    }

    /// Replaces each whole `[[inner]]` (brackets included) with the text
    /// `replacementText` returns, or leaves it when that returns nil.
    static func replaceLinks(
        in markdown: String,
        replacementText: (String) -> String?
    ) -> String {
        var rewrittenText = ""
        var searchStart = markdown.startIndex
        while let openRange = markdown.range(of: "[[", range: searchStart..<markdown.endIndex),
              let closeRange = markdown.range(of: "]]", range: openRange.upperBound..<markdown.endIndex) {
            let innerText = String(markdown[openRange.upperBound..<closeRange.lowerBound])
            if innerText.contains("\n") || innerText.contains("[[") {
                // Not a link: keep the "[[" and keep scanning after it.
                rewrittenText += markdown[searchStart..<openRange.upperBound]
                searchStart = openRange.upperBound
                continue
            }
            rewrittenText += markdown[searchStart..<openRange.lowerBound]
            if let replacement = replacementText(innerText) {
                rewrittenText += replacement
            } else {
                rewrittenText += markdown[openRange.lowerBound..<closeRange.upperBound]
            }
            searchStart = closeRange.upperBound
        }
        rewrittenText += markdown[searchStart...]
        return rewrittenText
    }
}
