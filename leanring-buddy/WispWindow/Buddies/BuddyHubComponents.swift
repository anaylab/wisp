//
//  BuddyHubComponents.swift
//  leanring-buddy
//
//  Small shared pieces of the Buddies messenger. The rule for all of them: a
//  buddy's colour is an accent, used once per surface (an icon, a selected
//  state, the user's bubble), never a fill gradient, glow or shadow.
//

import AppKit
import SwiftUI

/// The surface treatment shared by every pill, tab and segment: a soft fill with
/// a faint light from above, a thin lit top edge and a hairline outline. The
/// edge is what makes it feel like a physical, pressable thing without being
/// glossy.
struct BuddyBevel<S: InsettableShape>: ViewModifier {
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
    func buddyBevel<S: InsettableShape>(_ shape: S, fill: Color, outline: Color = WispColor.cardSeparator.opacity(0.8)) -> some View {
        modifier(BuddyBevel(shape: shape, fill: fill, outline: outline))
    }
}

/// A capsule button. Prominent = tinted with the buddy's colour; otherwise
/// neutral. Both lift a touch on hover and settle on press, and nothing more.
struct BuddyPillButtonStyle: ButtonStyle {
    let colorIndex: Int
    var isProminent = true

    func makeBody(configuration: Configuration) -> some View {
        BuddyPillBody(configuration: configuration, colorIndex: colorIndex, isProminent: isProminent)
    }
}

private struct BuddyPillBody: View {
    let configuration: ButtonStyle.Configuration
    let colorIndex: Int
    let isProminent: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    private var accent: Color { BuddyAppearance.deepColor(forColorIndex: colorIndex) }

    /// The deep accent reads on light surfaces; on dark ones the lighter body
    /// tone keeps the label legible.
    private var tintedTextColor: Color {
        colorScheme == .dark ? BuddyAppearance.lightColor(forColorIndex: colorIndex) : accent
    }

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isProminent ? tintedTextColor : WispColor.textPrimary)
            .padding(.horizontal, 13)
            .padding(.vertical, 6.5)
            .buddyBevel(
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

/// A plain icon button that gains a soft background on hover.
struct BuddyIconButton: View {
    let symbolName: String
    let label: String
    var tint: Color = WispColor.textSecondary
    var size: CGFloat = 28
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background {
                    if isHovering {
                        Color.clear.buddyBevel(Circle(), fill: WispColor.surface3).transition(.opacity)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering = $0 }
        .animation(WispMotion.quick, value: isHovering)
        .accessibilityLabel(label)
        .nativeTooltip(label)
    }
}

/// Three small bouncing dots: "it's writing back".
struct BuddyTypingDots: View {
    let colorIndex: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { dotIndex in
                    let lift = reduceMotion ? 0 : max(0, sin(time * 5 - Double(dotIndex) * 0.7))
                    Circle()
                        .fill(BuddyAppearance.deepColor(forColorIndex: colorIndex))
                        .frame(width: 6, height: 6)
                        .offset(y: -CGFloat(lift) * 3)
                        .opacity(0.45 + 0.4 * lift)
                }
            }
        }
        .frame(height: 12)
    }
}

/// The backdrop of a buddy's space: the window's own background with one very
/// faint wash of the buddy's colour in the top corner. Static — nothing drifts.
struct BuddyAmbientBackground: View {
    let colorIndex: Int

    var body: some View {
        ZStack {
            WispColor.windowBackground
            RadialGradient(
                colors: [BuddyAppearance.deepColor(forColorIndex: colorIndex).opacity(0.10), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 520
            )
        }
        .animation(WispMotion.gentle, value: colorIndex)
    }
}

/// Shown over the chat while a file is dragged over it.
struct BuddyDropOverlay: View {
    let colorIndex: Int

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(BuddyAppearance.deepColor(forColorIndex: colorIndex).opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(BuddyAppearance.deepColor(forColorIndex: colorIndex).opacity(0.07))
            )
            .overlay(
                Label("Drop to attach", systemImage: "arrow.down.doc")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(BuddyAppearance.deepColor(forColorIndex: colorIndex))
            )
            .padding(14)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

enum BuddyFormatting {
    static func moodColor(_ mood: BuddyMood, colorIndex: Int) -> Color {
        switch mood {
        case .oops: return DS.Colors.destructiveText
        case .waiting: return DS.Colors.warningText
        default: return WispColor.textSecondary
        }
    }

    static func nextRunPhrase(for buddy: WispBuddy) -> String {
        guard let nextScheduledRunAt = buddy.nextScheduledRunAt else { return "on request" }
        let calendar = Calendar.current
        let timeText = nextScheduledRunAt.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(nextScheduledRunAt) { return "today at \(timeText)" }
        if calendar.isDateInTomorrow(nextScheduledRunAt) { return "tomorrow at \(timeText)" }
        return nextScheduledRunAt.formatted(.dateTime.weekday(.wide)) + " at \(timeText)"
    }

    static func timeText(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds.rounded())
        return totalSeconds >= 60 ? "\(totalSeconds / 60)m \(totalSeconds % 60)s" : "\(totalSeconds)s"
    }

    static func byteText(_ byteCount: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }
}
