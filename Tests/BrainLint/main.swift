//
//  Brain lint suite. Pure checks and fixes over hand-built pages: what each
//  check flags, what it must not flag (the duplicate rules especially), that
//  issue ids are stable, and that merge/split produce the expected plans.
//

import Foundation

var failureCount = 0
var checkCount = 0

func check(_ condition: Bool, _ description: String) {
    checkCount += 1
    if !condition {
        failureCount += 1
        print("FAIL: \(description)")
    }
}

let referenceDate = Date(timeIntervalSince1970: 1_790_000_000)
let olderDate = Date(timeIntervalSince1970: 1_780_000_000)

func makePage(
    _ title: String,
    kind: BrainPageKind = .note,
    summary: String = "A page.",
    aliases: [String] = [],
    tags: [String] = [],
    sources: [String] = [],
    createdDate: Date? = referenceDate,
    isLocked: Bool = false,
    body: String = ""
) -> BrainPage {
    BrainPage(
        slug: BrainSlug.make(title: title, kind: kind),
        title: kind == .me ? "Me" : title,
        kind: kind,
        summary: summary,
        aliases: aliases,
        tags: tags,
        sources: sources,
        createdDate: createdDate,
        updatedDate: createdDate,
        isLocked: isLocked,
        body: body
    )
}

/// `== nil` on a main-actor type's optional picks its isolated `Equatable`
/// conformance; pattern matching doesn't need one.
func isNil<Wrapped>(_ value: Wrapped?) -> Bool {
    if case .none = value { return true }
    return false
}

func lint(_ pages: [BrainPage]) -> [BrainLintIssue] {
    BrainLintChecks.issues(in: pages, resolvePage: BrainLintChecks.makeResolver(pages: pages))
}

func isDuplicate(_ firstPage: BrainPage, _ secondPage: BrainPage) -> Bool {
    !BrainLintChecks.likelyDuplicateIssues(in: [firstPage, secondPage]).isEmpty
}

// MARK: Resolver

let sarahChen = makePage("Sarah Chen", kind: .person, aliases: ["S. Chen"], body: "## Facts\n- Leads design for [[Atlas]].")
let atlas = makePage("Atlas", kind: .project, body: "## Team\n- [[Sarah Chen|Sarah]] leads design.")
let resolveSample = BrainLintChecks.makeResolver(pages: [sarahChen, atlas])
check(resolveSample("sarah chen")?.slug == "people/sarah-chen", "resolver: title ignoring case")
check(resolveSample("S. Chen")?.slug == "people/sarah-chen", "resolver: alias")
check(resolveSample("projects/atlas")?.slug == "projects/atlas", "resolver: exact slug")
check(isNil(resolveSample("Atlas v2")), "resolver: unknown name")

// MARK: Broken links

let pageWithBrokenLink = makePage("Sarah Chen", kind: .person, body: "## Facts\n- Working on [[Atlas v2]] and [[Atlas]].")
let brokenLinkIssues = BrainLintChecks.brokenLinkIssues(
    in: [pageWithBrokenLink, atlas],
    resolvePage: BrainLintChecks.makeResolver(pages: [pageWithBrokenLink, atlas])
)
check(brokenLinkIssues.count == 1, "one broken link (Atlas resolves)")
check(brokenLinkIssues.first?.id == "brokenLink:people/sarah-chen:atlas-v2", "broken link id is kind + slug + target")
check(brokenLinkIssues.first?.brokenLinkTarget == "Atlas v2", "broken link keeps the target as written")
check(brokenLinkIssues.first?.message == "[[Atlas v2]] on Sarah Chen links to nothing", "broken link message")
check(brokenLinkIssues.first?.isAutoFixable == true, "broken link is fixable")
check(lint([pageWithBrokenLink, atlas]).map(\.id) == lint([atlas, pageWithBrokenLink]).map(\.id), "issue ids and order are stable regardless of page order")

// MARK: Orphans

let mePage = makePage("Me", kind: .me, body: "## About\n- Likes tea.")
let lonelyNote = makePage("Random Thought", body: "## Notes\n- Nothing links here.")
let selfLinkingNote = makePage("Self Ref", body: "## Notes\n- See [[Self Ref]].")
let orphanIssues = BrainLintChecks.orphanPageIssues(
    in: [mePage, lonelyNote, selfLinkingNote, sarahChen, atlas],
    resolvePage: BrainLintChecks.makeResolver(pages: [mePage, lonelyNote, selfLinkingNote, sarahChen, atlas])
)
check(Set(orphanIssues.map(\.pageSlugs[0])) == ["notes/random-thought", "notes/self-ref"], "orphans: unlinked pages and self-links only; me exempt; linked pages not flagged")
check(orphanIssues.allSatisfy { !$0.isAutoFixable }, "orphans aren't auto-fixable")
let onlyLinkedTo = makePage("Target Only", body: "## Notes\n- text")
let linkerPage = makePage("Linker", body: "- [[Target Only]]")
check(BrainLintChecks.orphanPageIssues(in: [onlyLinkedTo, linkerPage], resolvePage: BrainLintChecks.makeResolver(pages: [onlyLinkedTo, linkerPage])).isEmpty, "orphans: an incoming link is enough")

// MARK: Likely duplicates — positives

check(isDuplicate(makePage("Sarah", kind: .person), makePage("Sarah Chen", kind: .person)), "dup: person first name vs full name")
check(isDuplicate(makePage("Sarah C", kind: .person), makePage("Sarah Chen", kind: .person)), "dup: person initial")
check(isDuplicate(makePage("Sarah Chen", kind: .person), makePage("Sarah C", kind: .person)), "dup: person initial, either order")
check(!isDuplicate(makePage("Sarah Chen", kind: .person), makePage("Sarah Kowalski", kind: .person)), "not dup: equal word counts, different surname")
check(isDuplicate(makePage("Atlas", kind: .note), makePage("Atlas", kind: .project)), "dup: same name across kinds")
check(isDuplicate(makePage("Sam", kind: .person, aliases: ["Samantha Lee"]), makePage("Samantha Lee", kind: .person)), "dup: alias equals other title")
check(isDuplicate(makePage("Acme", kind: .organization), makePage("Acme Inc", kind: .organization)), "dup: org with generic suffix")
check(isDuplicate(makePage("Atlas", kind: .project), makePage("Atlas Project", kind: .project)), "dup: project with generic suffix")
check(isDuplicate(makePage("Japan Trip 2026", kind: .event), makePage("Trip to Japan 2026", kind: .event)), "dup: same words reordered")
let duplicateIssue = BrainLintChecks.likelyDuplicateIssues(in: [makePage("Sarah Chen", kind: .person), makePage("Sarah", kind: .person)]).first
check(duplicateIssue?.id == "likelyDuplicate:people/sarah:people/sarah-chen", "dup id: sorted slugs")
check(duplicateIssue?.pageSlugs == ["people/sarah", "people/sarah-chen"], "dup slugs sorted")

// MARK: Likely duplicates — must NOT flag

check(!isDuplicate(makePage("Sarah Chen", kind: .person), makePage("Sarah Kim", kind: .person)), "not dup: same first name, different surnames")
check(!isDuplicate(makePage("Atlas", kind: .project), makePage("Atlas v2", kind: .project)), "not dup: version suffix")
check(!isDuplicate(makePage("Swift", kind: .topic), makePage("Swift Concurrency", kind: .topic)), "not dup: topic and subtopic")
check(!isDuplicate(makePage("Q3 Planning Meeting", kind: .event), makePage("Q4 Planning Meeting", kind: .event)), "not dup: differ by a number")
check(!isDuplicate(makePage("Sarah", kind: .person), makePage("Sarah Street", kind: .place)), "not dup: subset across kinds")
check(!isDuplicate(makePage("Design Review", kind: .event), makePage("Code Review", kind: .event)), "not dup: half the words shared")
check(!isDuplicate(makePage("Me", kind: .me), makePage("Me", kind: .note)), "not dup: the me page is exempt")
let ambiguousPeople = [makePage("Sarah", kind: .person), makePage("Sarah Chen", kind: .person), makePage("Sarah Kim", kind: .person)]
check(BrainLintChecks.likelyDuplicateIssues(in: ambiguousPeople).isEmpty, "not dup: one first name matching two people is ambiguous")
check(BrainLintChecks.likelyDuplicateIssues(in: [makePage("Atlas", kind: .project, isLocked: true), makePage("Atlas", kind: .note)]).first?.isAutoFixable == false, "dup with a locked page isn't auto-fixable")

// MARK: Oversized and missing summary

let bigSection = String(repeating: "- a fact that takes up some room on the page\n", count: 215)
let oversizedPage = makePage("Big", kind: .topic, body: "## One\n\(bigSection)\n## Two\n\(bigSection)")
check(oversizedPage.body.count > BrainLintChecks.oversizedPageThresholdCharacters, "fixture is over the threshold")
let oversizedIssues = BrainLintChecks.oversizedPageIssues(in: [oversizedPage, atlas])
check(oversizedIssues.map(\.id) == ["oversizedPage:topics/big"], "oversized: only the big page")
check(oversizedIssues.first?.isAutoFixable == true, "oversized with sections is fixable")
let oneBlobPage = makePage("Blob", body: String(repeating: "x", count: 22_000))
check(BrainLintChecks.oversizedPageIssues(in: [oneBlobPage]).first?.isAutoFixable == false, "oversized with no sections isn't fixable")

let noSummary = makePage("No Summary", summary: "", body: "## Notes\n- Leads design for [[Atlas]]. Likes tea.")
let emptyNoSummary = makePage("Empty", summary: "  ", body: "## Notes")
let missingSummaryIssues = BrainLintChecks.missingSummaryIssues(in: [noSummary, emptyNoSummary, atlas])
check(missingSummaryIssues.map(\.id) == ["missingSummary:notes/no-summary", "missingSummary:notes/empty"], "missing summary: blank summaries flagged")
check(missingSummaryIssues.first?.isAutoFixable == true, "missing summary with text is fixable")
check(missingSummaryIssues.last?.isAutoFixable == false, "missing summary on an empty page isn't fixable")

// MARK: Summary text

check(BrainSummaryText.firstSentenceSummary(for: noSummary) == "Leads design for Atlas.", "first sentence, links shown as text")
check(BrainSummaryText.cleanedModelSummary("Summary: \"Design lead on the Atlas project.\"\nMore text") == "Design lead on the Atlas project.", "model summary cleaned")
check(BrainSummaryText.cleanedModelSummary("```\nA person Wisp knows.\n```") == "A person Wisp knows.", "model summary: code fence skipped")
check(BrainSummaryText.cleanedModelSummary("Sure") == "", "model summary: one word is a failure")
check(BrainSummaryText.plainText(fromBody: "## H\n- [[A|B]] and **c**") == "B and c", "plain text strips markup")

// MARK: Stub kind inference

let hubPage = makePage("Hub", body: """
## People
- [[Priya]]

## Notes
- Works at [[Globex]] since May.
- Met Sarah at [[Blue Bottle]] cafe.
- Something about [[Mystery]].
- Had coffee with my friend [[Tom]].
""")
check(BrainLintChecks.inferredKindForLinkTarget("Priya", onPage: hubPage) == .person, "kind from section heading")
check(BrainLintChecks.inferredKindForLinkTarget("Globex", onPage: hubPage) == .organization, "kind from 'works at'")
check(BrainLintChecks.inferredKindForLinkTarget("Blue Bottle", onPage: hubPage) == .place, "nearest context word wins ('cafe' over 'met')")
check(BrainLintChecks.inferredKindForLinkTarget("Mystery", onPage: hubPage) == .note, "no context → note")
check(BrainLintChecks.inferredKindForLinkTarget("tom", onPage: hubPage) == .person, "target matched ignoring case")
check(BrainLintChecks.kindNamedByHeading("Colleagues") == .person, "plural heading singularised")
check(BrainLintChecks.kindNamedByHeading("Notes") == nil, "'Notes' heading says nothing")

// MARK: Link rewriting

let rewritten = BrainLinkRewriter.rewriteLinks(in: "a [[X]] b [[Y|z]] c [[not\na link]]") { inner in
    inner == "X" ? "W" : nil
}
check(rewritten == "a [[W]] b [[Y|z]] c [[not\na link]]", "rewriter touches only accepted links")

// MARK: Merge

let shortSarah = makePage(
    "Sarah", kind: .person, summary: "", aliases: ["Sar"], tags: ["work"], sources: ["conversation 2026-09-01"],
    createdDate: olderDate,
    body: "## Facts\n- Likes tea.\n- Has a dog named Rex.\n\n## Meetings\n- Met on Monday."
)
let fullSarah = makePage(
    "Sarah Chen", kind: .person, summary: "Design lead on Atlas.", aliases: ["S. Chen"], tags: ["Work", "design"],
    sources: ["atlas-spec.pdf"],
    body: "## Facts\n- likes tea\n- Leads design for [[Atlas]].\n- Prefers async updates over meetings."
)
let pageLinkingToShortSarah = makePage("Atlas", kind: .project, body: "## Team\n- [[Sarah]] leads design; see [[Sarah#Facts]] and [[Sarah|her notes]].")
let lockedPageLinking = makePage("Locked", isLocked: true, body: "- [[Sarah]]")
let unrelatedPage = makePage("Unrelated", body: "- [[Sarah Chen]]")
let mergePages = [shortSarah, fullSarah, pageLinkingToShortSarah, lockedPageLinking, unrelatedPage]
let mergeResult = BrainPageMerger.merge(
    shortSarah, fullSarah,
    allPages: mergePages,
    resolvePage: BrainLintChecks.makeResolver(pages: mergePages),
    today: referenceDate
)
check(mergeResult?.keptPage.slug == "people/sarah-chen", "merge keeps the page with more content")
check(mergeResult?.removedPage.slug == "people/sarah", "merge removes the smaller page")
let mergedBody = mergeResult?.keptPage.body ?? ""
check(mergedBody.components(separatedBy: "tea").count == 2, "merge dedupes bullets ignoring case/punctuation")
check(mergedBody.contains("- Has a dog named Rex."), "merge folds new bullets into the shared section")
check(mergedBody.contains("## Meetings\n- Met on Monday."), "merge appends sections the kept page lacks")
check(mergeResult?.keptPage.aliases == ["S. Chen", "Sarah", "Sar"], "merge unions aliases + removed title")
check(mergeResult?.keptPage.tags == ["Work", "design"], "merge unions tags ignoring case")
check(mergeResult?.keptPage.sources == ["atlas-spec.pdf", "conversation 2026-09-01", "brain check"], "merge unions sources")
check(mergeResult?.keptPage.summary == "Design lead on Atlas.", "merge keeps the non-empty summary")
check(mergeResult?.keptPage.createdDate == olderDate, "merge keeps the earlier created date")
let rewrittenAtlas = mergeResult?.plan.pagesToWrite.first { $0.slug == "projects/atlas" }
check(rewrittenAtlas?.body == "## Team\n- [[Sarah Chen|Sarah]] leads design; see [[Sarah Chen#Facts|Sarah]] and [[Sarah Chen|her notes]].", "merge re-points links, keeping display text and headings")
check(mergeResult?.plan.pagesToWrite.contains { $0.slug == "notes/locked" } == false, "merge leaves locked pages alone")
check(mergeResult?.plan.pagesToWrite.contains { $0.slug == "notes/unrelated" } == false, "merge doesn't touch pages already linking the kept page")
check(mergeResult?.plan.pagesToWrite.contains { $0.slug == "people/sarah" } == false, "merge plan never writes the removed page")
check(mergeResult?.plan.createdSlugs.isEmpty == true, "merge creates nothing")
check(isNil(BrainPageMerger.merge(shortSarah, makePage("Other", isLocked: true), allPages: [], resolvePage: { _ in nil }, today: referenceDate)), "merge refuses locked pages")
check(isNil(BrainPageMerger.merge(mePage, shortSarah, allPages: [], resolvePage: { _ in nil }, today: referenceDate)), "merge refuses the me page")
let equalA = makePage("Equal A", createdDate: referenceDate, body: "same")
let equalB = makePage("Equal B", createdDate: olderDate, body: "same")
check(BrainPageMerger.pageToKeep(equalA, equalB).slug == equalB.slug, "equal content → older page kept")

// MARK: Split

let splitPlan = BrainPageSplitter.split(oversizedPage, resolvePage: { _ in nil }, today: referenceDate)
check(!isNil(splitPlan), "split produces a plan")
if let splitPlan {
    let splitParent = splitPlan.pagesToWrite.first { $0.slug == oversizedPage.slug }
    let childPages = splitPlan.pagesToWrite.filter { $0.slug != oversizedPage.slug }
    check(childPages.count == 1, "split moves just enough (one of two equal halves)")
    check(childPages.first?.title == "Big — One", "child title is '<Title> — <Section>'")
    check(childPages.first?.kind == .topic, "child keeps the parent's kind")
    check(childPages.first?.body.hasPrefix("## One\n- a fact") == true, "child holds the moved section")
    check(splitParent?.body.contains("## One\nSee [[Big — One]].") == true, "parent links to the child in place of the section")
    check((splitParent?.body.count ?? .max) <= BrainPageSplitter.targetParentBodyCharacters, "parent ends under the target")
    check(splitPlan.createdSlugs == Set(childPages.map(\.slug)), "children recorded as created")
    check(BrainLintChecks.oversizedPageIssues(in: splitPlan.pagesToWrite).isEmpty, "nothing oversized after the split")
}

let singleSectionPage = makePage("Log", kind: .me, body: "## Notes\n" + String(repeating: "- an older note line that is fairly long\n", count: 550) + "- the newest note")
let singleSectionPlan = BrainPageSplitter.split(singleSectionPage, resolvePage: { _ in nil }, today: referenceDate)
if let singleSectionPlan {
    let splitParent = singleSectionPlan.pagesToWrite.first { $0.slug == "me" }
    let child = singleSectionPlan.pagesToWrite.first { $0.slug != "me" }
    check(child?.title == "Me — Earlier Notes", "single-section split: earlier lines child")
    check(child?.kind == .note, "children of the me page are notes")
    check(splitParent?.body.hasPrefix("## Notes\nEarlier: [[Me — Earlier Notes]]") == true, "single-section split: parent links first")
    check(splitParent?.body.hasSuffix("- the newest note") == true, "single-section split keeps the newest lines")
    check((splitParent?.body.count ?? .max) <= BrainPageSplitter.targetParentBodyCharacters, "single-section parent under the target")
} else {
    check(false, "single-section split produces a plan")
}

let existingChild = makePage("Big — One", kind: .topic, body: "## One\n- already moved")
let splitIntoExisting = BrainPageSplitter.split(oversizedPage, resolvePage: BrainLintChecks.makeResolver(pages: [existingChild]), today: referenceDate)
let extendedChild = splitIntoExisting?.pagesToWrite.first { $0.slug == existingChild.slug }
check(extendedChild?.body.hasPrefix("## One\n- already moved\n- a fact") == true, "split extends an earlier child instead of clobbering it")
check(splitIntoExisting?.createdSlugs.isEmpty == true, "extended child isn't recorded as created")
check(isNil(BrainPageSplitter.split(makePage("Locked Big", isLocked: true, body: "## A\nx\n## B\ny"), resolvePage: { _ in nil }, today: referenceDate)), "split refuses locked pages")

// MARK: Whole lint

let wholeBrain = [mePage, sarahChen, atlas, makePage("Sarah", kind: .person, body: "- [[Atlas]]"), makePage("Other", body: "- [[Nowhere]]")]
let wholeIssues = lint(wholeBrain)
check(Set(wholeIssues.map(\.id)).count == wholeIssues.count, "issue ids are unique")
check(wholeIssues.first?.kind == .brokenLink, "issues sorted by kind")

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
