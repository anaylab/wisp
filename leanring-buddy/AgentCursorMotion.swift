//
//  AgentCursorMotion.swift
//  How the agent cursor travels from one point to the next.
//
//  The move shapes and timings follow the `adaptive` motion style of cua-driver
//  (trycua/cua, `libs/cua-driver/rust/crates/cursor-overlay/src/trajectory.rs`,
//  MIT licence): a Fitts'-law timed minimum-jerk glide along a slight bow for
//  ordinary moves, and a wider cubic swoop for moves across the screen. Wisp
//  writes its own implementation of that published behaviour; no code is copied
//  from another app.
//
//  A move is planned once, as time-stamped samples, and played back by elapsed
//  time. Pure and dependency-free so it can be tested with plain swiftc.
//

import CoreGraphics
import Foundation

/// One planned position, `millisecondsSinceMoveStarted` after the move begins.
struct AgentCursorSample: Equatable {
    let millisecondsSinceMoveStarted: Double
    let point: CGPoint
}

/// The samples of one move: the first is on the start point, the last on the target.
typealias AgentCursorMove = [AgentCursorSample]

enum AgentCursorMotion {
    /// 120 Hz sampling, so playback by interpolation never looks stepped.
    static let sampleIntervalMilliseconds: Double = 1000.0 / 120.0
    /// The size of target the planner assumes for an action that names a point.
    static let assumedTargetSizeInPoints: CGFloat = 24
    /// A move longer than this swoops instead of gliding.
    static let swoopThresholdInPoints: CGFloat = 900
    /// How far a swoop bends, as a share of its length.
    static let swoopBendShare: CGFloat = 0.3
    /// How far an ordinary glide bows, as a share of its length.
    static let glideBowShare: CGFloat = 0.02
    /// How finely a path is measured, so easing sets speed along the curve.
    static let pathMeasurementSteps = 256

    /// Plans one move. A move shorter than half a point has nothing to show and
    /// returns no samples, so the caller just places the cursor.
    static func planMove(from start: CGPoint, to target: CGPoint) -> AgentCursorMove {
        let moveLength = distance(start, target)
        if moveLength < 0.5 { return [] }

        // The bend goes upward for a move across the screen, the way a hand arcs.
        let bendSide: CGFloat = (target.x - start.x) >= 0 ? -1 : 1

        if moveLength > swoopThresholdInPoints {
            let durationMilliseconds = min(1100, max(450, 350 + 0.35 * Double(moveLength)))
            return sampledMove(
                from: start,
                to: target,
                path: swoopPath(from: start, to: target, bend: swoopBendShare * bendSide),
                easing: inOutCubic,
                durationMilliseconds: durationMilliseconds
            )
        }

        // Fitts' law in its Shannon form times the glide.
        let fittsDuration = 50 + 150 * log2(Double(moveLength / assumedTargetSizeInPoints) + 1)
        let durationMilliseconds = min(1400, max(180, fittsDuration))
        return sampledMove(
            from: start,
            to: target,
            path: bowPath(from: start, to: target, bend: glideBowShare * bendSide),
            easing: minimumJerk,
            durationMilliseconds: durationMilliseconds
        )
    }

    /// Where a planned move holds the cursor `elapsedMilliseconds` after it
    /// starts. Nil only for a move with no samples.
    static func point(on move: AgentCursorMove, atElapsedMilliseconds elapsedMilliseconds: Double) -> CGPoint? {
        guard let first = move.first, let last = move.last else { return nil }
        if elapsedMilliseconds <= first.millisecondsSinceMoveStarted { return first.point }
        if elapsedMilliseconds >= last.millisecondsSinceMoveStarted { return last.point }

        // Binary search for the first sample at or after the elapsed time.
        var lowerIndex = 0
        var upperIndex = move.count - 1
        while upperIndex - lowerIndex > 1 {
            let middleIndex = (lowerIndex + upperIndex) / 2
            if move[middleIndex].millisecondsSinceMoveStarted < elapsedMilliseconds {
                lowerIndex = middleIndex
            } else {
                upperIndex = middleIndex
            }
        }
        let before = move[lowerIndex]
        let after = move[upperIndex]
        let span = after.millisecondsSinceMoveStarted - before.millisecondsSinceMoveStarted
        let fraction = span > 0 ? (elapsedMilliseconds - before.millisecondsSinceMoveStarted) / span : 1
        return CGPoint(
            x: interpolate(before.point.x, after.point.x, CGFloat(fraction)),
            y: interpolate(before.point.y, after.point.y, CGFloat(fraction))
        )
    }

    /// The total time a move takes, zero for an empty one.
    static func durationMilliseconds(of move: AgentCursorMove) -> Double {
        move.last?.millisecondsSinceMoveStarted ?? 0
    }

    // MARK: - Paths

    /// A curve over 0...1, then re-parameterised by arc length so an easing
    /// profile controls the speed along the curve rather than the parameter.
    private static func arcLengthPath(_ curve: @escaping (CGFloat) -> CGPoint) -> (CGFloat) -> CGPoint {
        var parameters: [CGFloat] = [0]
        var cumulativeLengths: [CGFloat] = [0]
        var previousPoint = curve(0)
        var totalLength: CGFloat = 0
        for step in 1...pathMeasurementSteps {
            let parameter = CGFloat(step) / CGFloat(pathMeasurementSteps)
            let point = curve(parameter)
            totalLength += distance(previousPoint, point)
            parameters.append(parameter)
            cumulativeLengths.append(totalLength)
            previousPoint = point
        }
        let measuredTotalLength = totalLength
        return { fraction in
            let clampedFraction = min(1, max(0, fraction))
            if measuredTotalLength < 1e-9 { return curve(clampedFraction) }
            let targetLength = clampedFraction * measuredTotalLength
            var lowerIndex = 0
            var upperIndex = cumulativeLengths.count - 1
            while upperIndex - lowerIndex > 1 {
                let middleIndex = (lowerIndex + upperIndex) / 2
                if cumulativeLengths[middleIndex] < targetLength {
                    lowerIndex = middleIndex
                } else {
                    upperIndex = middleIndex
                }
            }
            let lengthBefore = cumulativeLengths[lowerIndex]
            let span = cumulativeLengths[upperIndex] - lengthBefore
            let localFraction = span > 0 ? (targetLength - lengthBefore) / span : 0
            return curve(interpolate(parameters[lowerIndex], parameters[upperIndex], localFraction))
        }
    }

    /// A gentle one-sided bend: a quadratic curve whose control point is pushed
    /// sideways from the midpoint by `bend` times the move's length.
    private static func bowPath(from start: CGPoint, to target: CGPoint, bend: CGFloat) -> (CGFloat) -> CGPoint {
        let moveLength = distance(start, target)
        let direction = unitVector(from: start, to: target)
        let controlPoint = CGPoint(
            x: interpolate(start.x, target.x, 0.5) - direction.y * bend * moveLength,
            y: interpolate(start.y, target.y, 0.5) + direction.x * bend * moveLength
        )
        return arcLengthPath { parameter in
            let complement = 1 - parameter
            return CGPoint(
                x: complement * complement * start.x + 2 * complement * parameter * controlPoint.x + parameter * parameter * target.x,
                y: complement * complement * start.y + 2 * complement * parameter * controlPoint.y + parameter * parameter * target.y
            )
        }
    }

    /// A wider arc for moves across the screen: a cubic whose two handles sit a
    /// third of the way along and are pushed to the side, a little more near the
    /// start so the cursor leaves in a sweep and settles onto the target.
    private static func swoopPath(from start: CGPoint, to target: CGPoint, bend: CGFloat) -> (CGFloat) -> CGPoint {
        let deltaX = target.x - start.x
        let deltaY = target.y - start.y
        let moveLength = max(1, hypot(deltaX, deltaY))
        let perpendicularX = -deltaY / moveLength
        let perpendicularY = deltaX / moveLength
        let deflection = moveLength * bend
        let flow: CGFloat = (0.2 + 1) / 2
        let nearDeflection = deflection * (1 - 0.5 * flow)
        let farDeflection = deflection * (1 - 0.5 * (1 - flow))
        let nearHandle = CGPoint(
            x: start.x + deltaX * 0.3 + perpendicularX * nearDeflection,
            y: start.y + deltaY * 0.3 + perpendicularY * nearDeflection
        )
        let farHandle = CGPoint(
            x: target.x - deltaX * 0.3 + perpendicularX * farDeflection,
            y: target.y - deltaY * 0.3 + perpendicularY * farDeflection
        )
        return arcLengthPath { parameter in
            let complement = 1 - parameter
            let startWeight = complement * complement * complement
            let nearWeight = 3 * complement * complement * parameter
            let farWeight = 3 * complement * parameter * parameter
            let targetWeight = parameter * parameter * parameter
            return CGPoint(
                x: startWeight * start.x + nearWeight * nearHandle.x + farWeight * farHandle.x + targetWeight * target.x,
                y: startWeight * start.y + nearWeight * nearHandle.y + farWeight * farHandle.y + targetWeight * target.y
            )
        }
    }

    private static func sampledMove(
        from start: CGPoint,
        to target: CGPoint,
        path: (CGFloat) -> CGPoint,
        easing: (CGFloat) -> CGFloat,
        durationMilliseconds: Double
    ) -> AgentCursorMove {
        let stepCount = max(2, Int(ceil(durationMilliseconds / sampleIntervalMilliseconds)))
        var samples: AgentCursorMove = []
        samples.reserveCapacity(stepCount + 1)
        for step in 0...stepCount {
            let progress = CGFloat(step) / CGFloat(stepCount)
            samples.append(AgentCursorSample(
                millisecondsSinceMoveStarted: Double(progress) * durationMilliseconds,
                point: path(easing(progress))
            ))
        }
        // The curves already end on both points; this keeps rounding from
        // leaving the cursor a hair off either one.
        samples[0] = AgentCursorSample(millisecondsSinceMoveStarted: 0, point: start)
        samples[stepCount] = AgentCursorSample(millisecondsSinceMoveStarted: durationMilliseconds, point: target)
        return samples
    }

    // MARK: - Small helpers

    private static func minimumJerk(_ progress: CGFloat) -> CGFloat {
        progress * progress * progress * (10 - 15 * progress + 6 * progress * progress)
    }

    private static func inOutCubic(_ progress: CGFloat) -> CGFloat {
        progress < 0.5
            ? 4 * progress * progress * progress
            : 1 - pow(-2 * progress + 2, 3) / 2
    }

    private static func distance(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
        hypot(second.x - first.x, second.y - first.y)
    }

    private static func unitVector(from first: CGPoint, to second: CGPoint) -> CGPoint {
        let length = distance(first, second)
        let safeLength = length == 0 ? 1 : length
        return CGPoint(x: (second.x - first.x) / safeLength, y: (second.y - first.y) / safeLength)
    }

    private static func interpolate(_ first: CGFloat, _ second: CGFloat, _ fraction: CGFloat) -> CGFloat {
        first + (second - first) * fraction
    }
}
