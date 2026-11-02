//
//  Buddy flow suite: hand-off links, loops, which buddy runs when (chains,
//  fan-out, fan-in waiting for all), failures skipping what follows, links
//  that may not be followed, and the hand-off message.
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

let briefer = UUID(), planner = UUID(), writer = UUID(), focus = UUID(), inbox = UUID()

// MARK: Graph

let chain: [UUID: [UUID]] = [briefer: [planner], planner: [writer]]
check(BuddyFlowGraph.wouldCreateLoop(adding: briefer, to: writer, links: chain), "writer → briefer would close a loop")
check(BuddyFlowGraph.wouldCreateLoop(adding: planner, to: planner, links: [:]), "a buddy can't hand to itself")
check(!BuddyFlowGraph.wouldCreateLoop(adding: focus, to: writer, links: chain), "a new buddy at the end is fine")
check(!BuddyFlowGraph.wouldCreateLoop(adding: writer, to: briefer, links: chain), "a second path to the same buddy is not a loop")
check(BuddyFlowGraph.reachableBuddies(from: briefer, links: chain) == [planner, writer], "reach follows links in order")
var longChain: [UUID: [UUID]] = [:]
let manyBuddies = (0..<20).map { _ in UUID() }
for index in 0..<19 { longChain[manyBuddies[index]] = [manyBuddies[index + 1]] }
check(BuddyFlowGraph.reachableBuddies(from: manyBuddies[0], links: longChain).count == BuddyFlowGraph.maximumBuddiesPerFlow - 1, "a flow's reach is capped")

// MARK: A chain

var chainRun = BuddyFlowRun(sourceBuddyID: briefer, sourceAnswer: "3 meetings today", allLinks: chain)
var actions = chainRun.takeReadyActions()
check(actions == [.start(buddyID: planner, inputs: [(briefer, "3 meetings today")])], "the first buddy starts with the job's answer")
check(chainRun.takeReadyActions().isEmpty, "each start is given once")
chainRun.markAnswered(planner, answer: "plan: gym at 6")
actions = chainRun.takeReadyActions()
check(actions == [.start(buddyID: writer, inputs: [(planner, "plan: gym at 6")])], "the next buddy gets the previous one's answer")
check(!chainRun.isFinished, "not finished while one runs")
chainRun.markAnswered(writer, answer: "done")
check(chainRun.takeReadyActions().isEmpty && chainRun.isFinished, "finished when the last one answers")

// MARK: Fan-out and fan-in

let diamond: [UUID: [UUID]] = [briefer: [planner, inbox], planner: [writer], inbox: [writer]]
var diamondRun = BuddyFlowRun(sourceBuddyID: briefer, sourceAnswer: "news", allLinks: diamond)
actions = diamondRun.takeReadyActions()
check(Set(actions.compactMap { if case .start(let id, _) = $0 { return id } else { return nil } }) == [planner, inbox], "fan-out starts both")
diamondRun.markAnswered(planner, answer: "from planner")
check(diamondRun.takeReadyActions().isEmpty, "fan-in waits for every input")
diamondRun.markAnswered(inbox, answer: "from inbox")
actions = diamondRun.takeReadyActions()
if case .start(let id, let inputs)? = actions.first {
    check(id == writer && Set(inputs.map(\.answer)) == ["from planner", "from inbox"] && actions.count == 1,
          "fan-in gets every answer in one start")
} else { check(false, "fan-in starts once both answered") }

// MARK: Failures

var failingRun = BuddyFlowRun(sourceBuddyID: briefer, sourceAnswer: "news", allLinks: diamond)
_ = failingRun.takeReadyActions()
failingRun.markFailed(planner)
failingRun.markAnswered(inbox, answer: "from inbox")
actions = failingRun.takeReadyActions()
check(actions == [.start(buddyID: writer, inputs: [(inbox, "from inbox")])], "with one input failed, the other still goes on")

var deadRun = BuddyFlowRun(sourceBuddyID: briefer, sourceAnswer: "news", allLinks: chain)
_ = deadRun.takeReadyActions()
deadRun.markFailed(planner)
actions = deadRun.takeReadyActions()
check(actions == [.skip(buddyID: writer)], "a buddy whose only input failed is skipped")
check(deadRun.isFinished, "a failure never leaves a flow waiting")

// MARK: Links that may not be followed

let blockedRun = BuddyFlowRun(sourceBuddyID: briefer, sourceAnswer: "private", allLinks: chain, isBlocked: { from, to in from == briefer && to == planner })
var blockedRunCopy = blockedRun
actions = blockedRunCopy.takeReadyActions()
check(actions.count == 2 && Set(actions.compactMap { if case .skip(let id) = $0 { return id } else { return nil } }) == [planner, writer],
      "an unconfirmed link off this Mac is skipped, and so is what only it fed")
check(blockedRunCopy.isFinished, "and the flow ends")

let loopyLinks: [UUID: [UUID]] = [briefer: [planner], planner: [briefer]]
var loopyRun = BuddyFlowRun(sourceBuddyID: briefer, sourceAnswer: "x", allLinks: loopyLinks)
_ = loopyRun.takeReadyActions()
loopyRun.markAnswered(planner, answer: "y")
check(loopyRun.takeReadyActions().isEmpty && loopyRun.isFinished, "even a stored loop never hands back to the source")

// MARK: Messages

let message = BuddyFlowPolicy.handOffMessage(inputs: [("Briefer", "3 meetings"), ("Inbox", "2 replies due")], targetJob: "plan my day")
check(message.contains("Briefer just finished its job") && message.contains("<<<\n3 meetings\n>>>"), "each answer is fenced as data")
check(message.hasSuffix("Use them for your own job: plan my day"), "it ends with the buddy's own job")
check(BuddyFlowPolicy.handOffMessage(inputs: [("A", String(repeating: "x", count: 3000))], targetJob: "j").count < 2200, "a long answer is clipped")
check(BuddyFlowPolicy.senderNames(["A", "B", "C"]) == "A, B and C" && BuddyFlowPolicy.senderNames(["A"]) == "A", "sender names read naturally")
check(BuddyFlowPolicy.handedOnStepSummary(targetNames: ["Planner", "Inbox"]) == "Handed its answer to Planner and Inbox", "the step says where it went")

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
