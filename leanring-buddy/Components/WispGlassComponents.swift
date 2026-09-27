//
//  WispGlassComponents.swift
//  leanring-buddy
//
//  Wisp's reusable Liquid Glass component layer. These sit on top of the low-
//  level glass modifiers in DesignSystem.swift (`wispNotchGlassSurface`,
//  `wispGlassSurface`, `wispGlassCard`) and give the app a small vocabulary of
//  ready-made glass objects — a panel, a button, an icon control — so surfaces
//  are assembled from one shared material rather than each view re-styling glass
//  by hand.
//
//  Design intent (from the Wisp brief): glass is felt, not shouted. Blur and
//  tint are restrained; depth comes from a soft shadow and a hairline border,
//  not from heavy effects. Every interactive control has an explicit hover and
//  pressed state and a pointer cursor.
//

import SwiftUI

// MARK: - WispGlassPanel

/// A floating glass container. Use it for the Dynamic Island surface, popovers,
/// and the hero input's backdrop — anything that should read as a distinct pane
/// of glass hovering over the desktop. Content is padded and clipped to a
/// continuous rounded rectangle, with a soft island shadow.
struct WispGlassPanel<Content: View>: View {
    var cornerRadius: CGFloat = WispRadius.panel
    var padding: CGFloat = WispSpacing.lg
    var shadow: WispShadow = .floating
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .wispGlassSurface(cornerRadius: cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(WispColor.OnGlass.borderSubtle, lineWidth: 1)
            )
            .wispShadow(shadow)
    }
}

// MARK: - WispGlassButton

/// How much visual weight a glass button carries.
enum WispGlassButtonProminence {
    /// A quiet chip — faint glass fill, used for secondary actions and skill chips.
    case subtle
    /// The primary action — a sage-tinted glass fill that reads as the call to
    /// action without the heaviness of a solid accent block.
    case prominent
}

/// A glass button style with explicit hover/pressed states and a pointer cursor.
/// Complements the solid `DS*ButtonStyle` family for surfaces that live on glass
/// (the notch panel, the confirmation card).
struct WispGlassButtonStyle: ButtonStyle {
    var prominence: WispGlassButtonProminence = .subtle
    var cornerRadius: CGFloat = WispRadius.medium

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return configuration.label
            .font(WispFont.bodyMedium)
            .foregroundColor(foreground)
            .padding(.horizontal, WispSpacing.md)
            .padding(.vertical, WispSpacing.sm + 1)
            .background(shape.fill(fill(isPressed: configuration.isPressed)))
            .overlay(shape.strokeBorder(border, lineWidth: 0.75))
            .clipShape(shape)
            // Press compresses ~3%, hover is communicated by fill, not scale, so
            // the motion stays subtle.
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(reduceMotion ? nil : WispMotion.quick, value: configuration.isPressed)
            .animation(reduceMotion ? nil : WispMotion.quick, value: isHovered)
            .contentShape(shape)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private var foreground: Color {
        switch prominence {
        case .subtle:    return WispColor.OnGlass.textPrimary
        case .prominent: return WispColor.OnGlass.textPrimary
        }
    }

    private func fill(isPressed: Bool) -> Color {
        switch prominence {
        case .subtle:
            if isPressed { return Color.white.opacity(0.14) }
            if isHovered { return Color.white.opacity(0.10) }
            return WispColor.OnGlass.chipFill
        case .prominent:
            let sage = WispColor.Brand.sage
            if isPressed { return sage.opacity(0.42) }
            if isHovered { return sage.opacity(0.34) }
            return sage.opacity(0.24)
        }
    }

    private var border: Color {
        switch prominence {
        case .subtle:    return WispColor.OnGlass.borderSubtle
        case .prominent: return WispColor.Brand.sage.opacity(isHovered ? 0.6 : 0.4)
        }
    }
}

extension View {
    /// Applies the Wisp glass button style.
    func wispGlassButtonStyle(
        prominence: WispGlassButtonProminence = .subtle,
        cornerRadius: CGFloat = WispRadius.medium
    ) -> some View {
        self.buttonStyle(WispGlassButtonStyle(prominence: prominence, cornerRadius: cornerRadius))
    }
}

// MARK: - WispGlassIcon

/// A compact icon control. Per the brief, an icon should usually carry its own
/// identity without being boxed in a giant rounded square, so the default is
/// container-less — the glyph simply brightens on hover and compresses on press.
/// Pass `contained: true` for the few places a subtle glass circle is warranted
/// (a standalone header control with nothing else around it).
struct WispGlassIcon: View {
    let systemName: String
    var size: CGFloat = 22
    var contained: Bool = false
    var tint: Color = WispColor.OnGlass.textSecondary
    var activeTint: Color? = nil
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.52, weight: .medium))
                .foregroundColor(resolvedTint)
                .frame(width: size, height: size)
                .background(containerBackground)
                .contentShape(Circle())
        }
        // Press-compression lives in the button style so the tap always fires;
        // hover brightening is driven by the local hover state.
        .buttonStyle(PressableScaleButtonStyle(reduceMotion: reduceMotion))
        .animation(reduceMotion ? nil : WispMotion.quick, value: isHovered)
        .pointerCursor()
        .onHover { isHovered = $0 }
    }

    private var resolvedTint: Color {
        if let activeTint, isHovered { return activeTint }
        return isHovered ? WispColor.OnGlass.textPrimary : tint
    }

    @ViewBuilder
    private var containerBackground: some View {
        if contained {
            Circle()
                .fill(isHovered ? Color.white.opacity(0.10) : WispColor.OnGlass.chipFill)
                .overlay(Circle().strokeBorder(WispColor.OnGlass.borderSubtle, lineWidth: 0.75))
        }
    }
}

/// A minimal button style that compresses ~6% on press and nothing else — used
/// where the label already owns its own hover/tint treatment (e.g. `WispGlassIcon`).
struct PressableScaleButtonStyle: ButtonStyle {
    var reduceMotion: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(reduceMotion ? nil : WispMotion.quick, value: configuration.isPressed)
    }
}
