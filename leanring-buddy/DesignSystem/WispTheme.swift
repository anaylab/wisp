//
//  WispTheme.swift
//  leanring-buddy
//
//  The data behind Wisp's themes. A theme is pure values (hex strings, one per
//  appearance), so it can be read from a dynamic `NSColor` provider that runs off
//  the main actor, and so `Tests/WispTheme` can compile this file with nothing but
//  Foundation. Hex literals live ONLY in this file's theme definitions (plus the
//  fixed brand and neutral tokens in `WispColors.swift`); everything else asks the
//  current theme for its colours.
//
//  What a theme does and does not change:
//   - It drives the accent (fills, text, hover), the AI-activity accent, the
//     signature gradient, the window backdrop, glass tint strength, and the buddies'
//     colour palette.
//   - It never touches the neutrals (window background, surfaces, text, borders), so
//     contrast stays predictable, and it never touches the notch island unless the
//     user turns on "Tint the island with my theme" (`islandTintHex`).
//
//  Every theme is checked for WCAG contrast in light and dark by
//  `WispThemeContrast.failures(for:)` and `Tests/WispTheme/run.sh`.
//

import Foundation

nonisolated enum WispThemeID: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A clean white messenger look: black accent, flat surfaces, vivid buddies.
    case paper
    /// HeyClicky-style: near-black window, periwinkle accent.
    case midnight
    case aqua
    /// The original look. Its accent values are identical to `WispColor.Brand`.
    case sage
    case candy
    case sunset
    case mint
    case berryNight
    case mono

    var id: String { rawValue }
}

/// One colour that resolves differently in light and dark, as "#RRGGBB" strings.
nonisolated struct WispThemeColorPair: Equatable, Sendable {
    let lightHex: String
    let darkHex: String
}

/// A buddy's two tones: the body colour and the deeper accent used for bubbles and
/// text. Same index order as the buddy palette has always had.
nonisolated struct WispThemeBuddyColor: Equatable, Sendable {
    let lightHex: String
    let deepHex: String
}

nonisolated struct WispTheme: Identifiable, Equatable, Sendable {
    let id: WispThemeID
    /// "Paper", "Midnight", "Aqua", "Sage", "Candy", "Sunset", "Mint", "Berry Night", "Mono".
    let name: String
    /// Fills: selected tab, prominent pill, switch. Carries `textOnAccentHex` at 4.5:1 or better.
    let accent: WispThemeColorPair
    let accentHover: WispThemeColorPair
    /// The accent used as text or a thin icon on surfaces: 4.5:1 or better on the window background.
    let accentText: WispThemeColorPair
    /// Text colour on top of `accent` fills.
    let textOnAccentHex: String
    /// A second hue for secondary highlights.
    let secondaryAccent: WispThemeColorPair
    /// The AI-activity accent (thinking, listening glow, live rim). 3:1 or better on the window background.
    let aiActivityAccent: WispThemeColorPair
    /// Exactly 3 stops: top-left, middle, bottom-right of the window backdrop. Their light
    /// values are also the signature gradient (the mark), in both appearances.
    let backdropStops: [WispThemeColorPair]
    /// Exactly `WispTheme.buddyPaletteCount` entries.
    let buddyPalette: [WispThemeBuddyColor]
    /// A dark tone used for the island ONLY while "Tint the island with my theme" is on.
    let islandTintHex: String
    /// 0...1. How strongly cards and bars take the backdrop's colour.
    let glassTintStrength: Double

    /// A deeper second colour for the accent's gradient (the talk pill), so the pill can
    /// slide from the accent to another hue. Nil means the accent's hover colour. It
    /// carries `textOnAccentHex` at 4.5:1 or better, like the accent itself.
    var accentGradientEnd: WispThemeColorPair? = nil
    /// Overrides for the window's page and card colours. Nil keeps the system's own.
    var windowBackground: WispThemeColorPair? = nil
    var cardBackground: WispThemeColorPair? = nil
    /// The window follows this theme's dark look even when the Mac is in light mode
    /// (unless the user chose Light explicitly in Settings → Appearance).
    var prefersDarkAppearance: Bool = false
    /// The same, for a theme made for light (Paper).
    var prefersLightAppearance: Bool = false

    static let buddyPaletteCount = 8

    static func theme(withID themeID: WispThemeID) -> WispTheme {
        all.first { $0.id == themeID } ?? defaultTheme
    }

    /// Paper is the out-of-the-box look; every other theme is one tap away in the picker.
    static let defaultTheme: WispTheme = paper

    /// The nine themes, in picker order.
    static let all: [WispTheme] = [paper, midnight, aqua, sage, candy, sunset, mint, berryNight, mono]
}

// MARK: - The nine themes

nonisolated extension WispTheme {

    /// The original look. Accent, accent text, hover, dark-mode AI accent, signature
    /// gradient and buddy palette are exactly the pre-theme values. The one deliberate
    /// difference is the light-mode AI accent: the old soft lavender (#AAA7D9) measures
    /// 2.1:1 on the light window, under the 3:1 floor for a UI indicator, so light mode
    /// uses a deeper lavender of the same hue. Dark mode is unchanged.
    static let sage = WispTheme(
        id: .sage,
        name: "Sage",
        accent: WispThemeColorPair(lightHex: "#394438", darkHex: "#596653"),
        accentHover: WispThemeColorPair(lightHex: "#47543F", darkHex: "#67765F"),
        accentText: WispThemeColorPair(lightHex: "#394438", darkHex: "#8C9A82"),
        textOnAccentHex: "#FFFFFF",
        secondaryAccent: WispThemeColorPair(lightHex: "#6F6CA8", darkHex: "#AAA7D9"),
        aiActivityAccent: WispThemeColorPair(lightHex: "#7774B3", darkHex: "#8F8CB5"),
        backdropStops: [
            WispThemeColorPair(lightHex: "#9AA88F", darkHex: "#2A3427"),
            WispThemeColorPair(lightHex: "#C9CBC1", darkHex: "#262A24"),
            WispThemeColorPair(lightHex: "#AAA7D9", darkHex: "#2B2A44"),
        ],
        buddyPalette: [
            WispThemeBuddyColor(lightHex: "#99CCAD", deepHex: "#3F8264"),
            WispThemeBuddyColor(lightHex: "#A8A3EB", deepHex: "#6159BD"),
            WispThemeBuddyColor(lightHex: "#F0B094", deepHex: "#B35E44"),
            WispThemeBuddyColor(lightHex: "#EDA6BF", deepHex: "#B55680"),
            WispThemeBuddyColor(lightHex: "#99C7F2", deepHex: "#4277BE"),
            WispThemeBuddyColor(lightHex: "#EDD18A", deepHex: "#947022"),
            WispThemeBuddyColor(lightHex: "#8CD4D4", deepHex: "#2E808C"),
            WispThemeBuddyColor(lightHex: "#CCA8E0", deepHex: "#8557A3"),
        ],
        islandTintHex: "#10160F",
        glassTintStrength: 0.25
    )

    /// Bright, clean aqua: a saturated cyan-teal accent over a cool, sunlit backdrop, with
    /// coral, sunshine and pink buddies so the colour stays playful rather than clinical.
    /// A clean white messenger: flat white and pale-grey surfaces, a near-black accent (the
    /// user's chat bubbles, the primary buttons) and buddies in bold, saturated colour, so
    /// the characters are the only colour on the page. The backdrop is a barely-there
    /// tint, and the window holds light even when the Mac is in dark mode.
    static let paper = WispTheme(
        id: .paper,
        name: "Paper",
        accent: WispThemeColorPair(lightHex: "#15151A", darkHex: "#3A3A44"),
        accentHover: WispThemeColorPair(lightHex: "#2A2A32", darkHex: "#4A4A56"),
        accentText: WispThemeColorPair(lightHex: "#15151A", darkHex: "#E8E8EE"),
        textOnAccentHex: "#FFFFFF",
        secondaryAccent: WispThemeColorPair(lightHex: "#2F6FED", darkHex: "#8DB2FF"),
        aiActivityAccent: WispThemeColorPair(lightHex: "#7C3AED", darkHex: "#B79CFF"),
        backdropStops: [
            WispThemeColorPair(lightHex: "#FFFFFF", darkHex: "#16161A"),
            WispThemeColorPair(lightHex: "#F4F5F8", darkHex: "#111114"),
            WispThemeColorPair(lightHex: "#EEF0F5", darkHex: "#1A1A20"),
        ],
        buddyPalette: [
            WispThemeBuddyColor(lightHex: "#8F5CF2", deepHex: "#6E3CD9"),
            WispThemeBuddyColor(lightHex: "#2F86F0", deepHex: "#1F6AD0"),
            WispThemeBuddyColor(lightHex: "#2FC25B", deepHex: "#177F37"),
            WispThemeBuddyColor(lightHex: "#19B8A6", deepHex: "#0E8577"),
            WispThemeBuddyColor(lightHex: "#F5479B", deepHex: "#C42A78"),
            WispThemeBuddyColor(lightHex: "#F03A4A", deepHex: "#C0202F"),
            WispThemeBuddyColor(lightHex: "#FF7A1A", deepHex: "#C25600"),
            WispThemeBuddyColor(lightHex: "#9A5B3C", deepHex: "#774327"),
        ],
        islandTintHex: "#0A0A0A",
        glassTintStrength: 0.04,
        windowBackground: WispThemeColorPair(lightHex: "#FFFFFF", darkHex: "#101012"),
        cardBackground: WispThemeColorPair(lightHex: "#F5F5F7", darkHex: "#1A1A1D"),
        prefersLightAppearance: true
    )

    /// A near-black window with a periwinkle accent, like HeyClicky: flat dark panels, hairline
    /// edges, and one bright pill. Dark text sits on the bright accent, so the accent fill is
    /// light in both appearances; the backdrop is only a faint blue-violet glow on the black.
    static let midnight = WispTheme(
        id: .midnight,
        name: "Midnight",
        accent: WispThemeColorPair(lightHex: "#8EA2FF", darkHex: "#8FA3FF"),
        accentHover: WispThemeColorPair(lightHex: "#A5B5FF", darkHex: "#A8B8FF"),
        accentText: WispThemeColorPair(lightHex: "#3A48B8", darkHex: "#A9B7FF"),
        textOnAccentHex: "#0B0B14",
        secondaryAccent: WispThemeColorPair(lightHex: "#7A5CE6", darkHex: "#C0A8FF"),
        aiActivityAccent: WispThemeColorPair(lightHex: "#6A52D9", darkHex: "#A99BFF"),
        backdropStops: [
            WispThemeColorPair(lightHex: "#CBD3FF", darkHex: "#171738"),
            WispThemeColorPair(lightHex: "#E4D9FF", darkHex: "#0E0E10"),
            WispThemeColorPair(lightHex: "#D0E4FF", darkHex: "#1D1236"),
        ],
        buddyPalette: WispTheme.sage.buddyPalette,
        islandTintHex: "#0A0A12",
        glassTintStrength: 0.08,
        accentGradientEnd: WispThemeColorPair(lightHex: "#C6D0FF", darkHex: "#CAD4FF"),
        windowBackground: WispThemeColorPair(lightHex: "#F2F3F8", darkHex: "#0C0C0E"),
        cardBackground: WispThemeColorPair(lightHex: "#FFFFFF", darkHex: "#161618"),
        prefersDarkAppearance: true
    )

    static let aqua = WispTheme(
        id: .aqua,
        name: "Aqua",
        accent: WispThemeColorPair(lightHex: "#007C8C", darkHex: "#087486"),
        accentHover: WispThemeColorPair(lightHex: "#006B79", darkHex: "#0A8296"),
        accentText: WispThemeColorPair(lightHex: "#006675", darkHex: "#5DE6F2"),
        textOnAccentHex: "#FFFFFF",
        secondaryAccent: WispThemeColorPair(lightHex: "#2F6BD6", darkHex: "#7FB2FF"),
        aiActivityAccent: WispThemeColorPair(lightHex: "#4B5BD8", darkHex: "#93A6FF"),
        // An aurora, not a single wash: aqua in one corner, lavender on the far side and a
        // warm blush below, so the glass cards have real colour to refract.
        backdropStops: [
            WispThemeColorPair(lightHex: "#6FE7E0", darkHex: "#06566B"),
            WispThemeColorPair(lightHex: "#B9A8FF", darkHex: "#2B2478"),
            WispThemeColorPair(lightHex: "#FFC4DA", darkHex: "#5A1F4E"),
        ],
        buddyPalette: [
            WispThemeBuddyColor(lightHex: "#5CE0E6", deepHex: "#0C7F8C"),
            WispThemeBuddyColor(lightHex: "#FF9E8A", deepHex: "#C2452F"),
            WispThemeBuddyColor(lightHex: "#FFE066", deepHex: "#8F6D00"),
            WispThemeBuddyColor(lightHex: "#FF9EC8", deepHex: "#C23C80"),
            WispThemeBuddyColor(lightHex: "#8FC2FF", deepHex: "#2C6AC4"),
            WispThemeBuddyColor(lightHex: "#A6F28F", deepHex: "#337A1A"),
            WispThemeBuddyColor(lightHex: "#B8A6FF", deepHex: "#5E49C9"),
            WispThemeBuddyColor(lightHex: "#FFB866", deepHex: "#B35E00"),
        ],
        islandTintHex: "#04222B",
        glassTintStrength: 0.14,
        accentGradientEnd: WispThemeColorPair(lightHex: "#2458C4", darkHex: "#2A5FD0")
    )

    static let candy = WispTheme(
        id: .candy,
        name: "Candy",
        accent: WispThemeColorPair(lightHex: "#B83A7A", darkHex: "#A8346F"),
        accentHover: WispThemeColorPair(lightHex: "#A53069", darkHex: "#BC4483"),
        accentText: WispThemeColorPair(lightHex: "#A12D6B", darkHex: "#F08CC0"),
        textOnAccentHex: "#FFFFFF",
        secondaryAccent: WispThemeColorPair(lightHex: "#6A4FD0", darkHex: "#A58BFF"),
        aiActivityAccent: WispThemeColorPair(lightHex: "#6B4FD0", darkHex: "#A793F5"),
        backdropStops: [
            WispThemeColorPair(lightHex: "#F9B5D6", darkHex: "#5A1F44"),
            WispThemeColorPair(lightHex: "#FFD9A8", darkHex: "#4A2F5E"),
            WispThemeColorPair(lightHex: "#C9B8FF", darkHex: "#2C2A66"),
        ],
        buddyPalette: [
            WispThemeBuddyColor(lightHex: "#FFA6D0", deepHex: "#C23C84"),
            WispThemeBuddyColor(lightHex: "#B9A6FF", deepHex: "#6A4FD0"),
            WispThemeBuddyColor(lightHex: "#FFB68F", deepHex: "#BD582B"),
            WispThemeBuddyColor(lightHex: "#FF9EB8", deepHex: "#C23C60"),
            WispThemeBuddyColor(lightHex: "#8FD3FF", deepHex: "#2D79BB"),
            WispThemeBuddyColor(lightHex: "#FFE08A", deepHex: "#937015"),
            WispThemeBuddyColor(lightHex: "#8FEBD0", deepHex: "#1C846F"),
            WispThemeBuddyColor(lightHex: "#E3A6FF", deepHex: "#9A3DC2"),
        ],
        islandTintHex: "#2A0F20",
        glassTintStrength: 0.45
    )

    static let sunset = WispTheme(
        id: .sunset,
        name: "Sunset",
        accent: WispThemeColorPair(lightHex: "#B5441F", darkHex: "#B04A25"),
        accentHover: WispThemeColorPair(lightHex: "#A33A18", darkHex: "#C2552D"),
        accentText: WispThemeColorPair(lightHex: "#98330F", darkHex: "#FFA074"),
        textOnAccentHex: "#FFFFFF",
        secondaryAccent: WispThemeColorPair(lightHex: "#C23F6A", darkHex: "#FF7BA3"),
        aiActivityAccent: WispThemeColorPair(lightHex: "#7C4DBF", darkHex: "#B79CF2"),
        backdropStops: [
            WispThemeColorPair(lightHex: "#FFB38A", darkHex: "#6B2A14"),
            WispThemeColorPair(lightHex: "#FF8FA3", darkHex: "#5C1F3A"),
            WispThemeColorPair(lightHex: "#C9A6F5", darkHex: "#2E2257"),
        ],
        buddyPalette: [
            WispThemeBuddyColor(lightHex: "#FFB27A", deepHex: "#BE571A"),
            WispThemeBuddyColor(lightHex: "#F59AA8", deepHex: "#C23F57"),
            WispThemeBuddyColor(lightHex: "#FFD27A", deepHex: "#986E0D"),
            WispThemeBuddyColor(lightHex: "#FF8F7A", deepHex: "#C2402B"),
            WispThemeBuddyColor(lightHex: "#C79BF2", deepHex: "#7A44B8"),
            WispThemeBuddyColor(lightHex: "#F2A0D0", deepHex: "#B83F8A"),
            WispThemeBuddyColor(lightHex: "#9AB8F5", deepHex: "#4668C0"),
            WispThemeBuddyColor(lightHex: "#FFC09A", deepHex: "#B35F39"),
        ],
        islandTintHex: "#2A130C",
        glassTintStrength: 0.45
    )

    static let mint = WispTheme(
        id: .mint,
        name: "Mint",
        accent: WispThemeColorPair(lightHex: "#0F7B64", darkHex: "#17806A"),
        accentHover: WispThemeColorPair(lightHex: "#0B6B56", darkHex: "#1A8570"),
        accentText: WispThemeColorPair(lightHex: "#0B6B56", darkHex: "#6FE0C0"),
        textOnAccentHex: "#FFFFFF",
        secondaryAccent: WispThemeColorPair(lightHex: "#1F7AB0", darkHex: "#6CC4F2"),
        aiActivityAccent: WispThemeColorPair(lightHex: "#3F63C9", darkHex: "#8FAAF5"),
        backdropStops: [
            WispThemeColorPair(lightHex: "#A8F0D8", darkHex: "#0F4A3C"),
            WispThemeColorPair(lightHex: "#BFE9FF", darkHex: "#12405A"),
            WispThemeColorPair(lightHex: "#D6F5C0", darkHex: "#1F3F2A"),
        ],
        buddyPalette: [
            WispThemeBuddyColor(lightHex: "#8FE6C8", deepHex: "#1C8566"),
            WispThemeBuddyColor(lightHex: "#8FD0F5", deepHex: "#2A78B5"),
            WispThemeBuddyColor(lightHex: "#B6E88F", deepHex: "#48841C"),
            WispThemeBuddyColor(lightHex: "#7FE0E0", deepHex: "#1B8288"),
            WispThemeBuddyColor(lightHex: "#A9B8F5", deepHex: "#4E5FC0"),
            WispThemeBuddyColor(lightHex: "#F5E08F", deepHex: "#887413"),
            WispThemeBuddyColor(lightHex: "#C6A6F0", deepHex: "#7A4FB8"),
            WispThemeBuddyColor(lightHex: "#F5A6B8", deepHex: "#B8456A"),
        ],
        islandTintHex: "#0A2620",
        glassTintStrength: 0.40
    )

    static let berryNight = WispTheme(
        id: .berryNight,
        name: "Berry Night",
        accent: WispThemeColorPair(lightHex: "#7A2D8F", darkHex: "#8B3A9E"),
        accentHover: WispThemeColorPair(lightHex: "#6A237D", darkHex: "#9C47AF"),
        accentText: WispThemeColorPair(lightHex: "#6E2480", darkHex: "#E0A0F5"),
        textOnAccentHex: "#FFFFFF",
        secondaryAccent: WispThemeColorPair(lightHex: "#B02B63", darkHex: "#FF7FB0"),
        aiActivityAccent: WispThemeColorPair(lightHex: "#5B4BD6", darkHex: "#A99BFF"),
        backdropStops: [
            WispThemeColorPair(lightHex: "#E4B8F5", darkHex: "#3D1052"),
            WispThemeColorPair(lightHex: "#F5B8D6", darkHex: "#52123F"),
            WispThemeColorPair(lightHex: "#C5B8F5", darkHex: "#1F1A5E"),
        ],
        buddyPalette: [
            WispThemeBuddyColor(lightHex: "#E39BF5", deepHex: "#8E3AAE"),
            WispThemeBuddyColor(lightHex: "#A69BF5", deepHex: "#5444C0"),
            WispThemeBuddyColor(lightHex: "#F59BC0", deepHex: "#B83A78"),
            WispThemeBuddyColor(lightHex: "#F59B9B", deepHex: "#B8404A"),
            WispThemeBuddyColor(lightHex: "#9BB8F5", deepHex: "#3F5FC0"),
            WispThemeBuddyColor(lightHex: "#F5C79B", deepHex: "#A9631F"),
            WispThemeBuddyColor(lightHex: "#9BE0D8", deepHex: "#288279"),
            WispThemeBuddyColor(lightHex: "#C79BF5", deepHex: "#7A3AB8"),
        ],
        islandTintHex: "#1C0B26",
        glassTintStrength: 0.45
    )

    /// Greyscale chrome. The buddies keep faint hues so eight of them can still be told apart.
    static let mono = WispTheme(
        id: .mono,
        name: "Mono",
        accent: WispThemeColorPair(lightHex: "#2B2B2B", darkHex: "#5C5C5C"),
        accentHover: WispThemeColorPair(lightHex: "#444444", darkHex: "#6E6E6E"),
        accentText: WispThemeColorPair(lightHex: "#2B2B2B", darkHex: "#CFCFCF"),
        textOnAccentHex: "#FFFFFF",
        secondaryAccent: WispThemeColorPair(lightHex: "#6B6B6B", darkHex: "#A0A0A0"),
        aiActivityAccent: WispThemeColorPair(lightHex: "#55557F", darkHex: "#A8A8D0"),
        backdropStops: [
            WispThemeColorPair(lightHex: "#D4D4D4", darkHex: "#2A2A2A"),
            WispThemeColorPair(lightHex: "#EBEBEB", darkHex: "#1E1E20"),
            WispThemeColorPair(lightHex: "#CFCFD6", darkHex: "#333338"),
        ],
        buddyPalette: [
            WispThemeBuddyColor(lightHex: "#B7C2B0", deepHex: "#5E6E56"),
            WispThemeBuddyColor(lightHex: "#B5B4CC", deepHex: "#5F5E86"),
            WispThemeBuddyColor(lightHex: "#CDB7AE", deepHex: "#86584A"),
            WispThemeBuddyColor(lightHex: "#CBB1BC", deepHex: "#84506A"),
            WispThemeBuddyColor(lightHex: "#AEBFCC", deepHex: "#4D6E86"),
            WispThemeBuddyColor(lightHex: "#CCC4A8", deepHex: "#7A6E3A"),
            WispThemeBuddyColor(lightHex: "#A8C4C0", deepHex: "#3F7A76"),
            WispThemeBuddyColor(lightHex: "#C0B0CC", deepHex: "#75568A"),
        ],
        islandTintHex: "#111111",
        glassTintStrength: 0.20
    )
}
