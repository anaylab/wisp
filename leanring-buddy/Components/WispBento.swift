//
//  WispBento.swift
//  leanring-buddy
//
//  The Wisp window's widget language: rounded tiles that respond to the
//  pointer, a live rim for anything that is working right now, and a gentle
//  entrance when a page appears. Today is laid out as a grid of these tiles,
//  and `DashboardCard` (every settings page) shares their surface, so the
//  whole window reads as one system rather than a stack of grey boxes.
//
//  Motion is small and purposeful — a tile lifts a few points under the
//  pointer, presses in on click, and a rim of light flows around work in
//  progress — and all of it turns off with Reduce Motion.
//

import SwiftUI

// MARK: - Tile

/// One widget on a bento page. Give it an `action` and the whole tile is a
/// button (hover lift + press); without one it is a quiet container that
/// still acknowledges the pointer with a slightly stronger edge.
struct WispBentoTile<Content: View>: View {
    var title: String?
    var symbolName: String?
    /// The colour of the title's icon chip — the sage accent by default.
    var tint: Color = WispColor.accentText
    /// Draws the flowing lavender rim used for work in progress.
    var isLive: Bool = false
    var action: (() -> Void)?
    /// Something small at the trailing edge of the title row (a count, a link).
    var accessory: AnyView?
    @ViewBuilder var content: Content

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let action {
            Button(action: action) {
                tileBody
            }
            .buttonStyle(WispBentoPressStyle())
            .pointerCursor()
        } else {
            tileBody
        }
    }

    private var tileBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || symbolName != nil || accessory != nil {
                titleRow
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .wispBentoSurface(isHovered: isHovered, isInteractive: action != nil, isLive: isLive)
        .offset(y: isHovered && action != nil && !reduceMotion ? -2 : 0)
        .onHover { hovering in
            withAnimation(WispMotion.smooth) { isHovered = hovering }
        }
        .contentShape(RoundedRectangle(cornerRadius: WispBentoMetrics.cornerRadius, style: .continuous))
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            if let symbolName {
                Image(systemName: symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(tint.opacity(0.14))
                    )
                    .scaleEffect(isHovered && !reduceMotion ? 1.08 : 1)
                    .rotationEffect(.degrees(isHovered && !reduceMotion ? -6 : 0))
            }
            if let title {
                Text(title)
                    .font(WispFont.headline)
                    .foregroundStyle(WispColor.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let accessory {
                accessory
            } else if action != nil {
                // An arrow that slides in on hover says "this tile goes somewhere".
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(WispColor.textTertiary)
                    .opacity(isHovered ? 1 : 0)
                    .offset(x: isHovered ? 0 : -4, y: isHovered ? 0 : 4)
            }
        }
    }
}

enum WispBentoMetrics {
    static let cornerRadius: CGFloat = 18
    static let gridSpacing: CGFloat = 14
}

/// Presses a tile in slightly, springing back on release.
struct WispBentoPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Surface

extension View {
    /// The tile surface shared by bento tiles and `DashboardCard`: real Liquid
    /// Glass over the theme backdrop (inside a `WispGlassContainer`; the native
    /// grouped-card fill anywhere else), a hairline edge, a soft shadow that deepens under the
    /// pointer, and an optional flowing rim for live work.
    func wispBentoSurface(isHovered: Bool = false, isInteractive: Bool = false, isLive: Bool = false) -> some View {
        modifier(WispBentoSurfaceModifier(isHovered: isHovered, isInteractive: isInteractive, isLive: isLive))
    }

    /// Fades and lifts a view into place when it first appears; `order` staggers
    /// siblings so a page assembles top-down instead of popping in at once.
    func wispEntrance(order: Int = 0) -> some View {
        modifier(WispEntranceModifier(order: order))
    }
}

private struct WispBentoSurfaceModifier: ViewModifier {
    let isHovered: Bool
    let isInteractive: Bool
    let isLive: Bool

    func body(content: Content) -> some View {
        let tileShape = RoundedRectangle(cornerRadius: WispBentoMetrics.cornerRadius, style: .continuous)
        content
            .wispWindowGlass(in: tileShape)
            .overlay(
                tileShape.strokeBorder(
                    isHovered && isInteractive ? WispColor.accentText.opacity(0.35) : WispColor.cardSeparator,
                    lineWidth: isHovered && isInteractive ? 1 : 0.5
                )
            )
            .overlay {
                if isLive {
                    WispLiveRim(cornerRadius: WispBentoMetrics.cornerRadius)
                }
            }
            .shadow(
                color: .black.opacity(isHovered && isInteractive ? 0.12 : 0.05),
                radius: isHovered && isInteractive ? 16 : 6,
                x: 0,
                y: isHovered && isInteractive ? 8 : 2
            )
    }
}

/// A band of lavender light travelling around a tile's edge — the window's
/// version of the notch's flowing rim, for "this is working right now".
struct WispLiveRim: View {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let rimShape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceMotion {
            rimShape.strokeBorder(WispColor.intelligence.opacity(0.7), lineWidth: 1.5)
                .allowsHitTesting(false)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let rotationDegrees = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 3.2) / 3.2 * 360
                rimShape.strokeBorder(
                    AngularGradient(
                        colors: [
                            WispColor.intelligence.opacity(0.0),
                            WispColor.intelligence.opacity(0.95),
                            WispColor.accentText.opacity(0.7),
                            WispColor.intelligence.opacity(0.0),
                            WispColor.intelligence.opacity(0.0),
                        ],
                        center: .center,
                        angle: .degrees(rotationDegrees)
                    ),
                    lineWidth: 1.5
                )
            }
            .allowsHitTesting(false)
        }
    }
}

private struct WispEntranceModifier: ViewModifier {
    let order: Int
    @State private var hasAppeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(hasAppeared || reduceMotion ? 1 : 0)
            .offset(y: hasAppeared || reduceMotion ? 0 : 10)
            .scaleEffect(hasAppeared || reduceMotion ? 1 : 0.985, anchor: .top)
            .onAppear {
                guard !hasAppeared else { return }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85).delay(Double(order) * 0.045)) {
                    hasAppeared = true
                }
            }
    }
}

// MARK: - Small pieces

/// A big rounded number with a caption under it, animating when it changes.
struct WispBentoStat: View {
    let value: Int
    let caption: String
    var tint: Color = WispColor.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(tint)
                .contentTransition(.numericText(value: Double(value)))
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: value)
            Text(caption)
                .font(WispFont.caption)
                .foregroundStyle(WispColor.textSecondary)
                .lineLimit(1)
        }
    }
}

/// A row of bars, one per bucket, that grow into place when they appear.
/// Used for "what Wisp did today, by hour".
struct WispActivityBars: View {
    /// One count per bucket, oldest first.
    let bucketCounts: [Int]
    /// The bucket to draw in the accent (e.g. the current hour).
    var highlightedBucketIndex: Int?

    @State private var hasGrown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let largestBucketCount = max(bucketCounts.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(bucketCounts.enumerated()), id: \.offset) { bucketIndex, bucketCount in
                let heightFraction = CGFloat(bucketCount) / CGFloat(largestBucketCount)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(barColor(bucketIndex: bucketIndex, bucketCount: bucketCount))
                    .frame(maxWidth: .infinity)
                    .frame(height: max(3, 34 * (hasGrown || reduceMotion ? heightFraction : 0)))
                    .animation(
                        .spring(response: 0.55, dampingFraction: 0.75).delay(Double(bucketIndex) * 0.018),
                        value: hasGrown
                    )
            }
        }
        .frame(height: 34, alignment: .bottom)
        .onAppear { hasGrown = true }
        .accessibilityHidden(true)
    }

    private func barColor(bucketIndex: Int, bucketCount: Int) -> Color {
        if bucketIndex == highlightedBucketIndex {
            return WispColor.intelligence
        }
        return bucketCount == 0 ? WispColor.textTertiary.opacity(0.18) : WispColor.accentText.opacity(0.55)
    }
}

/// A small text link inside a tile ("All routines", "Open History").
struct WispBentoLink: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .offset(x: isHovered ? 2 : 0)
            }
            .font(WispFont.caption)
            .foregroundStyle(WispColor.accentText)
            .opacity(isHovered ? 1 : 0.85)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            withAnimation(WispMotion.quick) { isHovered = hovering }
        }
    }
}
