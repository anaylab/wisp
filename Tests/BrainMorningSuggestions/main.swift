//
//  Brain morning-suggestions suite: the notes shown to the model, JSON parsing, and the quote
//  check that keeps invented follow-ups out of the banner.
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

let now = Date(timeIntervalSince1970: 1_800_000_000)
let daysAgo: (Double) -> Date = { now.addingTimeInterval(-$0 * 24 * 60 * 60) }

func page(_ title: String, body: String, updated: Date?) -> BrainPage {
    BrainPage(slug: title.lowercased(), title: title, kind: .topic, summary: "", aliases: [], tags: [],
              sources: [], createdDate: nil, updatedDate: updated, isLocked: false, body: body)
}

// MARK: Material

let pages = [
    page("Old", body: "- Stale line from last month", updated: daysAgo(30)),
    page("Recent", body: "## Heading\n- Reply to Sarah about the budget by Friday\n\nPlain paragraph line", updated: daysAgo(1)),
    page("Newest", body: "- Book the venue", updated: daysAgo(0.1)),
    page("Undated", body: "- Never updated", updated: nil),
]
let material = BrainMorningSuggestions.material(pages: pages, now: now)
check(!material.contains("Stale line"), "pages older than the lookback are left out")
check(!material.contains("Never updated"), "undated pages are left out")
check(!material.contains("Heading"), "headings are not shown")
check(material.hasPrefix("[Newest] - Book the venue"), "newest page comes first")
check(material.contains("[Recent] - Reply to Sarah about the budget by Friday"), "lines carry their page title")

let longPages = [page("Long", body: (0..<2_000).map { "- line number \($0) with some padding text" }.joined(separator: "\n"), updated: daysAgo(1))]
check(BrainMorningSuggestions.material(pages: longPages, now: now).count <= BrainMorningSuggestions.maximumMaterialCharacters,
      "material never exceeds the character budget")

// MARK: Parsing

let goodReply = #"{"suggestions":[{"title":"Reply to Sarah","evidence_quote":"Reply to Sarah about the budget by Friday"}]}"#
check(BrainMorningSuggestions.parse(reply: goodReply).count == 1, "well-formed reply parses")
check(BrainMorningSuggestions.parse(reply: "not json").isEmpty, "garbage parses to nothing")
check(BrainMorningSuggestions.parse(reply: #"{"suggestions":[{"title":"No quote"}]}"#).isEmpty, "a suggestion without a quote is dropped")
check(BrainMorningSuggestions.parse(reply: #"{"other":[]}"#).isEmpty, "wrong shape parses to nothing")

// MARK: Verification

func candidate(_ title: String, _ quote: String) -> BrainSuggestionCandidate {
    BrainSuggestionCandidate(title: title, evidenceQuote: quote)
}

let verifiedExact = BrainMorningSuggestions.verified([candidate("Reply to Sarah", "Reply to Sarah about the budget by Friday")], against: material)
check(verifiedExact.count == 1, "an exact quote is kept")

let verifiedLoose = BrainMorningSuggestions.verified([candidate("Reply", "reply  to SARAH about the   budget by friday")], against: material)
check(verifiedLoose.count == 1, "case and spacing differences are ignored")

let emphasised = BrainMorningSuggestions.verified(
    [candidate("Reply", "Reply to Sarah about the budget")],
    against: "[Recent] - Reply to **Sarah** about the budget by Friday")
check(emphasised.count == 1, "markdown emphasis in the notes does not break a quote")

check(BrainMorningSuggestions.verified([candidate("Invented", "Call the plumber about the leak tomorrow")], against: material).isEmpty,
      "a quote that is not in the notes is dropped")
check(BrainMorningSuggestions.verified([candidate("Paraphrase", "Answer Sarah on the budget before Friday")], against: material).isEmpty,
      "a paraphrased quote is dropped")
check(BrainMorningSuggestions.verified([candidate("Short", "Book the venue")], against: material).isEmpty,
      "a quote under the minimum length is dropped")
check(BrainMorningSuggestions.verified([candidate("", "Reply to Sarah about the budget by Friday")], against: material).isEmpty,
      "an empty title is dropped")
check(BrainMorningSuggestions.verified([candidate(String(repeating: "x", count: 81), "Reply to Sarah about the budget by Friday")], against: material).isEmpty,
      "an over-long title is dropped")

let duplicates = BrainMorningSuggestions.verified(
    [candidate("Reply to Sarah", "Reply to Sarah about the budget by Friday"),
     candidate("reply to sarah", "Reply to Sarah about the budget by Friday")], against: material)
check(duplicates.count == 1, "duplicate titles are dropped")

let manyMaterial = (0..<6).map { "[N] - Task number \($0) needs doing soon" }.joined(separator: "\n")
let many = (0..<6).map { candidate("Task \($0)", "Task number \($0) needs doing soon") }
check(BrainMorningSuggestions.verified(many, against: manyMaterial).count == BrainMorningSuggestions.maximumSuggestions,
      "no more than the maximum are kept")

// MARK: Banner row

let row = BrainMorningSuggestions.suggestionRow(for: candidate("Reply to Sarah", "Reply to Sarah about the budget by Friday"))
check(row.title == "Reply to Sarah", "row shows the title")
check(row.id.hasPrefix("brain-"), "row id is marked as a brain suggestion")
if case .askQuestion(let question) = row.action {
    check(question.contains("Reply to Sarah about the budget by Friday"), "clicking asks Wisp with the evidence attached")
} else {
    check(false, "row action is an ordinary typed question")
}

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
