//
//  WispColors.swift
//  leanring-buddy
//
//  The Wisp brand colour system — the single source of truth for every colour
//  in the app. It replaces the old blue-on-dark palette with Wisp's organic
//  identity: warm ink, cloud and bone neutrals, a sage brand accent, and a
//  restrained lavender reserved for AI activity.
//
//  There are three layers here, in order of what you reach for:
//
//   1. `WispColor.Brand` — the raw, fixed brand hexes straight from the brand
//      spec (sage, lavender, deep moss, …). Use these for brand moments: the
//      logo, the signature gradient, an active-AI glow. They never change with
//      light/dark because they *are* the brand.
//
//   2. `WispColor` semantic tokens (`.background`, `.textPrimary`, `.accent`, …)
//      — these adapt to the system appearance. This is what adaptive surfaces
//      such as the dashboard should use so light mode is a first-class,
//      hand-tuned experience rather than an inversion.
//
//   3. `WispColor.OnGlass` — a *fixed* light-on-dark set for surfaces that stay
//      a dark glass material regardless of system appearance (the notch HUD and
//      the on-screen overlay). Those surfaces are dark on purpose so their
//      near-white text stays legible over any desktop wallpaper; flipping them
//      to light mode would make them unreadable over a dark desktop.
//
//  The legacy `DS.Colors.*` API in DesignSystem.swift now forwards into this
//  file, so the whole app reskins from one place without every call site
//  changing.
//

import SwiftUI
import AppKit

enum WispColor {

    // MARK: - 1. Raw brand palette (fixed, never adapts)

    /// The immutable brand hexes. These are the brand — they read the same in
    /// light and dark so Wisp's identity is constant across appearances.
    enum Brand {
        // ── Light-family neutrals ──
        /// Primary text / logo ink in light contexts.
        static let ink = Color(hex: "#171815")
        /// Primary light-mode application background.
        static let cloud = Color(hex: "#F7F6F2")
        /// Secondary light surfaces and subtle panels.
        static let bone = Color(hex: "#EEECE5")

        // ── Brand accents ──
        /// The primary Wisp brand accent — soft, organic sage. Used for glows,
        /// active borders, the waveform, and the middle of the signature gradient.
        static let sage = Color(hex: "#8C9A82")
        /// Borders, separators, inactive states in light contexts.
        static let mist = Color(hex: "#C9D0C3")
        /// The AI-activity / intelligence accent. Reserved for moments where
        /// Wisp is actively thinking — never a general-purpose fill.
        static let lavender = Color(hex: "#AAA7D9")
        /// Deep moss — a dark, high-contrast accent for emphasis and for filled
        /// controls that carry light text.
        static let deepMoss = Color(hex: "#394438")

        // ── Dark-family ──
        /// Primary dark-mode background — a warm near-black, not pure black.
        static let night = Color(hex: "#111210")
        /// Secondary dark surface.
        static let darkSurface = Color(hex: "#191B18")
        /// The dark-mode brand accent — a lifted moss with enough weight to
        /// carry light text at WCAG AA.
        static let darkMoss = Color(hex: "#596653")
        /// A restrained, desaturated lavender for AI activity on dark surfaces,
        /// so the intelligence accent never glares against a dark material.
        static let mutedLavender = Color(hex: "#8F8CB5")
    }

    // MARK: - 2. Adaptive semantic tokens (light + dark, hand-tuned)

    // ── Backgrounds & surfaces ──
    // In light mode surfaces recede slightly *below* the background (cloud →
    // bone → deeper bone), which reads as calm paper. In dark mode they rise
    // (night → lifted moss-greys), the conventional elevation direction.

    static let background = adaptive(light: Brand.cloud,        dark: Brand.night)
    static let surface1   = adaptive(light: Brand.bone,         dark: Brand.darkSurface)
    static let surface2   = adaptive(light: "#E7E4DC",          dark: "#202220")
    static let surface3   = adaptive(light: "#DEDBD1",          dark: "#272926")
    static let surface4   = adaptive(light: "#D4D1C5",          dark: "#2E312D")

    // ── Borders ──
    static let borderSubtle = adaptive(light: Color.black.opacity(0.08),
                                       dark:  Color.white.opacity(0.08))
    static let borderStrong = adaptive(light: Color.black.opacity(0.16),
                                       dark:  Color.white.opacity(0.16))

    // ── Text ──
    static let textPrimary   = adaptive(light: Brand.ink,   dark: "#F2F1EC")
    static let textSecondary = adaptive(light: "#5A5C55",   dark: "#ADB2A8")
    static let textTertiary  = adaptive(light: "#8A8C83",   dark: "#6E736B")
    /// Text/icon colour on top of the accent fill. White reads AA+ on both the
    /// light (deep moss) and dark (dark moss) accent fills.
    static let textOnAccent: Color = .white

    // ── Accent ──
    /// The filled-accent colour (buttons, toggles). Deep moss in light mode and
    /// dark moss in dark mode — both dark enough to carry white text at AA.
    static let accent      = adaptive(light: Brand.deepMoss, dark: Brand.darkMoss)
    /// Hover/pressed state for the accent fill — a touch lifted.
    static let accentHover = adaptive(light: "#47543F",     dark: "#67765F")
    /// Accent-coloured text/icons on surfaces (links, active nav, highlights).
    /// Deep moss on light, brighter sage on dark for legibility.
    static let accentText  = adaptive(light: Brand.deepMoss, dark: Brand.sage)
    /// Very subtle accent tint for selected rows and hovered brand chips.
    static let accentSubtle = adaptive(light: Brand.sage.opacity(0.14),
                                       dark:  Brand.sage.opacity(0.16))

    /// The intelligence accent as an adaptive token — full lavender on light,
    /// muted on dark.
    static let intelligence = adaptive(light: Brand.lavender, dark: Brand.mutedLavender)

    // ── Adaptive glass tints ──
    // For Liquid Glass surfaces that FOLLOW the system appearance (the dashboard
    // sidebar and content cards). Frosted-light in light mode, dark in dark mode.
    // Always-dark surfaces (notch, overlay) pin their window to `.darkAqua`, so
    // these resolve dark there too.

    /// Tint for a primary adaptive glass surface (sidebar, panel).
    static let glassTint = adaptive(light: Color.white.opacity(0.55),
                                    dark:  Color(hex: "#0E100D").opacity(0.55))
    /// Tint for a nested adaptive glass card.
    static let glassCardTint = adaptive(light: Color.white.opacity(0.5),
                                        dark:  Color.black.opacity(0.22))

    // ── Semantic (organic-toned, not neon) ──
    static let success        = adaptive(light: "#4E8A6B", dark: "#6FBF9B")
    static let warning        = adaptive(light: "#C6852E", dark: "#E0A458")
    static let warningText    = adaptive(light: "#A96F1F", dark: "#EDB877")
    /// Errors read as a muted terracotta, not an aggressive red — an
    /// interruption, not an alarm, per the brand's "soft rather than sterile".
    static let destructive     = adaptive(light: "#C25B54", dark: "#CE6B63")
    static let destructiveHover = adaptive(light: "#B04E47", dark: "#D97A72")
    static let destructiveText  = adaptive(light: "#B04E47", dark: "#E58880")

    // MARK: - 3. Fixed on-glass tokens (dark material, never adapts)

    /// Colours for the notch HUD and on-screen overlay, which stay a dark glass
    /// material in every appearance so their text is legible over any wallpaper.
    enum OnGlass {
        /// The dark tint applied to the glass so light text stays readable even
        /// over a bright desktop. A hair of moss keeps it warm rather than a
        /// dead black.
        static let tint = Color(hex: "#0E100D").opacity(0.55)

        static let textPrimary   = Color(hex: "#F2F1EC")
        static let textSecondary = Color(hex: "#C4C9BD")
        static let textTertiary  = Color(hex: "#878C81")

        static let borderSubtle = Color.white.opacity(0.10)
        static let borderStrong = Color.white.opacity(0.20)

        /// A faint fill for chips/cards that sit on the glass.
        static let chipFill = Color.white.opacity(0.06)
    }

    // MARK: - 4. Fixed island tokens (the notch's Dynamic Island)

    /// Colours for the notch island, modeled on Apple's Dynamic Island: a solid
    /// true-black surface, so on a notched Mac it reads as the camera cutout
    /// itself growing, with neutral white/grey text and no brand tint. Colour on
    /// the island comes from content (a card, a buddy) and from Wisp's mark and
    /// lavender activity light — never from the surface or the text.
    enum Island {
        /// Pure black, to match the physical notch exactly. Any tint or
        /// translucency leaves a visible seam where the hardware ends.
        static let surface = Color.black

        static let textPrimary   = Color.white
        static let textSecondary = Color.white.opacity(0.62)
        static let textTertiary  = Color.white.opacity(0.40)

        /// Controls and chips are flat fills on the black, with no hairlines.
        static let controlFill        = Color.white.opacity(0.10)
        static let controlFillHovered = Color.white.opacity(0.16)
        static let controlFillPressed = Color.white.opacity(0.22)

        /// The one prominent action (Allow, Show me): a white capsule with
        /// black text, like the island's play button.
        static let prominentFill = Color.white
        static let prominentText = Color.black

        /// Dividers and the few edges that still need one (a text field).
        static let separator = Color.white.opacity(0.12)
    }

    // MARK: - Adaptive helpers

    /// Builds a `Color` that resolves to `light` or `dark` live, following the
    /// window's effective appearance. Uses AppKit's dynamic `NSColor` so the
    /// colour re-resolves whenever the appearance changes, without any observers.
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
    }

    /// Convenience overload for hex string literals, so the token table above
    /// stays compact.
    static func adaptive(light: String, dark: String) -> Color {
        adaptive(light: Color(hex: light), dark: Color(hex: dark))
    }

    static func adaptive(light: Color, dark: String) -> Color {
        adaptive(light: light, dark: Color(hex: dark))
    }

    static func adaptive(light: String, dark: Color) -> Color {
        adaptive(light: Color(hex: light), dark: dark)
    }
}
