//
//  Agent cursor motion suite: planned moves start and end on their points,
//  take longer for longer distances, never overshoot, and play back by time.
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

func near(_ first: CGPoint, _ second: CGPoint, _ tolerance: CGFloat = 0.001) -> Bool {
    hypot(first.x - second.x, first.y - second.y) <= tolerance
}

let origin = CGPoint(x: 100, y: 100)

// Nothing to show for a move under half a point.
check(AgentCursorMotion.planMove(from: origin, to: CGPoint(x: 100.2, y: 100.1)).isEmpty, "a sub-half-point move plans no samples")
check(AgentCursorMotion.point(on: [], atElapsedMilliseconds: 10) == nil, "an empty move has no point")

// Ends are exact.
let shortMove = AgentCursorMotion.planMove(from: origin, to: CGPoint(x: 300, y: 220))
check(near(shortMove.first!.point, origin), "a move starts on its start point")
check(near(shortMove.last!.point, CGPoint(x: 300, y: 220)), "a move ends on its target")
check(shortMove.first!.millisecondsSinceMoveStarted == 0, "a move starts at time zero")

// Samples are in time order.
var isOrdered = true
for index in 1..<shortMove.count where shortMove[index].millisecondsSinceMoveStarted < shortMove[index - 1].millisecondsSinceMoveStarted {
    isOrdered = false
}
check(isOrdered, "samples are in time order")

// Duration grows with distance, within the clamps.
let nearDuration = AgentCursorMotion.durationMilliseconds(of: AgentCursorMotion.planMove(from: origin, to: CGPoint(x: 110, y: 100)))
let midDuration = AgentCursorMotion.durationMilliseconds(of: shortMove)
let farDuration = AgentCursorMotion.durationMilliseconds(of: AgentCursorMotion.planMove(from: origin, to: CGPoint(x: 800, y: 600)))
check(nearDuration >= 180, "a tiny move still takes at least 180ms")
check(nearDuration < midDuration && midDuration < farDuration, "longer moves take longer")
check(farDuration <= 1400, "a glide never exceeds 1.4s")

// A swoop over 900 points is clamped to 450...1100ms.
let swoop = AgentCursorMotion.planMove(from: CGPoint(x: 50, y: 800), to: CGPoint(x: 1800, y: 100))
let swoopDuration = AgentCursorMotion.durationMilliseconds(of: swoop)
check(swoopDuration >= 450 && swoopDuration <= 1100, "a swoop takes between 450ms and 1.1s")
check(near(swoop.last!.point, CGPoint(x: 1800, y: 100)), "a swoop ends on its target")

// A swoop bends away from the straight line; an ordinary glide hardly does.
func largestSidewaysDeviation(of move: AgentCursorMove, from start: CGPoint, to target: CGPoint) -> CGFloat {
    let deltaX = target.x - start.x
    let deltaY = target.y - start.y
    let length = hypot(deltaX, deltaY)
    return move.map { abs((($0.point.x - start.x) * deltaY - ($0.point.y - start.y) * deltaX) / length) }.max() ?? 0
}
check(largestSidewaysDeviation(of: swoop, from: CGPoint(x: 50, y: 800), to: CGPoint(x: 1800, y: 100)) > 100, "a swoop visibly bends")
check(largestSidewaysDeviation(of: shortMove, from: origin, to: CGPoint(x: 300, y: 220)) < 15, "an ordinary glide stays nearly straight")

// A left-to-right move and its mirror bend to the same side of travel (upward on screen).
let rightward = AgentCursorMotion.planMove(from: CGPoint(x: 100, y: 500), to: CGPoint(x: 700, y: 500))
let leftward = AgentCursorMotion.planMove(from: CGPoint(x: 700, y: 500), to: CGPoint(x: 100, y: 500))
let rightwardMiddle = AgentCursorMotion.point(on: rightward, atElapsedMilliseconds: AgentCursorMotion.durationMilliseconds(of: rightward) / 2)!
let leftwardMiddle = AgentCursorMotion.point(on: leftward, atElapsedMilliseconds: AgentCursorMotion.durationMilliseconds(of: leftward) / 2)!
check(rightwardMiddle.y < 500 && leftwardMiddle.y < 500, "both directions bow upward on screen")

// Playback by time: clamps at the ends, and the middle is on the way.
check(near(AgentCursorMotion.point(on: shortMove, atElapsedMilliseconds: -50)!, origin), "before the start, the cursor holds the start")
check(near(AgentCursorMotion.point(on: shortMove, atElapsedMilliseconds: 99_999)!, CGPoint(x: 300, y: 220)), "after the end, the cursor holds the target")
let midpoint = AgentCursorMotion.point(on: shortMove, atElapsedMilliseconds: midDuration / 2)!
check(midpoint.x > 150 && midpoint.x < 250, "halfway through, the cursor is about halfway there")

// Easing: it starts slowly and does not overshoot the target.
let early = AgentCursorMotion.point(on: shortMove, atElapsedMilliseconds: midDuration * 0.1)!
check(hypot(early.x - origin.x, early.y - origin.y) < 0.05 * hypot(200, 120) + 5, "the first tenth of the time covers very little distance")
check(shortMove.allSatisfy { $0.point.x <= 300.5 }, "the cursor never overshoots the target")

// Same two points always plan the same move.
check(AgentCursorMotion.planMove(from: origin, to: CGPoint(x: 300, y: 220)) == shortMove, "planning is deterministic")

print("\(checkCount - failureCount)/\(checkCount) checks passed")
exit(failureCount == 0 ? 0 : 1)
