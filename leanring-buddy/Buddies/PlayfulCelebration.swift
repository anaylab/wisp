//
//  PlayfulCelebration.swift
//  leanring-buddy
//
//  The small celebrations the "Playful" switch allows: a quick squish of a buddy
//  when its run finishes, and a soft burst of dots when a checklist is finished.
//  Both are tasteful on purpose (under a second, one accent colour, nothing
//  that keeps moving), and both do nothing at all unless
//  `WispThemeStore.allowsPlayfulMotion` is true, which already folds in the
//  system's Reduce Motion setting. They never decide *whether* something
//  happened; the caller changes `trigger` when it did.
//

import SwiftUI

// MARK: - Burst

/// A soft ring of dots that drifts outward and fades, once per change of `trigger`.
/// Put it behind or over the thing being celebrated; it ignores the pointer.
struct PlayfulBurst: View {
    let trigger: Int
    let accentColor: Color

    static let durationSeconds: TimeInterval = 0.9
    private static let particleCount = 14

    @ObservedObject private var themeStore = WispThemeStore.shared
    /// When the current burst began; nil while at rest, which pauses the clock.
    @State private var burstStartedAt: Date?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: burstStartedAt == nil)) { timeline in
            Canvas { context, canvasSize in
                guard let burstStartedAt else { return }
                let progress = timeline.date.timeIntervalSince(burstStartedAt) / Self.durationSeconds
                guard progress >= 0, progress < 1 else { return }

                // Ease-out so the dots leave quickly and settle, fading in the last half.
                let easedProgress = 1 - pow(1 - progress, 3)
                let fadeOut = 1 - max(0, (progress - 0.4) / 0.6)
                let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                let maximumRadius = min(canvasSize.width, canvasSize.height) / 2

                for particleIndex in 0..<Self.particleCount {
                    let angleRadians = Double(particleIndex) / Double(Self.particleCount) * 2 * .pi
                    // Alternating distances keep the ring from looking like a clock face.
                    let distance = maximumRadius * (particleIndex.isMultiple(of: 2) ? 0.95 : 0.65) * easedProgress
                    let dotDiameter: CGFloat = (particleIndex.isMultiple(of: 3) ? 5 : 3.5) * CGFloat(1 - progress * 0.4)
                    let dotCenter = CGPoint(
                        x: center.x + CGFloat(cos(angleRadians) * distance),
                        y: center.y + CGFloat(sin(angleRadians) * distance)
                    )
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: dotCenter.x - dotDiameter / 2,
                            y: dotCenter.y - dotDiameter / 2,
                            width: dotDiameter,
                            height: dotDiameter
                        )),
                        with: .color(accentColor.opacity(0.85 * fadeOut))
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: trigger) { _, _ in
            // Read at the moment of the celebration so a Reduce Motion change takes effect at once.
            guard themeStore.allowsPlayfulMotion else { return }
            burstStartedAt = Date()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.durationSeconds + 0.05))
                burstStartedAt = nil
            }
        }
    }
}

// MARK: - Bounce

private struct PlayfulBounceModifier: ViewModifier {
    let trigger: Int

    @ObservedObject private var themeStore = WispThemeStore.shared
    /// True during the squash half of the squish.
    @State private var isSquashed = false

    func body(content: Content) -> some View {
        content
            // Squash wider and shorter from the bottom, like a cloud settling on a shelf.
            .scaleEffect(x: isSquashed ? 1.1 : 1, y: isSquashed ? 0.9 : 1, anchor: .bottom)
            .onChange(of: trigger) { _, _ in
                guard themeStore.allowsPlayfulMotion else { return }
                withAnimation(.spring(response: 0.16, dampingFraction: 0.6)) { isSquashed = true }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.5)) { isSquashed = false }
                }
            }
    }
}

extension View {
    /// A small spring squish each time `trigger` changes. Does nothing unless
    /// Playful motion is allowed.
    func playfulBounce(trigger: Int) -> some View {
        modifier(PlayfulBounceModifier(trigger: trigger))
    }
}
