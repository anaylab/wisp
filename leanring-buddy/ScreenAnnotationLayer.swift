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

    @ObservedObject private var cursorAppearance = CursorAppearanceStore.shared

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

            ForEach(annotations.filter { $0.style == .note }) { annotation in
                if let noteText = annotation.label {
                    noteView(for: annotation, text: noteText)
                }
            }

            ForEach(annotations) { annotation in
                if annotation.style != .note, let label = annotation.label, !label.isEmpty {
                    labelView(for: annotation, text: label)
                }
            }

            ForEach(annotations) { annotation in
                if let stepNumber = annotation.stepNumber {
                    stepBadge(for: annotation, stepNumber: stepNumber)
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
        let accent = cursorAppearance.color

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

        case .marker:
            drawMarker(at: CGPoint(x: rect.minX, y: rect.minY), in: &context, color: accent)

        case .circle:
            // Slightly larger than the region so the stroke rings the thing
            // rather than cutting through it; a little wider than tall, like a
            // loop drawn by hand.
            let ring = Path(ellipseIn: rect.insetBy(dx: -8, dy: -5))
            context.stroke(ring, with: .color(accent.opacity(0.28)), lineWidth: 6)
            context.stroke(ring, with: .color(accent), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

        case .note:
            // Drawn as a text view in `noteView`, not on the canvas.
            break
        }
    }

    /// Draws a target marker at a single point: a filled centre dot ringed by
    /// two concentric circles. The outer ring breathes with the shared pulse so
    /// the eye is drawn to the spot the way the flying cursor's arrival once did,
    /// without a cursor travelling there.
    private func drawMarker(at point: CGPoint, in context: inout GraphicsContext, color: Color) {
        // The pulse expands the outer ring and fades it as it grows, a radar-ping
        // that repeats via the layer's autoreversing animation on `isPulsing`.
        let pulseProgress: CGFloat = isPulsing ? 1.0 : 0.0
        let outerRadius = 14.0 + pulseProgress * 8.0
        let outerOpacity = 0.5 - pulseProgress * 0.35

        let outerRing = Path(ellipseIn: CGRect(
            x: point.x - outerRadius,
            y: point.y - outerRadius,
            width: outerRadius * 2,
            height: outerRadius * 2
        ))
        context.stroke(outerRing, with: .color(color.opacity(outerOpacity)), lineWidth: 3)

        // A steady inner ring so the point stays marked between pulses.
        let innerRadius: CGFloat = 10
        let innerRing = Path(ellipseIn: CGRect(
            x: point.x - innerRadius,
            y: point.y - innerRadius,
            width: innerRadius * 2,
            height: innerRadius * 2
        ))
        context.stroke(innerRing, with: .color(color.opacity(0.3)), lineWidth: 6)
        context.stroke(innerRing, with: .color(color), lineWidth: 2)

        // Centre dot marking the exact spot.
        let dotRadius: CGFloat = 3
        let centreDot = Path(ellipseIn: CGRect(
            x: point.x - dotRadius,
            y: point.y - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2
        ))
        context.fill(centreDot, with: .color(color))
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

    /// A numbered badge marking this step's place in a walkthrough. Sits at the
    /// region's top-left corner so the order reads top-to-bottom, left-to-right.
    private func stepBadge(for annotation: ScreenAnnotation, stepNumber: Int) -> some View {
        let rect = overlayRect(for: annotation)
        let badgeDiameter: CGFloat = 20
        return Text("\(stepNumber)")
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(.white)
            .frame(width: badgeDiameter, height: badgeDiameter)
            .background(
                Circle()
                    .fill(cursorAppearance.color)
                    .shadow(color: cursorAppearance.color.opacity(0.5), radius: 4)
            )
            .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
            .position(x: rect.minX, y: rect.minY)
            .opacity(isPulsing ? 1.0 : 0.8)
    }

    /// Handwritten working on the screen. Written in a pen-like face over a
    /// faint highlighter band so it reads on any content. A point region is
    /// where the text starts; an element's frame puts it just to the right.
    private func noteView(for annotation: ScreenAnnotation, text: String) -> some View {
        let rect = overlayRect(for: annotation)
        let isAnchoredToElement = rect.width > 0 || rect.height > 0
        let leadingEdge = isAnchoredToElement ? rect.maxX + 12 : rect.minX
        let verticalCentre = isAnchoredToElement ? rect.midY : rect.minY

        return Text(text)
            .font(.custom("Bradley Hand", size: AnnotationClickTarget.noteFontSize).weight(.bold))
            .foregroundColor(cursorAppearance.color)
            .padding(.horizontal, AnnotationClickTarget.noteHorizontalPadding)
            .padding(.vertical, AnnotationClickTarget.noteVerticalPadding)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(cursorAppearance.color.opacity(0.16))
            )
            .fixedSize()
            .padding(.leading, max(0, leadingEdge))
            .frame(width: displaySize.width, height: max(1, verticalCentre * 2), alignment: .leading)
            .position(x: displaySize.width / 2, y: verticalCentre)
    }

    private func labelView(for annotation: ScreenAnnotation, text: String) -> some View {
        let rect = overlayRect(for: annotation)
        let estimatedLabelHeight: CGFloat = 20

        // A marker's ring extends ~22px around its point, so its label needs a
        // wider berth than a box outline does to sit clear of the ring.
        let isMarker = annotation.style == .marker
        let aboveClearance: CGFloat = isMarker ? 30 : estimatedLabelHeight
        let belowClearance: CGFloat = isMarker ? 26 : 6

        // Above the region normally, below it when there's no room above.
        let placeAbove = rect.minY > aboveClearance + 6
        let labelY = placeAbove ? rect.minY - aboveClearance : rect.maxY + belowClearance

        return Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(cursorAppearance.color)
                    .shadow(color: cursorAppearance.color.opacity(0.45), radius: 5)
            )
            .fixedSize()
            .position(x: rect.midX, y: labelY)
            .opacity(isPulsing ? 1.0 : 0.75)
    }
}
