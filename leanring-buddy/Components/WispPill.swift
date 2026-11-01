//
//  WispPill.swift
//  leanring-buddy
//
//  The window's one button treatment, flat and quiet like OpenBot's: a neutral pill
//  with a hairline outline, and a prominent pill that is simply inverted (light on
//  dark, dark on light) with no tint, sheen, lift or squish. Premium comes from
//  restraint — one solid action per screen, everything else a quiet outline.
//
//  `WispBevel` is the matching flat surface for anything else that should read as a
//  control: a selected tab, a selected segment, a hovered icon button.
//

import SwiftUI

struct WispBevel<S: InsettableShape>: ViewModifier {
    let shape: S
    let fill: Color
    var outline: Color = WispColor.cardSeparator.opacity(0.8)
    /// Kept so existing call sites compile; surfaces are flat now, so it does nothing.
    var usesGlass = false

    func body(content: Content) -> some View {
        // Flat: a solid fill and a hairline. No lit edge, sheen or drop shadow.
        content
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(outline, lineWidth: 0.5))
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
    /// A soft red pill (delete, disconnect for good) instead of the inverted one.
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        WispPillBody(
            configuration: configuration, accent: accent, darkModeLabelColor: darkModeLabelColor,
            isProminent: isProminent, isDestructive: isDestructive)
    }

    /// A pill for something destructive (delete, disconnect for good).
    static var destructive: WispPillButtonStyle {
        WispPillButtonStyle(accent: WispColor.destructive, darkModeLabelColor: WispColor.destructiveText, isDestructive: true)
    }
}

private struct WispPillBody: View {
    let configuration: ButtonStyle.Configuration
    let accent: Color
    let darkModeLabelColor: Color?
    let isProminent: Bool
    let isDestructive: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    // Read from the environment, not WispMotion.prefersReducedMotion, so flipping the setting
    // while the window is open takes effect at once.
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @State private var isHovering = false

    /// Prominent is inverted: the text colour as the fill and the window colour as the label.
    private var labelColor: Color {
        if isDestructive { return WispColor.destructiveText }
        return isProminent ? WispColor.windowBackground : WispColor.textPrimary
    }

    private var fillColor: Color {
        if isDestructive { return WispColor.destructive.opacity(colorScheme == .dark ? 0.2 : 0.12) }
        return isProminent ? WispColor.textPrimary : WispColor.surface3
    }

    private var outlineColor: Color {
        if isDestructive { return WispColor.destructive.opacity(0.35) }
        return isProminent ? Color.clear : WispColor.cardSeparator.opacity(0.9)
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
            .wispBevel(Capsule(style: .continuous), fill: fillColor, outline: outlineColor)
            // Hover brightens a touch and press dims; nothing moves.
            .brightness(configuration.isPressed ? -0.06 : (isHovering ? 0.04 : 0))
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Capsule())
            .onHover { isHovering = $0 }
            // The finger is on the trackpad for a click, so this one always lands.
            .onChange(of: configuration.isPressed) { _, isNowPressed in
                if isNowPressed && isEnabled { WispHapticPlayer.shared.play(.tick) }
            }
            .animation(WispMotion.quick, value: isHovering)
            .animation(WispMotion.quick, value: configuration.isPressed)
    }
}
