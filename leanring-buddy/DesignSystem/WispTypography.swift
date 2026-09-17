//
//  WispTypography.swift
//  leanring-buddy
//
//  Wisp's type scale. Built on the native San Francisco family (SF Pro for text,
//  SF Mono for technical readouts) so the app reads as a first-class Mac citizen.
//  The scale favours generous, restrained hierarchy — a few large comfortable
//  headings and a calm body, rather than everything shouting in bold.
//
//  Use the semantic fonts (`WispFont.title`, `.body`, …) instead of ad-hoc
//  `.system(size:weight:)` calls so the rhythm stays consistent everywhere.
//

import SwiftUI

enum WispFont {

    // MARK: - Display & headings
    // Rounded design on the large sizes gives headings a soft, organic feel
    // that matches the brand without needing a custom typeface.

    /// The largest heading — hero moments only ("What can I help with?").
    static let hero = Font.system(size: 28, weight: .semibold, design: .rounded)
    /// Section / screen titles.
    static let title = Font.system(size: 20, weight: .semibold, design: .rounded)
    /// Card and group headers.
    static let headline = Font.system(size: 15, weight: .semibold, design: .rounded)

    // MARK: - Body & supporting

    /// Primary reading text.
    static let body = Font.system(size: 13, weight: .regular)
    /// Emphasised body.
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    /// Secondary supporting text, hints.
    static let callout = Font.system(size: 12, weight: .regular)
    /// Small labels, metadata, timestamps.
    static let caption = Font.system(size: 11, weight: .medium)
    /// The smallest label — all-caps section headers with tracking.
    static let overline = Font.system(size: 9, weight: .semibold)

    // MARK: - Technical

    /// Monospaced readouts — key capsules, code, metrics.
    static let mono = Font.system(size: 11, weight: .medium, design: .monospaced)

    // MARK: - Wordmark

    /// The lowercase "wisp" wordmark. Rounded and lightly tracked so it feels
    /// like a soft, spoken word rather than a logotype.
    static func wordmark(size: CGFloat) -> Font {
        .system(size: size, weight: .medium, design: .rounded)
    }
}

extension View {
    /// Applies an all-caps section-label treatment (overline font + tracking +
    /// tertiary colour). Centralises the repeated "SKILLS"/"REPLY" label style.
    func wispSectionLabel() -> some View {
        self.font(WispFont.overline)
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundColor(WispColor.OnGlass.textTertiary)
    }
}
