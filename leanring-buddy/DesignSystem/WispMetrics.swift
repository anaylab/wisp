//
//  WispMetrics.swift
//  leanring-buddy
//
//  Spacing and corner-radius scales. Wisp leans on generous negative space and
//  soft, rounded forms, so these two scales — plus consistent use of them — do
//  most of the work of making the UI feel calm and premium. Spacing creates
//  hierarchy; radii create the organic, rounded-rather-than-geometric feel.
//

import CoreGraphics

enum WispSpacing {
    /// 4 — tight, related elements.
    static let xs: CGFloat = 4
    /// 8 — default gap between related controls.
    static let sm: CGFloat = 8
    /// 12 — gap between grouped rows.
    static let md: CGFloat = 12
    /// 16 — standard panel padding.
    static let lg: CGFloat = 16
    /// 20 — section separation.
    static let xl: CGFloat = 20
    /// 24 — generous section separation.
    static let xxl: CGFloat = 24
    /// 32 — hero / large breathing room.
    static let xxxl: CGFloat = 32
    /// 48 — page-level breathing room around a hero.
    static let hero: CGFloat = 48
}

enum WispRadius {
    /// 6 — tags, key capsules, badges.
    static let small: CGFloat = 6
    /// 10 — buttons, chips, small cards.
    static let medium: CGFloat = 10
    /// 14 — cards, list rows.
    static let large: CGFloat = 14
    /// 18 — panels, dialogs.
    static let panel: CGFloat = 18
    /// 22 — the hero input and Dynamic Island surface (the brief's 20–24 range).
    static let input: CGFloat = 22
    /// Fully rounded — pills and circular controls.
    static let pill: CGFloat = 999
}
