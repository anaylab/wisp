//
//  WispGradients.swift
//  leanring-buddy
//
//  The one signature Wisp gradient — Sage → Mist → Soft Lavender — and the
//  helpers that render it. The concept is light passing through a translucent
//  wisp of air, so it is used very selectively: the logo, active-AI states,
//  the voice visualisation, processing moments. It must NOT become the fill of
//  every component; that is what would tip Wisp into "AI slop".
//

import SwiftUI

enum WispGradient {

    /// The signature stops, in order. Sourced from the brand spec:
    /// `#9AA88F → #C9CBC1 → #AAA7D9`.
    static let signatureStops: [Color] = [
        Color(hex: "#9AA88F"),   // sage
        Color(hex: "#C9CBC1"),   // mist
        Color(hex: "#AAA7D9")    // soft lavender
    ]

    /// The signature gradient as a diagonal linear gradient — the default for a
    /// logo fill or an active-state wash.
    static let signature = LinearGradient(
        colors: signatureStops,
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// A linear gradient along a custom axis, for the flowing-ribbon logo where
    /// the light should travel along the stroke rather than corner-to-corner.
    static func signatureLinear(
        from start: UnitPoint,
        to end: UnitPoint
    ) -> LinearGradient {
        LinearGradient(colors: signatureStops, startPoint: start, endPoint: end)
    }

    /// The signature stops phase-shifted by `offset` (0...1), so an animated
    /// surface can appear to have light slowly moving through it. Rotating the
    /// stop order is far cheaper than animating a shader and reads the same at
    /// this scale.
    static func signatureShifted(byPhase offset: CGFloat) -> LinearGradient {
        let count = signatureStops.count
        let steps = max(1, Int(offset * CGFloat(count))) % count
        let rotated = Array(signatureStops[steps...] + signatureStops[..<steps])
        return LinearGradient(colors: rotated, startPoint: .leading, endPoint: .trailing)
    }
}
