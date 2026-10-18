//
//  BuddyCharacter.swift
//  leanring-buddy
//
//  The buddies' cloud characters. One `Canvas` draws the whole character from a
//  clock, so every motion is a pure function of time and costs one draw pass.
//
//  The look is deliberately quiet: a soft tonal body (one hue, small range), a
//  faint highlight and a grounded shadow beneath it, simple dark eyes. No glow,
//  no sparkle, no confetti. What gives it life is motion and expression:
//
//    · breathing and a slow float, a blink every few seconds (offset per colour
//      so a row of buddies never blinks in unison)
//    · eyes that follow the pointer, when `looksAtPointer` is on
//    · a mood (`BuddyMood`): scanning eyes and a thin turning ring while working,
//      closed smiling eyes after finishing, worried brows after a failure, wide
//      eyes and an amber badge when it needs the user's ok, closed eyes and
//      slower breathing when sleepy
//    · a small squish when `bounceTrigger` changes or the pointer arrives
//
//  `Liveliness` is the cost dial: `.still` draws one frame and never runs a
//  clock (long lists), `.working` animates only the work state (the compact
//  avatar), `.full` animates everything. Reduce Motion freezes it.
//

import AppKit
import SwiftUI

/// Hands the character's on-screen frame to the clock so its eyes can follow
/// the pointer. Holds the backing view weakly; read once per tick.
@MainActor
final class BuddyScreenFrameBox {
    weak var view: NSView?

    /// A vector from the character toward the pointer: 0 when the pointer is on
    /// top of it, growing to length 1 about 180pt away.
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

/// The silhouettes buddies come in, so a rail of them reads as a cast of different
/// characters rather than eight recolours of one cloud. A buddy's colour slot picks
/// its shape, so the pairing is stable (the same buddy is always the same creature).
enum BuddyShape: CaseIterable {
    case cloud, drop, circle, roundedSquare, triangle, pill, bean, wideBlob

    init(colorIndex: Int) {
        // Slot order is chosen so neighbouring colours never share a silhouette.
        let slotShapes: [BuddyShape] = [.circle, .drop, .cloud, .roundedSquare, .triangle, .pill, .bean, .wideBlob]
        self = slotShapes[abs(colorIndex) % slotShapes.count]
    }

    /// How far down the face sits, as a fraction of the body size. A drop and a
    /// triangle are narrow at the top, so their faces ride low where the room is.
    var faceOffsetY: CGFloat {
        switch self {
        case .drop: return 0.09
        case .triangle: return 0.13
        case .cloud: return 0.0
        case .pill: return -0.02
        case .bean: return -0.03
        default: return 0.0
        }
    }

    /// The body outline, centred on the origin, y pointing down.
    func path(bodySize: CGFloat) -> Path {
        let size = bodySize
        switch self {
        case .cloud:
            let puffs: [(x: CGFloat, y: CGFloat, diameter: CGFloat)] = [
                (0.30, 0.56, 0.50), (0.50, 0.42, 0.60), (0.71, 0.55, 0.50), (0.50, 0.64, 0.56),
            ]
            var path = Path()
            for puff in puffs {
                let diameter = puff.diameter * size
                path.addEllipse(in: CGRect(
                    x: (puff.x - 0.5) * size - diameter / 2,
                    y: (puff.y - 0.5) * size - diameter / 2,
                    width: diameter,
                    height: diameter
                ))
            }
            return path
        case .circle:
            return Path(ellipseIn: CGRect(x: -0.43 * size, y: -0.43 * size, width: 0.86 * size, height: 0.86 * size))
        case .drop:
            var path = Path()
            path.move(to: CGPoint(x: 0, y: -0.50 * size))
            path.addQuadCurve(to: CGPoint(x: 0.35 * size, y: 0.12 * size), control: CGPoint(x: 0.30 * size, y: -0.22 * size))
            path.addArc(center: CGPoint(x: 0, y: 0.12 * size), radius: 0.35 * size,
                        startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
            path.addQuadCurve(to: CGPoint(x: 0, y: -0.50 * size), control: CGPoint(x: -0.30 * size, y: -0.22 * size))
            path.closeSubpath()
            return path
        case .roundedSquare:
            return Path(roundedRect: CGRect(x: -0.38 * size, y: -0.38 * size, width: 0.76 * size, height: 0.76 * size), cornerRadius: 0.22 * size)
        case .triangle:
            let corners = [CGPoint(x: 0, y: -0.34 * size), CGPoint(x: 0.37 * size, y: 0.30 * size), CGPoint(x: -0.37 * size, y: 0.30 * size)]
            var triangle = Path()
            triangle.addLines(corners)
            triangle.closeSubpath()
            // A round join on the outline is what softens the three corners.
            var rounded = triangle.strokedPath(StrokeStyle(lineWidth: 0.15 * size, lineJoin: .round))
            rounded.addPath(triangle)
            return rounded
        case .pill:
            return Path(roundedRect: CGRect(x: -0.46 * size, y: -0.25 * size, width: 0.92 * size, height: 0.50 * size), cornerRadius: 0.25 * size)
        case .bean:
            return Path(roundedRect: CGRect(x: -0.31 * size, y: -0.43 * size, width: 0.62 * size, height: 0.86 * size), cornerRadius: 0.30 * size)
        case .wideBlob:
            return Path(roundedRect: CGRect(x: -0.46 * size, y: -0.33 * size, width: 0.92 * size, height: 0.66 * size), cornerRadius: 0.30 * size)
        }
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
    /// Change this value to make the buddy squish (a selection, a click).
    var bounceTrigger: Int = 0
    var looksAtPointer: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounceStartedAt: TimeInterval = -10
    @State private var isHovering = false
    @State private var frameBox = BuddyScreenFrameBox()

    private static let inkColor = Color(red: 0.15, green: 0.13, blue: 0.20)
    private static let cheekColor = Color(red: 0.95, green: 0.55, blue: 0.60)
    private static let badgeColor = Color(red: 0.96, green: 0.68, blue: 0.20)

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
            // Room for the working ring and the badge outside the cloud itself.
            .frame(width: size * 1.4, height: size * 1.4)
        }
        .frame(width: size, height: size)
        .background(BuddyScreenFrameReader(box: frameBox))
        .onHover { isNowHovering in
            isHovering = isNowHovering
            if isNowHovering && liveliness == .full && !reduceMotion {
                bounceStartedAt = Date.timeIntervalSinceReferenceDate
            }
        }
        .onChange(of: bounceTrigger) { _, _ in
            bounceStartedAt = Date.timeIntervalSinceReferenceDate
        }
        .accessibilityHidden(true)
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, canvasSize: CGSize, now: TimeInterval, pointerDirection: CGSize) {
        let bodySize = size
        let seed = Double(colorIndex % 8)
        let animationTime = isAnimating ? now : 0

        let breathingSpeed = mood == .sleepy ? 1.0 : 1.7
        let breathing = 1 + 0.014 * sin(animationTime * breathingSpeed + seed)
        let floatOffset: CGFloat = {
            switch mood {
            case .working: return CGFloat(sin(animationTime * 3.0) * 0.025) * bodySize
            case .sleepy: return CGFloat(sin(animationTime * 0.8 + seed) * 0.01) * bodySize
            default: return CGFloat(sin(animationTime * 1.2 + seed) * 0.018) * bodySize
            }
        }()
        let tilt: Double = mood == .oops ? sin(animationTime * 26) * 1.2 : 0

        let bounceElapsed = animationTime - bounceStartedAt
        let bounceAmount: CGFloat = (isAnimating && bounceElapsed >= 0 && bounceElapsed < 1.2)
            ? CGFloat(exp(-4.2 * bounceElapsed) * cos(bounceElapsed * 16))
            : 0
        // An idle hop every few seconds (each buddy on its own beat): squash down, spring
        // up, land with a squash. Only while resting, so it never fights a working ring.
        let hopPeriod = 5.2 + seed * 0.85
        let hopPhase = animationTime.truncatingRemainder(dividingBy: hopPeriod)
        var hopLift: CGFloat = 0
        var hopSquash: Double = 0
        if liveliness == .full, mood == .idle || mood == .happy {
            if hopPhase < 0.16 {
                hopSquash = Double(hopPhase / 0.16) * 0.10                       // crouch
            } else if hopPhase < 0.62 {
                let flight = (hopPhase - 0.16) / 0.46
                hopLift = CGFloat(sin(flight * .pi)) * bodySize * 0.20           // up and over
                hopSquash = -0.06 * sin(flight * .pi)                            // stretch tall in flight
            } else if hopPhase < 0.84 {
                hopSquash = 0.09 * exp(-6 * (hopPhase - 0.62))                   // land and settle
            }
        }
        // Leans toward the pointer, and wiggles when poked.
        let leanDegrees = Double(pointerDirection.width) * 5
        let wiggleDegrees = (isAnimating && bounceElapsed >= 0 && bounceElapsed < 1.0)
            ? sin(bounceElapsed * 22) * exp(-4 * bounceElapsed) * 7
            : 0
        let squishX = breathing + Double(bounceAmount) * 0.09 + hopSquash
        let squishY = breathing - Double(bounceAmount) * 0.09 - hopSquash

        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)

        // A soft shadow on the ground, drawn before the character moves so it
        // stays put while the cloud floats above it.
        context.drawLayer { shadowContext in
            shadowContext.addFilter(.blur(radius: bodySize * 0.05))
            let shadowWidth = bodySize * (0.50 - floatOffset / bodySize * 2)
            shadowContext.fill(
                Path(ellipseIn: CGRect(
                    x: center.x - shadowWidth / 2,
                    y: center.y + bodySize * 0.43,
                    width: shadowWidth,
                    height: bodySize * 0.07
                )),
                with: .color(.black.opacity(0.14))
            )
        }

        if mood == .working { drawWorkingRing(in: &context, center: center, bodySize: bodySize, time: animationTime) }

        context.translateBy(x: center.x + CGFloat(pointerDirection.width) * bodySize * 0.03, y: center.y + floatOffset - hopLift)
        context.rotate(by: .degrees(tilt + leanDegrees + wiggleDegrees))
        context.scaleBy(x: squishX, y: squishY)

        let buddyShape = BuddyShape(colorIndex: colorIndex)
        let bodyPath = buddyShape.path(bodySize: bodySize)
        let lightColor = BuddyAppearance.lightColor(forColorIndex: colorIndex)
        let deepColor = BuddyAppearance.deepColor(forColorIndex: colorIndex)
        let lowerColor = lightColor.mix(with: deepColor, by: 0.38)

        context.fill(
            bodyPath,
            with: .linearGradient(
                Gradient(colors: [lightColor, lowerColor]),
                startPoint: CGPoint(x: 0, y: -bodySize * 0.42),
                endPoint: CGPoint(x: 0, y: bodySize * 0.42)
            )
        )
        // Light from the top left: one faint highlight, one hairline rim.
        context.fill(
            Path(ellipseIn: CGRect(x: -bodySize * 0.27, y: -bodySize * 0.30, width: bodySize * 0.26, height: bodySize * 0.11)),
            with: .color(.white.opacity(0.22))
        )
        context.stroke(bodyPath, with: .color(.white.opacity(0.14)), lineWidth: max(0.5, bodySize * 0.012))

        context.translateBy(x: 0, y: buddyShape.faceOffsetY * bodySize)
        drawFace(in: &context, bodySize: bodySize, time: animationTime, pointerDirection: pointerDirection)

        if mood == .waiting {
            let badgeRadius = bodySize * 0.075
            let badgeCenter = CGPoint(x: bodySize * 0.40, y: -bodySize * 0.36)
            context.fill(
                Path(ellipseIn: CGRect(x: badgeCenter.x - badgeRadius, y: badgeCenter.y - badgeRadius, width: badgeRadius * 2, height: badgeRadius * 2)),
                with: .color(Self.badgeColor)
            )
            context.stroke(
                Path(ellipseIn: CGRect(x: badgeCenter.x - badgeRadius, y: badgeCenter.y - badgeRadius, width: badgeRadius * 2, height: badgeRadius * 2)),
                with: .color(.white.opacity(0.9)),
                lineWidth: max(0.8, bodySize * 0.02)
            )
        }
    }

    /// A thin arc turning around the character: "busy", without decoration.
    private func drawWorkingRing(in context: inout GraphicsContext, center: CGPoint, bodySize: CGFloat, time: TimeInterval) {
        let radius = bodySize * 0.64
        let startAngle = Angle.radians(time * 2.6)
        var arc = Path()
        arc.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: startAngle + .degrees(110), clockwise: false)
        context.stroke(
            arc,
            with: .color(BuddyAppearance.deepColor(forColorIndex: colorIndex).opacity(0.75)),
            style: StrokeStyle(lineWidth: max(1.2, bodySize * 0.035), lineCap: .round)
        )
    }

    private func drawFace(in context: inout GraphicsContext, bodySize: CGFloat, time: TimeInterval, pointerDirection: CGSize) {
        let ink = Self.inkColor
        let eyeSpacing = bodySize * 0.17
        let eyeCenterY = bodySize * 0.05
        let strokeWidth = max(1.1, bodySize * 0.045)

        var lookX = pointerDirection.width
        var lookY = pointerDirection.height
        if mood == .working {
            lookX = sin(time * 2.2) * 0.85
            lookY = -0.1
        } else if pointerDirection == .zero, liveliness == .full {
            // Nothing to follow: glance around every couple of seconds, easing between
            // spots rather than snapping, on its own schedule per buddy.
            let glanceInterval = 2.3 + Double(colorIndex % 3) * 0.6
            let glanceNumber = floor(time / glanceInterval)
            let sinceGlanceStarted = time - glanceNumber * glanceInterval
            let easeIn = min(1, sinceGlanceStarted / 0.22)
            let smoothedEase = easeIn * easeIn * (3 - 2 * easeIn)
            func glanceTarget(_ number: Double) -> CGSize {
                func unit(_ salt: Double) -> Double {
                    let raw = sin((number + Double(colorIndex)) * 127.1 + salt * 311.7) * 43758.5453
                    return (raw - floor(raw)) * 2 - 1
                }
                return CGSize(width: unit(1) * 0.9, height: unit(2) * 0.5)
            }
            let previousTarget = glanceTarget(glanceNumber - 1)
            let nextTarget = glanceTarget(glanceNumber)
            lookX = previousTarget.width + (nextTarget.width - previousTarget.width) * smoothedEase
            lookY = previousTarget.height + (nextTarget.height - previousTarget.height) * smoothedEase
        }
        let pupilShift = CGSize(width: lookX * bodySize * 0.026, height: lookY * bodySize * 0.018)

        let blinkPeriod = 3.6 + Double(colorIndex % 4) * 0.7
        let blinkPhase = time.truncatingRemainder(dividingBy: blinkPeriod)
        let blinkLength = 0.13
        let eyeOpenness: CGFloat = blinkPhase < blinkLength
            ? 1 - CGFloat(sin(.pi * blinkPhase / blinkLength)) * 0.92
            : 1

        for side in [-1.0, 1.0] {
            let cheekRect = CGRect(
                x: CGFloat(side) * bodySize * 0.26 - bodySize * 0.045,
                y: bodySize * 0.13 - bodySize * 0.025,
                width: bodySize * 0.09,
                height: bodySize * 0.05
            )
            context.fill(Path(ellipseIn: cheekRect), with: .color(Self.cheekColor.opacity(mood == .happy ? 0.30 : 0.18)))
        }

        for side in [-1.0, 1.0] {
            let eyeCenter = CGPoint(x: CGFloat(side) * eyeSpacing, y: eyeCenterY)
            switch mood {
            case .happy:
                var arc = Path()
                let halfWidth = bodySize * 0.055
                arc.move(to: CGPoint(x: eyeCenter.x - halfWidth, y: eyeCenter.y + bodySize * 0.02))
                arc.addQuadCurve(
                    to: CGPoint(x: eyeCenter.x + halfWidth, y: eyeCenter.y + bodySize * 0.02),
                    control: CGPoint(x: eyeCenter.x, y: eyeCenter.y - bodySize * 0.065)
                )
                context.stroke(arc, with: .color(ink), style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
            case .sleepy:
                var arc = Path()
                let halfWidth = bodySize * 0.055
                arc.move(to: CGPoint(x: eyeCenter.x - halfWidth, y: eyeCenter.y))
                arc.addQuadCurve(
                    to: CGPoint(x: eyeCenter.x + halfWidth, y: eyeCenter.y),
                    control: CGPoint(x: eyeCenter.x, y: eyeCenter.y + bodySize * 0.05)
                )
                context.stroke(arc, with: .color(ink), style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
            default:
                let radius = bodySize * (mood == .waiting ? 0.064 : 0.053)
                let eyeRect = CGRect(
                    x: eyeCenter.x - radius + pupilShift.width,
                    y: eyeCenter.y - radius * 1.2 * eyeOpenness + pupilShift.height,
                    width: radius * 2,
                    height: radius * 2.4 * eyeOpenness
                )
                context.fill(Path(ellipseIn: eyeRect), with: .color(ink))
                if eyeOpenness > 0.5 {
                    let sparkleRadius = radius * 0.34
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: eyeCenter.x + pupilShift.width + radius * 0.18,
                            y: eyeCenter.y + pupilShift.height - radius * 0.7,
                            width: sparkleRadius * 2,
                            height: sparkleRadius * 2
                        )),
                        with: .color(.white.opacity(0.9))
                    )
                }
                if mood == .oops {
                    var brow = Path()
                    let inward = CGFloat(-side)
                    brow.move(to: CGPoint(x: eyeCenter.x - inward * bodySize * 0.055, y: eyeCenter.y - bodySize * 0.07))
                    brow.addLine(to: CGPoint(x: eyeCenter.x + inward * bodySize * 0.055, y: eyeCenter.y - bodySize * 0.11))
                    context.stroke(brow, with: .color(ink), style: StrokeStyle(lineWidth: strokeWidth * 0.75, lineCap: .round))
                }
            }
        }

        let mouthCenter = CGPoint(x: 0, y: bodySize * 0.15)
        switch mood {
        case .idle, .waiting:
            var smile = Path()
            smile.move(to: CGPoint(x: mouthCenter.x - bodySize * 0.045, y: mouthCenter.y))
            smile.addQuadCurve(
                to: CGPoint(x: mouthCenter.x + bodySize * 0.045, y: mouthCenter.y),
                control: CGPoint(x: mouthCenter.x, y: mouthCenter.y + (mood == .waiting ? 0.02 : 0.04) * bodySize)
            )
            context.stroke(smile, with: .color(ink), style: StrokeStyle(lineWidth: strokeWidth * 0.75, lineCap: .round))
        case .happy:
            var openSmile = Path()
            openSmile.move(to: CGPoint(x: mouthCenter.x - bodySize * 0.06, y: mouthCenter.y - bodySize * 0.005))
            openSmile.addQuadCurve(
                to: CGPoint(x: mouthCenter.x + bodySize * 0.06, y: mouthCenter.y - bodySize * 0.005),
                control: CGPoint(x: mouthCenter.x, y: mouthCenter.y + bodySize * 0.11)
            )
            openSmile.closeSubpath()
            context.fill(openSmile, with: .color(ink))
        case .working:
            let openness = 0.6 + 0.4 * abs(sin(time * 6))
            context.fill(
                Path(ellipseIn: CGRect(
                    x: mouthCenter.x - bodySize * 0.022,
                    y: mouthCenter.y - bodySize * 0.016 * openness,
                    width: bodySize * 0.044,
                    height: bodySize * 0.034 * openness + bodySize * 0.008
                )),
                with: .color(ink)
            )
        case .oops:
            var wobble = Path()
            wobble.move(to: CGPoint(x: mouthCenter.x - bodySize * 0.05, y: mouthCenter.y + bodySize * 0.02))
            wobble.addQuadCurve(to: CGPoint(x: mouthCenter.x, y: mouthCenter.y + bodySize * 0.02), control: CGPoint(x: mouthCenter.x - bodySize * 0.025, y: mouthCenter.y - bodySize * 0.015))
            wobble.addQuadCurve(to: CGPoint(x: mouthCenter.x + bodySize * 0.05, y: mouthCenter.y + bodySize * 0.02), control: CGPoint(x: mouthCenter.x + bodySize * 0.025, y: mouthCenter.y + bodySize * 0.055))
            context.stroke(wobble, with: .color(ink), style: StrokeStyle(lineWidth: strokeWidth * 0.75, lineCap: .round))
        case .sleepy:
            let breathe = 0.8 + 0.2 * sin(time * 1.2)
            context.fill(
                Path(ellipseIn: CGRect(x: mouthCenter.x - bodySize * 0.018 * breathe, y: mouthCenter.y - bodySize * 0.008, width: bodySize * 0.036 * breathe, height: bodySize * 0.032 * breathe)),
                with: .color(ink.opacity(0.8))
            )
        }
    }
}
