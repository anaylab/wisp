//
//  AgentToolRouter.swift
//  leanring-buddy
//
//  Chooses which registered tools the model is shown for one request.
//
//  AgentToolScope handles the built-in families well (browser / filesystem /
//  coding) with hand-tuned vocabulary, but it only knows the tool names it was
//  written against. A marketplace changes that: a user can install GitHub,
//  Slack, or Composio's connect server, whose tools match no built-in scope and
//  would therefore never be shown. And they can install more tools than the
//  small model can choose well from at once.
//
//  So selection becomes a ranking rather than a fixed list. Every registered
//  tool is scored for lexical relevance to the request — its name (split into
//  words) counting heavily, its description lightly — and the top few within the
//  per-turn budget are shown. Built-in scope membership adds a large bonus, so
//  the tuned browser/filesystem/coding routing is preserved exactly while
//  arbitrary marketplace tools can now surface when the request is about them.
//
//  Deterministic and model-free, like the rest of the routing here: the binding
//  constraint is model residency, so spending a model call to pick tools for a
//  model call is the wrong trade. Install as many tools as you like; only the
//  relevant handful reaches the prompt each turn.
//

import Foundation

enum AgentToolRouter {
    private struct ScoredTool {
        let tool: BuddyToolDefinition
        let score: Int
    }

    /// Bonus added to a tool the built-in scope already selects, so the tuned
    /// browser/filesystem/coding routing is preferred — worth about two strong
    /// name matches. Deliberately not overwhelming: a marketplace tool the
    /// request is clearly about (say `github__*` for "search GitHub issues")
    /// should still be able to outrank an in-scope tool it beats on relevance,
    /// rather than being crowded out by the scope's built-ins.
    private static let scopeMembershipBonus = 6

    /// Very common words that carry no routing signal.
    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "to", "of", "in", "on", "for", "my", "me",
        "you", "it", "is", "are", "was", "do", "does", "can", "could", "would",
        "please", "with", "this", "that", "these", "those", "what", "how", "why",
        "when", "where", "get", "got", "set", "use", "using", "want", "need",
        "have", "has", "let", "make", "give", "show", "tell", "about", "into",
        "from", "your", "our", "any", "all", "some", "then", "than", "will"
    ]

    /// Selects the tools to show the model, ranked by relevance to the request.
    ///
    /// - Parameter boostedToolNames: Tools a caller knows are relevant beyond
    ///   what words alone show — e.g. `run_shortcut` when the request names one
    ///   of the user's Apple Shortcuts. They get the same bonus as scope
    ///   membership (not stacked with it).
    /// - Parameter scopeOverride: The scope to use instead of the one the
    ///   request's words pick — for a caller that knows better, e.g. `.general`
    ///   for "click the New Note button in Notes", whose "click" would otherwise
    ///   give the browser tools a bonus they can't use on a native app.
    static func select(
        from tools: [BuddyToolDefinition],
        for transcript: String,
        limit: Int,
        boostedToolNames: Set<String> = [],
        scopeOverride: AgentToolScope? = nil
    ) -> [BuddyToolDefinition] {
        guard limit > 0, !tools.isEmpty else { return [] }

        // Always-available tools are shown unconditionally (see AgentToolScope).
        let alwaysNames = AgentToolScope.alwaysAvailableToolNames
        let alwaysTools = tools.filter { alwaysNames.contains($0.name) }

        let scope = scopeOverride ?? AgentToolScope.forRequest(transcript)
        let queryTerms = terms(from: transcript)

        var scored: [ScoredTool] = []
        for tool in tools where !alwaysNames.contains(tool.name) {
            var score = lexicalScore(tool, queryTerms: queryTerms)
            if scope.includes(toolNamed: tool.name) || boostedToolNames.contains(tool.name) {
                score += scopeMembershipBonus
            }
            if score > 0 { scored.append(ScoredTool(tool: tool, score: score)) }
        }
        // Highest score first; ties broken by name so selection is stable.
        scored.sort { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.tool.name < rhs.tool.name
        }

        let remaining = max(0, limit - alwaysTools.count)
        let topTools: [BuddyToolDefinition] = scored.prefix(remaining).map { $0.tool }
        let chosen = alwaysTools + topTools

        // If nothing matched at all (and there are no always-available tools),
        // fall back to a small deterministic slice rather than showing nothing
        // or flooding the prompt with everything.
        if chosen.isEmpty {
            return Array(tools.sorted { $0.name < $1.name }.prefix(limit))
        }

        return Array(chosen.prefix(limit))
    }

    // MARK: - Scoring

    /// Relevance of one tool to the request: a query word that hits the tool's
    /// name is worth more than one that only hits its description.
    static func lexicalScore(_ tool: BuddyToolDefinition, queryTerms: Set<String>) -> Int {
        guard !queryTerms.isEmpty else { return 0 }

        let nameTerms = Set(identifierWords(tool.name))
        let descriptionTerms = terms(from: tool.description)

        var score = 0
        for queryTerm in queryTerms {
            if nameTerms.contains(where: { matches(queryTerm, $0) }) {
                score += 3
            } else if descriptionTerms.contains(where: { matches(queryTerm, $0) }) {
                score += 1
            }
        }
        return score
    }

    /// Two terms match when they're equal or one meaningfully contains the
    /// other — a loose stem so "files" hits "file" and "repository" hits "repo".
    private static func matches(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        if lhs.count >= 4 && rhs.contains(lhs) { return true }
        if rhs.count >= 4 && lhs.contains(rhs) { return true }
        return false
    }

    /// Significant words from free text.
    static func terms(from text: String) -> Set<String> {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return Set(words.filter { $0.count >= 3 && !stopwords.contains($0) })
    }

    /// Splits a tool identifier into words: `composio-connect__COMPOSIO_SEARCH_TOOLS`
    /// → composio, connect, search, tools; `read_page` → read, page.
    static func identifierWords(_ identifier: String) -> [String] {
        let separated = identifier
            .replacingOccurrences(of: "__", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        var words: [String] = []
        for token in separated.split(separator: " ") {
            words.append(contentsOf: splitCamelCase(String(token)))
        }
        return words.map { $0.lowercased() }.filter { $0.count >= 2 }
    }

    /// Splits camelCase / PascalCase into its words, leaving already-split
    /// lowercase or all-caps tokens intact.
    private static func splitCamelCase(_ token: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previousWasLower = false

        for character in token {
            if character.isUppercase && previousWasLower {
                if !current.isEmpty { words.append(current) }
                current = String(character)
            } else {
                current.append(character)
            }
            previousWasLower = character.isLowercase
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}
