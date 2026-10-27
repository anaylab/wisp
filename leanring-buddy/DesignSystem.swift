//
//  DesignSystem.swift
//  leanring-buddy
//
//  Short `DS.*` names for the Wisp design tokens. The real values live in the
//  `DesignSystem/` folder (`WispColor`, `WispRadius`, …); everything here
//  forwards to them so a change there reskins the whole app without touching
//  call sites.
//
//  The colours are the adaptive ones. Always-dark surfaces (notch, overlay)
//  pin their hosting window to dark aqua, so the same names resolve to the
//  dark values there.
//

import SwiftUI
import AppKit

// MARK: - Tokens

enum DS {

    enum Colors {
        // Surfaces, from the window fill up through each level of elevation.
        static let background = WispColor.background
        static let surface1 = WispColor.surface1
        static let surface2 = WispColor.surface2
        static let surface3 = WispColor.surface3
        static let surface4 = WispColor.surface4

        // Hairlines.
        static let borderSubtle = WispColor.borderSubtle
        static let borderStrong = WispColor.borderStrong

        // Text.
        static let textPrimary = WispColor.textPrimary
        static let textSecondary = WispColor.textSecondary
        static let textTertiary = WispColor.textTertiary

        /// Label colour on top of a solid accent fill (white on the dark moss
        /// accent clears WCAG AA in both appearances).
        static let textOnAccent: Color = .white

        // Sage accent family.
        static let accent = WispColor.accent
        static let accentHover = WispColor.accentHover
        static let accentText = WispColor.accentText
        static let accentSubtle = WispColor.accentSubtle

        // Status colours, kept inside the palette (errors are a muted terracotta).
        static let destructive = WispColor.destructive
        static let destructiveHover = WispColor.destructiveHover
        static let destructiveText = WispColor.destructiveText
        static let success = WispColor.success
        static let warning = WispColor.warning
        static let warningText = WispColor.warningText
        static let info = WispColor.intelligence

        /// Fill for a disabled control.
        static var disabledBackground: Color {
            textPrimary.opacity(0.12)
        }
    }

    enum CornerRadius {
        static let small: CGFloat = WispRadius.small
        static let medium: CGFloat = WispRadius.medium
        static let large: CGFloat = WispRadius.large
        static let extraLarge: CGFloat = WispRadius.panel
        static let pill: CGFloat = .infinity
    }
}

// MARK: - Text button

/// The quietest button: no background in any state, just a text colour that
/// brightens while hovered or pressed.
struct DSTextButtonStyle: ButtonStyle {
    var fontSize: CGFloat = 14

    @State private var isPointerOverButton = false

    func makeBody(configuration: Configuration) -> some View {
        let isHighlighted = configuration.isPressed || isPointerOverButton

        return configuration.label
            .font(.system(size: fontSize, weight: .medium))
            .foregroundColor(isHighlighted ? DS.Colors.textPrimary : DS.Colors.textTertiary)
            .animation(.easeOut(duration: 0.15), value: isHighlighted)
            .onHover { isHovering in
                isPointerOverButton = isHovering
                if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}

// MARK: - Cursors

/// A transparent view whose only job is to register a cursor rectangle over
/// its bounds. Cursor rects belong to the window, so unlike push/pop inside
/// `.onHover` they stay balanced when the pointer moves quickly, and since the
/// view never hit-tests, clicks and text selection reach whatever is beneath.
private final class CursorRectView: NSView {
    private let cursorToShow: NSCursor

    init(cursor: NSCursor) {
        self.cursorToShow = cursor
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("CursorRectView is only created in code")
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: cursorToShow)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private struct CursorRectRepresentable: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> NSView {
        CursorRectView(cursor: cursor)
    }

    func updateNSView(_ cursorView: NSView, context: Context) {
        // The view may have been resized; make AppKit recompute the rectangle.
        cursorView.window?.invalidateCursorRects(for: cursorView)
    }
}

/// Overlay that shows the I-beam over a text field.
struct IBeamCursorView: View {
    var body: some View {
        CursorRectRepresentable(cursor: .iBeam)
    }
}

extension View {
    /// Shows the pointing hand over this view. Pass `false` for a disabled
    /// control so it keeps the arrow.
    func pointerCursor(isEnabled: Bool = true) -> some View {
        overlay {
            if isEnabled {
                CursorRectRepresentable(cursor: .pointingHand)
            }
        }
    }
}

// MARK: - Tooltip

/// Carries an AppKit tooltip but never takes a click. A plain `NSView` laid
/// over a SwiftUI button is hit-tested first and swallows the mouse-down, so
/// the button beneath silently stopped working; tooltips are tracked per
/// window and don't need hit-testing, so this view opts out of it.
private final class TooltipCarrierView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private struct TooltipRepresentable: NSViewRepresentable {
    let tooltipText: String

    func makeNSView(context: Context) -> NSView {
        let carrier = TooltipCarrierView()
        carrier.toolTip = tooltipText
        return carrier
    }

    func updateNSView(_ carrier: NSView, context: Context) {
        carrier.toolTip = tooltipText
    }
}

extension View {
    /// A native macOS tooltip. SwiftUI's `.help()` fights with `.onHover`
    /// tracking areas; this goes straight to AppKit and doesn't.
    @ViewBuilder
    func nativeTooltip(_ text: String?) -> some View {
        if let text, !text.isEmpty {
            overlay(TooltipRepresentable(tooltipText: text))
        } else {
            self
        }
    }
}

// MARK: - Hex colours

extension Color {
    /// Builds a colour from `"#RRGGBB"` or `"RRGGBB"`. Anything unparseable
    /// comes out black.
    init(hex: String) {
        let digits = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var packedRGB: UInt64 = 0
        Scanner(string: digits).scanHexInt64(&packedRGB)

        self.init(
            red: Double((packedRGB >> 16) & 0xFF) / 255,
            green: Double((packedRGB >> 8) & 0xFF) / 255,
            blue: Double(packedRGB & 0xFF) / 255
        )
    }
}

// MARK: - Glass surfaces

extension View {
    /// The notch HUD's surface: real macOS 26 Liquid Glass with a heavy dark
    /// tint. The HUD forces a dark colour scheme, so the glass picks its dark
    /// variant, and the tint lands it between a flat black box and bright
    /// frost — translucent, with near-white text still readable on it.
    ///
    /// Deliberately not `.interactive()`: the collapsed pill is click-through
    /// and the open panel gets its feedback from its own controls, and a
    /// pointer-reactive sheen made the glass recompute every frame, which is
    /// what made the pill's grow animation stutter.
    func wispNotchGlassSurface<GlassShape: Shape>(in shape: GlassShape) -> some View {
        glassEffect(.regular.tint(Color.black.opacity(0.68)), in: shape)
    }

    /// Liquid Glass for panels and window chrome, tinted by `WispColor.glassTint`
    /// so it frosts light in a light surface and darkens in a dark one.
    func wispGlassSurface(cornerRadius: CGFloat, interactive: Bool = false) -> some View {
        let surfaceShape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let tintedGlass = Glass.regular.tint(WispColor.glassTint)
        return glassEffect(interactive ? tintedGlass.interactive() : tintedGlass, in: surfaceShape)
    }

    /// A fainter glass card for content that sits inside a darker surface
    /// (settings rows, list cards, bubbles), outlined so its edge stays defined.
    func wispGlassCard(cornerRadius: CGFloat = DS.CornerRadius.large) -> some View {
        let cardShape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .glassEffect(Glass.regular.tint(WispColor.glassCardTint), in: cardShape)
            .overlay(
                cardShape.strokeBorder(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.75)
            )
    }
}
