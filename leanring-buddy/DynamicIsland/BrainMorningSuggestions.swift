//
//  BrainMorningSuggestions.swift
//  leanring-buddy
//
//  Adapted in spirit from Sentient OS's Proactive "judge" step (AGPL-3.0; see NOTICE): find the
//  few follow-ups worth the user's attention. Wisp's version is much smaller and fully local.
//
//  Once a day, when the morning banner is built, the local model reads the Brain pages updated in
//  the last week and proposes at most three follow-ups. A small model invents things, so every
//  proposal must carry a quote from the notes, and code checks that the quote really appears in
//  the text the model was shown. A proposal whose quote is missing or paraphrased is dropped.
//  Proposals only become rows in the banner; clicking one is an ordinary typed question, so
//  anything that sends or changes something still goes through Wisp's confirmation cards.
//

import Foundation

nonisolated struct BrainSuggestionCandidate: Equatable, Sendable {
    /// A short imperative headline for the banner row.
    let title: String
    /// A passage copied from the notes that justifies the follow-up.
    let evidenceQuote: String
}

nonisolated enum BrainMorningSuggestions {
    /// How far back the notes are read.
    static let lookbackDays = 7
    /// The most follow-ups offered. Scarcity is the point; the banner already has other rows.
    static let maximumSuggestions = 3
    /// About 2.5k tokens, leaving room for the prompt and reply inside Wisp's 8k-token window.
    static let maximumMaterialCharacters = 9_000
    static let minimumMaterialCharacters = 200
    static let minimumQuoteCharacters = 20
    static let maximumTitleCharacters = 80

    static let enabledUserDefaultsKey = "wisp.announcements.brainSuggestionsEnabled"
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledUserDefaultsKey) == nil
            || UserDefaults.standard.bool(forKey: enabledUserDefaultsKey)
    }

    // MARK: Material

    /// The text the model is shown: bullet and paragraph lines from pages updated recently,
    /// newest first, each prefixed with its page title so the model can tell notes apart.
    static func material(pages: [BrainPage], now: Date) -> String {
        let cutoff = now.addingTimeInterval(-Double(lookbackDays) * 24 * 60 * 60)
        let recentPages = pages
            .filter { ($0.updatedDate ?? .distantPast) >= cutoff }
            .sorted { ($0.updatedDate ?? .distantPast) > ($1.updatedDate ?? .distantPast) }

        var lines: [String] = []
        var characterCount = 0
        for page in recentPages {
            for rawLine in page.body.components(separatedBy: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#") else { continue }
                let renderedLine = "[\(page.title)] \(line)"
                guard characterCount + renderedLine.count <= maximumMaterialCharacters else { return lines.joined(separator: "\n") }
                lines.append(renderedLine)
                characterCount += renderedLine.count + 1
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Model call

    private static let systemPrompt = """
    You read the user's recent personal notes and suggest follow-ups they may want to act on \
    today. Only suggest something the notes clearly point to: an unanswered question, a promised \
    task, a deadline, a decision waiting on them. Never invent facts, dates or people. Each \
    suggestion needs a short imperative title (under 10 words) and an evidence_quote copied \
    EXACTLY, word for word, from the notes (a full sentence or phrase, at least 20 characters). \
    Return at most 3 suggestions. If nothing clearly qualifies, return an empty list. \
    Reply with JSON: {"suggestions": [{"title": "...", "evidence_quote": "..."}]}
    """

    /// Asks the local model for follow-ups and returns only those whose quote checks out.
    @MainActor static func judge(material: String) async throws -> [BrainSuggestionCandidate] {
        guard material.count >= minimumMaterialCharacters else { return [] }
        let baseURLString = AppBundleConfiguration.stringValue(forKey: "OllamaBaseURL") ?? "http://localhost:11434"
        let modelName = AppBundleConfiguration.stringValue(forKey: "OllamaModel") ?? "qwen2.5vl:3b"
        guard let baseURL = URL(string: baseURLString) else { return [] }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"), cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": modelName,
            "stream": false,
            "format": [
                "type": "object",
                "properties": [
                    "suggestions": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": ["title": ["type": "string"], "evidence_quote": ["type": "string"]],
                            "required": ["title", "evidence_quote"],
                        ],
                    ],
                ],
                "required": ["suggestions"],
            ],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "Notes:\n\(material)"],
            ],
            // Must equal the context size the rest of Wisp uses, or Ollama reloads the model (see LocalOllamaAPI).
            "options": ["temperature": 0.2, "num_ctx": LocalOllamaAPI.activeContextWindowTokens, "num_predict": 400],
            "keep_alive": LocalOllamaAPI.modelResidencyWindow,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let envelope = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              envelope["done_reason"] as? String != "length",
              let message = envelope["message"] as? [String: Any],
              let content = message["content"] as? String else { return [] }
        return verified(parse(reply: content), against: material)
    }

    // MARK: Parsing and verification (pure)

    static func parse(reply: String) -> [BrainSuggestionCandidate] {
        guard let data = reply.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawSuggestions = object["suggestions"] as? [[String: Any]] else { return [] }
        return rawSuggestions.compactMap { rawSuggestion in
            guard let title = rawSuggestion["title"] as? String,
                  let quote = rawSuggestion["evidence_quote"] as? String else { return nil }
            return BrainSuggestionCandidate(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                evidenceQuote: quote.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// Keeps a candidate only if its title is sensible and its quote appears in the material
    /// (ignoring case, spacing and markdown emphasis). Drops duplicates and caps the count.
    static func verified(_ candidates: [BrainSuggestionCandidate], against material: String) -> [BrainSuggestionCandidate] {
        let normalizedMaterial = normalizedForComparison(material)
        var seenTitles = Set<String>()
        var kept: [BrainSuggestionCandidate] = []
        for candidate in candidates {
            let normalizedQuote = normalizedForComparison(candidate.evidenceQuote)
            guard !candidate.title.isEmpty,
                  candidate.title.count <= maximumTitleCharacters,
                  normalizedQuote.count >= minimumQuoteCharacters,
                  normalizedMaterial.contains(normalizedQuote),
                  seenTitles.insert(candidate.title.lowercased()).inserted else { continue }
            kept.append(candidate)
            if kept.count == maximumSuggestions { break }
        }
        return kept
    }

    static func normalizedForComparison(_ text: String) -> String {
        let withoutEmphasis = text.replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "`", with: "")
        return withoutEmphasis.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The banner row for a verified candidate. Clicking it asks Wisp, with the evidence attached.
    static func suggestionRow(for candidate: BrainSuggestionCandidate) -> MorningSuggestion {
        MorningSuggestion(
            id: "brain-\(abs(candidate.title.lowercased().hashValue))",
            title: candidate.title,
            symbolName: "sparkles",
            action: .askQuestion("Help me with this: \(candidate.title). It comes from my notes: \"\(candidate.evidenceQuote)\"")
        )
    }
}
