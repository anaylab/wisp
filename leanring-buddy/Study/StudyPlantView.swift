//
//  StudyPlantView.swift
//  leanring-buddy
//
//  Study mode's mascot: a sprout that grows with the focus block, sways in the breeze,
//  blooms when the block is done and droops if it's given up on. `StudyGarden` lines one
//  plant up per round, `StudyGrowingPlant` grows on its own (finished screen, idle
//  launcher) and `StudyBreathingCaption` paces a breath during breaks.
//

import SwiftUI

/// Block progress (0...1) as plant growth: a small sprout is up from the first second, so the plant never starts as a bare seed.
func studyPlantGrowth(forProgress progress: Double) -> Double {
    0.08 + 0.92 * min(max(progress, 0), 1)
}

/// One plant. `growth` runs 0 (a seed) to 1 (in bloom).
struct StudyPlantView: View {
    var growth: Double
    var isSwaying = true
    var isWilted = false
    var showsGround = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let stemColor = WispColor.Brand.sage
    private let leafColor = WispColor.Brand.sage
    private let flowerColor = WispColor.Brand.lavender
    private let flowerCenterColor = WispColor.Brand.cloud

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !isSwaying || reduceMotion || isWilted)) { timeline in
            Canvas { context, size in
                let swayPhase = sin(timeline.date.timeIntervalSinceReferenceDate * 1.6)
                draw(into: &context, size: size, sway: swayPhase)
            }
        }
        .accessibilityHidden(true)
    }

    private func draw(into context: inout GraphicsContext, size: CGSize, sway: Double) {
        let clampedGrowth = min(max(growth, 0), 1)
        let eased = 1 - pow(1 - clampedGrowth, 2)
        let wilt: CGFloat = isWilted ? 1 : 0

        let base = CGPoint(x: size.width / 2, y: size.height * 0.92)

        if showsGround {
            let groundRect = CGRect(x: base.x - size.width * 0.26, y: base.y - size.height * 0.035,
                                    width: size.width * 0.52, height: size.height * 0.09)
            context.fill(Path(ellipseIn: groundRect), with: .color(stemColor.opacity(0.28)))
        }

        // A seed before anything has grown.
        guard clampedGrowth > 0.015 else {
            let seedRadius = max(1.5, size.width * 0.05)
            context.fill(Path(ellipseIn: CGRect(x: base.x - seedRadius, y: base.y - seedRadius * 1.6,
                                                width: seedRadius * 2, height: seedRadius * 2)),
                         with: .color(stemColor.opacity(0.7)))
            return
        }

        let stemHeight = size.height * 0.74 * max(eased, 0.05)
        let swayOffset = CGFloat(sway) * size.width * 0.045 * CGFloat(eased)
        let tip = CGPoint(
            x: base.x + swayOffset + wilt * size.width * 0.24,
            y: base.y - stemHeight * (1 - 0.38 * wilt)
        )
        let control = CGPoint(x: base.x - swayOffset * 0.4, y: base.y - stemHeight * 0.55)

        var stem = Path()
        stem.move(to: base)
        stem.addQuadCurve(to: tip, control: control)
        context.stroke(
            stem,
            with: .color(stemColor.opacity(isWilted ? 0.55 : 1)),
            style: StrokeStyle(lineWidth: max(1.3, size.width * 0.075), lineCap: .round)
        )

        func pointOnStem(_ t: CGFloat) -> CGPoint {
            let u = 1 - t
            return CGPoint(
                x: u * u * base.x + 2 * u * t * control.x + t * t * tip.x,
                y: u * u * base.y + 2 * u * t * control.y + t * t * tip.y
            )
        }

        // Leaves open one after another as the block goes on.
        let leafSpecs: [(opensAt: Double, along: CGFloat, side: CGFloat)] = [
            (0.16, 0.36, -1), (0.36, 0.52, 1), (0.56, 0.70, -1), (0.76, 0.86, 1),
        ]
        for spec in leafSpecs {
            let openness = min(max((clampedGrowth - spec.opensAt) / 0.14, 0), 1)
            guard openness > 0 else { continue }
            let leafLength = size.width * 0.3 * CGFloat(openness)
            let anchor = pointOnStem(spec.along)

            var leaf = Path()
            leaf.move(to: .zero)
            leaf.addQuadCurve(to: CGPoint(x: leafLength, y: 0), control: CGPoint(x: leafLength * 0.5, y: -leafLength * 0.42))
            leaf.addQuadCurve(to: .zero, control: CGPoint(x: leafLength * 0.5, y: leafLength * 0.42))

            let upDegrees: Double = 38
            let downDegrees: Double = 52
            let angleDegrees: Double
            if spec.side > 0 {
                angleDegrees = isWilted ? downDegrees : -upDegrees
            } else {
                angleDegrees = isWilted ? 180 - downDegrees : 180 + upDegrees
            }
            let transform = CGAffineTransform(translationX: anchor.x, y: anchor.y)
                .rotated(by: CGFloat(Angle.degrees(angleDegrees).radians))
            context.fill(leaf.applying(transform), with: .color(leafColor.opacity(isWilted ? 0.5 : 1)))
        }

        // The flower opens at the very end.
        let bloom = min(max((clampedGrowth - 0.9) / 0.1, 0), 1)
        if bloom > 0 && !isWilted {
            let petalLength = size.width * 0.15 * CGFloat(bloom)
            for petalIndex in 0..<5 {
                let angle = Double(petalIndex) / 5 * 2 * .pi - .pi / 2
                let center = CGPoint(x: tip.x + CGFloat(cos(angle)) * petalLength,
                                     y: tip.y + CGFloat(sin(angle)) * petalLength)
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x - petalLength * 0.72, y: center.y - petalLength * 0.72,
                                           width: petalLength * 1.44, height: petalLength * 1.44)),
                    with: .color(flowerColor)
                )
            }
            let centerRadius = petalLength * 0.62
            context.fill(
                Path(ellipseIn: CGRect(x: tip.x - centerRadius, y: tip.y - centerRadius, width: centerRadius * 2, height: centerRadius * 2)),
                with: .color(flowerCenterColor)
            )
        }
    }
}

/// A plant that grows from seed to bloom by itself, after an optional delay.
struct StudyGrowingPlant: View {
    var delay: Double = 0
    var growDuration: Double = 1.4

    @State private var startDate = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(startDate) - delay
            StudyPlantView(growth: min(max(elapsed / growDuration, 0), 1), isSwaying: elapsed > growDuration)
        }
        .onAppear { startDate = Date() }
    }
}

/// One plant per round: finished rounds in bloom, the current one growing, the rest still seeds.
struct StudyGarden: View {
    let totalRounds: Int
    let finishedRounds: Int
    /// Growth of the round in progress (nil when none is, e.g. during a break).
    let currentRoundGrowth: Double?
    var plantWidth: CGFloat = 16
    var plantHeight: CGFloat = 20
    var spacing: CGFloat = 2

    var body: some View {
        HStack(alignment: .bottom, spacing: spacing) {
            ForEach(0..<max(totalRounds, 0), id: \.self) { roundIndex in
                StudyPlantView(
                    growth: growth(forRoundAt: roundIndex),
                    isSwaying: roundIndex == finishedRounds && currentRoundGrowth != nil,
                    showsGround: true
                )
                .frame(width: plantWidth, height: plantHeight)
                .scaleEffect(roundIndex < finishedRounds ? 1 : 0.92, anchor: .bottom)
                .animation(WispMotion.pop, value: roundIndex < finishedRounds)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(finishedRounds) of \(totalRounds) rounds grown")
    }

    private func growth(forRoundAt roundIndex: Int) -> Double {
        if roundIndex < finishedRounds { return 1 }
        if roundIndex == finishedRounds, let currentRoundGrowth { return currentRoundGrowth }
        return 0
    }
}

/// "Breathe in" / "Breathe out", four seconds each, matching the breathing halo.
struct StudyBreathingCaption: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let isBreathingIn = Int(timeline.date.timeIntervalSinceReferenceDate / 4) % 2 == 0
            Text(isBreathingIn ? "Breathe in…" : "Breathe out…")
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.6), value: isBreathingIn)
        }
    }
}

/// A soft halo that swells and settles on the same eight-second breath as `StudyBreathingCaption`.
struct StudyBreathingHalo: View {
    var tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let breathProgress = 0.5 - 0.5 * cos(2 * .pi * timeline.date.timeIntervalSinceReferenceDate / 8)
            Circle()
                .fill(tint.opacity(0.14 + 0.1 * breathProgress))
                .scaleEffect(reduceMotion ? 0.95 : 0.78 + 0.22 * breathProgress)
        }
    }
}
