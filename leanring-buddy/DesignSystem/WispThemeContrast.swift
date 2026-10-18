//
//  WispThemeContrast.swift
//  leanring-buddy
//
//  WCAG contrast maths for theme colours, kept to Foundation and hex strings so the
//  standalone `Tests/WispTheme` suite can compile it with `WispTheme.swift` alone.
//
//  `failures(for:)` is the gate every theme must pass in BOTH appearances. It checks
//  the pairs people actually read: accent text and secondary/primary text on the
//  window and on the glass (backdrop stop blended under the glass tint), the label on
//  an accent fill, and the AI-activity accent as a UI indicator.
//

import Foundation

/// The neutral colours themes are measured against. They mirror the theme-independent
/// tokens in `WispColor` (`background`, `textPrimary`, `textSecondary`); neutrals never
/// change with a theme, so the contrast of a theme colour against them is fixed.
nonisolated enum WispThemeReferenceNeutrals {
    static let lightBackgroundHex = "#F7F6F2"
    static let darkBackgroundHex = "#111210"
    static let lightTextPrimaryHex = "#171815"
    static let darkTextPrimaryHex = "#F2F1EC"
    static let lightTextSecondaryHex = "#5A5C55"
    static let darkTextSecondaryHex = "#ADB2A8"
}

nonisolated enum WispThemeContrast {

    static let minimumTextRatio = 4.5
    /// WCAG 1.4.11: the floor for a meaningful non-text indicator.
    static let minimumIndicatorRatio = 3.0

    // MARK: Hex parsing

    /// Red, green, blue in 0...255, or nil when `hex` is not "#RRGGBB".
    static func rgbComponents(ofHex hex: String) -> (red: Int, green: Int, blue: Int)? {
        guard hex.count == 7, hex.hasPrefix("#") else { return nil }
        guard let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
    }

    static func isValidHex(_ hex: String) -> Bool {
        rgbComponents(ofHex: hex) != nil
    }

    // MARK: Contrast

    private static func linearized(_ channel: Int) -> Double {
        let unit = Double(channel) / 255.0
        return unit <= 0.03928 ? unit / 12.92 : pow((unit + 0.055) / 1.055, 2.4)
    }

    static func relativeLuminance(ofHex hex: String) -> Double {
        guard let components = rgbComponents(ofHex: hex) else { return 0 }
        return 0.2126 * linearized(components.red)
            + 0.7152 * linearized(components.green)
            + 0.0722 * linearized(components.blue)
    }

    /// WCAG relative-luminance contrast ratio of two "#RRGGBB" colours, 1...21.
    static func ratio(foregroundHex: String, backgroundHex: String) -> Double {
        let foregroundLuminance = relativeLuminance(ofHex: foregroundHex)
        let backgroundLuminance = relativeLuminance(ofHex: backgroundHex)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Hex of `foregroundHex` composited at `alpha` over `overBackgroundHex`.
    static func blendedHex(foregroundHex: String, alpha: Double, overBackgroundHex: String) -> String {
        guard let foreground = rgbComponents(ofHex: foregroundHex),
              let background = rgbComponents(ofHex: overBackgroundHex) else {
            return overBackgroundHex
        }
        let clampedAlpha = min(max(alpha, 0), 1)
        func mixed(_ foregroundChannel: Int, _ backgroundChannel: Int) -> Int {
            let value = Double(foregroundChannel) * clampedAlpha + Double(backgroundChannel) * (1 - clampedAlpha)
            return min(max(Int(value.rounded()), 0), 255)
        }
        return String(
            format: "#%02X%02X%02X",
            mixed(foreground.red, background.red),
            mixed(foreground.green, background.green),
            mixed(foreground.blue, background.blue)
        )
    }

    // MARK: Gate

    /// Every contrast and structure failure for a theme, as readable strings; empty = pass.
    static func failures(for theme: WispTheme) -> [String] {
        var problems: [String] = []

        // Structure first: the colour checks below assume well-formed hex.
        if theme.backdropStops.count != 3 {
            problems.append("\(theme.name): needs exactly 3 backdrop stops, has \(theme.backdropStops.count)")
        }
        if theme.buddyPalette.count != WispTheme.buddyPaletteCount {
            problems.append("\(theme.name): needs \(WispTheme.buddyPaletteCount) buddy colours, has \(theme.buddyPalette.count)")
        }
        if !(0...1).contains(theme.glassTintStrength) {
            problems.append("\(theme.name): glassTintStrength \(theme.glassTintStrength) is outside 0...1")
        }
        var everyHex: [String] = [theme.textOnAccentHex, theme.islandTintHex]
        for pair in [theme.accent, theme.accentHover, theme.accentText, theme.secondaryAccent, theme.aiActivityAccent] + theme.backdropStops {
            everyHex += [pair.lightHex, pair.darkHex]
        }
        for buddyColor in theme.buddyPalette {
            everyHex += [buddyColor.lightHex, buddyColor.deepHex]
        }
        for hex in everyHex where !isValidHex(hex) {
            problems.append("\(theme.name): \"\(hex)\" is not a #RRGGBB colour")
        }
        guard problems.isEmpty else { return problems }

        func check(_ label: String, foregroundHex: String, backgroundHex: String, minimum: Double) {
            let measured = ratio(foregroundHex: foregroundHex, backgroundHex: backgroundHex)
            if measured < minimum {
                problems.append(String(
                    format: "%@: %@ is %.2f:1 (%@ on %@), needs %.1f:1",
                    theme.name, label, measured, foregroundHex, backgroundHex, minimum
                ))
            }
        }

        let appearances: [(name: String, background: String, textPrimary: String, textSecondary: String, isDark: Bool)] = [
            ("light", WispThemeReferenceNeutrals.lightBackgroundHex, WispThemeReferenceNeutrals.lightTextPrimaryHex,
             WispThemeReferenceNeutrals.lightTextSecondaryHex, false),
            ("dark", WispThemeReferenceNeutrals.darkBackgroundHex, WispThemeReferenceNeutrals.darkTextPrimaryHex,
             WispThemeReferenceNeutrals.darkTextSecondaryHex, true),
        ]

        for appearance in appearances {
            func pick(_ pair: WispThemeColorPair) -> String { appearance.isDark ? pair.darkHex : pair.lightHex }

            check("\(appearance.name) accent text on window",
                  foregroundHex: pick(theme.accentText), backgroundHex: appearance.background, minimum: minimumTextRatio)
            check("\(appearance.name) label on accent fill",
                  foregroundHex: theme.textOnAccentHex, backgroundHex: pick(theme.accent), minimum: minimumTextRatio)
            check("\(appearance.name) label on accent hover fill",
                  foregroundHex: theme.textOnAccentHex, backgroundHex: pick(theme.accentHover), minimum: minimumTextRatio)
            check("\(appearance.name) AI-activity accent on window",
                  foregroundHex: pick(theme.aiActivityAccent), backgroundHex: appearance.background, minimum: minimumIndicatorRatio)

            // Cards and bars are glass tinted by the backdrop, so text must also hold on the
            // backdrop colour at the strength it reaches the glass.
            for (stopIndex, stop) in theme.backdropStops.enumerated() {
                let glassHex = blendedHex(
                    foregroundHex: pick(stop),
                    alpha: theme.glassTintStrength,
                    overBackgroundHex: appearance.background
                )
                check("\(appearance.name) primary text on glass stop \(stopIndex + 1)",
                      foregroundHex: appearance.textPrimary, backgroundHex: glassHex, minimum: minimumTextRatio)
                check("\(appearance.name) secondary text on glass stop \(stopIndex + 1)",
                      foregroundHex: appearance.textSecondary, backgroundHex: glassHex, minimum: minimumTextRatio)
                check("\(appearance.name) accent text on glass stop \(stopIndex + 1)",
                      foregroundHex: pick(theme.accentText), backgroundHex: glassHex, minimum: minimumTextRatio)
            }
        }

        // A buddy's deep tone carries body-size white text in chat bubbles, so it needs the text ratio.
        for (buddyIndex, buddyColor) in theme.buddyPalette.enumerated() {
            check("buddy colour \(buddyIndex + 1) deep tone under white text",
                  foregroundHex: "#FFFFFF", backgroundHex: buddyColor.deepHex, minimum: minimumTextRatio)
        }

        return problems
    }
}
