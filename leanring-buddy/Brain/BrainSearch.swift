//
//  BrainSearch.swift
//  leanring-buddy
//
//  Lexical search over brain pages: BM25 with field weights (title and aliases
//  count most, then summary and tags, then body). Pure and model-free.
//
//  Why not embeddings: a second resident model doesn't fit next to the local
//  vision model on 18GB (see CLAUDE.md, "model residency"), and a personal
//  wiki is small and full of proper nouns — exactly where lexical matching is
//  strongest. The index is rebuilt in memory whenever pages change; for a few
//  thousand pages that is milliseconds.
//

import Foundation

struct BrainSearchResult: Equatable, Sendable {
    var slug: String
    var title: String
    var kind: BrainPageKind
    var summary: String
    var score: Double
    /// A short excerpt of the body around the best-matching words.
    var snippet: String
}

enum BrainSearchTokenizer {
    /// Words that carry no meaning for matching. Kept short on purpose: a
    /// personal wiki's proper nouns are often ordinary words.
    static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "of", "to", "in", "on", "for", "with", "at", "by", "from",
        "is", "are", "was", "were", "be", "been", "it", "its", "this", "that", "these", "those",
        "i", "me", "my", "you", "your", "we", "our", "he", "she", "they", "them", "his", "her",
        "what", "who", "whom", "which", "when", "where", "why", "how", "do", "does", "did",
        "about", "tell", "know", "remember", "can", "could", "would", "should", "will", "just",
        "any", "some", "there", "here", "have", "has", "had", "not", "so", "if", "as", "up",
        "please", "wisp", "hey", "okay", "ok", "brain"
    ]

    /// Lowercased, diacritic-folded words with a light plural/possessive strip.
    static func tokens(in text: String) -> [String] {
        let foldedText = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        return foldedText
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !stopWords.contains($0) }
            .map(stem)
    }

    /// Deliberately crude: strips a trailing "s" / "es" / "'s" so "projects"
    /// matches "project". Anything cleverer mangles names.
    static func stem(_ word: String) -> String {
        guard word.count > 4 else { return word }
        if word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("sses") { return String(word.dropLast(2)) }
        if word.hasSuffix("s") && !word.hasSuffix("ss") && !word.hasSuffix("us") { return String(word.dropLast()) }
        return word
    }
}

/// An in-memory BM25 index over a set of pages.
struct BrainSearchIndex: Sendable {
    private struct IndexedPage: Sendable {
        let page: BrainPage
        /// Term → weighted frequency across fields.
        let weightedTermFrequencies: [String: Double]
        let weightedLength: Double
    }

    static let titleWeight = 4.0
    static let aliasWeight = 3.0
    static let summaryWeight = 2.0
    static let tagWeight = 2.0
    static let bodyWeight = 1.0
    /// BM25 constants (standard values).
    static let termSaturation = 1.2
    static let lengthNormalization = 0.75

    private let indexedPages: [IndexedPage]
    private let documentFrequencies: [String: Int]
    private let averageWeightedLength: Double

    init(pages: [BrainPage]) {
        var documentFrequencies: [String: Int] = [:]
        var indexedPages: [IndexedPage] = []
        for page in pages {
            var frequencies: [String: Double] = [:]
            func add(_ text: String, weight: Double) {
                for token in BrainSearchTokenizer.tokens(in: text) {
                    frequencies[token, default: 0] += weight
                }
            }
            add(page.title, weight: Self.titleWeight)
            page.aliases.forEach { add($0, weight: Self.aliasWeight) }
            add(page.summary, weight: Self.summaryWeight)
            page.tags.forEach { add($0, weight: Self.tagWeight) }
            add(page.body, weight: Self.bodyWeight)
            for term in frequencies.keys { documentFrequencies[term, default: 0] += 1 }
            let weightedLength = frequencies.values.reduce(0, +)
            indexedPages.append(IndexedPage(page: page, weightedTermFrequencies: frequencies, weightedLength: weightedLength))
        }
        self.indexedPages = indexedPages
        self.documentFrequencies = documentFrequencies
        let totalLength = indexedPages.map(\.weightedLength).reduce(0, +)
        self.averageWeightedLength = indexedPages.isEmpty ? 1 : max(1, totalLength / Double(indexedPages.count))
    }

    var pageCount: Int { indexedPages.count }

    /// Pages ranked by relevance to the query, best first. Pages with a zero
    /// score are left out. An exact title/alias match is lifted to the top.
    func search(_ query: String, limit: Int = 8, kinds: Set<BrainPageKind>? = nil) -> [BrainSearchResult] {
        let queryTerms = Array(Set(BrainSearchTokenizer.tokens(in: query)))
        guard !queryTerms.isEmpty else { return [] }
        let pageTotal = Double(indexedPages.count)
        let comparableQuery = BrainSlug.comparableName(query)

        var scoredResults: [BrainSearchResult] = []
        for indexedPage in indexedPages {
            if let kinds, !kinds.contains(indexedPage.page.kind) { continue }
            var score = 0.0
            for term in queryTerms {
                guard let termFrequency = indexedPage.weightedTermFrequencies[term] else { continue }
                let documentFrequency = Double(documentFrequencies[term] ?? 0)
                let inverseDocumentFrequency = log(1 + (pageTotal - documentFrequency + 0.5) / (documentFrequency + 0.5))
                let lengthRatio = indexedPage.weightedLength / averageWeightedLength
                let saturatedFrequency = termFrequency * (Self.termSaturation + 1)
                    / (termFrequency + Self.termSaturation * (1 - Self.lengthNormalization + Self.lengthNormalization * lengthRatio))
                score += inverseDocumentFrequency * saturatedFrequency
            }
            guard score > 0 else { continue }
            // A query that names the page ("sarah chen", "atlas") should always win.
            let namesThePage = indexedPage.page.allNames.contains { name in
                let comparableName = BrainSlug.comparableName(name)
                // Whole slug words only: page "Rust" must not win for "trust".
                return comparableName.count >= 3
                    && ("-" + comparableQuery + "-").contains("-" + comparableName + "-")
            }
            if namesThePage { score += 10 }
            scoredResults.append(BrainSearchResult(
                slug: indexedPage.page.slug,
                title: indexedPage.page.title,
                kind: indexedPage.page.kind,
                summary: indexedPage.page.summary,
                score: score,
                snippet: Self.snippet(of: indexedPage.page.body, matching: queryTerms)
            ))
        }
        return Array(scoredResults.sorted { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.title < rhs.title
        }.prefix(limit))
    }

    /// Up to ~160 characters of the body: the line with the most query terms.
    static func snippet(of body: String, matching queryTerms: [String], maximumCharacters: Int = 160) -> String {
        let queryTermSet = Set(queryTerms)
        let candidateLines = body.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let bestLine = candidateLines.max { lhs, rhs in
            let lhsHits = Set(BrainSearchTokenizer.tokens(in: lhs)).intersection(queryTermSet).count
            let rhsHits = Set(BrainSearchTokenizer.tokens(in: rhs)).intersection(queryTermSet).count
            return lhsHits < rhsHits
        } ?? ""
        var snippet = bestLine
        for bulletPrefix in ["- ", "* ", "+ "] where snippet.hasPrefix(bulletPrefix) {
            snippet = String(snippet.dropFirst(bulletPrefix.count))
        }
        if snippet.count > maximumCharacters { snippet = String(snippet.prefix(maximumCharacters)) + "…" }
        return snippet
    }
}

// MARK: - Prompt context

/// The block of relevant pages that rides a turn's user message.
enum BrainPromptContext {
    /// Characters of page text one turn may carry — about 150 tokens.
    static let defaultCharacterBudget = 700
    static let maximumPagesPerTurn = 4
    /// Results below this score are noise, not context.
    static let minimumRelevanceScore = 1.5

    /// Renders the pages relevant to a request, or "" when nothing clears the
    /// bar — an unrelated question pays nothing for the brain.
    static func promptText(
        for request: String,
        index: BrainSearchIndex,
        characterBudget: Int = defaultCharacterBudget
    ) -> String {
        let relevantResults = index.search(request, limit: maximumPagesPerTurn)
            .filter { $0.score >= minimumRelevanceScore && $0.kind != .me }
        guard !relevantResults.isEmpty else { return "" }

        var lines = ["notes the user has saved in their brain (about people, projects and topics — not facts about the user unless the page is \"Me\"); use what's relevant, don't recite it:"]
        var charactersUsed = lines[0].count
        for result in relevantResults {
            let detail = result.summary.isEmpty ? result.snippet : result.summary
            let line = "- \(result.title) (\(result.kind.rawValue)): \(detail)"
            guard charactersUsed + line.count <= characterBudget else { continue }
            lines.append(line)
            charactersUsed += line.count
        }
        return lines.count > 1 ? lines.joined(separator: "\n") : ""
    }
}
