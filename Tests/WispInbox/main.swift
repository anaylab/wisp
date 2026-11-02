import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("FAIL: \(message)") }
}

let now = Date()
func entry(_ id: String, _ kind: WispInboxKind, _ secondsAgo: Double) -> WispInboxEntry {
    WispInboxEntry(id: id, kind: kind, occurredAt: now.addingTimeInterval(-secondsAgo))
}

// Order: approval, failure, system, result; newest first within a kind.
let ordered = WispInboxPolicy.ordered([
    entry("result-new", .result, 10),
    entry("system", .system, 5),
    entry("failure-old", .failure, 500),
    entry("approval", .approval, 900),
    entry("failure-new", .failure, 20),
]).map(\.id)
check(ordered == ["approval", "failure-new", "failure-old", "system", "result-new"], "order was \(ordered)")

// Exact ties are stable by id.
let tied = WispInboxPolicy.ordered([entry("b", .result, 1), entry("a", .result, 1)]).map(\.id)
check(tied == ["a", "b"], "tie order was \(tied)")

// Cap at three, counting the rest.
let many = (0..<6).map { entry("r\($0)", .result, Double($0)) }
let capped = WispInboxPolicy.layout(of: many)
check(capped.shownIDs.count == 3 && capped.hiddenCount == 3, "cap was \(capped)")

// Show all.
let all = WispInboxPolicy.layout(of: many, showsAll: true)
check(all.shownIDs.count == 6 && all.hiddenCount == 0, "showsAll was \(all)")

// Approvals are never hidden, even beyond the limit.
let approvals = (0..<5).map { entry("a\($0)", .approval, Double($0)) } + [entry("f", .failure, 1)]
let approvalLayout = WispInboxPolicy.layout(of: approvals)
check(approvalLayout.shownIDs.count == 5 && approvalLayout.hiddenCount == 1, "approvals were \(approvalLayout)")

// Empty and zero limit.
check(WispInboxPolicy.layout(of: []).shownIDs.isEmpty, "empty")
check(WispInboxPolicy.layout(of: many, visibleLimit: 0).hiddenCount == 6, "zero limit")

if failures == 0 { print("WispInbox: all checks passed") } else { exit(1) }
