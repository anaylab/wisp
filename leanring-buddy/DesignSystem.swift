//
//  DesignSystem.swift
//  leanring-buddy
//
//  The legacy `DS.*` design-token facade. As of the Wisp visual refresh the
//  actual brand values live in the `DesignSystem/` folder (`WispColor`,
//  `WispFont`, `WispSpacing`, `WispRadius`, `WispShadow`, `WispGradient`,
//  `WispMotion`). This file keeps the widely-used `DS.Colors.*` /
//  `DS.CornerRadius.*` / … names alive by forwarding them to those tokens, so
//  the whole app reskins from one place without every call site changing.
//
//  These forwards resolve to the *fixed dark* Wisp palette: the notch HUD and
//  the on-screen overlay stay a dark glass material in every appearance so
//  their near-white text is legible over any wallpaper. Adaptive light/dark
//  colour (for the dashboard) lives on `WispColor` directly and is adopted
//  there.
//

import SwiftUI
import AppKit

// MARK: - Design System Namespace

/// The top-level namespace for all design system tokens.
/// Usage: `DS.Colors.background`, `DS.Colors.accent`, etc.
enum DS {

    // MARK: - Color Tokens

    enum Colors {

        // ── Backgrounds ──────────────────────────────────────────────
        // Layered surfaces from deepest to most elevated.
        // Higher surfaces are lighter, creating a sense of depth.

        // These forward to the *adaptive* Wisp palette, so surfaces that follow
        // the system appearance (the dashboard, the menu-bar panel) reskin
        // light/dark for free. The always-dark surfaces (notch, overlay, menu-bar
        // panel) pin their hosting window to `.darkAqua`, so these same tokens
        // resolve to the dark values there and stay legible over any wallpaper.

        /// The deepest background — used for the main app window fill.
        static let background = WispColor.background

        /// First elevation layer — used for cards, sidebar, top bar backgrounds.
        static let surface1 = WispColor.surface1

        /// Second elevation layer — used for input fields, elevated cards, chat bubbles.
        static let surface2 = WispColor.surface2

        /// Third elevation layer — used for hover backgrounds on interactive elements.
        static let surface3 = WispColor.surface3

        /// Fourth elevation layer — used for active/pressed states on interactive elements.
        static let surface4 = WispColor.surface4

        // ── Borders ──────────────────────────────────────────────────

        /// Subtle border — used for card outlines, dividers, input field borders.
        static let borderSubtle = WispColor.borderSubtle

        /// Strong border — used for focused inputs, hovered card outlines.
        static let borderStrong = WispColor.borderStrong

        // ── Text ─────────────────────────────────────────────────────

        /// Primary text — main body text, titles, headings.
        static let textPrimary = WispColor.textPrimary

        /// Secondary text — descriptions, hints, muted labels.
        static let textSecondary = WispColor.textSecondary

        /// Tertiary text — very muted, used for section labels, timestamps, disabled text.
        static let textTertiary = WispColor.textTertiary

        /// Text used on top of the accent fill, like the primary button label.
        /// White on the moss accent reads at WCAG AA in both appearances.
        static let textOnAccent: Color = .white

        // ── Accent (Wisp moss / sage) ──────────────────────────────
        // The primary fill is dark moss; accent text is the brighter sage.

        /// Accent fill — used for solid button backgrounds. White text on dark
        /// moss (#596653) reads ~6.5:1 (WCAG AA+).
        static let accent = WispColor.accent

        /// Accent hover — a lifted moss for hover/pressed.
        static let accentHover = WispColor.accentHover

        /// Accent text — the sage brand accent for accent-coloured text and icons
        /// (deep moss on light, brighter sage on dark).
        static let accentText = WispColor.accentText

        /// Very subtle accent tint — used for selected item backgrounds (e.g. current step
        /// in the sidebar). Low opacity so it doesn't overpower.
        static let accentSubtle = WispColor.accentSubtle

        // ── Semantic Colors ──────────────────────────────────────────
        // Re-toned to fit the organic palette: an error reads as a muted
        // terracotta interruption rather than an aggressive neon red.

        /// Destructive/error actions — delete buttons, error messages, close button hover.
        static let destructive = WispColor.destructive

        /// Destructive hover state.
        static let destructiveHover = WispColor.destructiveHover

        /// Destructive used for text on dark backgrounds (brighter for readability).
        static let destructiveText = WispColor.destructiveText

        /// Success — checkmarks, granted status, completion indicators.
        /// A sage-family green so success sits inside the brand rather than beside it.
        static let success = WispColor.success

        /// Warning — caution messages, manual verification failure explanations.
        static let warning = WispColor.warning

        /// Warning text — brighter variant for text on dark backgrounds.
        static let warningText = WispColor.warningText

        /// Info/feature highlight — used for prompt card headers, code highlights.
        /// The lavender intelligence accent, so informational elements read
        /// as "Wisp is telling you something" rather than a generic blue link.
        static let info = WispColor.intelligence

        // ── Disabled State ───────────────────────────────────────────
        // Following Material Design 3's disabled pattern:
        // Container: onSurface at 12% opacity
        // Content: onSurface at 38% opacity

        /// Disabled button/container background.
        static var disabledBackground: Color {
            textPrimary.opacity(0.12)
        }
    }

    // MARK: - Spacing (for reference, not enforced)

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    // MARK: - Corner Radii

    // These forward to `WispRadius` so the whole app shares one softer,
    // rounder-rather-than-geometric scale.
    enum CornerRadius {
        /// Small elements like tags, badges.
        static let small: CGFloat = WispRadius.small        // 6
        /// Buttons, input fields, small cards.
        static let medium: CGFloat = WispRadius.medium      // 10
        /// Cards, dialogs, chat bubbles.
        static let large: CGFloat = WispRadius.large        // 14
        /// Large panels, permission cards.
        static let extraLarge: CGFloat = WispRadius.panel   // 18
        /// Pill-shaped buttons (the continue button).
        static let pill: CGFloat = .infinity
    }

    // MARK: - Animation Durations

    enum Animation {
        /// Quick state changes — hover in/out, press feedback.
        static let fast: Double = 0.15
        /// Standard transitions — content reveal, button state changes.
        static let normal: Double = 0.25
        /// Slower, more dramatic — fade-ins, celebration screen elements.
        static let slow: Double = 0.4
    }
}

// MARK: - Button Styles

/// Secondary button — supporting actions, less visual weight than primary.
/// Surface-colored background with primary text. Used for: action buttons
/// (download, open link), embedded element buttons.
struct DSSecondaryButtonStyle: ButtonStyle {
    var isFullWidth: Bool = true

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(DS.Colors.textPrimary)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.vertical, 12)
            .padding(.horizontal, isFullWidth ? 0 : 16)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface4
        } else if isHovered {
            return DS.Colors.surface3
        } else {
            return DS.Colors.surface2
        }
    }
}

/// Text button — the lowest-emphasis button style. No background on any
/// state, not even hover. Only the text color changes. Used for: "restart",
/// "skip", "cancel", and other truly minimal inline actions where a
/// background would add too much visual weight.
struct DSTextButtonStyle: ButtonStyle {
    var fontSize: CGFloat = 14

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .medium))
            .foregroundColor(
                configuration.isPressed
                    ? DS.Colors.textPrimary
                    : isHovered
                        ? DS.Colors.textPrimary
                        : DS.Colors.textTertiary
            )
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}

/// Destructive button — for dangerous/irreversible actions (close session, delete).
/// Red-tinted background that intensifies on hover and press.
struct DSDestructiveButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(
                isHovered || configuration.isPressed
                    ? .white
                    : DS.Colors.destructiveText
            )
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Capsule()
                    .stroke(
                        borderColor(isPressed: configuration.isPressed),
                        lineWidth: 1
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.destructive.opacity(0.40)
        } else if isHovered {
            return DS.Colors.destructive.opacity(0.30)
        } else {
            return DS.Colors.destructive.opacity(0.10)
        }
    }

    private func borderColor(isPressed: Bool) -> Color {
        if isPressed || isHovered {
            return DS.Colors.destructive.opacity(0.40)
        } else {
            return DS.Colors.destructive.opacity(0.15)
        }
    }
}

// MARK: - Convenience View Extensions

extension View {
    /// Attaches the shared pointing-hand cursor treatment used across interactive controls.
    /// Disabled controls can opt out so they keep the default arrow cursor.
    func pointerCursor(isEnabled: Bool = true) -> some View {
        self.overlay {
            if isEnabled {
                PointerCursorView()
            }
        }
    }
}

// MARK: - Pointer Cursor (AppKit Bridge)

/// Uses AppKit's cursor rect system to reliably show a pointing hand cursor.
/// More reliable than NSCursor.push()/pop() inside SwiftUI's .onHover because
/// cursor rects are managed at the window level and don't conflict with
/// SwiftUI's internal cursor handling.
private class PointerCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

private struct PointerCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return PointerCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Invalidate cursor rects when the view updates (e.g., resizes)
        // so AppKit recalculates the cursor area.
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

// MARK: - I-Beam Cursor (AppKit Bridge)

/// Uses AppKit's cursor rect system to reliably show an I-beam (text selection) cursor.
/// Same approach as PointerCursorView — cursor rects are managed at the window level
/// and don't conflict with SwiftUI's internal cursor handling.
/// Unlike NSCursor.push()/pop() in .onHover, this avoids cursor stack imbalance
/// when the mouse moves quickly between views.
private class IBeamCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    /// Pass through all mouse events so the TextField underneath still receives
    /// focus, clicks, and text selection. Cursor rects are registered with the
    /// window (via resetCursorRects) and work independently of hit testing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

struct IBeamCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return IBeamCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Invalidate cursor rects when the view updates (e.g., resizes)
        // so AppKit recalculates the cursor area.
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

// MARK: - Native Tooltip

/// Uses AppKit's `NSView.toolTip` to show a tooltip on hover.
/// SwiftUI's `.help()` conflicts with `.onHover` tracking areas, so
/// this bridges directly to AppKit's tooltip system which works independently.
/// Carries a tooltip but never takes a click. A plain `NSView` overlaid on a
/// SwiftUI button is hit-tested first and swallows the mouse-down, so the
/// button under it silently never fired (found with the Agent tab's "Show
/// now"). Tooltips don't need hit-testing — AppKit tracks tooltip rects per
/// window — so, like `PointerCursorNSView`, this view opts out of it.
private final class ClickThroughTooltipNSView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

private struct NativeTooltipView: NSViewRepresentable {
    let tooltip: String

    func makeNSView(context: Context) -> NSView {
        let view = ClickThroughTooltipNSView()
        view.toolTip = tooltip
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = tooltip
    }
}

extension View {
    /// Attaches a native macOS tooltip that works even alongside `.onHover`.
    func nativeTooltip(_ text: String?) -> some View {
        if let text = text, !text.isEmpty {
            return AnyView(self.overlay(NativeTooltipView(tooltip: text)))
        } else {
            return AnyView(self)
        }
    }
}

// MARK: - Color Utilities

extension Color {
    /// Create a Color from a hex string like "#FF5733" or "FF5733".
    init(hex: String) {
        let hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var rgbValue: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgbValue)

        let red = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let green = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let blue = Double(rgbValue & 0x0000FF) / 255.0

        self.init(red: red, green: green, blue: blue)
    }
}

extension View {
    /// Wisp's notch HUD surface: Apple Liquid Glass, tinted dark.
    ///
    /// It uses the real macOS 26 `.regular` glass material so the island
    /// refracts and reflects the desktop like a proper dynamic island. The trick
    /// to keeping it legible rather than a washed-out white is twofold: the HUD
    /// forces a dark colour scheme (see `NotchHUDView`), so the glass renders its
    /// dark variant, and it carries a fairly heavy dark tint here. Together that
    /// lands between "flat black box" and "bright white frost" — a translucent
    /// dark glass the near-white text stays readable on.
    func wispNotchGlassSurface<GlassShape: Shape>(in shape: GlassShape) -> some View {
        // Non-interactive on purpose: the collapsed pill is click-through and the
        // expanded panel gets its feedback from its own controls, so the pointer-
        // reactive `.interactive()` sheen bought nothing but made the glass
        // recompute every frame — which is what made the pill's grow animation
        // feel laggy as its width changed. A static tinted glass animates cheaply.
        glassEffect(.regular.tint(Color.black.opacity(0.68)), in: shape)
    }

    /// A general Liquid Glass surface for the menu bar panel and dashboard, so
    /// every Wisp surface reads as the same material rather than a mix of flat
    /// fills. Its tint is *adaptive* (`WispColor.glassTint`): frosted-light in a
    /// light-appearance surface (the dashboard sidebar) and dark in a
    /// dark-appearance surface (the menu-bar panel, which forces a dark scheme).
    func wispGlassSurface(cornerRadius: CGFloat, interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let base = Glass.regular.tint(WispColor.glassTint)
        return glassEffect(interactive ? base.interactive() : base, in: shape)
    }

    /// A lighter Liquid Glass "card" for content blocks that sit *inside* a
    /// darker surface (settings rows, list cards, chat bubbles). Uses a fainter
    /// tint so nested cards stay distinct from their container, with a hairline
    /// border to define the edge.
    func wispGlassCard(cornerRadius: CGFloat = DS.CornerRadius.large) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .glassEffect(Glass.regular.tint(WispColor.glassCardTint), in: shape)
            .overlay(
                shape.strokeBorder(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.75)
            )
    }
}
