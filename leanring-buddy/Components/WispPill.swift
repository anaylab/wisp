//
//  WispPill.swift
//  leanring-buddy
//
//  The window's one button treatment. A soft fill with a faint light from above,
//  a thin lit top edge and a hairline outline — it reads as a physical, pressable
//  thing without being glossy. A prominent pill is tinted with an accent
//  (sage by default, a buddy's colour in the Buddies pages); otherwise it is
//  neutral. Both lift a touch on hover and settle on press, and nothing more.
//
//  `WispBevel` is the same surface for anything else that should feel raised:
//  a selected tab, a selected segment, a hovered icon button.
//

import SwiftUI

struct WispBevel<S: InsettableShape>: ViewModifier {
    let shape: S
    let fill: Color
    var outline: Color = WispColor.cardSeparator.opacity(0.8)

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                shape.fill(fill)
                    .overlay(
                        shape.fill(LinearGradient(
                            colors: [.white.opacity(colorScheme == .dark ? 0.08 : 0.28), .clear],
                            startPoint: .top, endPoint: .center))
                    )
            )
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
}

extension View {
    func wispBevel<S: InsettableShape>(_ shape: S, fill: Color, outline: Color = WispColor.cardSeparator.opacity(0.8)) -> some View {
        modifier(WispBevel(shape: shape, fill: fill, outline: outline))
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
                outline: isProminent ? accent.opacity(0.30) : WispColor.cardSeparator.opacity(0.8)
            )
            .brightness(configuration.isPressed ? -0.05 : (isHovering ? 0.03 : 0))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .offset(y: isHovering && !configuration.isPressed ? -0.5 : 0)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Capsule())
            .onHover { isHovering = $0 }
            .animation(WispMotion.quick, value: isHovering)
            .animation(WispMotion.quick, value: configuration.isPressed)
    }
}
