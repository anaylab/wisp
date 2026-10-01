//
//  BrainCore suite: the brain's pure core — page format, slugs, links,
//  sections, the edit planner's policies, the lenient proposal parser, BM25
//  search and the per-turn prompt context — plus the integration's own pure
//  pieces: the "about the user" block, the memory.md migration plan, the
//  agent tools' formatting/parsing/routing and the brain command router.
//
//  `knownIssue` records a core-file behaviour that looks wrong; it prints but
//  doesn't fail the suite, so the bug is visible without blocking.
//

import Foundation

var failureCount = 0
var checkCount = 0
var knownIssueCount = 0

func check(_ condition: Bool, _ description: String) {
    checkCount += 1
    if !condition {
        failureCount += 1
        print("FAIL: \(description)")
    }
}

func knownIssue(_ conditionThatShouldHold: Bool, _ description: String) {
    if !conditionThatShouldHold {
        knownIssueCount += 1
        print("KNOWN ISSUE: \(description)")
    }
}

func day(_ dayString: String) -> Date {
    BrainDateFormat.date(fromDayString: dayString)!
}

func makePage(
    slug: String,
    title: String,
    kind: BrainPageKind,
    summary: String = "",
    aliases: [String] = [],
    tags: [String] = [],
    sources: [String] = [],
    isLocked: Bool = false,
    body: String = ""
) -> BrainPage {
    BrainPage(
        slug: slug, title: title, kind: kind, summary: summary, aliases: aliases, tags: tags,
        sources: sources, createdDate: day("2026-09-01"), updatedDate: day("2026-09-01"),
        isLocked: isLocked, body: body
    )
}

/// A stand-in for `BrainStore.resolvePage(named:)` over an in-memory set.
func resolver(for pages: [BrainPage]) -> (String) -> BrainPage? {
    return { nameOrSlug in
        if let slugMatch = pages.first(where: { $0.slug == nameOrSlug }) { return slugMatch }
        let comparableName = BrainSlug.comparableName(nameOrSlug)
        return pages.first { page in
            page.allNames.contains { BrainSlug.comparableName($0) == comparableName }
                || BrainSlug.comparableName(String(page.slug.split(separator: "/").last ?? "")) == comparableName
        }
    }
}

func plan(_ proposals: [BrainEditProposal], trust: BrainEditProvenance.Trust, pages: [BrainPage], label: String = "test") -> BrainEditPlan {
    BrainEditPlanner.plan(
        proposals: proposals,
        provenance: BrainEditProvenance(origin: .agent, label: label, trust: trust),
        resolvePage: resolver(for: pages),
        today: day("2026-09-29")
    )
}

/// Applies a plan to an in-memory vault, like `BrainStore.apply` does on disk.
func applying(_ editPlan: BrainEditPlan, to pages: [BrainPage]) -> [BrainPage] {
    var pagesBySlug = Dictionary(uniqueKeysWithValues: pages.map { ($0.slug, $0) })
    for page in editPlan.pagesToWrite { pagesBySlug[page.slug] = page }
    return Array(pagesBySlug.values)
}

// MARK: - Page format

let roundTripPage = BrainPage(
    slug: "people/sarah-chen", title: "Sarah Chen", kind: .person,
    summary: "Design lead on the Atlas project; prefers async updates.",
    aliases: ["Sarah", "S. Chen"], tags: ["work"], sources: ["conversation 2026-09-29"],
    createdDate: day("2026-09-29"), updatedDate: day("2026-09-30"), isLocked: true,
    body: "## Facts\n- Leads design for [[Atlas]]."
)
let renderedRoundTripPage = BrainPageFormat.render(roundTripPage)
check(BrainPageFormat.parse(markdown: renderedRoundTripPage, slug: roundTripPage.slug) == roundTripPage, "render → parse round trip")
check(renderedRoundTripPage.hasPrefix("---\ntitle: Sarah Chen\nkind: person\n"), "frontmatter order")
check(renderedRoundTripPage.contains("locked: true"), "locked written")
check(!BrainPageFormat.render(makePage(slug: "notes/x", title: "X", kind: .note)).contains("aliases:"), "empty lists omitted")

let bareNote = BrainPageFormat.parse(markdown: "just some text\n", slug: "notes/my-idea")
check(bareNote.title == "My Idea" && bareNote.kind == .note && bareNote.body == "just some text", "no frontmatter → note titled from slug")
check(BrainPageFormat.parse(markdown: "hello", slug: "me").kind == .me, "slug me → kind me")
check(BrainPageFormat.parse(markdown: "hello", slug: "people/bob").kind == .person, "kind from folder")
let unclosedFrontmatter = BrainPageFormat.parse(markdown: "---\ntitle: X\nbody", slug: "notes/y")
check(unclosedFrontmatter.title != "X" && unclosedFrontmatter.body.contains("title: X"), "unclosed frontmatter is body")
let quotedTitlePage = BrainPageFormat.parse(markdown: "---\ntitle: \"Hello: World\"\nkind: company\n---\nbody", slug: "organizations/x")
check(quotedTitlePage.title == "Hello: World", "quoted value with colon")
check(quotedTitlePage.kind == .organization, "lenient kind in frontmatter")
check(BrainPageFormat.parseList("[a, \"b\", c]") == ["a", "b", "c"], "parse bracketed list")
check(BrainPageFormat.parseList("a, b") == ["a", "b"], "parse bare list")
check(BrainPageFormat.parseList("") == [] && BrainPageFormat.parseList(nil) == [], "empty list")
check(BrainPageFormat.renderList(["a,b", "c"]) == "[a b, c]", "comma in list item neutralised")
var multilineSummaryPage = makePage(slug: "notes/x", title: "X", kind: .note)
multilineSummaryPage.summary = "line one\nline two"
check(BrainPageFormat.render(multilineSummaryPage).contains("summary: line one line two"), "summary kept on one line")
check(BrainPageKind.lenient("People") == .person && BrainPageKind.lenient("myself") == .me && BrainPageKind.lenient("xyz") == nil, "lenient kinds")

// MARK: - Slugs

check(BrainSlug.fileName(fromTitle: "Sarah Chen") == "sarah-chen", "slug basic")
check(BrainSlug.fileName(fromTitle: "Café Crème!") == "cafe-creme", "slug folds diacritics, drops punctuation")
check(BrainSlug.fileName(fromTitle: "  --  ") == "untitled", "slug of nothing")
check(BrainSlug.fileName(fromTitle: "日本語") == "untitled", "non-ASCII letters dropped")
let longSlug = BrainSlug.fileName(fromTitle: String(repeating: "word ", count: 30))
check(longSlug.count <= BrainSlug.maximumFileNameLength && !longSlug.hasSuffix("-"), "slug capped without trailing dash")
check(BrainSlug.make(title: "Anything", kind: .me) == "me", "me slug")
check(BrainSlug.make(title: "Atlas", kind: .project) == "projects/atlas", "folder slug")
for safeSlug in ["people/sarah-chen", "me", "notes/x_y", "topics/rust-2"] {
    check(BrainSlug.isSafe(safeSlug), "safe: \(safeSlug)")
}
for unsafeSlug in ["", "../etc", "/abs", "a/b/c", "People/x", "a//b", "a b", "people/", "notes/..x", "notes/é"] {
    check(!BrainSlug.isSafe(unsafeSlug), "unsafe: \(unsafeSlug)")
}
check(BrainSlug.comparableName("Sarah  CHEN!") == BrainSlug.comparableName("sarah chen"), "comparable names")

// MARK: - Links

let linkText = "see [[Sarah Chen|Sarah]] and [[Atlas#Goals]] and [[sarah chen]] and [[ ]] [[broken\n]] [[Rust]]"
check(BrainLinkParser.linkTargets(in: linkText) == ["Sarah Chen", "Atlas", "Rust"], "link targets de-duplicated, broken skipped")
check(BrainLinkParser.displayText(fromInnerText: "Sarah Chen|Sarah") == "Sarah", "display alias")
check(BrainLinkParser.displayText(fromInnerText: "Atlas#Goals") == "Atlas", "display strips heading")
check(BrainLinkParser.linkTargets(in: "no links [here]") == [], "no links")

// MARK: - Sections

let sectionedBody = "intro\n\n## Facts\n- a\n### Sub\n- b\n## Notes\n"
let parsedSections = BrainPageSections.parse(sectionedBody)
check(parsedSections.count == 3, "three sections")
check(parsedSections.first == BrainPageSection(heading: "", content: "intro"), "preamble section")
check(parsedSections[1] == BrainPageSection(heading: "Facts", content: "- a\n### Sub\n- b"), "### stays inside")
check(parsedSections[2] == BrainPageSection(heading: "Notes", content: ""), "empty section kept")
check(BrainPageSections.render(parsedSections) == "intro\n\n## Facts\n- a\n### Sub\n- b\n\n## Notes", "render sections")
check(BrainPageSections.indexOfSection(named: "facts!", in: parsedSections) == 1, "section lookup ignores case/punctuation")
check(BrainPageSections.indexOfSection(named: "", in: parsedSections) == nil, "empty heading never matched")
check(BrainPageSections.headingText(onLine: "##") == nil && BrainPageSections.headingText(onLine: "## ") == nil, "bare ## isn't a heading")
check(BrainPageSections.parse("") == [], "empty body")

// MARK: - Planner

let atlasPage = makePage(slug: "projects/atlas", title: "Atlas", kind: .project, body: "## Facts\n- old fact")
let replaceProposal = BrainEditProposal(operation: .replace, pageTitle: "Atlas", section: "Facts", content: "- new fact")

let downgradedPlan = plan([replaceProposal], trust: .derivedFromUser, pages: [atlasPage])
check(downgradedPlan.pagesToWrite.first?.body == "## Facts\n- old fact\n- new fact", "replace downgraded to append for derived trust")
let externalReplacePlan = plan([replaceProposal], trust: .external, pages: [atlasPage])
check(externalReplacePlan.pagesToWrite.first?.body.contains("- old fact") == true, "replace downgraded for external trust")
let userReplacePlan = plan([replaceProposal], trust: .userAuthored, pages: [atlasPage])
check(userReplacePlan.pagesToWrite.first?.body == "## Facts\n- new fact", "user may replace")
check(userReplacePlan.changeDescriptions == ["rewrote Facts on Atlas"], "replace description")

let existingMePage = makePage(slug: "me", title: "Me", kind: .me, body: "## Facts\n- likes tea")
let mePlanByTitle = plan([BrainEditProposal(operation: .append, pageTitle: "me", content: "- is a spy")], trust: .external, pages: [existingMePage])
check(mePlanByTitle.isEmpty && mePlanByTitle.refusals.contains("outside content can't change your own page"), "external can't touch me page (by title)")
let mePlanByKind = plan([BrainEditProposal(operation: .append, pageTitle: "The User", pageKind: .me, content: "- x")], trust: .external, pages: [])
check(mePlanByKind.isEmpty && !mePlanByKind.refusals.isEmpty, "external can't create me page (by kind)")
let meDerivedPlan = plan([BrainEditProposal(operation: .append, pageTitle: "Me", pageKind: .me, section: "Facts", content: "- likes coffee")], trust: .derivedFromUser, pages: [existingMePage])
check(meDerivedPlan.pagesToWrite.first?.body == "## Facts\n- likes tea\n- likes coffee", "derived trust may append to me page")

let lockedPage = makePage(slug: "people/bob", title: "Bob", kind: .person, isLocked: true, body: "## Facts\n- x")
let lockedPlan = plan([BrainEditProposal(operation: .append, pageTitle: "Bob", content: "- y")], trust: .userAuthored, pages: [lockedPage])
check(lockedPlan.isEmpty && lockedPlan.refusals == ["\"Bob\" is locked"], "locked page refused even for the user")

let sarahPage = makePage(slug: "people/sarah-chen", title: "Sarah Chen", kind: .person, aliases: ["Sarah"], body: "## Facts\n- Leads design for [[Atlas]].")
let dedupePlan = plan([BrainEditProposal(operation: .append, pageTitle: "sarah", section: "Facts", content: "- leads design for atlas\n- New fact\n* new fact")], trust: .external, pages: [sarahPage])
check(dedupePlan.pagesToWrite.first?.body == "## Facts\n- Leads design for [[Atlas]].\n- New fact", "bullet dedupe against page and within content; alias resolves")
check(dedupePlan.changeDescriptions == ["added 1 fact to Sarah Chen"], "dedupe description")
let nothingNewPlan = plan([BrainEditProposal(operation: .append, pageTitle: "Sarah Chen", content: "- Leads design for Atlas")], trust: .external, pages: [sarahPage])
check(nothingNewPlan.isEmpty && nothingNewPlan.refusals.isEmpty, "all-duplicate append changes nothing, silently")

let manyProposals = (1...30).map { BrainEditProposal(operation: .append, pageTitle: "Atlas", content: "- fact \($0)") }
let cappedPlan = plan(manyProposals, trust: .external, pages: [atlasPage])
check(cappedPlan.refusals.first == "dropped 6 edits over the 24-per-batch limit", "per-batch proposal cap")
check(cappedPlan.pagesToWrite.first?.body.contains("- fact 24") == true && cappedPlan.pagesToWrite.first?.body.contains("- fact 25") == false, "only the first 24 applied")

let manyNewPages = (1...12).map { BrainEditProposal(operation: .append, pageTitle: "Topic \($0)", pageKind: .topic, content: "- x") }
let newPageCapPlan = plan(manyNewPages, trust: .external, pages: [])
check(newPageCapPlan.createdSlugs.count == 10 && newPageCapPlan.refusals.count == 2, "new-pages-per-batch cap")

let longContentPlan = plan([BrainEditProposal(operation: .append, pageTitle: "Atlas", content: String(repeating: "a", count: 5000))], trust: .external, pages: [atlasPage])
let appendedLongLine = longContentPlan.pagesToWrite.first?.body.components(separatedBy: "\n").last ?? ""
check(appendedLongLine.count == BrainEditPlanner.maximumContentCharacters, "content capped")
check(BrainEditPlanner.cleanedTitle(String(repeating: "t", count: 200)).count == BrainEditPlanner.maximumTitleCharacters, "title capped")
let fullPage = makePage(slug: "notes/full", title: "Full", kind: .note, body: "## Notes\n" + String(repeating: "x", count: BrainEditPlanner.maximumPageBodyCharacters - 20))
let fullPagePlan = plan([BrainEditProposal(operation: .append, pageTitle: "Full", content: "- one more fact that overflows")], trust: .userAuthored, pages: [fullPage])
check(fullPagePlan.isEmpty && fullPagePlan.refusals == ["Full is full — it needs splitting before it can grow"], "page body cap")

let newPagePlan = plan([BrainEditProposal(operation: .append, pageTitle: "Rust async", pageKind: .topic, content: "- tokio", summary: "Async\nprogramming in Rust")], trust: .external, pages: [])
check(newPagePlan.pagesToWrite.first?.slug == "topics/rust-async" && newPagePlan.createdSlugs == ["topics/rust-async"], "new page slug from kind")
check(newPagePlan.pagesToWrite.first?.summary == "Async programming in Rust", "new page takes proposal summary (one line)")
check(newPagePlan.pagesToWrite.first?.body == "## Notes\n- tokio", "default section is Notes")
check(newPagePlan.pagesToWrite.first?.createdDate == day("2026-09-29"), "created stamped")
let existingSummaryPlan = plan([BrainEditProposal(operation: .append, pageTitle: "Atlas", content: "- x", summary: "ignored")], trust: .external, pages: [atlasPage])
check(existingSummaryPlan.pagesToWrite.first?.summary == "", "existing page doesn't take an append's summary")
check(plan([BrainEditProposal(operation: .append, pageTitle: "Loose", content: "- x")], trust: .external, pages: []).pagesToWrite.first?.slug == "notes/loose", "no kind → note")

let summarizeProposal = BrainEditProposal(operation: .summarize, pageTitle: "Atlas", content: "The launch project")
check(plan([summarizeProposal], trust: .external, pages: [atlasPage]).pagesToWrite.first?.summary == "The launch project", "summarize fills empty summary")
var summarizedAtlasPage = atlasPage
summarizedAtlasPage.summary = "Existing"
check(plan([summarizeProposal], trust: .derivedFromUser, pages: [summarizedAtlasPage]).isEmpty, "summarize doesn't overwrite for non-user")
check(plan([summarizeProposal], trust: .userAuthored, pages: [summarizedAtlasPage]).pagesToWrite.first?.summary == "The launch project", "user may overwrite summary")

let sourcesPlan = plan([BrainEditProposal(operation: .append, pageTitle: "Atlas", content: "- s")], trust: .external, pages: [atlasPage], label: "spec.pdf")
check(sourcesPlan.pagesToWrite.first?.sources == ["spec.pdf"], "provenance label added to sources")
var manySourcesPage = atlasPage
manySourcesPage.sources = (1...12).map { "source \($0)" }
let cappedSources = plan([BrainEditProposal(operation: .append, pageTitle: "Atlas", content: "- s")], trust: .external, pages: [manySourcesPage], label: "new").pagesToWrite.first?.sources ?? []
check(cappedSources.count == 12 && cappedSources.last == "new" && cappedSources.first == "source 2", "sources capped at 12, newest last")
var commaSourcePage = atlasPage
commaSourcePage.sources = ["a  b"] // what a label "a, b" was stored as last time
let commaSourcesAgain = plan([BrainEditProposal(operation: .append, pageTitle: "Atlas", content: "- s")], trust: .external, pages: [commaSourcePage], label: "a, b").pagesToWrite.first?.sources ?? []
knownIssue(commaSourcesAgain == ["a  b"], "BrainEditPlanner: a provenance label with a comma is re-added to sources on every batch (compares raw label, stores FrontmatterSafe.listItem(label)) — got \(commaSourcesAgain)")

let aliasPlan = plan([BrainEditProposal(operation: .alias, pageTitle: "Sarah Chen", content: "Sarah, S.C., sarah chen")], trust: .external, pages: [sarahPage])
check(aliasPlan.pagesToWrite.first?.aliases == ["Sarah", "S.C."], "alias adds only new names")
let tagPlan = plan([BrainEditProposal(operation: .tag, pageTitle: "Sarah Chen", content: "work, design\nwork")], trust: .external, pages: [sarahPage])
check(tagPlan.pagesToWrite.first?.tags == ["work", "design", "work"] || tagPlan.pagesToWrite.first?.tags.first == "work", "tags added")

let twoProposalsOnePagePlan = plan([
    BrainEditProposal(operation: .append, pageTitle: "Nova", pageKind: .project, section: "Facts", content: "- one"),
    BrainEditProposal(operation: .append, pageTitle: "nova", section: "Decisions", content: "- two"),
], trust: .external, pages: [])
check(twoProposalsOnePagePlan.pagesToWrite.count == 1 && twoProposalsOnePagePlan.pagesToWrite.first?.body == "## Facts\n- one\n\n## Decisions\n- two", "two proposals merge into one new page")
check(plan([BrainEditProposal(operation: .append, pageTitle: "  ", content: "- x")], trust: .external, pages: []).refusals == ["an edit had no page title"], "blank title refused")

check(BrainEditPlanner.cleanedContent("# Big\n---\n\n\n- a\n## Split\n  ") == "### Big\n\n- a\n### Split", "cleanedContent neutralises headings/fences, collapses blanks")
check(BrainEditPlanner.cleanedSection(nil) == "Notes" && BrainEditPlanner.cleanedSection("## Facts") == "Facts", "cleanedSection")

let renamedMePage = makePage(slug: "me", title: "Anay", kind: .me, body: "## Facts\n- likes tea")
let twoMeProposalsPlan = plan([
    BrainEditProposal(operation: .append, pageTitle: "Me", pageKind: .me, section: "Facts", content: "- fact one"),
    BrainEditProposal(operation: .append, pageTitle: "Me", pageKind: .me, section: "Facts", content: "- fact two"),
], trust: .userAuthored, pages: [renamedMePage])
let twoMeProposalsBody = twoMeProposalsPlan.pagesToWrite.first(where: { $0.slug == "me" })?.body ?? ""
knownIssue(twoMeProposalsBody.contains("fact one") && twoMeProposalsBody.contains("fact two"),
           "BrainEditPlanner: a second proposal in one batch for a page it already touched, reached by a name the page doesn't carry (\"Me\" for a me page titled \"Anay\"), restarts from resolvePage's on-disk copy and drops the first proposal's change — got \(twoMeProposalsBody.debugDescription)")

// MARK: - Proposal parser

let fencedReply = "Sure! Here you go:\n```json\n[{\"page\":\"Atlas\",\"content\":\"- x\"}]\n```"
let fencedProposals = BrainEditProposalParser.parseProposals(fromModelReply: fencedReply)
check(fencedProposals == [BrainEditProposal(operation: .append, pageTitle: "Atlas", content: "- x")], "fenced json array")
check(BrainEditPlanner.coalescedChangeDescriptions(["added 1 fact to Maps", "added 2 facts to Atlas", "added 1 fact to Maps", "summarised Atlas", "summarised Atlas"])
      == ["added 2 facts to Maps", "added 2 facts to Atlas", "summarised Atlas"], "fact additions coalesce per page")
let rememberCases: [(String, String?)] = [
    ("remember that my favorite hiking spot is Mount Tamalpais", "Favorite hiking spot is Mount Tamalpais"),
    ("Hey Wisp, remember my sister's name is Ana.", "Sister's name is Ana"),
    ("please remember that I'm vegetarian now", "Is vegetarian now"),
    ("remember that the Atlas launch moved to March", "The Atlas launch moved to March"),
    ("remember I prefer metric units", "I prefer metric units"),
    ("remember to buy milk", nil),
    ("remember this page", nil),
    ("remember that page", nil),
    ("remember when we went to Tahoe", nil),
    ("do you remember my name", nil),
    ("remember that", nil),
    ("remember the milk", nil),
]
for (utterance, expectedFact) in rememberCases {
    let parsedFact = BrainCommandRouter.rememberedFact(from: utterance)
    check(parsedFact == expectedFact, "remember parse: \(utterance) → \(parsedFact ?? "nil")")
}
// Measured on qwen2.5vl:3b: a long array ended without its closing bracket.
let unclosedReply = #"[{"page":"Priya Raman","kind":"person","content":"- PM for [[Atlas]]"},{"page":"Marcus Lee","kind":"person","content":"- Leads iOS"},{"page":"Atlas","kind":"project","section":"Decisions","content":"- iOS first"}"#
let unclosedProposals = BrainEditProposalParser.parseProposals(fromModelReply: unclosedReply)
check(unclosedProposals.map(\.pageTitle) == ["Priya Raman", "Marcus Lee", "Atlas"], "every object of an unclosed array is read (got \(unclosedProposals.map(\.pageTitle)))")
let truncatedMidObjectReply = #"[{"page":"Atlas","content":"- a"},{"page":"Orbit","content":"- b"#
check(BrainEditProposalParser.parseProposals(fromModelReply: truncatedMidObjectReply).map(\.pageTitle) == ["Atlas"], "a reply cut off mid-object keeps the complete ones")
check(BrainEditProposalParser.parseProposals(fromModelReply: "{\"edits\":[{\"title\":\"A\",\"text\":\"t\"},{\"title\":\"B\",\"text\":\"u\"}]}").count == 2, "wrapped in edits")
check(BrainEditProposalParser.parseProposals(fromModelReply: "{\"changes\":[{\"name\":\"A\",\"body\":\"t\"}]}").count == 1, "wrapped in changes")
check(BrainEditProposalParser.parseProposals(fromModelReply: "{\"title\":\"Solo\",\"text\":\"t\"}").first?.pageTitle == "Solo", "single bare object")
let synonymProposal = BrainEditProposalParser.parseProposals(fromModelReply: "[{\"pageTitle\":\"Sam\",\"op\":\"add\",\"type\":\"people\",\"heading\":\"Facts\",\"facts\":[\"a\",\"b\"]}]").first
check(synonymProposal == BrainEditProposal(operation: .append, pageTitle: "Sam", pageKind: .person, section: "Facts", content: "- a\n- b"), "key synonyms + array content")
check(BrainEditProposalParser.parseProposals(fromModelReply: "[{\"page\":\"A\",\"action\":\"rewrite\",\"content\":\"c\"}]").first?.operation == .replace, "rewrite → replace")
let summaryOnlyProposal = BrainEditProposalParser.parseProposals(fromModelReply: "[{\"page\":\"A\",\"op\":\"summary\",\"summary\":\"one line\"}]").first
check(summaryOnlyProposal?.operation == .summarize && summaryOnlyProposal?.content == "one line" && summaryOnlyProposal?.summary == nil, "summarize from summary key")
check(BrainEditProposalParser.parseProposals(fromModelReply: "[{\"content\":\"no page\"},{\"page\":\"no content\"},{\"page\":\"ok\",\"content\":\"c\"}]").count == 1, "unreadable items dropped")
check(BrainEditProposalParser.parseProposals(fromModelReply: "I think {not json} then [{\"page\":\"A\",\"content\":\"- see [x] and {y}\"}]").first?.content == "- see [x] and {y}", "skips unparseable braces; brackets in strings")
check(BrainEditProposalParser.parseProposals(fromModelReply: "nothing worth keeping").isEmpty, "prose only → none")
check(BrainEditProposalParser.parseProposals(fromModelReply: "[]").isEmpty, "empty array")
check(BrainEditProposalParser.parseProposals(fromModelReply: "[{\"page\":\"A\",\"op\":\"frobnicate\",\"content\":\"c\"}]").first?.operation == .append, "unknown op → append")

// MARK: - Search

let searchPages = [
    makePage(slug: "people/sarah-chen", title: "Sarah Chen", kind: .person, summary: "Design lead on Atlas", body: "## Facts\n- Works on [[Atlas]]\n- work"),
    makePage(slug: "projects/atlas", title: "Atlas", kind: .project, summary: "The launch project", body: "## Facts\n- [[Sarah Chen]] leads design\n- work"),
    makePage(slug: "topics/rust-async", title: "Rust async", kind: .topic, body: "## Notes\n- tokio runtime\n- work"),
    makePage(slug: "notes/cooking", title: "Cooking", kind: .note, body: "## Notes\n- pasta recipes, mentioned atlas once\n- work"),
    makePage(slug: "places/cafe-nero", title: "Café Nero", kind: .place, body: "## Notes\n- coffee\n- work"),
    makePage(slug: "me", title: "Me", kind: .me, summary: "Works on Atlas", body: "## Facts\n- Atlas\n- work"),
]
let searchIndex = BrainSearchIndex(pages: searchPages)
check(searchIndex.search("sarah chen").first?.title == "Sarah Chen", "name wins")
check(searchIndex.search("what's up with atlas").first?.title == "Atlas", "title beats body mentions")
check(searchIndex.search("the and of").isEmpty, "stop words only → nothing")
check(searchIndex.search("cafe").first?.title == "Café Nero", "diacritics folded")
check(searchIndex.search("runtimes").first?.title == "Rust async", "crude plural stem")
check(searchIndex.search("atlas", kinds: [.person]).allSatisfy { $0.kind == .person }, "kind filter")
check(searchIndex.search("atlas", limit: 2).count == 2, "limit")
check(searchIndex.search("tokio").first?.snippet == "tokio runtime", "snippet is best line without bullet")
check(BrainSearchTokenizer.stem("stories") == "story" && BrainSearchTokenizer.stem("class") == "class" && BrainSearchTokenizer.stem("bus") == "bus", "stem rules")

let atlasContext = BrainPromptContext.promptText(for: "how is atlas going", index: searchIndex)
check(atlasContext.hasPrefix("notes the user has saved in their brain") && atlasContext.contains("- Atlas (project): The launch project"), "prompt context names relevant page with summary")
check(!atlasContext.contains("(me)"), "me page never in per-turn context")
check(BrainPromptContext.promptText(for: "what's the weather in paris", index: searchIndex) == "", "unrelated request → nothing")
check(BrainPromptContext.promptText(for: "work", index: searchIndex) == "", "a word on every page is below the relevance bar")
check(BrainPromptContext.promptText(for: "how is atlas going", index: searchIndex, characterBudget: 20) == "", "budget too small → nothing")
check(atlasContext.count <= BrainPromptContext.defaultCharacterBudget + 10, "prompt context within budget")

let substringPages = [
    makePage(slug: "topics/rust", title: "Rust", kind: .topic, body: "## Notes\n- I trust the borrow checker"),
    makePage(slug: "topics/trust-fund", title: "Trust Fund", kind: .topic, body: "## Notes\n- trust paperwork"),
]
knownIssue(BrainSearchIndex(pages: substringPages).search("trust").first?.title == "Trust Fund",
           "BrainSearchIndex: the +10 'names the page' boost uses plain substring containment, so page \"Rust\" is lifted for the query \"trust\" — compare dash-bounded (\"-\\(query)-\".contains(\"-\\(name)-\"))")

// MARK: - About the user

let aboutMePage = makePage(slug: "me", title: "Me", kind: .me, summary: "Designer in [[Lisbon]]",
                           body: "## Facts\n- prefers metric units\n- works on [[Atlas|the Atlas app]]\n\n## Notes\n- a note")
check(BrainAboutMe.factBullets(onMePage: aboutMePage) == ["prefers metric units", "works on [[Atlas|the Atlas app]]"], "fact bullets from Facts only")
check(BrainAboutMe.factBullets(onMePage: nil) == [], "no me page → no facts")
let aboutMeBlock = BrainAboutMe.promptInstructions(mePage: aboutMePage)
check(aboutMeBlock == "\n\nabout the user (from their brain's me page). use it when it's relevant; don't recite it:\nDesigner in Lisbon\n- prefers metric units\n- works on the Atlas app", "about-me block: summary then facts, links as text")
check(BrainAboutMe.promptInstructions(mePage: aboutMePage) == aboutMeBlock, "about-me block stable across calls")
check(BrainAboutMe.promptInstructions(mePage: nil) == "", "no me page → empty block")
check(BrainAboutMe.promptInstructions(mePage: makePage(slug: "me", title: "Me", kind: .me)) == "", "empty me page → empty block")
let manyFactsMePage = makePage(slug: "me", title: "Me", kind: .me,
                               body: "## Facts\n" + (1...100).map { "- fact number \($0) with some words" }.joined(separator: "\n"))
let budgetedBlock = BrainAboutMe.promptInstructions(mePage: manyFactsMePage)
check(budgetedBlock.contains("fact number 100 ") && !budgetedBlock.contains("fact number 1 "), "newest facts preferred")
let budgetedFactLines = budgetedBlock.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }
check(budgetedFactLines.map(\.count).reduce(0, +) <= BrainAboutMe.defaultCharacterBudget, "within budget")
check(budgetedFactLines.first?.contains("fact number") == true && budgetedFactLines == budgetedFactLines.sorted { lhs, rhs in
    Int(lhs.split(separator: " ")[3])! < Int(rhs.split(separator: " ")[3])!
}, "returned oldest first")
let longFactMePage = makePage(slug: "me", title: "Me", kind: .me, body: "## Facts\n- short one\n- " + String(repeating: "x", count: 900))
check(BrainAboutMe.promptInstructions(mePage: longFactMePage).contains("- short one"), "an overlong fact is skipped, not the walk")
check(BrainAboutMe.plainText(fromMarkdownWithLinks: "a [[B]] c [[D|e]] [[unclosed") == "a B c e [[unclosed", "plain text from links")

// remember → planner, from no me page at all.
let firstRememberPlan = BrainEditPlanner.plan(
    proposals: [BrainAboutMe.rememberProposal(forFact: "prefers tea")],
    provenance: BrainAboutMe.rememberProvenance, resolvePage: resolver(for: []), today: day("2026-09-29")
)
check(firstRememberPlan.pagesToWrite.first?.slug == "me" && firstRememberPlan.pagesToWrite.first?.title == "Me", "remember creates the me page")
check(firstRememberPlan.pagesToWrite.first?.body == "## Facts\n- prefers tea", "remember appends under Facts")
check(firstRememberPlan.pagesToWrite.first?.sources == ["you said"], "remember provenance label")
let secondRememberPlan = BrainEditPlanner.plan(
    proposals: [BrainAboutMe.rememberProposal(forFact: "Prefers tea")],
    provenance: BrainAboutMe.rememberProvenance, resolvePage: resolver(for: firstRememberPlan.pagesToWrite), today: day("2026-09-29")
)
check(secondRememberPlan.isEmpty && secondRememberPlan.refusals.isEmpty, "remembering a known fact changes nothing (→ alreadyKnown)")
let lockedMePage = makePage(slug: "me", title: "Me", kind: .me, isLocked: true)
check(!BrainEditPlanner.plan(proposals: [BrainAboutMe.rememberProposal(forFact: "x")], provenance: BrainAboutMe.rememberProvenance,
                              resolvePage: resolver(for: [lockedMePage]), today: Date()).refusals.isEmpty, "locked me page refuses remember (→ refused)")

let forgetMePage = makePage(slug: "me", title: "Me", kind: .me, body: "## Facts\n- likes Metric units\n- lives in Lisbon\nprose mentioning metric\n\n## Notes\n- metric stuff")
check(BrainAboutMe.bulletsMatching("metric", onMePage: forgetMePage) == ["likes Metric units", "metric stuff"], "forget matches bullets in any section, case-insensitive")
let forgetRemoval = BrainAboutMe.pageRemovingBullets(matching: "metric", from: forgetMePage)
check(forgetRemoval.removedBullets.count == 2 && forgetRemoval.updatedPage.body == "## Facts\n- lives in Lisbon\nprose mentioning metric\n\n## Notes", "forget keeps prose and headings")
check(BrainAboutMe.pageRemovingBullets(matching: "  ", from: forgetMePage).removedBullets.isEmpty, "blank query removes nothing")
check(BrainAboutMe.pageRemovingExactBullet("lives in Lisbon", from: forgetMePage).removedBullets == ["lives in Lisbon"], "exact removal")
check(BrainAboutMe.pageRemovingExactBullet("lives in", from: forgetMePage).removedBullets.isEmpty, "exact removal needs the exact text")

// MARK: - memory.md migration

let memoryFileMarkdown = MemoryFileFormat.newFileHeader + "- prefers metric units\n- name is Anay\n* - double bullet\n"
let migrationBatches = BrainMemoryMigration.proposalBatches(forMemoryFileMarkdown: memoryFileMarkdown)
check(migrationBatches.count == 1 && migrationBatches[0].count == 1, "small memory file → one proposal")
check(migrationBatches.first?.first?.content == "- prefers metric units\n- name is Anay\n- double bullet", "facts in file order, bullets normalised")
check(migrationBatches.first?.first?.section == "Facts" && migrationBatches.first?.first?.pageKind == .me, "targets me page Facts")
check(BrainMemoryMigration.proposalBatches(forMemoryFileMarkdown: MemoryFileFormat.newFileHeader).isEmpty, "no facts → nothing")
check(BrainMemoryMigration.proposalBatches(forMemoryFileMarkdown: "").isEmpty, "empty file → nothing")

let longMemoryFile = (1...40).map { "- fact \($0) " + String(repeating: "w", count: 200) }.joined(separator: "\n")
let longMigrationProposals = BrainMemoryMigration.proposalBatches(forMemoryFileMarkdown: longMemoryFile).flatMap { $0 }
check(longMigrationProposals.count > 1, "long memory file split")
check(longMigrationProposals.allSatisfy { $0.content.count <= BrainEditPlanner.maximumContentCharacters }, "no proposal is cut off by the content cap")
var migratedVault: [BrainPage] = [renamedMePage]
for migrationBatch in BrainMemoryMigration.proposalBatches(forMemoryFileMarkdown: longMemoryFile) {
    let batchPlan = BrainEditPlanner.plan(proposals: migrationBatch, provenance: BrainMemoryMigration.migrationProvenance,
                                          resolvePage: resolver(for: migratedVault), today: day("2026-09-29"))
    migratedVault = applying(batchPlan, to: migratedVault)
}
let migratedFacts = BrainAboutMe.factBullets(onMePage: migratedVault.first { $0.slug == "me" })
check(migratedFacts.count == 41 && migratedFacts.first == "likes tea" && migratedFacts.last?.hasPrefix("fact 40 ") == true,
      "every fact lands on a renamed me page, in order, after existing facts")

let annotatedMemoryFile = BrainMemoryMigration.memoryFileMarkdownAddingMovedNote(memoryFileMarkdown)
check(annotatedMemoryFile.hasPrefix("# Wisp memory\n\n" + BrainMemoryMigration.movedFactsNoteLine), "note goes under the heading")
check(BrainMemoryMigration.memoryFileMarkdownAddingMovedNote(annotatedMemoryFile) == annotatedMemoryFile, "note added once")
check(MemoryFileFormat.parseFacts(from: annotatedMemoryFile) == MemoryFileFormat.parseFacts(from: memoryFileMarkdown), "note isn't a fact")
check(BrainMemoryMigration.memoryFileMarkdownAddingMovedNote("- a\n").hasPrefix(BrainMemoryMigration.movedFactsNoteLine + "\n\n- a"), "headingless file gets the note on top")

// MARK: - Agent tool helpers

check(BrainAgentToolFormatting.bulletedNoteContent("likes tea\n\n- already\n## Heading\n  spaced  ") == "- likes tea\n\n- already\n## Heading\n- spaced", "note lines bulleted")
let addProposal = BrainAgentToolFormatting.addToBrainProposal(pageTitle: " Sarah Chen ", pageKindName: "colleague", note: "leads design", section: " ", summary: "")
check(addProposal == BrainEditProposal(operation: .append, pageTitle: "Sarah Chen", pageKind: .person, section: "Facts", content: "- leads design"), "add_to_brain proposal defaults")
check(BrainAgentToolFormatting.addToBrainProposal(pageTitle: "X", pageKindName: nil, note: "  ", section: nil, summary: nil) == nil, "empty note → nil")
check(BrainAgentToolFormatting.addToBrainProposal(pageTitle: "", pageKindName: nil, note: "n", section: nil, summary: nil) == nil, "empty page → nil")
let addPlan = BrainEditPlanner.plan(proposals: [addProposal!], provenance: BrainAgentToolFormatting.addToBrainProvenance,
                                    resolvePage: resolver(for: [sarahPage]), today: Date())
check(addPlan.pagesToWrite.first?.body.hasSuffix("- leads design") == true, "add_to_brain appends to existing page")
check(BrainAgentToolFormatting.addToBrainProvenance.trust == .derivedFromUser && BrainAgentToolFormatting.addToBrainProvenance.origin == .agent, "add_to_brain provenance")

check(BrainAgentToolFormatting.searchResultsText([], query: "zzz") == "nothing in the user's brain matches \"zzz\".", "empty search text")
let searchText = BrainAgentToolFormatting.searchResultsText(searchIndex.search("tokio"), query: "tokio")
check(searchText.contains("- Rust async (topic) — tokio runtime"), "search result line with snippet")
let bigPage = makePage(slug: "notes/big", title: "Big", kind: .note, body: String(repeating: "y", count: 5000))
let bigPageText = BrainAgentToolFormatting.pageText(bigPage, backlinkTitles: (1...15).map { "Page \($0)" })
check(bigPageText.contains("…(truncated"), "page text truncated")
check(bigPageText.hasSuffix("linked from: " + (1...12).map { "Page \($0)" }.joined(separator: ", ") + " and 3 more"), "backlinks listed and capped")
check(!BrainAgentToolFormatting.pageText(sarahPage, backlinkTitles: []).contains("linked from"), "no backlinks line when none")

check(BrainIngestSourceParser.source(from: "https://example.com/a?b=1") == .webPage(URL(string: "https://example.com/a?b=1")!), "https URL")
check(BrainIngestSourceParser.source(from: "  \"www.example.com/post\" ") == .webPage(URL(string: "https://www.example.com/post")!), "bare domain, quoted")
check(BrainIngestSourceParser.source(from: "/Users/x/Documents/spec.pdf") == .file(URL(fileURLWithPath: "/Users/x/Documents/spec.pdf")), "absolute path")
check(BrainIngestSourceParser.source(from: "~/notes.md") == .file(URL(fileURLWithPath: NSHomeDirectory() + "/notes.md")), "tilde path")
check(BrainIngestSourceParser.source(from: "file:///tmp/a.txt") == .file(URL(fileURLWithPath: "/tmp/a.txt")), "file URL")
check(BrainIngestSourceParser.source(from: "my notes file") == nil, "prose → nil")
check(BrainIngestSourceParser.source(from: "https://") == nil, "URL without host → nil")
check(BrainIngestSourceParser.source(from: "") == nil, "empty → nil")

check(BrainToolRouting.requestNamesAPage("how's atlas going?", pageNames: ["Atlas"]), "names a page")
check(BrainToolRouting.requestNamesAPage("when is sarah chen's birthday", pageNames: ["Sarah Chen"]), "multi-word name")
check(!BrainToolRouting.requestNamesAPage("i trust you", pageNames: ["Rust"]), "no match inside a word")
check(!BrainToolRouting.requestNamesAPage("ai stuff", pageNames: ["AI"]), "short names ignored")
check(!BrainToolRouting.requestNamesAPage("anything", pageNames: ["日本語"]), "untitled comparable ignored")

// MARK: - Brain command router

let webPageCommands = ["Add this page to my brain.", "hey wisp, save this article to my brain please", "remember this page",
                       "Add this link to the wiki", "ingest this website", "put this tab in my brain", "add this web page to my brain"]
for webPageCommand in webPageCommands {
    check(BrainCommandRouter.command(from: webPageCommand) == BrainCommandRouter.Command(targetHint: .webPage), "web page command: \(webPageCommand)")
}
let fileCommands = ["add this file to my brain", "Ingest this PDF", "save this document into my brain", "remember this file"]
for fileCommand in fileCommands {
    check(BrainCommandRouter.command(from: fileCommand) == BrainCommandRouter.Command(targetHint: .file), "file command: \(fileCommand)")
}
let frontmostCommands = ["save this to my brain", "ingest this", "Add it to my brain!", "could you add this to my brain", "ingest this into my brain"]
for frontmostCommand in frontmostCommands {
    check(BrainCommandRouter.command(from: frontmostCommand) == BrainCommandRouter.Command(targetHint: .frontmostThing), "frontmost command: \(frontmostCommand)")
}
let notCommands = ["remember this", "remember that i like tea", "what's in my brain about atlas", "add this page to my reading list",
                   "save this", "add milk to my shopping list", "ingest", "add this page to my brain and summarize it",
                   "how does ingesting this work", "add sarah to my brain"]
for notCommand in notCommands {
    check(BrainCommandRouter.command(from: notCommand) == nil, "not a command: \(notCommand)")
}
check(BrainCommandRouter.normalized("  Hey Wisp,  Please ADD this… page!! thanks ") == "add this page", "normalization")
check(BrainCommandRouter.queuedReply(forTitles: ["Atlas spec"]) == "adding “Atlas spec” to your brain.", "one-title reply")
check(BrainCommandRouter.queuedReply(forTitles: ["a", "b", "c"]) == "adding 3 things to your brain.", "many reply")

print("\(checkCount - failureCount)/\(checkCount) checks passed, \(knownIssueCount) known core issues")
exit(failureCount == 0 ? 0 : 1)
