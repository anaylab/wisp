//
//  ResearchBrainPages.swift
//  leanring-buddy
//
//  "…and save it to my brain" (phase 11): a research report as Brain edit
//  proposals — a `topics/` page for the question (its summary and the cited
//  points, each linking its source) and a `sources/` page per cited source
//  (its address and the quotes used). Built from the verified report only, no
//  model call.
//
//  Everything in a report came from web pages, so the batch is applied with
//  `.external` provenance: `BrainEditPlanner` lets it append and create and
//  nothing else — it can't replace a section the user wrote or touch the `me`
//  page. Saving the same report twice adds nothing (appends skip bullets
//  already on the page).
//
//  Pure (Foundation + the Brain's pure edit types), tested by `Tests/ChromeExtResearch`.
//

import Foundation

enum ResearchBrainPages {

    static func provenance(for report: ResearchReport) -> BrainEditProvenance {
        BrainEditProvenance(origin: .agent, label: "research: \(String(report.topic.prefix(60)))", trust: .external)
    }

    static func topicPageTitle(for report: ResearchReport) -> String {
        let title = report.topic.prefix(1).uppercased() + report.topic.dropFirst()
        return String(title.prefix(BrainEditPlanner.maximumTitleCharacters))
    }

    static func sourcePageTitle(for source: ResearchReport.Source) -> String {
        String(source.title
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
            .prefix(BrainEditPlanner.maximumTitleCharacters))
    }

    static func proposals(for report: ResearchReport, calendar: Calendar = .current) -> [BrainEditProposal] {
        guard !report.claims.isEmpty else { return [] }
        let topicTitle = topicPageTitle(for: report)
        let dayText = dayString(report.createdAt, calendar: calendar)
        let sectionHeading = "Research \(dayText)"

        var claimBullets: [String] = []
        for claim in report.claims {
            guard let source = report.source(numbered: claim.sourceNumber) else { continue }
            claimBullets.append("- \(singleLine(claim.text)) ([[\(sourcePageTitle(for: source))]])")
        }

        var proposals: [BrainEditProposal] = [
            BrainEditProposal(
                operation: .append,
                pageTitle: topicTitle,
                pageKind: .topic,
                section: sectionHeading,
                content: clipped((["- \(singleLine(report.summary))"] + claimBullets).joined(separator: "\n")),
                summary: String(singleLine(report.summary).prefix(BrainEditPlanner.maximumSummaryCharacters))
            ),
            BrainEditProposal(operation: .summarize, pageTitle: topicTitle, pageKind: .topic, content: String(singleLine(report.summary).prefix(BrainEditPlanner.maximumSummaryCharacters))),
        ]

        for source in report.sources {
            let quoteBullets = report.claims
                .filter { $0.sourceNumber == source.number }
                .map { "- “\(singleLine($0.quote))” — for [[\(topicTitle)]]" }
            proposals.append(BrainEditProposal(
                operation: .append,
                pageTitle: sourcePageTitle(for: source),
                pageKind: .source,
                section: "Quotes",
                content: clipped((["- address: \(source.url)"] + quoteBullets).joined(separator: "\n")),
                summary: "A web page read for research on \(String(report.topic.prefix(80)))."
            ))
        }
        return Array(proposals.prefix(BrainEditPlanner.maximumProposalsPerBatch))
    }

    private static func dayString(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
    }

    private static func clipped(_ content: String) -> String {
        String(content.prefix(BrainEditPlanner.maximumContentCharacters))
    }
}
