//
//  RadialMenuGeometry.swift
//  leanring-buddy
//
//  The maths of the radial quick menu, kept pure so it can be tested without a
//  screen: where each wedge sits around the centre, and which wedge the pointer is
//  pointing at. Angles run clockwise from straight up, the way a clock face does,
//  so the first wedge is always at twelve o'clock.
//

import Foundation

nonisolated enum RadialMenuGeometry {

    /// The angle, in radians clockwise from straight up, of the centre of a wedge.
    static func angle(ofWedge wedgeIndex: Int, wedgeCount: Int) -> Double {
        guard wedgeCount > 0 else { return 0 }
        return Double(wedgeIndex) * (2 * Double.pi / Double(wedgeCount))
    }

    /// Where a wedge's button sits, relative to the menu's centre, in screen-style
    /// coordinates (x to the right, y DOWN), at the given distance from the centre.
    static func offset(ofWedge wedgeIndex: Int, wedgeCount: Int, radius: Double) -> (x: Double, y: Double) {
        let wedgeAngle = angle(ofWedge: wedgeIndex, wedgeCount: wedgeCount)
        return (x: sin(wedgeAngle) * radius, y: -cos(wedgeAngle) * radius)
    }

    /// The wedge the pointer is pointing toward, given its offset from the centre in
    /// screen-style coordinates (y DOWN). Nil inside the dead zone, so resting the
    /// pointer in the middle chooses nothing and a click there simply closes the menu.
    static func wedgeIndex(
        pointerOffsetX: Double,
        pointerOffsetY: Double,
        wedgeCount: Int,
        deadZoneRadius: Double
    ) -> Int? {
        guard wedgeCount > 0 else { return nil }
        let distanceFromCentre = (pointerOffsetX * pointerOffsetX + pointerOffsetY * pointerOffsetY).squareRoot()
        guard distanceFromCentre >= deadZoneRadius else { return nil }

        var pointerAngle = atan2(pointerOffsetX, -pointerOffsetY)
        if pointerAngle < 0 { pointerAngle += 2 * Double.pi }
        let wedgeWidth = 2 * Double.pi / Double(wedgeCount)
        // Wedges are centred on their angle, so round to the nearest one rather than
        // truncating (which would make the first wedge start at twelve o'clock).
        return Int((pointerAngle / wedgeWidth).rounded()) % wedgeCount
    }
}
