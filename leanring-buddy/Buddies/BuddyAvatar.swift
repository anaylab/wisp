//
//  BuddyAvatar.swift
//  leanring-buddy
//
//  A buddy's face. `BuddyAvatar` is the small, cheap form used in lists and the
//  notch (still at rest, bobbing while it works); the full expressive character
//  is `BuddyCharacter`. Colours come from the current theme's buddy palette.
//

import SwiftUI

/// The buddies' colours: eight calm, slightly warm hues, saturated enough to
/// tell apart at a glance and quiet enough to sit on Wisp's surfaces. Each has a
/// body tone (`light`) and a deeper accent (`deep`) used for text, bubbles and
/// buttons; gradients stay within one hue and a small tonal range, never a
/// rainbow, so nothing looks airbrushed.
enum BuddyAppearance {
    /// The eight colours come from the current theme (`WispTheme.buddyPalette`),
    /// in a fixed index order, so a buddy's `colorIndex` keeps meaning "the same
    /// slot" when the theme changes. The Sage theme holds the original hues:
    /// sage, iris, clay, rose, sky, sand, teal, plum.
    static var paletteCount: Int { WispTheme.buddyPaletteCount }

    static func lightColor(forColorIndex colorIndex: Int) -> Color {
        Color(hex: themedPaletteEntry(forColorIndex: colorIndex).lightHex)
    }

    static func deepColor(forColorIndex colorIndex: Int) -> Color {
        Color(hex: themedPaletteEntry(forColorIndex: colorIndex).deepHex)
    }

    private static func themedPaletteEntry(forColorIndex colorIndex: Int) -> WispThemeBuddyColor {
        let themedPalette = WispThemeStore.currentThemeNow.buddyPalette
        return themedPalette[abs(colorIndex) % themedPalette.count]
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
    /// Change this value to make the buddy squish, e.g. when its run finishes.
    /// The caller only changes it when Playful motion is allowed.
    var bounceTrigger: Int = 0
    /// Decorative by default. Pass words when the avatar is the only sign of a state
    /// (for example "Sky is working"), so VoiceOver can say it.
    var accessibilityDescription: String? = nil

    var body: some View {
        BuddyCharacter(
            colorIndex: colorIndex,
            size: size,
            mood: isWorking ? .working : .idle,
            liveliness: isWorking ? .working : .still,
            bounceTrigger: bounceTrigger
        )
        .accessibilityHidden(accessibilityDescription == nil)
        .accessibilityLabel(accessibilityDescription ?? "")
    }
}
