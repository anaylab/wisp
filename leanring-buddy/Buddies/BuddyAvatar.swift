//
//  BuddyAvatar.swift
//  leanring-buddy
//
//  A buddy's face. `BuddyAvatar` is the small, cheap form used in lists and the
//  notch (still at rest, bobbing while it works); the full expressive character
//  is `BuddyCharacter`. Colours are the buddies' vivid palette.
//

import SwiftUI

/// The buddies' colours: bright, saturated tones that pop on Wisp's dark and
/// light surfaces and stay distinct from one another at avatar size.
enum BuddyAppearance {
    private static let palette: [(light: Color, deep: Color)] = [
        (Color(red: 0.50, green: 0.96, blue: 0.74), Color(red: 0.08, green: 0.72, blue: 0.55)), // mint
        (Color(red: 0.76, green: 0.64, blue: 1.00), Color(red: 0.47, green: 0.31, blue: 0.96)), // violet
        (Color(red: 1.00, green: 0.76, blue: 0.46), Color(red: 1.00, green: 0.43, blue: 0.28)), // coral
        (Color(red: 1.00, green: 0.64, blue: 0.80), Color(red: 0.95, green: 0.27, blue: 0.54)), // pink
        (Color(red: 0.52, green: 0.84, blue: 1.00), Color(red: 0.14, green: 0.50, blue: 0.98)), // sky
        (Color(red: 1.00, green: 0.91, blue: 0.42), Color(red: 0.98, green: 0.67, blue: 0.08)), // sun
        (Color(red: 0.42, green: 0.93, blue: 0.93), Color(red: 0.04, green: 0.63, blue: 0.78)), // teal
        (Color(red: 0.93, green: 0.62, blue: 0.99), Color(red: 0.72, green: 0.24, blue: 0.88)), // orchid
    ]

    static var paletteCount: Int { palette.count }

    static func lightColor(forColorIndex colorIndex: Int) -> Color {
        palette[abs(colorIndex) % palette.count].light
    }

    static func deepColor(forColorIndex colorIndex: Int) -> Color {
        palette[abs(colorIndex) % palette.count].deep
    }

    /// Top-to-bottom body gradient.
    static func gradient(forColorIndex colorIndex: Int) -> LinearGradient {
        LinearGradient(
            colors: [lightColor(forColorIndex: colorIndex), deepColor(forColorIndex: colorIndex)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Diagonal gradient for chat bubbles, headers and buttons that belong to a buddy.
    static func accentGradient(forColorIndex colorIndex: Int) -> LinearGradient {
        LinearGradient(
            colors: [deepColor(forColorIndex: colorIndex), lightColor(forColorIndex: colorIndex).opacity(0.9)],
            startPoint: .bottomLeading,
            endPoint: .topTrailing
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
