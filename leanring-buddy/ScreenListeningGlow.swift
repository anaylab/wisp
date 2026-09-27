//
//  ScreenListeningGlow.swift
//  leanring-buddy
//
//  An ambient glow around the screen edges while Wisp is actively listening.
//
//  The command-mode badge names *which* gesture fired, but it is a small label
//  in one spot. This is the other half of the answer to "is it hearing me?": a
//  saturated lavender frame — the design system's AI-activity accent — that
//  breathes along every edge of the display while the mic is live, visible
//  wherever the user happens to be looking and gone the instant recording stops.
//  It is the same idea as the system dictation glow, in Wisp's own colours.
//
//  Drawn only while listening, so the resident overlay pays nothing for it at
//  rest, and it honours Reduce Motion by holding a steady glow instead of
//  breathing.
//

import SwiftUI

struct ScreenListeningGlow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Drives the slow breath between a dim and a brighter glow. Only toggled
    /// when motion is allowed; otherwise the glow holds a fixed opacity.
    @State private var isBreathing = false

    /// How far the glow reaches inward from each edge before fading to nothing.
    /// Wide enough to read as an ambient frame, not a hard border.
    private let edgeReach: CGFloat = 165

    private let dimOpacity: Double = 0.58
    private let brightOpacity: Double = 1.0

    /// A saturated lavender wash. The design system reserves lavender for AI
    /// activity, and listening is exactly that, so this is both more on-brand and
    /// far more visible over dark apps than the pastel signature gradient — which
    /// washed out to a faint grey at these opacities.
    private var listeningGradient: LinearGradient {
        LinearGradient(
            colors: [
                WispColor.Brand.lavender,
                WispColor.Brand.mutedLavender,
                WispColor.Brand.lavender
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        listeningGradient
            .mask(edgeMask)
            .blur(radius: 16)
            .opacity(currentOpacity)
            .allowsHitTesting(false)
            .ignoresSafeArea()
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(WispMotion.breath) {
                    isBreathing = true
                }
            }
    }

    /// A steady mid glow under Reduce Motion, otherwise the breathing value the
    /// `WispMotion.breath` animation oscillates between.
    private var currentOpacity: Double {
        if reduceMotion {
            return (dimOpacity + brightOpacity) / 2
        }
        return isBreathing ? brightOpacity : dimOpacity
    }

    /// A frame that is opaque at the very edge and fades to clear inward on all
    /// four sides. Applied as a mask to the full-screen gradient, it leaves only
    /// the edges lit. Corners overlap and read a touch brighter, which is what a
    /// real glow does.
    private var edgeMask: some View {
        ZStack {
            LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: edgeReach)
                .frame(maxHeight: .infinity, alignment: .top)

            LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom)
                .frame(height: edgeReach)
                .frame(maxHeight: .infinity, alignment: .bottom)

            LinearGradient(colors: [.white, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: edgeReach)
                .frame(maxWidth: .infinity, alignment: .leading)

            LinearGradient(colors: [.clear, .white], startPoint: .leading, endPoint: .trailing)
                .frame(width: edgeReach)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
