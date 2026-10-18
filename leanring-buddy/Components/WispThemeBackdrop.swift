//
//  WispThemeBackdrop.swift
//  leanring-buddy
//
//  The Wisp window's liquid-glass stage. A 3x3 `MeshGradient` of the theme's backdrop
//  colours flows slowly behind the content, and the window's cards, top bar and
//  pills are real `.glassEffect` surfaces that refract them.
//
//  Three pieces, usually used together through `WispThemedWindowSurface`:
//   - `WispThemeBackdrop`  — the drifting colour field (paused when it can't be seen).
//   - `WispGlassContainer` — a `GlassEffectContainer` that also switches glass ON for
//                            everything inside it.
//   - `wispWindowGlass`    — what a card, bar or pill calls to be a glass surface. Outside
//                            a container it draws the flat grouped-card look the window
//                            had before, so a view shown somewhere without the stage
//                            (a sheet, a preview) never goes blank.
//
//  Cost: the drift is a few radial gradients in one `Canvas`, redrawn at ~20 fps
//  only while the window is key, `isActive` is true, Playful is on and Reduce Motion
//  is off. Otherwise it draws once and stops.
//

import SwiftUI

// MARK: - Environment

extension EnvironmentValues {
    /// True inside a `WispGlassContainer`: surfaces there are real Liquid Glass.
    @Entry var wispWindowGlassEnabled: Bool = false
}

// MARK: - Backdrop

struct WispThemeBackdrop: View {
    /// False pauses the drift (the window passes false when it is hidden or covered).
    var isActive: Bool = true

    @ObservedObject private var themeStore = WispThemeStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    init(isActive: Bool = true) {
        self.isActive = isActive
    }

    /// How far each moving point of the mesh wanders, as a fraction of the window, and how
    /// long one lap takes. Different periods keep them from ever lining up, so the colours
    /// swirl instead of pulsing together.
    private static let centreWander: CGFloat = 0.13
    private static let edgeWander: CGFloat = 0.09
    private static let periodsSeconds: [Double] = [41, 53, 47, 59, 67]

    private var isDrifting: Bool {
        isActive && controlActiveState != .inactive && themeStore.isPlayful && !reduceMotion
    }

    var body: some View {
        let stopColors = themeStore.currentTheme.backdropStops.map {
            Color(hex: colorScheme == .dark ? $0.darkHex : $0.lightHex)
        }
        // Dark glows sit on a near-black window and need more weight to show at all.
        let glowStrength: Double = colorScheme == .dark ? 0.90 : 0.78

        ZStack {
            WispColor.windowBackground
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !isDrifting)) { timeline in
                let elapsedSeconds = isDrifting ? timeline.date.timeIntervalSinceReferenceDate : 0
                MeshGradient(
                    width: 3,
                    height: 3,
                    points: meshPoints(elapsedSeconds: elapsedSeconds),
                    colors: meshColors(stopColors: stopColors, glowStrength: glowStrength)
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A 3x3 mesh: corners fixed, the four edge midpoints sliding along their edge, and the
    /// centre wandering. That is enough movement for the colour to flow like liquid without
    /// the window's edges ever showing a seam.
    private func meshPoints(elapsedSeconds: Double) -> [SIMD2<Float>] {
        func wave(_ index: Int, amplitude: CGFloat, offset: Double = 0) -> Float {
            let phase = elapsedSeconds / Self.periodsSeconds[index] * 2 * .pi + offset
            return Float(amplitude * CGFloat(sin(phase)))
        }
        return [
            SIMD2(0, 0), SIMD2(0.5 + wave(0, amplitude: Self.edgeWander), 0), SIMD2(1, 0),
            SIMD2(0, 0.5 + wave(1, amplitude: Self.edgeWander, offset: 1.3)),
            SIMD2(0.5 + wave(2, amplitude: Self.centreWander), 0.5 + wave(3, amplitude: Self.centreWander, offset: 0.9)),
            SIMD2(1, 0.5 + wave(4, amplitude: Self.edgeWander, offset: 2.1)),
            SIMD2(0, 1), SIMD2(0.5 + wave(1, amplitude: Self.edgeWander, offset: 3.0), 1), SIMD2(1, 1),
        ]
    }

    /// The theme's three backdrop colours spread across the mesh, with the quiet window
    /// colour between them so there is calm space around each glow.
    private func meshColors(stopColors: [Color], glowStrength: Double) -> [Color] {
        let calm = WispColor.windowBackground.opacity(0)
        let glow = stopColors.map { $0.opacity(glowStrength) }
        return [
            glow[0], calm, glow[1],
            calm, glow[2].opacity(0.55), calm,
            glow[2], calm, glow[0],
        ]
    }
}

// MARK: - Glass container

/// A `GlassEffectContainer` that turns window glass on for its content. Spacing is
/// the blend distance between neighbouring glass shapes: kept small so cards a
/// normal gap apart stay separate panes rather than merging into one blob.
struct WispGlassContainer<Content: View>: View {
    var spacing: CGFloat = 2
    @ViewBuilder var content: Content

    var body: some View {
        GlassEffectContainer(spacing: spacing) {
            content
        }
        .environment(\.wispWindowGlassEnabled, true)
    }
}

/// The whole stage in one wrapper: backdrop behind, glass container around the
/// content, and the content keyed on the theme so every dynamic colour re-resolves
/// the moment the theme changes.
struct WispThemedWindowSurface<Content: View>: View {
    var isActive: Bool = true
    @ViewBuilder var content: Content

    @ObservedObject private var themeStore = WispThemeStore.shared

    var body: some View {
        ZStack {
            WispThemeBackdrop(isActive: isActive)
                .ignoresSafeArea()
            WispGlassContainer {
                content
            }
            .id(themeStore.currentThemeID)
        }
    }
}

// MARK: - Glass surface

extension View {
    /// Card / bar / pill glass: `.glassEffect` tinted by the theme's glass strength.
    /// Call it inside a `WispGlassContainer`. Outside one it falls back to the flat
    /// grouped-card fill (`tint` is ignored there).
    func wispWindowGlass<GlassShape: Shape>(
        in shape: GlassShape,
        interactive: Bool = false,
        tint: Color? = nil
    ) -> some View {
        modifier(WispWindowGlassModifier(shape: shape, isInteractive: interactive, tint: tint))
    }
}

private struct WispWindowGlassModifier<GlassShape: Shape>: ViewModifier {
    let shape: GlassShape
    let isInteractive: Bool
    let tint: Color?

    @Environment(\.wispWindowGlassEnabled) private var isGlassEnabled

    @ViewBuilder
    func body(content: Content) -> some View {
        if isGlassEnabled {
            let baseGlass = Glass.regular.tint(tint ?? WispColor.glassCardTint)
            content.glassEffect(isInteractive ? baseGlass.interactive() : baseGlass, in: shape)
        } else {
            content.background(shape.fill(WispColor.groupedCardBackground))
        }
    }
}
