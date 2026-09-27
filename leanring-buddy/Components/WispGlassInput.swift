//
//  WispGlassInput.swift
//  leanring-buddy
//
//  The floating "Ask Wisp anything…" input — the physical-object text field from
//  the brief. It is a pane of glass with a soft hairline border and a very low
//  shadow; on focus the signature Wisp gradient rises gently into the border, so
//  the field feels like it wakes up rather than snapping to a hard focus ring.
//
//  It is deliberately self-contained and reusable: the Dynamic Island's hero
//  moment and the dashboard command centre can both drop it in with a binding, a
//  placeholder, a submit handler, and an optional trailing voice affordance.
//

import SwiftUI

struct WispGlassInput: View {
    @Binding var text: String
    var placeholder: String = "Ask Wisp anything…"
    /// Called when the user commits the field (Return).
    var onSubmit: () -> Void = {}
    /// Optional trailing microphone action. When non-nil a mic control is shown.
    var onMicTap: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool

    private let cornerRadius = WispRadius.input

    var body: some View {
        HStack(spacing: WispSpacing.md) {
            field
            if let onMicTap {
                WispGlassIcon(
                    systemName: "mic",
                    size: 30,
                    contained: true,
                    tint: WispColor.OnGlass.textSecondary,
                    activeTint: WispColor.Brand.sage,
                    action: onMicTap
                )
            }
        }
        .padding(.horizontal, WispSpacing.lg)
        .padding(.vertical, WispSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(WispColor.OnGlass.tint)
                .background(
                    // The glass material itself, so the field refracts the
                    // desktop behind the panel.
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.clear)
                        .wispGlassSurface(cornerRadius: cornerRadius)
                )
        )
        .overlay(focusBorder)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .wispShadow(.ambient)
        .animation(reduceMotion ? nil : WispMotion.smooth, value: isFocused)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onTapGesture { isFocused = true }
    }

    private var field: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(WispFont.body)
                    .foregroundColor(WispColor.OnGlass.textTertiary)
            }
            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(WispFont.body)
                .foregroundColor(WispColor.OnGlass.textPrimary)
                .tint(WispColor.Brand.sage)
                .focused($isFocused)
                .lineLimit(1...4)
                .onSubmit(onSubmit)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(IBeamCursorView())
    }

    /// A hairline border at rest that blooms into the signature gradient on
    /// focus. The gradient is faint — a subconscious "Wisp is listening", not a
    /// glowing box.
    private var focusBorder: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                isFocused
                    ? AnyShapeStyle(WispGradient.signature.opacity(0.9))
                    : AnyShapeStyle(WispColor.OnGlass.borderSubtle),
                lineWidth: isFocused ? 1.5 : 1
            )
    }
}
