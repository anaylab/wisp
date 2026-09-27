//
//  WispShadows.swift
//  leanring-buddy
//
//  Shadow tokens. Wisp should feel like floating glass, not a card stacked on a
//  page — so every shadow here is soft, low-opacity, and generously blurred.
//  There is no heavy drop shadow anywhere; depth comes from a faint ambient
//  shadow plus the glass material itself.
//

import SwiftUI

/// A single, reusable shadow definition (colour + blur + offset).
struct WispShadow {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat

    /// Barely-there depth for resting cards and chips.
    static let ambient = WispShadow(color: .black.opacity(0.10), radius: 10, x: 0, y: 4)

    /// A floating element lifted off the surface — panels, popovers.
    static let floating = WispShadow(color: .black.opacity(0.16), radius: 24, x: 0, y: 10)

    /// The Dynamic Island / notch surface, which sits above everything and needs
    /// to read as a distinct floating object without a hard edge.
    static let island = WispShadow(color: .black.opacity(0.22), radius: 30, x: 0, y: 12)
}

extension View {
    /// Applies a `WispShadow`. Keeping this on the view layer (rather than baking
    /// offsets into every call site) keeps depth consistent and easy to retune.
    func wispShadow(_ shadow: WispShadow) -> some View {
        self.shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
    }
}
