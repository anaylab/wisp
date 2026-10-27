//
//  WispLiquidRim.swift
//  leanring-buddy
//
//  The edge of Wisp's Liquid Glass. Real glass is read almost entirely at its
//  rim: the body is see-through, and what tells your eye "there is a lens here"
//  is the thin line of light caught along the edge. `.glassEffect` gives the
//  refraction; this modifier adds that caught light on top, so a glass surface
//  reads as a thick, polished piece of glass rather than a tinted blur.
//
//  It also lets the rim carry state, which keeps the island calm: rather than
//  adding another badge, light moves *inside the glass edge* —
//
//   • resting  — only the specular highlight, perfectly still (no redraws).
//   • flowing  — an arc of coloured light travels around the rim, like light
//                caught in a moving lens. Used for AI activity (lavender).
//   • glowing  — the whole rim lights evenly in one colour. Used for a decision
//                pending (warning) and the brief success / error flashes.
//
//  The flowing clock is a `TimelineView` that is paused whenever the light is
//  not flowing or Reduce Motion is on, so a resident, idle Wisp costs nothing.
//  Under Reduce Motion a flowing rim becomes a steady glow instead.
//

import SwiftUI

/// What light a glass rim carries.
enum WispLiquidRimLight: Equatable {
    /// Just the specular edge highlight, still.
    case resting
    /// An arc of light travelling around the rim — ongoing activity.
    case flowing(Color)
    /// The whole rim softly lit in one colour — a state to notice.
    case glowing(Color)
}

/// Draws the specular highlight and the state light along a glass shape's edge.
/// Apply it after the glass (and after any clip) so the light sits on top.
private struct WispLiquidRimModifier<RimShape: InsettableShape>: ViewModifier {
    let rimShape: RimShape
    let light: WispLiquidRimLight
    /// Which edge the light source sits beyond, so it catches brightest there.
    /// A panel floating on the desktop is lit from the top; the notch surface
    /// hangs from the bezel, whose top edge is hidden, so it is lit from below.
    let highlightEdge: VerticalEdge
    /// Off for a surface that isn't glass (the black island): there is no lens
    /// edge to catch light, so only the state light is drawn.
    let showsSpecularHighlight: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One full trip of the flowing light around the rim. Slow enough to read as
    /// light drifting through glass, not a loading spinner.
    private static var flowingLapDurationSeconds: Double { 3.2 }

    func body(content: Content) -> some View {
        content
            .overlay(specularHighlight.opacity(showsSpecularHighlight ? 1 : 0).allowsHitTesting(false))
            .overlay(stateLight.allowsHitTesting(false))
            .animation(WispMotion.gentle, value: light)
    }

    // MARK: Specular highlight

    /// A hairline that is bright where the light source is, fades to almost
    /// nothing across the middle, and picks up a faint bounce on the far edge —
    /// the way light sits on the rim of a real lens. `.plusLighter` adds light
    /// rather than painting grey, so it brightens whatever the glass refracts.
    private var specularHighlight: some View {
        let litEnd: UnitPoint = highlightEdge == .top ? .top : .bottom
        let farEnd: UnitPoint = highlightEdge == .top ? .bottom : .top
        return rimShape
            .strokeBorder(
                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.42), location: 0.0),
                        .init(color: Color.white.opacity(0.10), location: 0.28),
                        .init(color: Color.white.opacity(0.02), location: 0.62),
                        .init(color: Color.white.opacity(0.12), location: 1.0),
                    ],
                    startPoint: litEnd,
                    endPoint: farEnd
                ),
                lineWidth: 1
            )
            .blendMode(.plusLighter)
    }

    // MARK: State light

    @ViewBuilder
    private var stateLight: some View {
        switch light {
        case .resting:
            EmptyView()
        case .glowing(let glowColor):
            evenRimGlow(glowColor)
                .transition(.opacity)
        case .flowing(let flowColor):
            if reduceMotion {
                evenRimGlow(flowColor)
                    .transition(.opacity)
            } else {
                travellingRimLight(flowColor)
                    .transition(.opacity)
            }
        }
    }

    /// The whole rim lit evenly: a crisp line plus a soft bloom around it.
    private func evenRimGlow(_ glowColor: Color) -> some View {
        ZStack {
            rimShape
                .strokeBorder(glowColor.opacity(0.55), lineWidth: 3)
                .blur(radius: 5)
            rimShape
                .strokeBorder(glowColor.opacity(0.8), lineWidth: 1)
        }
        .blendMode(.plusLighter)
    }

    /// An arc of light travelling around the rim. The angular gradient is mostly
    /// transparent with one bright, white-cored band, and its start angle turns
    /// with the clock — so the band sweeps the perimeter. A blurred copy under
    /// the crisp line gives it the bloom of light inside glass.
    private func travellingRimLight(_ flowColor: Color) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            let lapProgress = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: Self.flowingLapDurationSeconds)
                / Self.flowingLapDurationSeconds
            let travellingGradient = AngularGradient(
                stops: [
                    .init(color: flowColor.opacity(0.0), location: 0.0),
                    .init(color: flowColor.opacity(0.0), location: 0.52),
                    .init(color: flowColor.opacity(0.85), location: 0.72),
                    .init(color: Color.white.opacity(0.95), location: 0.8),
                    .init(color: flowColor.opacity(0.85), location: 0.86),
                    .init(color: flowColor.opacity(0.0), location: 1.0),
                ],
                center: .center,
                angle: .degrees(lapProgress * 360)
            )
            ZStack {
                // A faint constant glow so the rim never goes fully dark between
                // passes of the band — the glass reads as "on" the whole time.
                rimShape
                    .strokeBorder(flowColor.opacity(0.22), lineWidth: 1)
                rimShape
                    .strokeBorder(travellingGradient, lineWidth: 3.5)
                    .blur(radius: 6)
                rimShape
                    .strokeBorder(travellingGradient, lineWidth: 1.25)
            }
            .blendMode(.plusLighter)
        }
    }
}

extension View {
    /// Adds the Liquid Glass rim — a specular edge highlight plus optional state
    /// light — along `rimShape`. Apply it after the glass surface and any clip.
    func wispLiquidRim<RimShape: InsettableShape>(
        in rimShape: RimShape,
        light: WispLiquidRimLight = .resting,
        highlightEdge: VerticalEdge = .top,
        showsSpecularHighlight: Bool = true
    ) -> some View {
        modifier(WispLiquidRimModifier(
            rimShape: rimShape,
            light: light,
            highlightEdge: highlightEdge,
            showsSpecularHighlight: showsSpecularHighlight
        ))
    }
}

extension WispIslandState {
    /// The light the island's glass rim carries in this state. AI activity flows
    /// in lavender (the accent reserved for "Wisp is working"); a pending
    /// decision and the success / error flashes light the whole rim in their
    /// semantic colour; rest and a lingering answer keep just the highlight.
    /// The flowing colour is lavender unless the island is tinted with the theme.
    var rimLight: WispLiquidRimLight {
        switch self {
        case .idle, .preview:
            return .resting
        case .listening, .thinking, .processing, .executing, .responding:
            return .flowing(WispColor.Island.activityAccent)
        case .confirmation:
            return .glowing(WispColor.warning)
        case .success:
            return .glowing(WispColor.success)
        case .error:
            return .glowing(WispColor.destructive)
        }
    }
}


// MARK: - State wash

/// A soft radial colour wash rising from the bottom edge of a dark surface.
/// Used to name the state of a card (pending decision, success, error) without
/// recolouring the surface itself. Clip it to the surface's shape.
struct WispStateWash: View {
    var color: Color?
    var strength: Double = 0.3

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RadialGradient(
            colors: [(color ?? .clear).opacity(strength), .clear],
            center: .bottom,
            startRadius: 0,
            endRadius: 190
        )
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : WispMotion.gentle, value: color)
    }
}
