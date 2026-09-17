//
//  WispIcon.swift
//  leanring-buddy
//
//  Wisp's Liquid Icon System. Every custom icon is one continuous stroke with a
//  single weight, round terminals and smooth curves, so the whole set reads as
//  if drawn from one piece of liquid glass. Icons carry their own identity and
//  are NOT boxed in a rounded square by default — a container is opt-in for the
//  rare standalone control.
//
//  Only the highest-value Wisp actions get a custom glyph (message, search, mic,
//  send, voice, files, calendar, and a gear-free settings mark). Everything else
//  falls back to an SF Symbol so the long tail stays consistent with the system
//  without us hand-drawing hundreds of icons. The renderer supports interaction/
//  status states via a tint or the signature gradient for active/processing.
//

import SwiftUI

/// The set of Wisp actions that have a bespoke liquid glyph. `.system` wraps any
/// SF Symbol so callers can use one type everywhere.
enum WispIconSymbol: Equatable {
    case message
    case search
    case mic
    case send
    case voice
    case files
    case calendar
    /// A gear-free settings mark (three soft sliders), per the brief's ask to
    /// avoid a generic gear.
    case settings
    /// Fallback to any SF Symbol by name.
    case system(String)
}

/// Visual status of an icon, driving its treatment. Kept small and subtle —
/// state is communicated by tint and a hint of motion, never a loud animation.
enum WispIconState: Equatable {
    case normal
    case active
    case processing
    case success
    case error
    case disabled
}

struct WispIcon: View {
    let symbol: WispIconSymbol
    var size: CGFloat = 18
    var state: WispIconState = .normal
    /// The resting tint. Active/processing may override with the brand gradient.
    var tint: Color = WispColor.OnGlass.textSecondary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch symbol {
            case .system(let name):
                Image(systemName: name)
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(foregroundStyle)
            default:
                strokeGlyph
            }
        }
        .frame(width: size, height: size)
        .opacity(state == .disabled ? 0.38 : 1)
    }

    /// The custom stroked glyph, rendered with the shared line style.
    private var strokeGlyph: some View {
        let lineWidth = size * 0.11
        return WispIconShape(symbol: symbol)
            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .foregroundStyle(foregroundStyle)
            .frame(width: size, height: size)
    }

    /// Tint or gradient depending on state. Active and processing get the
    /// signature gradient so the icon reads as "lit"; success/error use the
    /// semantic tone; normal uses the passed tint.
    private var foregroundStyle: AnyShapeStyle {
        switch state {
        case .active, .processing:
            return AnyShapeStyle(WispGradient.signature)
        case .success:
            return AnyShapeStyle(WispColor.success)
        case .error:
            return AnyShapeStyle(WispColor.destructive)
        case .normal, .disabled:
            return AnyShapeStyle(tint)
        }
    }
}

// MARK: - The glyph geometry

/// Draws the path for a bespoke Wisp icon. Each glyph is authored in the unit
/// square and scaled to the view's rect, so they share proportions and weight.
private struct WispIconShape: Shape {
    let symbol: WispIconSymbol

    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        func p(_ xFraction: CGFloat, _ yFraction: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + width * xFraction, y: rect.minY + height * yFraction)
        }
        func circle(_ center: CGPoint, radiusFraction: CGFloat) -> Path {
            let radius = width * radiusFraction
            return Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                          width: radius * 2, height: radius * 2))
        }
        func roundedRect(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat,
                         cornerFraction: CGFloat) -> Path {
            let frame = CGRect(x: rect.minX + width * x0, y: rect.minY + height * y0,
                               width: width * (x1 - x0), height: height * (y1 - y0))
            return Path(roundedRect: frame, cornerRadius: width * cornerFraction, style: .continuous)
        }

        var path = Path()

        switch symbol {
        case .message:
            // A rounded speech bubble with a soft flowing tail.
            path.addPath(roundedRect(0.12, 0.16, 0.88, 0.66, cornerFraction: 0.16))
            path.move(to: p(0.30, 0.66))
            path.addLine(to: p(0.24, 0.86))
            path.addLine(to: p(0.46, 0.66))

        case .search:
            // Rounded magnifier with a slightly organic handle.
            path.addPath(circle(p(0.42, 0.42), radiusFraction: 0.26))
            path.move(to: p(0.62, 0.62))
            path.addLine(to: p(0.84, 0.84))

        case .mic:
            // Soft capsule mic body + a cradle arc + stand.
            path.addPath(roundedRect(0.37, 0.10, 0.63, 0.54, cornerFraction: 0.13))
            path.addArc(center: p(0.50, 0.46), radius: width * 0.24,
                        startAngle: .degrees(20), endAngle: .degrees(160), clockwise: false)
            path.move(to: p(0.50, 0.70))
            path.addLine(to: p(0.50, 0.86))
            path.move(to: p(0.36, 0.86))
            path.addLine(to: p(0.64, 0.86))

        case .send:
            // A flowing paper-plane, customised so it reads as air, not origami.
            path.move(to: p(0.12, 0.52))
            path.addLine(to: p(0.88, 0.16))
            path.addLine(to: p(0.58, 0.88))
            path.addLine(to: p(0.46, 0.58))
            path.closeSubpath()
            path.move(to: p(0.88, 0.16))
            path.addLine(to: p(0.46, 0.58))

        case .voice:
            // Flowing concentric arcs emanating from a small centre — sound as
            // rings of air rather than conventional waveform bars.
            path.addPath(circle(p(0.28, 0.50), radiusFraction: 0.05))
            path.addArc(center: p(0.28, 0.50), radius: width * 0.22,
                        startAngle: .degrees(-55), endAngle: .degrees(55), clockwise: false)
            path.addArc(center: p(0.28, 0.50), radius: width * 0.38,
                        startAngle: .degrees(-50), endAngle: .degrees(50), clockwise: false)

        case .files:
            // Two layered translucent sheets.
            path.addPath(roundedRect(0.30, 0.14, 0.84, 0.70, cornerFraction: 0.10))
            path.addPath(roundedRect(0.16, 0.30, 0.70, 0.86, cornerFraction: 0.10))

        case .calendar:
            // Rounded calendar with simplified geometry and two soft hangers.
            path.addPath(roundedRect(0.14, 0.22, 0.86, 0.84, cornerFraction: 0.12))
            path.move(to: p(0.14, 0.40))
            path.addLine(to: p(0.86, 0.40))
            path.move(to: p(0.34, 0.14))
            path.addLine(to: p(0.34, 0.30))
            path.move(to: p(0.66, 0.14))
            path.addLine(to: p(0.66, 0.30))

        case .settings:
            // Three soft sliders with knobs — a settings mark without a gear.
            let rows: [(CGFloat, CGFloat)] = [(0.28, 0.36), (0.50, 0.64), (0.72, 0.44)]
            for (rowY, knobX) in rows {
                path.move(to: p(0.16, rowY))
                path.addLine(to: p(0.84, rowY))
                path.addPath(circle(p(knobX, rowY), radiusFraction: 0.07))
            }

        case .system:
            break  // handled by the Image branch; never reached here.
        }

        return path
    }
}
