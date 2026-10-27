//
//  BrainAboutMe.swift
//  leanring-buddy
//
//  The user's own brain page (`wiki/me.md`) as Wisp's long-term memory of
//  them. Pure: reading the page's facts, the compact "about the user" block
//  for the system prompt, and the bullet edits `remember` / `forget` make —
//  so all of it is testable without a file system.
//
//  This replaced `~/.wisp/memory.md` as the source of the system prompt's
//  memory block (see `BrainMemoryMigration` for the one-time move). The block
//  rides the *system prompt*, not the user message, on purpose: it only
//  changes when the me page does, so the local model's prefix cache still
//  hits turn after turn. Per-turn brain context (pages relevant to this
//  request) goes on the user message instead — see `BrainPromptContext`.
//

import Foundation

enum BrainAboutMe {
    /// The me page's slug (`wiki/me.md`).
    static let mePageSlug = "me"
    /// The section `remember` appends to and the prompt block reads.
    static let factsSectionHeading = "Facts"
    /// Characters of summary + facts the system prompt may carry. About 200
    /// tokens — the same budget `MemoryIndex` had, so the prompt doesn't grow.
    static let defaultCharacterBudget = 800

    // MARK: Reading

    /// The bullet texts under the me page's `## Facts` section, in page order
    /// (oldest first — `remember` appends at the end).
    static func factBullets(onMePage mePage: BrainPage?) -> [String] {
        guard let mePage else { return [] }
        let sections = BrainPageSections.parse(mePage.body)
        guard let factsSectionIndex = BrainPageSections.indexOfSection(named: factsSectionHeading, in: sections) else {
            return []
        }
        return MemoryFileFormat.parseFacts(from: sections[factsSectionIndex].content)
    }

    /// `Leads design for [[Atlas]]` → `Leads design for Atlas`. The prompt
    /// block is read by the model as prose; link brackets are noise there.
    static func plainText(fromMarkdownWithLinks markdown: String) -> String {
        var plainText = ""
        var remainingText = Substring(markdown)
        while let openRange = remainingText.range(of: "[["),
              let closeRange = remainingText.range(of: "]]", range: openRange.upperBound..<remainingText.endIndex) {
            plainText += remainingText[remainingText.startIndex..<openRange.lowerBound]
            let innerText = String(remainingText[openRange.upperBound..<closeRange.lowerBound])
            plainText += BrainLinkParser.displayText(fromInnerText: innerText)
            remainingText = remainingText[closeRange.upperBound...]
        }
        plainText += remainingText
        return plainText
    }

    // MARK: Prompt block

    /// The "about the user" block appended to the system prompt, or "" when
    /// the me page has nothing to say — a user with an empty brain pays
    /// nothing for this.
    ///
    /// The summary comes first (when it fits), then as many facts as fit the
    /// budget, newest preferred. A fact that would overflow is skipped rather
    /// than ending the walk, so one long fact can't crowd out every shorter
    /// one before it (the same rule `MemoryIndex` used).
    static func promptInstructions(
        mePage: BrainPage?,
        characterBudget: Int = defaultCharacterBudget
    ) -> String {
        guard let mePage else { return "" }
        var charactersUsed = 0

        var summaryLine: String?
        let trimmedSummary = plainText(fromMarkdownWithLinks: mePage.summary)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSummary.isEmpty && trimmedSummary.count <= characterBudget {
            summaryLine = trimmedSummary
            charactersUsed += trimmedSummary.count
        }

        var chosenFactLinesNewestFirst: [String] = []
        for fact in factBullets(onMePage: mePage).reversed() {
            let renderedFactLine = "- " + plainText(fromMarkdownWithLinks: fact)
            guard charactersUsed + renderedFactLine.count <= characterBudget else { continue }
            chosenFactLinesNewestFirst.append(renderedFactLine)
            charactersUsed += renderedFactLine.count
        }

        guard summaryLine != nil || !chosenFactLinesNewestFirst.isEmpty else { return "" }

        var lines = [
            "",
            "",
            "about the user (from their brain's me page). use it when it's relevant; don't recite it:"
        ]
        if let summaryLine { lines.append(summaryLine) }
        lines.append(contentsOf: chosenFactLinesNewestFirst.reversed())
        return lines.joined(separator: "\n")
    }

    // MARK: Edits

    /// The proposal `remember` applies: one bullet appended under the me
    /// page's Facts section (created if missing). The planner skips it if the
    /// bullet is already on the page.
    static func rememberProposal(forFact fact: String) -> BrainEditProposal {
        BrainEditProposal(
            operation: .append,
            pageTitle: "Me",
            pageKind: .me,
            section: factsSectionHeading,
            content: "- \(fact)"
        )
    }

    /// Where `remember` writes are recorded as coming from: the user's own
    /// words, so it may touch the me page.
    static let rememberProvenance = BrainEditProvenance.user("you said")

    /// Bullets on the me page whose text contains the query, ignoring case —
    /// what `forget` would remove. Bullets in any section count: a fact the
    /// user wants gone shouldn't survive because it was filed under "Notes".
    static func bulletsMatching(_ query: String, onMePage mePage: BrainPage) -> [String] {
        MemoryFileFormat.facts(matching: query, in: mePage.body)
    }

    /// The me page with every bullet containing the query removed, plus what
    /// was removed. Non-bullet lines (headings, prose) are always kept.
    static func pageRemovingBullets(
        matching query: String,
        from mePage: BrainPage
    ) -> (updatedPage: BrainPage, removedBullets: [String]) {
        let removal = MemoryFileFormat.removingFacts(matching: query, from: mePage.body)
        var updatedPage = mePage
        updatedPage.body = removal.updatedMarkdown
        return (updatedPage, removal.removedFacts)
    }

    /// The me page with one exact bullet removed (a per-row delete button,
    /// where the user pointed at precisely the line they mean).
    static func pageRemovingExactBullet(
        _ bulletToRemove: String,
        from mePage: BrainPage
    ) -> (updatedPage: BrainPage, removedBullets: [String]) {
        let removal = MemoryFileFormat.removingFacts(from: mePage.body) { bulletText in
            bulletText == bulletToRemove
        }
        var updatedPage = mePage
        updatedPage.body = removal.updatedMarkdown
        return (updatedPage, removal.removedFacts)
    }
}
