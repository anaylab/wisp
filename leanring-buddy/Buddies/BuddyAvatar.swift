//
//  BuddyAvatar.swift
//  leanring-buddy
//
//  A buddy's face. `BuddyAvatar` is the small, cheap form used in lists and the
//  notch (still at rest, bobbing while it works); the full expressive character
//  is `BuddyCharacter`. Colours are the buddies' vivid palette.
//

import SwiftUI

/// The buddies' colours: eight calm, slightly warm hues, saturated enough to
/// tell apart at a glance and quiet enough to sit on Wisp's surfaces. Each has a
/// body tone (`light`) and a deeper accent (`deep`) used for text, bubbles and
/// buttons; gradients stay within one hue and a small tonal range, never a
/// rainbow, so nothing looks airbrushed.
enum BuddyAppearance {
    private static let palette: [(light: Color, deep: Color)] = [
        (Color(red: 0.60, green: 0.80, blue: 0.68), Color(red: 0.25, green: 0.52, blue: 0.40)), // sage
        (Color(red: 0.66, green: 0.64, blue: 0.92), Color(red: 0.38, green: 0.35, blue: 0.74)), // iris
        (Color(red: 0.94, green: 0.69, blue: 0.58), Color(red: 0.76, green: 0.40, blue: 0.29)), // clay
        (Color(red: 0.93, green: 0.65, blue: 0.75), Color(red: 0.72, green: 0.34, blue: 0.51)), // rose
        (Color(red: 0.60, green: 0.78, blue: 0.95), Color(red: 0.27, green: 0.49, blue: 0.78)), // sky
        (Color(red: 0.93, green: 0.82, blue: 0.54), Color(red: 0.70, green: 0.53, blue: 0.16)), // sand
        (Color(red: 0.55, green: 0.83, blue: 0.83), Color(red: 0.19, green: 0.52, blue: 0.57)), // teal
        (Color(red: 0.80, green: 0.66, blue: 0.88), Color(red: 0.52, green: 0.34, blue: 0.64)), // plum
    ]

    static var paletteCount: Int { palette.count }

    static func lightColor(forColorIndex colorIndex: Int) -> Color {
        palette[abs(colorIndex) % palette.count].light
    }

    static func deepColor(forColorIndex colorIndex: Int) -> Color {
        palette[abs(colorIndex) % palette.count].deep
    }

    /// Top-to-bottom body tone: the light colour easing a little toward the
    /// deep one, so the cloud has volume without a hard two-colour ramp.
    static func gradient(forColorIndex colorIndex: Int) -> LinearGradient {
        LinearGradient(
            colors: [
                lightColor(forColorIndex: colorIndex),
                lightColor(forColorIndex: colorIndex).mix(with: deepColor(forColorIndex: colorIndex), by: 0.38),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// The compact avatar for lists, the notch and Today. Now the same character
/// as everywhere else: still at rest (so a long list costs nothing), lively
/// while working.
struct BuddyAvatar: View {
    let colorIndex: Int
    var size: CGFloat = 32
    var isWorking: Bool = false

    var body: some View {
        BuddyCharacter(
            colorIndex: colorIndex,
            size: size,
            mood: isWorking ? .working : .idle,
            liveliness: isWorking ? .working : .still
        )
        .accessibilityHidden(true)
    }
}
