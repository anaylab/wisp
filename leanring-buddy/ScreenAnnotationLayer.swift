//
//  ScreenAnnotationLayer.swift
//  leanring-buddy
//
//  Draws the assistant's annotations over one screen.
//
//  Rendered with Canvas rather than a stack of Shape views: several shapes
//  and their labels are drawn together, they change as a set, and Canvas
//  draws them in a single pass instead of building a view per shape. Labels
//  are the exception — they are real Text views so they pick up the system's
//  font rendering and stay legible at small sizes.
//
//  Everything is non-interactive. The overlay window ignores mouse events
//  entirely, and it sits above nearly every other window, so anything drawn
//  here must never intercept a click meant for the app underneath.
//

import SwiftUI

struct ScreenAnnotationLayer: View {
    let annotations: [ScreenAnnotation]
    /// Pixel dimensions of the screenshot the coordinates came from.
    let screenshotSize: CGSize
    /// Point dimensions of the screen being drawn on.
    let displaySize: CGSize

    /// Drives the gentle pulse. A static outline is easy to miss on a busy
    /// screen; a moving one draws the eye without demanding attention.
    @State private var isPulsing = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for annotation in annotations {
                    draw(annotation, in: &context)
                }
            }

            ForEach(annotations) { annotation in
                if let label = annotation.label, !label.isEmpty {
                    labelView(for: annotation, text: label)
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }

    private func overlayRect(for annotation: ScreenAnnotation) -> CGRect {
        annotation.regionInOverlayCoordinates(
            screenshotSize: screenshotSize,
            displaySize: displaySize
        )
    }

    private func draw(_ annotation: ScreenAnnotation, in context: inout GraphicsContext) {
        let rect = overlayRect(for: annotation)
        let accent = DS.Colors.overlayCursorBlue

        switch annotation.style {
        case .box:
            let rounded = Path(roundedRect: rect, cornerRadius: 6, style: .continuous)
            // A soft outer glow keeps the outline visible over both light and
            // dark content underneath.
            context.stroke(rounded, with: .color(accent.opacity(0.28)), lineWidth: 6)
            context.stroke(rounded, with: .color(accent), lineWidth: 2)

        case .highlight:
            let rounded = Path(roundedRect: rect, cornerRadius: 8, style: .continuous)
            context.fill(rounded, with: .color(accent.opacity(0.16)))
            context.stroke(rounded, with: .color(accent.opacity(0.55)), lineWidth: 1.5)

        case .arrow:
            drawArrow(pointingAt: CGPoint(x: rect.minX, y: rect.minY), in: &context, color: accent)
        }
    }

    /// Draws an arrow that ends just short of its target, so the tip indicates
    /// the spot without covering it.
    private func drawArrow(pointingAt target: CGPoint, in context: inout GraphicsContext, color: Color) {
        let shaftLength: CGFloat = 46
        let gap: CGFloat = 8

        // Approach from the upper left, which is clear of content more often
        // than not, and flip near the screen edge so the arrow stays on screen.
        let approachFromLeft = target.x > shaftLength + 20
        let horizontalDirection: CGFloat = approachFromLeft ? -1 : 1

        let tip = CGPoint(x: target.x + horizontalDirection * gap, y: target.y - gap)
        let tail = CGPoint(
            x: tip.x + horizontalDirection * shaftLength,
            y: tip.y - shaftLength * 0.66
        )

        var shaft = Path()
        shaft.move(to: tail)
        shaft.addLine(to: tip)
        context.stroke(shaft, with: .color(color.opacity(0.3)), lineWidth: 6)
        context.stroke(
            shaft,
            with: .color(color),
            style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
        )

        // Head, built from the shaft's own direction so it always lines up.
        let angle = atan2(tip.y - tail.y, tip.x - tail.x)
        let headLength: CGFloat = 11
        let spread: CGFloat = .pi / 7

        var head = Path()
        head.move(to: tip)
        head.addLine(to: CGPoint(
            x: tip.x - headLength * cos(angle - spread),
            y: tip.y - headLength * sin(angle - spread)
        ))
        head.addLine(to: CGPoint(
            x: tip.x - headLength * cos(angle + spread),
            y: tip.y - headLength * sin(angle + spread)
        ))
        head.closeSubpath()
        context.fill(head, with: .color(color))
    }

    private func labelView(for annotation: ScreenAnnotation, text: String) -> some View {
        let rect = overlayRect(for: annotation)
        let estimatedLabelHeight: CGFloat = 20

        // Above the region normally, below it when there's no room above.
        let placeAbove = rect.minY > estimatedLabelHeight + 6
        let labelY = placeAbove ? rect.minY - estimatedLabelHeight : rect.maxY + 6

        return Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(DS.Colors.overlayCursorBlue)
                    .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.45), radius: 5)
            )
            .fixedSize()
            .position(x: rect.midX, y: labelY)
            .opacity(isPulsing ? 1.0 : 0.75)
    }
}
