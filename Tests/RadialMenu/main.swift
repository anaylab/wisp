//
//  Radial quick menu suite: where wedges sit and which one a pointer direction picks.
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

func closeEnough(_ first: Double, _ second: Double) -> Bool { abs(first - second) < 0.0001 }

// Wedge positions: the first is straight up, the rest follow clockwise.
let topOffset = RadialMenuGeometry.offset(ofWedge: 0, wedgeCount: 4, radius: 100)
check(closeEnough(topOffset.x, 0) && closeEnough(topOffset.y, -100), "wedge 0 of 4 sits straight up (y is down, so negative)")
let rightOffset = RadialMenuGeometry.offset(ofWedge: 1, wedgeCount: 4, radius: 100)
check(closeEnough(rightOffset.x, 100) && closeEnough(rightOffset.y, 0), "wedge 1 of 4 sits to the right")
let bottomOffset = RadialMenuGeometry.offset(ofWedge: 2, wedgeCount: 4, radius: 100)
check(closeEnough(bottomOffset.x, 0) && closeEnough(bottomOffset.y, 100), "wedge 2 of 4 sits straight down")
let leftOffset = RadialMenuGeometry.offset(ofWedge: 3, wedgeCount: 4, radius: 100)
check(closeEnough(leftOffset.x, -100) && closeEnough(leftOffset.y, 0), "wedge 3 of 4 sits to the left")

// Which wedge a direction chooses.
func pick(_ x: Double, _ y: Double, count: Int = 5) -> Int? {
    RadialMenuGeometry.wedgeIndex(pointerOffsetX: x, pointerOffsetY: y, wedgeCount: count, deadZoneRadius: 24)
}
check(pick(0, -80) == 0, "straight up chooses wedge 0")
check(pick(80, 0, count: 4) == 1, "straight right chooses wedge 1 of 4")
check(pick(0, 80, count: 4) == 2, "straight down chooses wedge 2 of 4")
check(pick(-80, 0, count: 4) == 3, "straight left chooses wedge 3 of 4")
check(pick(-4, -80) == 0, "slightly left of up still chooses wedge 0")
check(pick(4, -80) == 0, "slightly right of up still chooses wedge 0")
check(pick(-30, -70) == 0, "up and a bit left of five wedges is still wedge 0 (its slice is 72 degrees wide)")

// Five wedges: every wedge is chosen when the pointer points at its own button.
for wedgeIndex in 0..<5 {
    let buttonOffset = RadialMenuGeometry.offset(ofWedge: wedgeIndex, wedgeCount: 5, radius: 90)
    check(pick(buttonOffset.x, buttonOffset.y) == wedgeIndex, "pointing at wedge \(wedgeIndex)'s own button chooses it")
}

// Dead zone and degenerate input.
check(pick(0, 0) == nil, "the exact centre chooses nothing")
check(pick(10, -10) == nil, "inside the dead zone chooses nothing")
check(pick(0, -24) == 0, "right on the dead zone's edge chooses a wedge")
check(RadialMenuGeometry.wedgeIndex(pointerOffsetX: 50, pointerOffsetY: 0, wedgeCount: 0, deadZoneRadius: 10) == nil, "no wedges chooses nothing")
check(pick(0, -5000) == 0, "far outside the ring still chooses by direction")

// The last wedge wraps round to straight up rather than falling off the end.
check(pick(-1, -80) == 0, "just left of straight up wraps to wedge 0, not wedge 5")

print("\(checkCount - failureCount)/\(checkCount) checks passed")
if failureCount > 0 {
    print("\(failureCount) FAILED")
    exit(1)
}
