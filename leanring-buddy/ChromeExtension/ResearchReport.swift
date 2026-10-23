//
//  ResearchReport.swift
//  leanring-buddy
//
//  What a research run produces (phase 11): a short summary, numbered claims
//  each tied to one source by a quote checked against that source's text, and
//  the sources in the order they're first cited.
//
//  `ResearchReportAssembler` turns the model's draft (claims naming a source
//  number and a quote) into a report: it verifies every quote with
//  `ResearchCitationVerifier`, drops a claim whose quote isn't in its source,
//  renumbers the sources by first citation, and builds each citation's
//  text-fragment address. The model never chooses an address: sources are the
//  pages Wisp itself opened and read.
//
//  Chrome tab ids are not part of a report (they die with the browser
//  session, contracts §1); `ResearchSession` maps a source's address to its
//  open tab.
//
//  Pure (Foundation only), tested by `Tests/ChromeExtResearch`.
//

import Foundation

/// A page Wisp opened and read for a research run.
nonisolated struct ResearchSourceDocument: Equatable, Sendable {
    let url: String
    let title: String
    let text: String
}

/// A claim as the model wrote it, before checking. `sourceNumber` counts from
/// 1 in the order the sources were given to the model.
nonisolated struct ResearchDraftClaim: Equatable, Sendable {
    let text: String
    let sourceNumber: Int
    let quote: String
}

nonisolated struct ResearchReport: Codable, Equatable, Identifiable, Sendable {
    struct Source: Codable, Equatable, Sendable {
        /// 1-based, in order of first citation.
        let number: Int
        let title: String
        let url: String
    }

    struct Claim: Codable, Equatable, Sendable {
        let number: Int
        let text: String
        let sourceNumber: Int
        /// Exactly as it appears in the source's text.
        let quote: String
        /// The source's address that opens it at the quote.
        let textFragmentURLString: String?
    }

    let id: UUID
    let topic: String
    let summary: String
    let claims: [Claim]
    /// Cited sources, numbered.
    let sources: [Source]
    /// Pages read but not cited.
    let otherReadSources: [Source]
    /// Claims dropped because their quote wasn't in their source.
    let droppedClaimCount: Int
    let createdAt: Date
    let usedLocalModel: Bool

    func source(numbered sourceNumber: Int) -> Source? {
        sources.first { $0.number == sourceNumber }
    }

    /// The report as plain text, for History, the clipboard and the agent
    /// tool's result: summary, numbered claims with their source, sources.
    var plainText: String {
        var lines: [String] = [summary]
        if !claims.isEmpty {
            lines.append("")
            for claim in claims {
                lines.append("\(claim.number). \(claim.text) [\(claim.sourceNumber)] — “\(claim.quote)”")
            }
        }
        if !sources.isEmpty {
            lines.append("")
            lines.append("sources:")
            for source in sources {
                lines.append("[\(source.number)] \(source.title) — \(source.url)")
            }
        }
        if droppedClaimCount > 0 {
            lines.append("")
            lines.append(ResearchReportText.droppedClaimsNote(count: droppedClaimCount))
        }
        return lines.joined(separator: "\n")
    }
}

nonisolated enum ResearchReportText {
    static func droppedClaimsNote(count: Int) -> String {
        count == 1
            ? "(1 claim was left out: its quote wasn't in the page it named.)"
            : "(\(count) claims were left out: their quotes weren't in the pages they named.)"
    }

    /// The notch's short line when a run finishes.
    static func notchLine(for report: ResearchReport) -> String {
        guard !report.claims.isEmpty else {
            return "i read \(report.otherReadSources.count + report.sources.count) pages on \(report.topic) but couldn't back any claim with a quote. the pages are still open in the wisp group."
        }
        let sourceWord = report.sources.count == 1 ? "source" : "sources"
        return "\(report.summary) (\(report.claims.count) cited points from \(report.sources.count) \(sourceWord).)"
    }
}

nonisolated enum ResearchReportAssembler {

    /// A report longer than this stops being a quick read.
    static let maximumClaims = 8

    static func assemble(
        id: UUID = UUID(),
        topic: String,
        summary: String,
        draftClaims: [ResearchDraftClaim],
        sourceDocuments: [ResearchSourceDocument],
        usedLocalModel: Bool,
        createdAt: Date
    ) -> ResearchReport {
        var acceptedClaims: [(text: String, documentIndex: Int, quote: String)] = []
        var droppedClaimCount = 0
        var seenClaimTexts = Set<String>()

        for draftClaim in draftClaims {
            let claimText = cleanedModelText(draftClaim.text)
            let documentIndex = draftClaim.sourceNumber - 1
            guard !claimText.isEmpty, sourceDocuments.indices.contains(documentIndex),
                  let verifiedQuote = ResearchCitationVerifier.verifiedQuote(
                      draftClaim.quote, inSourceText: sourceDocuments[documentIndex].text
                  ) else {
                droppedClaimCount += 1
                continue
            }
            // The same claim twice (local reduce repeats itself) isn't two points.
            guard seenClaimTexts.insert(ResearchTextFolding.foldedString(claimText)).inserted else { continue }
            guard acceptedClaims.count < maximumClaims else { continue }
            acceptedClaims.append((claimText, documentIndex, verifiedQuote))
        }

        // Sources numbered by first citation, so [1] is the first one cited.
        var reportNumberByDocumentIndex: [Int: Int] = [:]
        var citedSources: [ResearchReport.Source] = []
        for acceptedClaim in acceptedClaims where reportNumberByDocumentIndex[acceptedClaim.documentIndex] == nil {
            let reportNumber = citedSources.count + 1
            reportNumberByDocumentIndex[acceptedClaim.documentIndex] = reportNumber
            let document = sourceDocuments[acceptedClaim.documentIndex]
            citedSources.append(ResearchReport.Source(number: reportNumber, title: displayTitle(for: document), url: document.url))
        }
        let otherReadSources = sourceDocuments.indices
            .filter { reportNumberByDocumentIndex[$0] == nil }
            .enumerated()
            .map { offset, documentIndex in
                ResearchReport.Source(
                    number: citedSources.count + offset + 1,
                    title: displayTitle(for: sourceDocuments[documentIndex]),
                    url: sourceDocuments[documentIndex].url
                )
            }

        let claims = acceptedClaims.enumerated().map { offset, acceptedClaim in
            ResearchReport.Claim(
                number: offset + 1,
                text: acceptedClaim.text,
                sourceNumber: reportNumberByDocumentIndex[acceptedClaim.documentIndex] ?? 0,
                quote: acceptedClaim.quote,
                textFragmentURLString: ResearchTextFragmentURL.url(
                    forSourceURLString: sourceDocuments[acceptedClaim.documentIndex].url,
                    quote: acceptedClaim.quote
                )?.absoluteString
            )
        }

        let cleanedSummary = cleanedModelText(summary)
        return ResearchReport(
            id: id,
            topic: topic,
            summary: cleanedSummary.isEmpty ? "here's what the sources say about \(topic)." : cleanedSummary,
            claims: claims,
            sources: citedSources,
            otherReadSources: otherReadSources,
            droppedClaimCount: droppedClaimCount,
            createdAt: createdAt,
            usedLocalModel: usedLocalModel
        )
    }

    /// Model text derived from untrusted pages: one line, no machine tags
    /// (`[TOOL:…]`, `[POINT:…]`, `[SAY:…]`, `[CARD:…]`), capped.
    static func cleanedModelText(_ modelText: String) -> String {
        let withoutTags = modelText.replacingOccurrences(
            of: #"\[(?:POINT|BOX|HIGHLIGHT|ARROW|CIRCLE|NOTE|STEP|SAY|TOOL|CARD)[\s:][^\]]*\]?"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        let singleLine = withoutTags.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(singleLine.prefix(400)).trimmingCharacters(in: .whitespaces)
    }

    private static func displayTitle(for document: ResearchSourceDocument) -> String {
        let trimmedTitle = document.title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if !trimmedTitle.isEmpty { return String(trimmedTitle.prefix(120)) }
        return URLComponents(string: document.url)?.host ?? document.url
    }
}
