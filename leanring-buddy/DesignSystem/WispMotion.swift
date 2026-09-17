//
//  WispMotion.swift
//  leanring-buddy
//
//  The centralized animation system: a small set of named timing curves so all
//  motion in Wisp feels like it comes from one hand — responsive but calm,
//  ease-out and controlled-spring, never bouncy or long. Also the reduce-motion
//  bridge: when the user has Reduce Motion on, liquid morphing is swapped for a
//  simple fade, per the accessibility brief.
//

import SwiftUI
import AppKit

enum WispMotion {

    // MARK: - Named curves

    /// Hover in/out, press feedback — fast, snappy state changes.
    static let quick = Animation.easeOut(duration: 0.15)

    /// Standard content transitions — reveals, colour changes.
    static let smooth = Animation.easeOut(duration: 0.25)

    /// Slower, deliberate — fades, celebratory resolves.
    static let gentle = Animation.easeInOut(duration: 0.4)

    /// The Dynamic Island / pill↔panel morph — a controlled spring with just
    /// enough life to feel liquid, tuned to not overshoot into a bounce.
    static let island = Animation.spring(response: 0.34, dampingFraction: 0.86)

    /// A softer spring for element-level appearance (a card sliding in).
    static let springSoft = Animation.spring(response: 0.45, dampingFraction: 0.82)

    /// A slow, self-reversing breath for ambient "alive" states (the idle logo,
    /// a resting glow). Long period so it reads as breathing, not pulsing.
    static let breath = Animation.easeInOut(duration: 2.6).repeatForever(autoreverses: true)

    // MARK: - Reduce Motion

    /// Whether the system currently asks for reduced motion. Read this for
    /// one-off decisions outside a SwiftUI view; inside a view, prefer the
    /// `@Environment(\.accessibilityReduceMotion)` value, which updates live.
    static var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Returns `animation` normally, or a plain fade when reduce-motion is on,
    /// so callers can degrade a liquid morph to a fade in one place.
    static func respectingReduceMotion(
        _ animation: Animation,
        reduceMotion: Bool,
        fade: Animation = .easeInOut(duration: 0.2)
    ) -> Animation {
        reduceMotion ? fade : animation
    }
}
