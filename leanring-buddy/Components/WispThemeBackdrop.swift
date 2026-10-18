//
//  WispThemeBackdrop.swift
//  leanring-buddy
//
//  The Wisp window's liquid-glass stage. Three soft blobs of the theme's backdrop
//  colours drift slowly behind the content, and the window's cards, top bar and
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

    /// Where each blob rests, as a fraction of the window, and how far and how fast
    /// it wanders. Different periods keep the three from ever lining up.
    private static let blobs: [(anchor: CGPoint, wander: CGFloat, periodSeconds: Double, radiusFraction: CGFloat)] = [
        (CGPoint(x: 0.12, y: 0.10), 0.07, 47, 0.62),
        (CGPoint(x: 0.88, y: 0.38), 0.09, 61, 0.58),
        (CGPoint(x: 0.34, y: 0.96), 0.08, 53, 0.66),
    ]

    private var isDrifting: Bool {
        isActive && controlActiveState != .inactive && themeStore.isPlayful && !reduceMotion
    }

    var body: some View {
        let stopColors = themeStore.currentTheme.backdropStops.map {
            Color(hex: colorScheme == .dark ? $0.darkHex : $0.lightHex)
        }
        // Dark blobs sit on a near-black window and need more weight to show at all.
        let blobStrength: Double = colorScheme == .dark ? 0.85 : 0.60

        ZStack {
            WispColor.windowBackground
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !isDrifting)) { timeline in
                let elapsedSeconds = isDrifting ? timeline.date.timeIntervalSinceReferenceDate : 0
                Canvas { context, size in
                    for (blobIndex, blob) in Self.blobs.enumerated() {
                        let phase = elapsedSeconds / blob.periodSeconds * 2 * .pi
                        let centre = CGPoint(
                            x: (blob.anchor.x + blob.wander * CGFloat(sin(phase + Double(blobIndex)))) * size.width,
                            y: (blob.anchor.y + blob.wander * CGFloat(cos(phase * 0.8 + Double(blobIndex)))) * size.height
                        )
                        let radius = max(size.width, size.height) * blob.radiusFraction
                        context.fill(
                            Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)),
                            with: .radialGradient(
                                Gradient(colors: [stopColors[blobIndex].opacity(blobStrength), stopColors[blobIndex].opacity(0)]),
                                center: centre,
                                startRadius: 0,
                                endRadius: radius
                            )
                        )
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
