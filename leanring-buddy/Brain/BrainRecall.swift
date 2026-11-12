//
//  BrainRecall.swift
//  leanring-buddy
//
//  Graph-aware recall over the brain, after cognee's `recall`: find the pages
//  that answer a question by both words and meaning, then follow their
//  relationships one step so connected context comes along ("Korematsu" brings
//  "Executive Order 9066" because one is challenged by the other).
//
//  1. Keyword ranks come from BM25 (`BrainSearchIndex`) — strongest for names.
//  2. Meaning ranks come from on-device sentence embeddings of each page's
//     facts (`BrainSemanticIndex`); a page scores by its best-matching fact,
//     because averaging a whole page blurs it (measured on a real brain:
//     page-level vectors put "Marshall Plan" first for "spanish class grades").
//  3. The two rank lists are fused with reciprocal rank fusion, so neither
//     score scale has to be calibrated against the other.
//  4. The best few become seeds; their neighbours (typed relations first,
//     plain links after) join at a fraction of the seed's score, each with the
//     reason it came along.
//
//  Pure (Foundation only) and tested by `Tests/BrainCore`.
//

import Foundation

nonisolated struct BrainRecallHit: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case matchedWords
        case similarMeaning(similarity: Double, closestFact: String)
        /// Came along because a seed relates to it.
        case connected(seedTitle: String, relationDescription: String)
    }

    var slug: String
    var title: String
    var kind: BrainPageKind
    var summary: String
    var score: Double
    var reasons: [Reason]
    /// The keyword search's excerpt, when it matched words.
    var snippet: String

    var isDirectMatch: Bool {
        reasons.contains { reason in
            if case .connected = reason { return false }
            return true
        }
    }
}

/// What the semantic side knows about one page for a query.
nonisolated struct BrainSemanticMatch: Equatable, Sendable {
    var similarity: Double
    var closestFact: String
}

nonisolated enum BrainRecallPlanner {
    /// Reciprocal-rank-fusion constant. Small, because a personal brain is
    /// small and the top few ranks should count for a lot.
    static let rankFusionConstant = 20.0
    static let keywordWeight = 1.0
    static let meaningWeight = 0.8
    /// Below this cosine similarity a meaning match is noise (the on-device
    /// sentence model puts unrelated short facts around 0.2–0.35).
    static let minimumMeaningSimilarity = 0.45
    static let candidatesPerSignal = 20
    static let seedCount = 3
    /// A neighbour's score as a share of its seed's.
    static let typedRelationShare = 0.6
    static let plainLinkShare = 0.35

    static func recall(
        pages: [BrainPage],
        keywordResults: [BrainSearchResult],
        meaningMatchesBySlug: [String: BrainSemanticMatch],
        relations: [BrainRelation],
        linkedSlugsBySlug: [String: Set<String>],
        limit: Int = 8,
        excludedKinds: Set<BrainPageKind> = []
    ) -> [BrainRecallHit] {
        let pagesBySlug = Dictionary(pages.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
        func isAllowed(_ slug: String) -> Bool {
            guard let page = pagesBySlug[slug] else { return false }
            return !excludedKinds.contains(page.kind)
        }

        var hitsBySlug: [String: BrainRecallHit] = [:]
        func hit(for slug: String) -> BrainRecallHit? {
            if let existingHit = hitsBySlug[slug] { return existingHit }
            guard let page = pagesBySlug[slug] else { return nil }
            return BrainRecallHit(slug: slug, title: page.title, kind: page.kind, summary: page.summary, score: 0, reasons: [], snippet: "")
        }

        // 1–3: fuse the two rank lists.
        let keywordCandidates = keywordResults.filter { isAllowed($0.slug) }.prefix(candidatesPerSignal)
        for (rankIndex, keywordResult) in keywordCandidates.enumerated() {
            guard var recallHit = hit(for: keywordResult.slug) else { continue }
            recallHit.score += keywordWeight / (rankFusionConstant + Double(rankIndex + 1))
            // A query that names the page outright should lead, as in search.
            if keywordResult.score >= 10 { recallHit.score += keywordWeight / rankFusionConstant }
            recallHit.reasons.append(.matchedWords)
            recallHit.snippet = keywordResult.snippet
            hitsBySlug[keywordResult.slug] = recallHit
        }
        let meaningCandidates = meaningMatchesBySlug
            .filter { $0.value.similarity >= minimumMeaningSimilarity && isAllowed($0.key) }
            .sorted { lhs, rhs in
                lhs.value.similarity != rhs.value.similarity ? lhs.value.similarity > rhs.value.similarity : lhs.key < rhs.key
            }
            .prefix(candidatesPerSignal)
        for (rankIndex, meaningCandidate) in meaningCandidates.enumerated() {
            guard var recallHit = hit(for: meaningCandidate.key) else { continue }
            recallHit.score += meaningWeight / (rankFusionConstant + Double(rankIndex + 1))
            recallHit.reasons.append(.similarMeaning(similarity: meaningCandidate.value.similarity, closestFact: meaningCandidate.value.closestFact))
            hitsBySlug[meaningCandidate.key] = recallHit
        }

        // 4: follow the seeds' relations and links one step.
        let seeds = hitsBySlug.values.sorted(by: ranksBefore).prefix(seedCount)
        let titleBySlug = Dictionary(pages.map { ($0.slug, $0.title) }, uniquingKeysWith: { first, _ in first })
        for seed in seeds {
            var connectionsByNeighbour: [String: (share: Double, description: String)] = [:]
            for relation in relations {
                let neighbourSlug: String
                if relation.sourceSlug == seed.slug {
                    neighbourSlug = relation.targetSlug
                } else if relation.targetSlug == seed.slug {
                    neighbourSlug = relation.sourceSlug
                } else {
                    continue
                }
                guard connectionsByNeighbour[neighbourSlug] == nil else { continue }
                connectionsByNeighbour[neighbourSlug] = (typedRelationShare, BrainRelationGraph.describe(relation, titleBySlug: titleBySlug))
            }
            for linkedSlug in (linkedSlugsBySlug[seed.slug] ?? []).sorted() where connectionsByNeighbour[linkedSlug] == nil {
                let linkedTitle = titleBySlug[linkedSlug] ?? linkedSlug
                connectionsByNeighbour[linkedSlug] = (plainLinkShare, "\(seed.title) ↔ \(linkedTitle)")
            }
            for (neighbourSlug, connection) in connectionsByNeighbour where neighbourSlug != seed.slug && isAllowed(neighbourSlug) {
                guard var neighbourHit = hit(for: neighbourSlug) else { continue }
                let carriedScore = seed.score * connection.share
                // A direct match keeps its own score; the connection is added
                // as a reason and a small nudge.
                neighbourHit.score = neighbourHit.isDirectMatch
                    ? neighbourHit.score + carriedScore * 0.25
                    : max(neighbourHit.score, carriedScore)
                neighbourHit.reasons.append(.connected(seedTitle: seed.title, relationDescription: connection.description))
                hitsBySlug[neighbourSlug] = neighbourHit
            }
        }

        return Array(hitsBySlug.values.sorted(by: ranksBefore).prefix(max(0, limit)))
    }

    static func ranksBefore(_ lhs: BrainRecallHit, _ rhs: BrainRecallHit) -> Bool {
        lhs.score != rhs.score ? lhs.score > rhs.score : lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    /// Both directions of every resolved `[[link]]`, for the plain-link step.
    static func linkedSlugsBySlug(pages: [BrainPage], resolver: BrainLinkResolver) -> [String: Set<String>] {
        var linkedSlugs: [String: Set<String>] = [:]
        for page in pages {
            for target in page.outgoingLinkTargets {
                guard let targetSlug = resolver.slug(forTarget: target), targetSlug != page.slug else { continue }
                linkedSlugs[page.slug, default: []].insert(targetSlug)
                linkedSlugs[targetSlug, default: []].insert(page.slug)
            }
        }
        return linkedSlugs
    }

    // MARK: - Text for the model

    /// The `recall` tool's answer: each page, why it came up, and how it is
    /// connected — so the model can say "via X" instead of guessing.
    static func toolText(for hits: [BrainRecallHit], query: String) -> String {
        guard !hits.isEmpty else { return "nothing in the user's brain relates to \"\(query)\"." }
        var lines = ["what the user's brain holds about \"\(query)\" (call read_brain_page for a page in full):"]
        for recallHit in hits {
            var line = "- \(recallHit.title) (\(recallHit.kind.rawValue))"
            if !recallHit.summary.isEmpty { line += ": \(recallHit.summary)" }
            var whyParts: [String] = []
            for reason in recallHit.reasons {
                switch reason {
                case .matchedWords:
                    if !recallHit.snippet.isEmpty && recallHit.snippet != recallHit.summary { whyParts.append("\"\(recallHit.snippet)\"") }
                case .similarMeaning(_, let closestFact):
                    whyParts.append("close in meaning: \"\(clipped(closestFact, to: 140))\"")
                case .connected(_, let relationDescription):
                    whyParts.append("connected: \(relationDescription)")
                }
            }
            if !whyParts.isEmpty { line += " — " + whyParts.prefix(3).joined(separator: "; ") }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    static func clipped(_ text: String, to maximumCharacters: Int) -> String {
        text.count > maximumCharacters ? String(text.prefix(maximumCharacters)) + "…" : text
    }
}

// MARK: - Facts the semantic index embeds

nonisolated enum BrainSemanticFacts {
    /// Most facts embedded per page; a huge page doesn't need every bullet to
    /// be found by meaning.
    static let maximumFactsPerPage = 120
    static let maximumFactCharacters = 300

    /// A page as the short texts that are embedded: "Title: summary" and
    /// "Title: <fact>" for each bullet, with link brackets removed. Prefixing
    /// the title keeps a bare fact ("A budgeting app") tied to its subject.
    static func factTexts(for page: BrainPage) -> [String] {
        var factTexts: [String] = []
        let titlePrefix = page.title
        let summaryText = plainText(page.summary)
        factTexts.append(summaryText.isEmpty ? titlePrefix : "\(titlePrefix): \(summaryText)")
        var isInsideCodeFence = false
        for rawLine in page.body.components(separatedBy: "\n") {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("```") { isInsideCodeFence.toggle(); continue }
            guard !isInsideCodeFence else { continue }
            var factText: String?
            for bulletPrefix in ["- ", "* ", "+ "] where trimmedLine.hasPrefix(bulletPrefix) {
                factText = String(trimmedLine.dropFirst(bulletPrefix.count))
            }
            guard var bulletText = factText.map(plainText), bulletText.count >= 3 else { continue }
            if bulletText.count > maximumFactCharacters { bulletText = String(bulletText.prefix(maximumFactCharacters)) }
            factTexts.append("\(titlePrefix): \(bulletText)")
            if factTexts.count >= maximumFactsPerPage { break }
        }
        return factTexts
    }

    /// `[[Target|shown]]` → "shown", `[[Target]]` → "Target", `works at::` → "works at".
    static func plainText(_ markdownText: String) -> String {
        var text = markdownText.replacingOccurrences(of: "\\[\\[([^\\]|]+)\\|([^\\]]+)\\]\\]", with: "$2", options: .regularExpression)
        text = text.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
        text = text.replacingOccurrences(of: "::", with: "")
        text = text.replacingOccurrences(of: "**", with: "")
        return text.trimmingCharacters(in: .whitespaces)
    }
}
