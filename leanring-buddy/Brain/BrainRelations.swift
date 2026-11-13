//
//  BrainRelations.swift
//  leanring-buddy
//
//  Typed relationships between brain pages, cognee-style: not just "Sarah
//  links to Atlas" but "Sarah — leads design at → Atlas". They live in the
//  pages themselves, so the vault stays plain markdown:
//
//  - Explicit: a bullet `- works at:: [[Orbit]]` (Obsidian's inline-field
//    form). Writers file these under `## Relations`; the user can type them.
//  - Derived: a short linked fact, `- Runs design at [[Orbit]]`, already says
//    how two pages relate. The words before the first link (1–5 of them, no
//    sentence punctuation) become the relation, so every existing page has
//    labelled edges without a model call. Long sentences around a link are
//    left alone.
//
//  Pure (Foundation only) and tested by `Tests/BrainCore`. The graph is
//  rebuilt from the pages whenever they change; it is never stored.
//

import Foundation

nonisolated struct BrainRelation: Equatable, Hashable, Sendable {
    var sourceSlug: String
    /// Lowercase words, e.g. "works at", "plaintiff in".
    var predicate: String
    var targetSlug: String
    /// Written as `relation:: [[Target]]` rather than read off a fact.
    var isExplicit: Bool
}

nonisolated enum BrainRelationParser {
    struct ParsedRelation: Equatable, Sendable {
        var predicate: String
        var targetName: String
        var isExplicit: Bool
    }

    /// A derived relation's predicate is at most this many words; longer
    /// openings are sentences, not relations.
    static let maximumDerivedPredicateWords = 5
    /// …and the rest of the fact after the first link stays this short, so
    /// "She said the deadline for [[Atlas]] slipped again because…" is left
    /// as the sentence it is.
    static let maximumDerivedTailWords = 5
    static let maximumPredicateCharacters = 40

    static func relations(inBody body: String) -> [ParsedRelation] {
        var parsedRelations: [ParsedRelation] = []
        var isInsideCodeFence = false
        for rawLine in body.components(separatedBy: "\n") {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("```") { isInsideCodeFence.toggle(); continue }
            guard !isInsideCodeFence else { continue }
            guard let bulletText = bulletText(of: trimmedLine) else { continue }
            let linkTargets = BrainLinkParser.linkTargets(in: bulletText)
            guard !linkTargets.isEmpty else { continue }

            if let fieldSeparatorRange = bulletText.range(of: "::") {
                // Explicit: `predicate:: [[A]], [[B]]`.
                let predicate = normalizedPredicate(String(bulletText[..<fieldSeparatorRange.lowerBound]))
                let valueText = String(bulletText[fieldSeparatorRange.upperBound...])
                guard !predicate.isEmpty else { continue }
                for targetName in BrainLinkParser.linkTargets(in: valueText) {
                    parsedRelations.append(ParsedRelation(predicate: predicate, targetName: targetName, isExplicit: true))
                }
                continue
            }

            // Derived: the words before the first link, if they read as a relation.
            guard let firstLinkRange = bulletText.range(of: "[[") else { continue }
            let openingText = String(bulletText[..<firstLinkRange.lowerBound])
            guard isRelationLikeOpening(openingText) else { continue }
            let tailText = BrainSemanticFacts.plainText(String(bulletText[firstLinkRange.lowerBound...]))
            let tailWordCount = tailText.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.count
                - BrainSemanticFacts.plainText("[[\(linkTargets[0])]]").components(separatedBy: .whitespaces).filter { !$0.isEmpty }.count
            guard tailWordCount <= maximumDerivedTailWords else { continue }
            let predicate = normalizedPredicate(openingText)
            guard !predicate.isEmpty, let firstTarget = linkTargets.first else { continue }
            parsedRelations.append(ParsedRelation(predicate: predicate, targetName: firstTarget, isExplicit: false))
        }
        return parsedRelations
    }

    /// "works at", from "Works at", "works at:" or " **works  at** ".
    static func normalizedPredicate(_ rawPredicate: String) -> String {
        var predicate = rawPredicate
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":-–—,")))
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // Keep acronyms ("CEO of"); lowercase ordinary words.
        predicate = predicate.components(separatedBy: " ").map { word in
            word.count > 1 && word == word.uppercased() && word.rangeOfCharacter(from: .letters) != nil ? word : word.lowercased()
        }.joined(separator: " ")
        if predicate.count > maximumPredicateCharacters { return "" }
        return predicate
    }

    /// 1–5 words, no sentence punctuation or digits-only date ("2026-09-29:").
    static func isRelationLikeOpening(_ openingText: String) -> Bool {
        let trimmedOpening = openingText.trimmingCharacters(in: .whitespaces)
        guard !trimmedOpening.isEmpty else { return false }
        guard trimmedOpening.rangeOfCharacter(from: CharacterSet(charactersIn: ".?!:;()[]\"")) == nil else { return false }
        let words = trimmedOpening.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard (1...maximumDerivedPredicateWords).contains(words.count) else { return false }
        return words.contains { $0.rangeOfCharacter(from: .letters) != nil }
    }

    private static func bulletText(of trimmedLine: String) -> String? {
        for bulletPrefix in ["- ", "* ", "+ "] where trimmedLine.hasPrefix(bulletPrefix) {
            var text = String(trimmedLine.dropFirst(bulletPrefix.count))
            // A task bullet's box is not part of the relation.
            for checkbox in ["[ ] ", "[x] ", "[X] "] where text.hasPrefix(checkbox) {
                text = String(text.dropFirst(checkbox.count))
            }
            return text
        }
        return nil
    }
}

nonisolated enum BrainRelationGraph {
    /// Every relation among the pages, resolved to slugs. One per (source,
    /// predicate, target); an explicit relation wins over the same derived one,
    /// and a self-relation or an unresolved target is dropped.
    static func relations(pages: [BrainPage], resolver: BrainLinkResolver) -> [BrainRelation] {
        var relationsByKey: [String: BrainRelation] = [:]
        var keyOrder: [String] = []
        for page in pages {
            for parsedRelation in BrainRelationParser.relations(inBody: page.body) {
                guard let targetSlug = resolver.slug(forTarget: parsedRelation.targetName), targetSlug != page.slug else { continue }
                let relationKey = "\(page.slug)\u{0}\(parsedRelation.predicate)\u{0}\(targetSlug)"
                let relation = BrainRelation(
                    sourceSlug: page.slug,
                    predicate: parsedRelation.predicate,
                    targetSlug: targetSlug,
                    isExplicit: parsedRelation.isExplicit
                )
                if let existingRelation = relationsByKey[relationKey] {
                    if parsedRelation.isExplicit && !existingRelation.isExplicit { relationsByKey[relationKey] = relation }
                } else {
                    relationsByKey[relationKey] = relation
                    keyOrder.append(relationKey)
                }
            }
        }
        return keyOrder.compactMap { relationsByKey[$0] }
    }

    /// "Fred Korematsu — plaintiff in → Korematsu v. United States".
    static func describe(_ relation: BrainRelation, titleBySlug: [String: String]) -> String {
        let sourceTitle = titleBySlug[relation.sourceSlug] ?? relation.sourceSlug
        let targetTitle = titleBySlug[relation.targetSlug] ?? relation.targetSlug
        return "\(sourceTitle) — \(relation.predicate) → \(targetTitle)"
    }
}
