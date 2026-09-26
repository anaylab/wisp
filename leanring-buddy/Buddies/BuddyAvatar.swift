//
//  BuddyAvatar.swift
//  leanring-buddy
//
//  A buddy's face: a soft cloud in the buddy's colour with two happy, closed
//  "^ ^" eyes, after HeyClicky's cloud characters but in Wisp's muted palette.
//  While the buddy is working it bobs gently and its eyes open; at rest it is
//  still, and its clock is paused so an idle sidebar of avatars costs nothing.
//

import SwiftUI

/// The buddies' colours: soft tones that sit with Wisp's sage/lavender brand
/// and stay distinct from one another at avatar size.
enum BuddyAppearance {
    private static let palette: [(light: Color, deep: Color)] = [
        (Color(red: 0.80, green: 0.87, blue: 0.80), Color(red: 0.55, green: 0.68, blue: 0.56)), // sage
        (Color(red: 0.86, green: 0.82, blue: 0.95), Color(red: 0.62, green: 0.56, blue: 0.82)), // lavender
        (Color(red: 0.98, green: 0.85, blue: 0.76), Color(red: 0.90, green: 0.62, blue: 0.48)), // peach
        (Color(red: 0.96, green: 0.80, blue: 0.84), Color(red: 0.85, green: 0.52, blue: 0.62)), // rose
        (Color(red: 0.78, green: 0.88, blue: 0.96), Color(red: 0.46, green: 0.64, blue: 0.84)), // sky
        (Color(red: 0.94, green: 0.89, blue: 0.74), Color(red: 0.82, green: 0.70, blue: 0.42)), // sand
        (Color(red: 0.76, green: 0.92, blue: 0.87), Color(red: 0.42, green: 0.72, blue: 0.64)), // mint
        (Color(red: 0.90, green: 0.80, blue: 0.92), Color(red: 0.72, green: 0.52, blue: 0.76)), // lilac
    ]

    static var paletteCount: Int { palette.count }

    static func lightColor(forColorIndex colorIndex: Int) -> Color {
        palette[abs(colorIndex) % palette.count].light
    }

    static func deepColor(forColorIndex colorIndex: Int) -> Color {
        palette[abs(colorIndex) % palette.count].deep
    }
}

struct BuddyAvatar: View {
    let colorIndex: Int
    var size: CGFloat = 32
    var isWorking: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isWorking || reduceMotion)) { timeline in
            let elapsedSeconds = timeline.date.timeIntervalSinceReferenceDate
            let bobOffset = isWorking && !reduceMotion ? sin(elapsedSeconds * 3.2) * size * 0.04 : 0
            ZStack {
                cloudBody
                eyes
            }
            .offset(y: bobOffset)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// Overlapping puffs make the cloud; one gradient fills them all so the
    /// seams disappear.
    private var cloudBody: some View {
        let puffLayout: [(x: CGFloat, y: CGFloat, diameter: CGFloat)] = [
            (0.30, 0.56, 0.50),
            (0.50, 0.42, 0.60),
            (0.71, 0.55, 0.50),
            (0.50, 0.64, 0.56),
        ]
        return ZStack {
            ForEach(Array(puffLayout.enumerated()), id: \.offset) { _, puff in
                Circle()
                    .frame(width: size * puff.diameter, height: size * puff.diameter)
                    .position(x: size * puff.x, y: size * puff.y)
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(
            LinearGradient(
                colors: [
                    BuddyAppearance.lightColor(forColorIndex: colorIndex),
                    BuddyAppearance.deepColor(forColorIndex: colorIndex),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .shadow(color: BuddyAppearance.deepColor(forColorIndex: colorIndex).opacity(0.45), radius: size * 0.12)
    }

    /// Happy closed "^ ^" eyes at rest; small open dots while working.
    private var eyes: some View {
        let eyeSpacing = size * 0.17
        let eyeCenterY = size * 0.55
        return ZStack {
            ForEach([-1.0, 1.0], id: \.self) { side in
                Group {
                    if isWorking {
                        Circle()
                            .fill(Color.white)
                            .frame(width: size * 0.09, height: size * 0.09)
                    } else {
                        HappyClosedEyeShape()
                            .stroke(Color.white, style: StrokeStyle(lineWidth: max(1.2, size * 0.055), lineCap: .round))
                            .frame(width: size * 0.13, height: size * 0.07)
                    }
                }
                .position(x: size / 2 + CGFloat(side) * eyeSpacing, y: eyeCenterY)
            }
        }
        .frame(width: size, height: size)
    }
}

/// A "^": an upward arc, the curve of a smiling closed eye.
private struct HappyClosedEyeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.6)
        )
        return path
    }
}
