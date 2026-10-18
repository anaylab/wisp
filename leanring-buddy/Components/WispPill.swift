//
//  WispPill.swift
//  leanring-buddy
//
//  The window's one button treatment. A soft fill with a faint light from above,
//  a thin lit top edge and a hairline outline — it reads as a physical, pressable
//  thing. A prominent pill is tinted with an accent (sage by default, a buddy's
//  colour in the Buddies pages) and carries a glossy sheen; otherwise it is
//  neutral and flat. Both lift on hover and squish on press with a springy
//  overshoot (a plain ease under Reduce Motion).
//
//  `WispBevel` is the same surface for anything else that should feel raised:
//  a selected tab, a selected segment, a hovered icon button.
//
//  Inside a `WispGlassContainer` a pill's body is real Liquid Glass tinted by its
//  fill, and keeps the lit top edge and hairline on top, so it still reads as a
//  physical, pressable thing refracting the theme backdrop.
//

import SwiftUI

struct WispBevel<S: InsettableShape>: ViewModifier {
    let shape: S
    let fill: Color
    var outline: Color = WispColor.cardSeparator.opacity(0.8)
    /// Opt in to real glass for the body (pills). Segment thumbs and tabs, which sit
    /// inside a glass bar already, stay flat so glass is not stacked on glass.
    var usesGlass = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.wispWindowGlassEnabled) private var isGlassEnabled

    func body(content: Content) -> some View {
        content
            .background(bodyFill)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(colorScheme == .dark ? 0.24 : 0.75), .white.opacity(0)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
            )
            .overlay(shape.strokeBorder(outline, lineWidth: 0.5))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.25 : 0.07), radius: 1.5, y: 1)
    }

    /// The body of the bevel: flat fill with a faint light from above, or, for a
    /// glass pill, the glass itself (tinted by the fill) with the same faint light.
    @ViewBuilder
    private var bodyFill: some View {
        let topLight = shape.fill(LinearGradient(
            colors: [.white.opacity(colorScheme == .dark ? 0.08 : 0.28), .clear],
            startPoint: .top, endPoint: .center))
        if usesGlass && isGlassEnabled {
            shape.fill(Color.clear)
                .glassEffect(Glass.regular.tint(fill.opacity(0.55)), in: shape)
                .overlay(topLight)
        } else {
            shape.fill(fill).overlay(topLight)
        }
    }
}

extension View {
    func wispBevel<S: InsettableShape>(
        _ shape: S,
        fill: Color,
        outline: Color = WispColor.cardSeparator.opacity(0.8),
        usesGlass: Bool = false
    ) -> some View {
        modifier(WispBevel(shape: shape, fill: fill, outline: outline, usesGlass: usesGlass))
    }
}

struct WispPillButtonStyle: ButtonStyle {
    /// The tint of a prominent pill, and of its outline.
    var accent: Color = WispColor.accentText
    /// A lighter label colour for dark mode, where a deep accent is hard to read.
    var darkModeLabelColor: Color?
    var isProminent = true

    func makeBody(configuration: Configuration) -> some View {
        WispPillBody(configuration: configuration, accent: accent, darkModeLabelColor: darkModeLabelColor, isProminent: isProminent)
    }

    /// A pill for something destructive (delete, disconnect for good).
    static var destructive: WispPillButtonStyle {
        WispPillButtonStyle(accent: WispColor.destructive, darkModeLabelColor: WispColor.destructiveText)
    }
}

private struct WispPillBody: View {
    let configuration: ButtonStyle.Configuration
    let accent: Color
    let darkModeLabelColor: Color?
    let isProminent: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    // Read from the environment, not WispMotion.prefersReducedMotion, so flipping the setting
    // while the window is open takes effect at once.
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @State private var isHovering = false

    private var labelColor: Color {
        guard isProminent else { return WispColor.textPrimary }
        return colorScheme == .dark ? (darkModeLabelColor ?? accent) : accent
    }

    private var fontSize: CGFloat {
        switch controlSize {
        case .mini, .small: return 11
        case .large, .extraLarge: return 13
        default: return 12
        }
    }

    private var horizontalPadding: CGFloat {
        switch controlSize {
        case .mini: return 9
        case .small: return 11
        case .large, .extraLarge: return 17
        default: return 13
        }
    }

    private var verticalPadding: CGFloat {
        switch controlSize {
        case .mini: return 3.5
        case .small: return 5
        case .large, .extraLarge: return 8.5
        default: return 6.5
        }
    }

    var body: some View {
        configuration.label
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(labelColor)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .wispBevel(
                Capsule(style: .continuous),
                fill: isProminent ? accent.opacity(colorScheme == .dark ? 0.30 : 0.16) : WispColor.surface3,
                outline: isProminent ? accent.opacity(0.30) : WispColor.cardSeparator.opacity(0.8),
                usesGlass: true
            )
            .overlay(glossHighlight)
            .brightness(configuration.isPressed ? -0.05 : (isHovering ? 0.03 : 0))
            // Squish on press, a small lift on hover; the spring overshoots on release.
            // Reduce Motion drops the movement itself (scale and lift); the brightness change stays.
            .scaleEffect(reducesMotion ? 1 : (configuration.isPressed ? 0.93 : (isHovering ? 1.03 : 1)))
            .offset(y: !reducesMotion && isHovering && !configuration.isPressed ? -1 : 0)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Capsule())
            .onHover { isHovering = $0 }
            .animation(reducesMotion ? WispMotion.quick : WispMotion.bouncy, value: isHovering)
            .animation(reducesMotion ? WispMotion.quick : WispMotion.bouncy, value: configuration.isPressed)
    }

    /// A glossy sheen on prominent pills: a bright band across the top half that fades
    /// out, like a lit glass button. Neutral pills stay flat.
    @ViewBuilder
    private var glossHighlight: some View {
        if isProminent {
            Capsule(style: .continuous)
                .fill(LinearGradient(
                    colors: [.white.opacity(colorScheme == .dark ? 0.16 : 0.45), .white.opacity(0)],
                    startPoint: .top, endPoint: .center))
                .padding(1)
                .allowsHitTesting(false)
        }
    }
}
