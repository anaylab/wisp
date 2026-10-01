//
//  Brain UI suite: the pure halves of the Brain pages in the Wisp window —
//  markdown blocks, [[link]] rewriting, backlink context, link resolution and
//  the force-directed graph layout.
//

import CoreGraphics
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

func makePage(_ slug: String, _ title: String, _ kind: BrainPageKind, aliases: [String] = [], body: String = "") -> BrainPage {
    BrainPage(
        slug: slug, title: title, kind: kind, summary: "", aliases: aliases, tags: [], sources: [],
        createdDate: nil, updatedDate: nil, isLocked: false, body: body
    )
}

// MARK: - Blocks

let sampleBody = """
Intro line one
continues here.

## Facts
- Leads design for [[Atlas]].
  - Nested detail
- [ ] open task
- [x] done task
1. first
2) second

> quoted
> more

```swift
let value = "[[not a link]]"
```
---
### Small heading
"""

let parsedBlocks = BrainMarkdownBlockParser.blocks(from: sampleBody)
check(parsedBlocks.first == .paragraph(text: "Intro line one continues here."), "soft-wrapped paragraph joins lines")
check(parsedBlocks.contains(.heading(level: 2, text: "Facts")), "level-2 heading")
check(parsedBlocks.contains(.bullet(indentLevel: 0, text: "Leads design for [[Atlas]].", checkboxIsChecked: nil)), "plain bullet")
check(parsedBlocks.contains(.bullet(indentLevel: 1, text: "Nested detail", checkboxIsChecked: nil)), "nested bullet indent")
check(parsedBlocks.contains(.bullet(indentLevel: 0, text: "open task", checkboxIsChecked: false)), "unchecked task")
check(parsedBlocks.contains(.bullet(indentLevel: 0, text: "done task", checkboxIsChecked: true)), "checked task")
check(parsedBlocks.contains(.numbered(indentLevel: 0, number: "1", text: "first")), "numbered with dot")
check(parsedBlocks.contains(.numbered(indentLevel: 0, number: "2", text: "second")), "numbered with paren")
check(parsedBlocks.contains(.quote(text: "quoted more")), "quote lines joined")
check(parsedBlocks.contains(.code(language: "swift", text: "let value = \"[[not a link]]\"")), "code fence verbatim")
check(parsedBlocks.contains(.rule), "horizontal rule")
check(parsedBlocks.last == .heading(level: 3, text: "Small heading"), "level-3 heading last")
check(BrainMarkdownBlockParser.blocks(from: "#hashtag not heading") == [.paragraph(text: "#hashtag not heading")], "hashtag is not a heading")
check(BrainMarkdownBlockParser.blocks(from: "```\nunclosed") == [.code(language: "", text: "unclosed")], "unclosed fence still shown")
check(BrainMarkdownBlockParser.blocks(from: "") == [], "empty body has no blocks")
check(BrainMarkdownBlockParser.blocks(from: "-not a bullet") == [.paragraph(text: "-not a bullet")], "dash without space is text")

// MARK: - Inline links

let existingTargets: Set<String> = ["atlas", "sarah-chen"]
let isResolved: (String) -> Bool = { existingTargets.contains(BrainSlug.comparableName($0)) }

let rewritten = BrainInlineMarkdown.markdownReplacingWikiLinks("See [[Atlas]] and [[Nowhere|the void]].", isResolved: isResolved)
check(rewritten == "See [Atlas](wisp-brain://page/Atlas) and [the void](wisp-brain://missing/Nowhere).", "wiki links rewritten: \(rewritten)")

let codeUntouched = BrainInlineMarkdown.markdownReplacingWikiLinks("use `[[Atlas]]` literally", isResolved: isResolved)
check(codeUntouched == "use `[[Atlas]]` literally", "inline code keeps [[ ]]")

let trickyTarget = "Sarah Chen (design)#Role"
let trickyRewrite = BrainInlineMarkdown.markdownReplacingWikiLinks("[[\(trickyTarget)|Sarah]]", isResolved: { _ in true })
let trickyAttributed = BrainInlineMarkdown.attributedString(from: "[[\(trickyTarget)|Sarah]]", isResolved: { _ in true })
check(String(trickyAttributed.characters) == "Sarah", "alias text shown: \(trickyRewrite)")
check(BrainInlineMarkdown.linkDestinations(in: trickyAttributed) == [.page(target: "Sarah Chen (design)")], "parenthesised target survives encoding, heading dropped")

let styled = BrainInlineMarkdown.attributedString(from: "**bold** and *it* with [[Atlas]] and [[Ghost]] and [web](https://example.com)", isResolved: isResolved)
check(String(styled.characters) == "bold and it with Atlas and Ghost and web", "markup removed: \(String(styled.characters))")
check(BrainInlineMarkdown.linkDestinations(in: styled) == [.page(target: "Atlas"), .missingPage(target: "Ghost")], "brain link destinations in order")
check(styled.runs.contains { $0.link?.absoluteString == "https://example.com" }, "ordinary markdown links kept")
check(styled.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }, "bold parsed")

let escapedShown = BrainInlineMarkdown.attributedString(from: "[[Atlas|a*b_c]]", isResolved: isResolved)
check(String(escapedShown.characters) == "a*b_c", "markdown characters in shown text are escaped")

check(BrainInlineMarkdown.destination(from: URL(string: "https://example.com")!) == nil, "web URL is not a brain destination")
let roundTripURL = URL(string: BrainInlineMarkdown.urlString(for: .missingPage(target: "Café & Co")))!
check(BrainInlineMarkdown.destination(from: roundTripURL) == .missingPage(target: "Café & Co"), "unicode target round trip")

// MARK: - Backlink context

let backlinkBody = "## Notes\n- Met at a conference.\n- Works with [[Sarah Chen|Sarah]] on design.\n"
check(BrainBacklinkContext.mentioningLine(in: backlinkBody, linkingToAnyOf: ["Sarah Chen"]) == "Works with [[Sarah Chen|Sarah]] on design.", "backlink line found without bullet")
check(BrainBacklinkContext.mentioningLine(in: backlinkBody, linkingToAnyOf: ["Atlas"]) == nil, "no line when not linked")
check(BrainBacklinkContext.mentioningLine(in: "- see [[sarah chen]]", linkingToAnyOf: ["Sarah Chen"]) == "see [[sarah chen]]", "case-insensitive match")

// MARK: - Link resolver

let resolverPages = [
    makePage("me", "Me", .me),
    makePage("people/sarah-chen", "Sarah Chen", .person, aliases: ["Sarah"]),
    makePage("projects/atlas", "Atlas", .project),
    makePage("people/sarah-lee", "Sarah", .person)
]
let resolver = BrainLinkResolver(pages: resolverPages)
check(resolver.slug(forTarget: "Sarah Chen") == "people/sarah-chen", "resolve by title")
check(resolver.slug(forTarget: "projects/atlas") == "projects/atlas", "resolve by slug")
check(resolver.slug(forTarget: "Sarah") == "people/sarah-lee", "title beats another page's alias")
check(resolver.slug(forTarget: "me") == "me", "me resolves")
check(resolver.slug(forTarget: "Nobody") == nil, "unknown target unresolved")

// MARK: - Graph

var graphPages = [makePage("me", "Me", .me, body: "Working on [[Atlas]] with [[Sarah Chen]].")]
graphPages.append(makePage("projects/atlas", "Atlas", .project, body: "Led by [[Sarah Chen]]. Also [[Missing Page]]. Self [[Atlas]]."))
graphPages.append(makePage("people/sarah-chen", "Sarah Chen", .person, body: "Works on [[Atlas]] and knows [[me]]."))
for loneIndex in 0..<6 {
    graphPages.append(makePage("topics/lone-\(loneIndex)", "Lone \(loneIndex)", .topic))
}
let graphResolver = BrainLinkResolver(pages: graphPages)
var graph = BrainGraphLayout.build(pages: graphPages, resolver: graphResolver)
check(graph.nodes.count == 9, "every page is a node")
check(graph.edges.count == 3, "undirected links de-duplicated, unresolved and self links dropped: \(graph.edges.count)")
check(graph.nodes.first?.slug == "me", "me first (centre of the spiral)")
check(graph.nodes.first { $0.slug == "projects/atlas" }?.linkCount == 2, "link count is degree")
check(Set(graph.edges.map { "\($0.sourceIndex)-\($0.targetIndex)" }).count == graph.edges.count, "no duplicate edges")
check(graph.edges.allSatisfy { $0.sourceIndex < $0.targetIndex }, "edges stored lower index first")

let cappedGraph = BrainGraphLayout.build(pages: graphPages, maximumNodeCount: 2, resolver: graphResolver)
check(cappedGraph.nodes.count == 2 && cappedGraph.wasTruncated, "node cap applied and reported")
check(cappedGraph.nodes.map(\.slug).contains("me"), "me survives the cap")
check(cappedGraph.edges.count == 1, "edges limited to kept nodes")

let filteredGraph = BrainGraphLayout.build(pages: graphPages, kinds: [.person, .project], resolver: graphResolver)
check(filteredGraph.nodes.count == 2 && filteredGraph.edges.count == 1, "kind filter limits nodes and edges")

var stepCount = 0
while !graph.isSettled && stepCount < 2000 {
    graph.step()
    stepCount += 1
}
check(graph.isSettled, "layout settles (took \(stepCount) steps)")
check(stepCount < 600, "layout settles quickly enough for the clock to stop: \(stepCount)")
check(graph.nodes.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite }, "no NaN positions")

func distanceBetween(_ firstSlug: String, _ secondSlug: String) -> CGFloat {
    let firstNode = graph.nodes.first { $0.slug == firstSlug }!
    let secondNode = graph.nodes.first { $0.slug == secondSlug }!
    return hypot(firstNode.position.x - secondNode.position.x, firstNode.position.y - secondNode.position.y)
}
check(distanceBetween("projects/atlas", "people/sarah-chen") < distanceBetween("topics/lone-0", "topics/lone-3") + 60,
      "linked pages sit close together")
check(graph.boundingBox.width > 40 && graph.boundingBox.width < 2000, "layout spreads out without flying apart: \(graph.boundingBox)")

// Pinned nodes stay put.
var pinnedGraph = BrainGraphLayout.build(pages: graphPages, resolver: graphResolver)
pinnedGraph.nodes[1].isPinned = true
pinnedGraph.nodes[1].position = CGPoint(x: 300, y: 300)
pinnedGraph.targetTemperature = 0.3
for _ in 0..<50 { pinnedGraph.step() }
check(pinnedGraph.nodes[1].position == CGPoint(x: 300, y: 300), "pinned node does not move")
check(!pinnedGraph.isSettled, "a held drag keeps the layout awake")

// Hit testing and neighbours.
let hitNode = graph.nodes[0]
check(graph.nodeIndex(at: hitNode.position) == 0, "hit test finds the node under the point")
check(graph.nodeIndex(at: CGPoint(x: 100_000, y: 100_000)) == nil, "hit test misses empty space")
let atlasIndex = graph.nodes.firstIndex { $0.slug == "projects/atlas" }!
check(graph.neighborIndices(of: atlasIndex).count == 2, "neighbours of Atlas")

// Positions carried over on rebuild.
var rebuiltGraph = BrainGraphLayout.build(pages: graphPages + [makePage("notes/new", "New", .note)], resolver: graphResolver)
rebuiltGraph.adoptPositions(from: graph)
check(rebuiltGraph.nodes.first { $0.slug == "me" }?.position == graph.nodes.first { $0.slug == "me" }?.position, "existing node keeps its place")
check(rebuiltGraph.temperature < 1, "mostly-unchanged graph only nudged")

check(BrainGraphLayout.build(pages: [], resolver: BrainLinkResolver(pages: [])).isSettled, "empty graph is settled")

print("\(checkCount - failureCount)/\(checkCount) checks passed")
if failureCount > 0 { exit(1) }
