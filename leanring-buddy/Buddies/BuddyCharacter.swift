//
//  BuddyCharacter.swift
//  leanring-buddy
//
//  The buddies' cloud characters, brought to life. One `Canvas` draws the whole
//  character from a clock, so every motion is a pure function of time and costs
//  one draw pass:
//
//    · breathing and a slow float, a blink every few seconds (offset per colour
//      so a row of buddies never blinks in unison)
//    · eyes that follow the pointer, when `looksAtPointer` is on
//    · a mood (`BuddyMood`) that changes the eyes, mouth and little extras:
//      scanning eyes and orbiting dots while working, closed smiling eyes and
//      a burst of sparkles when happy, drooping brows when something failed,
//      wide eyes and a "?" when it needs the user's ok, closed eyes and drifting
//      "z"s when sleepy
//    · a squish-and-settle when `bounceTrigger` changes or the pointer arrives
//
//  `Liveliness` is the cost dial: `.still` draws one frame and never runs a
//  clock (long lists), `.working` animates only the work state (the compact
//  avatar), `.full` animates everything (the rail, headers, empty states).
//  Reduce Motion freezes it to a still frame in every case.
//

import AppKit
import SwiftUI

/// Hands the character's on-screen frame to the clock so its eyes can follow
/// the pointer. Holds the backing view weakly; read once per tick.
@MainActor
final class BuddyScreenFrameBox {
    weak var view: NSView?

    /// A unit-ish vector from the character toward the pointer, 0 when the
    /// pointer is on top of it and growing to length 1 about 180pt away.
    func pointerDirection() -> CGSize {
        guard let view, let window = view.window, window.isVisible else { return .zero }
        let rectOnScreen = window.convertToScreen(view.convert(view.bounds, to: nil))
        let mouseLocation = NSEvent.mouseLocation
        let deltaX = mouseLocation.x - rectOnScreen.midX
        let deltaY = rectOnScreen.midY - mouseLocation.y
        let distance = hypot(deltaX, deltaY)
        guard distance > 1 else { return .zero }
        let strength = min(1, distance / 180)
        return CGSize(width: deltaX / distance * strength, height: deltaY / distance * strength)
    }
}

private struct BuddyScreenFrameReader: NSViewRepresentable {
    let box: BuddyScreenFrameBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        box.view = nsView
    }
}

struct BuddyCharacter: View {
    enum Liveliness {
        case still
        case working
        case full
    }

    let colorIndex: Int
    var size: CGFloat = 48
    var mood: BuddyMood = .idle
    var liveliness: Liveliness = .full
    /// Change this value to make the buddy squish and bounce (a selection, a click).
    var bounceTrigger: Int = 0
    var looksAtPointer: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moodChangedAt: TimeInterval = 0
    @State private var bounceStartedAt: TimeInterval = -10
    @State private var isHovering = false
    @State private var frameBox = BuddyScreenFrameBox()

    private static let inkColor = Color(red: 0.13, green: 0.10, blue: 0.24)
    private static let cheekColor = Color(red: 1.0, green: 0.50, blue: 0.62)

    private var isAnimating: Bool {
        guard !reduceMotion else { return false }
        switch liveliness {
        case .still: return false
        case .working: return mood == .working
        case .full: return true
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isAnimating)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let pointerDirection = (looksAtPointer && isAnimating && !isHovering) ? frameBox.pointerDirection() : .zero
            Canvas { context, canvasSize in
                draw(in: &context, canvasSize: canvasSize, now: now, pointerDirection: pointerDirection)
            }
            // Room for sparkles and orbiting dots outside the cloud itself.
            .frame(width: size * 1.45, height: size * 1.45)
        }
        .frame(width: size, height: size)
        .background(BuddyScreenFrameReader(box: frameBox))
        .scaleEffect(isHovering && liveliness == .full ? 1.06 : 1)
        .animation(WispMotion.quick, value: isHovering)
        .onHover { isNowHovering in
            isHovering = isNowHovering
            if isNowHovering && liveliness == .full && !reduceMotion {
                bounceStartedAt = Date.timeIntervalSinceReferenceDate
            }
        }
        .onChange(of: bounceTrigger) { _, _ in
            bounceStartedAt = Date.timeIntervalSinceReferenceDate
        }
        .onChange(of: mood) { _, _ in
            moodChangedAt = Date.timeIntervalSinceReferenceDate
        }
        .accessibilityHidden(true)
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, canvasSize: CGSize, now: TimeInterval, pointerDirection: CGSize) {
        let bodySize = size
        let seed = Double(colorIndex % 8)
        let animationTime = isAnimating ? now : 0

        // Motion, all derived from the clock.
        let breathing = 1 + 0.018 * sin(animationTime * 1.8 + seed)
        let floatOffset: CGFloat = {
            switch mood {
            case .working: return CGFloat(sin(animationTime * 3.4) * 0.035) * bodySize
            case .sleepy: return CGFloat(sin(animationTime * 0.9 + seed) * 0.012) * bodySize
            default: return CGFloat(sin(animationTime * 1.3 + seed) * 0.022) * bodySize
            }
        }()
        let tilt: Double = mood == .working ? sin(animationTime * 2.1) * 2.5 : (mood == .oops ? sin(animationTime * 30) * 2.0 : 0)

        let bounceElapsed = animationTime - bounceStartedAt
        let bounceAmount: CGFloat = (isAnimating && bounceElapsed >= 0 && bounceElapsed < 1.4)
            ? CGFloat(exp(-3.6 * bounceElapsed) * cos(bounceElapsed * 17))
            : 0
        let squishX = breathing + Double(bounceAmount) * 0.16
        let squishY = breathing - Double(bounceAmount) * 0.16

        context.translateBy(x: canvasSize.width / 2, y: canvasSize.height / 2 + floatOffset)
        context.rotate(by: .degrees(tilt))
        context.scaleBy(x: squishX, y: squishY)

        let bodyPath = Self.cloudPath(bodySize: bodySize)
        let lightColor = BuddyAppearance.lightColor(forColorIndex: colorIndex)
        let deepColor = BuddyAppearance.deepColor(forColorIndex: colorIndex)

        // Glow, then the gradient body, then a soft highlight and rim.
        context.drawLayer { glowContext in
            glowContext.addFilter(.shadow(color: deepColor.opacity(mood == .working ? 0.75 : 0.5), radius: bodySize * 0.16))
            glowContext.fill(bodyPath, with: .color(deepColor))
        }
        context.fill(
            bodyPath,
            with: .linearGradient(
                Gradient(colors: [lightColor, deepColor]),
                startPoint: CGPoint(x: 0, y: -bodySize * 0.42),
                endPoint: CGPoint(x: 0, y: bodySize * 0.42)
            )
        )
        let highlightRect = CGRect(x: -bodySize * 0.28, y: -bodySize * 0.30, width: bodySize * 0.30, height: bodySize * 0.14)
        context.fill(Path(ellipseIn: highlightRect), with: .color(.white.opacity(0.38)))
        context.stroke(bodyPath, with: .color(.white.opacity(0.16)), lineWidth: max(0.6, bodySize * 0.015))

        drawFace(in: &context, bodySize: bodySize, time: animationTime, pointerDirection: pointerDirection)
        drawExtras(in: &context, bodySize: bodySize, time: animationTime, light: lightColor)
    }

    /// Overlapping puffs make the cloud, centred on the origin.
    private static func cloudPath(bodySize: CGFloat) -> Path {
        let puffs: [(x: CGFloat, y: CGFloat, diameter: CGFloat)] = [
            (0.30, 0.56, 0.50),
            (0.50, 0.42, 0.60),
            (0.71, 0.55, 0.50),
            (0.50, 0.64, 0.56),
        ]
        var path = Path()
        for puff in puffs {
            let diameter = puff.diameter * bodySize
            path.addEllipse(in: CGRect(
                x: (puff.x - 0.5) * bodySize - diameter / 2,
                y: (puff.y - 0.5) * bodySize - diameter / 2,
                width: diameter,
                height: diameter
            ))
        }
        return path
    }

    private func drawFace(in context: inout GraphicsContext, bodySize: CGFloat, time: TimeInterval, pointerDirection: CGSize) {
        let ink = Self.inkColor
        let eyeSpacing = bodySize * 0.17
        let eyeCenterY = bodySize * 0.05
        let strokeWidth = max(1.2, bodySize * 0.05)

        // Where the eyes look: the pointer, or a scan while working.
        var lookX = pointerDirection.width
        var lookY = pointerDirection.height
        if mood == .working {
            lookX = sin(time * 2.4) * 0.9
            lookY = -0.15
        }
        let pupilShift = CGSize(width: lookX * bodySize * 0.028, height: lookY * bodySize * 0.02)

        // Blink: a short close every few seconds, staggered per colour.
        let blinkPeriod = 3.4 + Double(colorIndex % 4) * 0.7
        let blinkPhase = time.truncatingRemainder(dividingBy: blinkPeriod)
        let blinkLength = 0.14
        let eyeOpenness: CGFloat = blinkPhase < blinkLength
            ? 1 - CGFloat(sin(.pi * blinkPhase / blinkLength)) * 0.92
            : 1

        // Cheeks first, so the eyes sit on top.
        for side in [-1.0, 1.0] {
            let cheekRect = CGRect(
                x: CGFloat(side) * bodySize * 0.265 - bodySize * 0.06,
                y: bodySize * 0.13 - bodySize * 0.035,
                width: bodySize * 0.12,
                height: bodySize * 0.07
            )
            context.fill(Path(ellipseIn: cheekRect), with: .color(Self.cheekColor.opacity(mood == .happy ? 0.55 : 0.36)))
        }

        for side in [-1.0, 1.0] {
            let eyeCenter = CGPoint(x: CGFloat(side) * eyeSpacing, y: eyeCenterY)
            switch mood {
            case .happy:
                var arc = Path()
                let halfWidth = bodySize * 0.065
                arc.move(to: CGPoint(x: eyeCenter.x - halfWidth, y: eyeCenter.y + bodySize * 0.025))
                arc.addQuadCurve(
                    to: CGPoint(x: eyeCenter.x + halfWidth, y: eyeCenter.y + bodySize * 0.025),
                    control: CGPoint(x: eyeCenter.x, y: eyeCenter.y - bodySize * 0.075)
                )
                context.stroke(arc, with: .color(ink), style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
            case .sleepy:
                var arc = Path()
                let halfWidth = bodySize * 0.06
                arc.move(to: CGPoint(x: eyeCenter.x - halfWidth, y: eyeCenter.y))
                arc.addQuadCurve(
                    to: CGPoint(x: eyeCenter.x + halfWidth, y: eyeCenter.y),
                    control: CGPoint(x: eyeCenter.x, y: eyeCenter.y + bodySize * 0.06)
                )
                context.stroke(arc, with: .color(ink), style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
            default:
                let radius = bodySize * (mood == .waiting ? 0.072 : 0.058)
                let eyeRect = CGRect(
                    x: eyeCenter.x - radius + pupilShift.width,
                    y: eyeCenter.y - radius * 1.2 * eyeOpenness + pupilShift.height,
                    width: radius * 2,
                    height: radius * 2.4 * eyeOpenness
                )
                context.fill(Path(ellipseIn: eyeRect), with: .color(ink))
                if eyeOpenness > 0.5 {
                    let sparkleRadius = radius * 0.4
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: eyeCenter.x + pupilShift.width + radius * 0.15,
                            y: eyeCenter.y + pupilShift.height - radius * 0.75,
                            width: sparkleRadius * 2,
                            height: sparkleRadius * 2
                        )),
                        with: .color(.white.opacity(0.95))
                    )
                }
                if mood == .oops {
                    // Brows slanted up toward the middle: worried.
                    var brow = Path()
                    let inward = CGFloat(-side)
                    brow.move(to: CGPoint(x: eyeCenter.x - inward * bodySize * 0.06, y: eyeCenter.y - bodySize * 0.075))
                    brow.addLine(to: CGPoint(x: eyeCenter.x + inward * bodySize * 0.06, y: eyeCenter.y - bodySize * 0.12))
                    context.stroke(brow, with: .color(ink), style: StrokeStyle(lineWidth: strokeWidth * 0.8, lineCap: .round))
                }
            }
        }

        // Mouth.
        let mouthCenter = CGPoint(x: 0, y: bodySize * 0.155)
        switch mood {
        case .idle:
            var smile = Path()
            smile.move(to: CGPoint(x: mouthCenter.x - bodySize * 0.055, y: mouthCenter.y))
            smile.addQuadCurve(
                to: CGPoint(x: mouthCenter.x + bodySize * 0.055, y: mouthCenter.y),
                control: CGPoint(x: mouthCenter.x, y: mouthCenter.y + bodySize * 0.05)
            )
            context.stroke(smile, with: .color(ink), style: StrokeStyle(lineWidth: strokeWidth * 0.8, lineCap: .round))
        case .happy:
            var openSmile = Path()
            openSmile.move(to: CGPoint(x: mouthCenter.x - bodySize * 0.07, y: mouthCenter.y - bodySize * 0.01))
            openSmile.addQuadCurve(
                to: CGPoint(x: mouthCenter.x + bodySize * 0.07, y: mouthCenter.y - bodySize * 0.01),
                control: CGPoint(x: mouthCenter.x, y: mouthCenter.y + bodySize * 0.13)
            )
            openSmile.closeSubpath()
            context.fill(openSmile, with: .color(ink))
            context.fill(
                Path(ellipseIn: CGRect(x: mouthCenter.x - bodySize * 0.03, y: mouthCenter.y + bodySize * 0.045, width: bodySize * 0.06, height: bodySize * 0.035)),
                with: .color(Self.cheekColor)
            )
        case .working:
            // A tiny talking/chewing mouth.
            let openness = 0.6 + 0.4 * abs(sin(time * 7))
            context.fill(
                Path(ellipseIn: CGRect(
                    x: mouthCenter.x - bodySize * 0.025,
                    y: mouthCenter.y - bodySize * 0.02 * openness,
                    width: bodySize * 0.05,
                    height: bodySize * 0.04 * openness + bodySize * 0.01
                )),
                with: .color(ink)
            )
        case .waiting:
            context.fill(
                Path(ellipseIn: CGRect(x: mouthCenter.x - bodySize * 0.03, y: mouthCenter.y - bodySize * 0.02, width: bodySize * 0.06, height: bodySize * 0.055)),
                with: .color(ink)
            )
        case .oops:
            var wobble = Path()
            wobble.move(to: CGPoint(x: mouthCenter.x - bodySize * 0.06, y: mouthCenter.y + bodySize * 0.02))
            wobble.addQuadCurve(to: CGPoint(x: mouthCenter.x, y: mouthCenter.y + bodySize * 0.02), control: CGPoint(x: mouthCenter.x - bodySize * 0.03, y: mouthCenter.y - bodySize * 0.02))
            wobble.addQuadCurve(to: CGPoint(x: mouthCenter.x + bodySize * 0.06, y: mouthCenter.y + bodySize * 0.02), control: CGPoint(x: mouthCenter.x + bodySize * 0.03, y: mouthCenter.y + bodySize * 0.06))
            context.stroke(wobble, with: .color(ink), style: StrokeStyle(lineWidth: strokeWidth * 0.8, lineCap: .round))
        case .sleepy:
            let breathe = 0.8 + 0.2 * sin(time * 1.6)
            context.fill(
                Path(ellipseIn: CGRect(x: mouthCenter.x - bodySize * 0.022 * breathe, y: mouthCenter.y - bodySize * 0.01, width: bodySize * 0.044 * breathe, height: bodySize * 0.04 * breathe)),
                with: .color(ink.opacity(0.85))
            )
        }
    }

    private func drawExtras(in context: inout GraphicsContext, bodySize: CGFloat, time: TimeInterval, light: Color) {
        switch mood {
        case .working:
            // Three dots orbiting: "busy" legible even at list size.
            for dotIndex in 0..<3 {
                let angle = time * 2.3 + Double(dotIndex) * 2 * .pi / 3
                let orbitRadius = bodySize * 0.6
                let dotCenter = CGPoint(x: cos(angle) * orbitRadius, y: sin(angle) * orbitRadius * 0.55 - bodySize * 0.04)
                let dotRadius = bodySize * (0.045 + 0.012 * CGFloat(dotIndex))
                context.fill(
                    Path(ellipseIn: CGRect(x: dotCenter.x - dotRadius, y: dotCenter.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)),
                    with: .color(light.opacity(0.95))
                )
            }
        case .sleepy:
            for zIndex in 0..<2 {
                let phase = (time * 0.45 + Double(zIndex) * 0.5).truncatingRemainder(dividingBy: 1)
                let letterSize = bodySize * (0.14 + 0.07 * CGFloat(phase))
                let position = CGPoint(x: bodySize * (0.38 + 0.12 * CGFloat(phase)), y: -bodySize * (0.30 + 0.25 * CGFloat(phase)))
                context.draw(
                    Text("z").font(.system(size: letterSize, weight: .bold, design: .rounded)).foregroundColor(.white.opacity(0.9 - 0.7 * phase)),
                    at: position
                )
            }
        case .waiting:
            let bubbleCenter = CGPoint(x: bodySize * 0.46, y: -bodySize * 0.42)
            let bubbleRadius = bodySize * 0.13
            context.fill(
                Path(ellipseIn: CGRect(x: bubbleCenter.x - bubbleRadius, y: bubbleCenter.y - bubbleRadius, width: bubbleRadius * 2, height: bubbleRadius * 2)),
                with: .color(.white)
            )
            context.draw(
                Text("?").font(.system(size: bubbleRadius * 1.5, weight: .heavy, design: .rounded)).foregroundColor(Self.inkColor),
                at: bubbleCenter
            )
        case .happy:
            let elapsed = time - moodChangedAt
            guard elapsed >= 0, elapsed < 1.5 else { return }
            let progress = elapsed / 1.5
            for sparkleIndex in 0..<6 {
                let angle = Double(sparkleIndex) * .pi / 3 + 0.4
                let distance = bodySize * (0.45 + 0.35 * CGFloat(progress))
                let center = CGPoint(x: cos(angle) * distance, y: sin(angle) * distance * 0.9 - bodySize * 0.05)
                let starRadius = bodySize * 0.085 * CGFloat(1 - progress * 0.7)
                context.fill(Self.sparklePath(center: center, radius: starRadius), with: .color(.white.opacity(1 - progress * 0.6)))
            }
        case .idle, .oops:
            break
        }
    }

    /// A four-pointed star.
    private static func sparklePath(center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        let innerRadius = radius * 0.35
        for pointIndex in 0..<8 {
            let angle = Double(pointIndex) * .pi / 4 - .pi / 2
            let pointRadius = pointIndex % 2 == 0 ? radius : innerRadius
            let point = CGPoint(x: center.x + cos(angle) * pointRadius, y: center.y + sin(angle) * pointRadius)
            if pointIndex == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}
