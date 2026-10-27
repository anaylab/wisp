//
//  WispMark.swift
//  leanring-buddy
//
//  The liquid Wisp logo — a single flowing ribbon of air, rendered as a smooth
//  stroked bezier with round terminals and the signature Sage→Mist→Lavender
//  gradient running along it. It is intentionally NOT a cloud, flame, leaf,
//  infinity or sparkle: it is a breath of wind, communicating motion, air and
//  lightness, distinctive enough to become an app icon.
//
//  The mark is a reusable component with a static mode and a state-driven
//  animated mode. Motion is extremely subtle — liquid moving through air, never
//  a logo bouncing around — and it self-animates on a `TimelineView` clock that
//  is paused whenever the state is at rest (or Reduce Motion is on), so a
//  resident menu-bar app never redraws for no reason.
//

import SwiftUI

/// The expressive states the mark can portray. These map from the app's higher
/// level island/voice state; the mark only needs to know how to *move*.
enum WispMarkState {
    /// At rest — a still, elegant ribbon (a barely-there breath).
    case idle
    /// Capturing voice — the ribbon breathes gently in and out.
    case listening
    /// Working the model — light slowly circulates through the gradient.
    case thinking
    /// Carrying out an action — the ribbon flows in one direction.
    case acting
    /// A moment of resolution — the ribbon tightens into a stable form.
    case success
    /// Interrupted — motion stops and the form compresses slightly.
    case error

    /// Whether this state animates at all (drives whether the clock ticks).
    var isAnimated: Bool {
        switch self {
        case .idle, .success, .error: return false
        case .listening, .thinking, .acting: return true
        }
    }
}

/// The flowing ribbon path — a gentle double-curve laid on a diagonal, like a
/// gust of air. Drawn in the view's own rect so it scales to any size.
struct WispRibbonShape: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ xFraction: CGFloat, _ yFraction: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * xFraction,
                    y: rect.minY + rect.height * yFraction)
        }

        var path = Path()
        path.move(to: point(0.10, 0.64))
        // Rising first crest.
        path.addCurve(to: point(0.42, 0.30),
                      control1: point(0.14, 0.40),
                      control2: point(0.28, 0.28))
        // Dip through the middle.
        path.addCurve(to: point(0.68, 0.68),
                      control1: point(0.56, 0.32),
                      control2: point(0.58, 0.68))
        // Second, smaller rise tapering off into air.
        path.addCurve(to: point(0.90, 0.36),
                      control1: point(0.78, 0.68),
                      control2: point(0.84, 0.42))
        return path
    }
}

struct WispMark: View {
    var state: WispMarkState = .idle
    var size: CGFloat = 24
    /// When false, the mark never animates regardless of state (for use as a
    /// static logo in menus, the about box, etc.).
    var animated: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Whether the clock should tick right now.
    private var isMoving: Bool {
        animated && !reduceMotion && state.isAnimated
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isMoving)) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            ribbon(atElapsed: elapsed)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Wisp")
    }

    private func ribbon(atElapsed elapsed: TimeInterval) -> some View {
        let strokeWidth = size * 0.16

        return ZStack {
            // A soft, wide glow stroke behind the mark gives it a sense of air
            // and depth without a hard drop shadow.
            WispRibbonShape()
                .stroke(WispColor.Brand.sage.opacity(glowOpacity(atElapsed: elapsed)),
                        style: StrokeStyle(lineWidth: strokeWidth * 1.9, lineCap: .round))
                .blur(radius: size * 0.10)

            // The ribbon itself, carrying the signature gradient along its axis.
            WispRibbonShape()
                .stroke(gradient(atElapsed: elapsed),
                        style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round))
        }
        // State-level transforms: breathing while listening, a slight settle on
        // success, a compression on error.
        .scaleEffect(x: horizontalScale, y: verticalScale(atElapsed: elapsed), anchor: .center)
        .animation(reduceMotion ? nil : WispMotion.gentle, value: state)
    }

    // MARK: - Per-state motion

    /// The gradient running along the ribbon. For "thinking" its axis slowly
    /// rotates so light appears to circulate; for "acting" the stops shift so the
    /// light flows in one direction; otherwise it is a steady diagonal.
    private func gradient(atElapsed elapsed: TimeInterval) -> LinearGradient {
        switch state {
        case .thinking:
            let angle = elapsed * 0.9
            let start = UnitPoint(x: 0.5 + 0.5 * cos(angle), y: 0.5 + 0.5 * sin(angle))
            let end = UnitPoint(x: 0.5 - 0.5 * cos(angle), y: 0.5 - 0.5 * sin(angle))
            return WispGradient.signatureLinear(from: start, to: end)
        case .acting:
            let phase = CGFloat((sin(elapsed * 2.2) + 1) / 2)
            return WispGradient.signatureShifted(byPhase: phase)
        case .error:
            // Motion stops; the gradient desaturates toward a flat, quiet moss.
            return LinearGradient(colors: [WispColor.Brand.sage.opacity(0.6),
                                           WispColor.Brand.mist.opacity(0.5)],
                                  startPoint: .leading, endPoint: .trailing)
        default:
            return WispGradient.signature
        }
    }

    /// The back-glow gently breathes while listening, is steady otherwise.
    private func glowOpacity(atElapsed elapsed: TimeInterval) -> Double {
        switch state {
        case .listening:
            return 0.28 + 0.18 * Double((sin(elapsed * 3.0) + 1) / 2)
        case .thinking, .acting:
            return 0.30
        case .success:
            return 0.40
        case .idle, .error:
            return 0.16
        }
    }

    /// Listening breathes the mark vertically; other states hold at 1.
    private func verticalScale(atElapsed elapsed: TimeInterval) -> CGFloat {
        switch state {
        case .listening:
            return 1.0 + 0.06 * CGFloat((sin(elapsed * 3.0) + 1) / 2)
        default:
            return 1.0
        }
    }

    /// Error compresses the ribbon slightly; everything else is full width.
    private var horizontalScale: CGFloat {
        state == .error ? 0.94 : 1.0
    }
}

// MARK: - Convenience state mapping

extension CompanionVoiceState {
    /// The mark motion that matches the companion's current voice state, so the
    /// logo and the app's state always agree.
    var markState: WispMarkState {
        switch self {
        case .idle:       return .idle
        case .listening:  return .listening
        case .processing: return .thinking
        case .responding: return .acting
        }
    }
}
