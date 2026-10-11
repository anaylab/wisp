//
//  BuddyHubComponents.swift
//  leanring-buddy
//
//  Small shared pieces of the Buddies messenger: the coloured pill button,
//  chips, the typing dots, the ambient tinted backdrop and the drop-a-file
//  overlay. Everything here takes a buddy's colour index so a buddy's whole
//  space — header, bubbles, buttons — reads as that buddy.
//

import AppKit
import SwiftUI

/// A capsule button in a buddy's colour. Prominent = filled gradient, white text.
struct BuddyPillButtonStyle: ButtonStyle {
    let colorIndex: Int
    var isProminent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(isProminent ? Color.white : BuddyAppearance.deepColor(forColorIndex: colorIndex))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(isProminent
                          ? AnyShapeStyle(BuddyAppearance.accentGradient(forColorIndex: colorIndex))
                          : AnyShapeStyle(BuddyAppearance.deepColor(forColorIndex: colorIndex).opacity(0.14)))
            )
            .shadow(color: isProminent ? BuddyAppearance.deepColor(forColorIndex: colorIndex).opacity(0.35) : .clear, radius: 8, y: 3)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(WispMotion.quick, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// A round icon button (inspector toggle, attach, …).
struct BuddyIconButtonStyle: ButtonStyle {
    var tint: Color = WispColor.textSecondary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(Circle().fill(WispColor.surface2.opacity(configuration.isPressed ? 1 : 0.7)))
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(WispMotion.quick, value: configuration.isPressed)
            .contentShape(Circle())
    }
}

struct BuddyChip: View {
    let symbolName: String
    let text: String
    let colorIndex: Int

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbolName)
                .font(.system(size: 10, weight: .bold))
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(BuddyAppearance.deepColor(forColorIndex: colorIndex))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule(style: .continuous).fill(BuddyAppearance.deepColor(forColorIndex: colorIndex).opacity(0.14)))
    }
}

/// Three bouncing dots: "it's writing back".
struct BuddyTypingDots: View {
    let colorIndex: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { dotIndex in
                    let lift = reduceMotion ? 0 : max(0, sin(time * 5 - Double(dotIndex) * 0.7))
                    Circle()
                        .fill(BuddyAppearance.deepColor(forColorIndex: colorIndex))
                        .frame(width: 7, height: 7)
                        .offset(y: -CGFloat(lift) * 5)
                        .opacity(0.55 + 0.45 * lift)
                }
            }
        }
        .frame(height: 16)
    }
}

/// The soft, slowly drifting colour wash behind a buddy's chat.
struct BuddyAmbientBackground: View {
    let colorIndex: Int
    @State private var drifts = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            WispColor.windowBackground
            Circle()
                .fill(BuddyAppearance.deepColor(forColorIndex: colorIndex).opacity(0.20))
                .frame(width: 520, height: 520)
                .blur(radius: 120)
                .offset(x: drifts ? -120 : -220, y: drifts ? -200 : -260)
            Circle()
                .fill(BuddyAppearance.lightColor(forColorIndex: colorIndex).opacity(0.16))
                .frame(width: 420, height: 420)
                .blur(radius: 110)
                .offset(x: drifts ? 260 : 160, y: drifts ? 220 : 160)
        }
        .clipped()
        .animation(reduceMotion ? nil : .easeInOut(duration: 14).repeatForever(autoreverses: true), value: drifts)
        .onAppear { drifts = true }
        .animation(WispMotion.gentle, value: colorIndex)
    }
}

/// Shown over the chat while a file is dragged over it.
struct BuddyDropOverlay: View {
    let buddyName: String
    let colorIndex: Int

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(BuddyAppearance.deepColor(forColorIndex: colorIndex).opacity(0.14))
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(BuddyAppearance.deepColor(forColorIndex: colorIndex), style: StrokeStyle(lineWidth: 2.5, dash: [9, 7]))
            VStack(spacing: 10) {
                BuddyCharacter(colorIndex: colorIndex, size: 64, mood: .waiting, liveliness: .full)
                Text("Drop files for \(buddyName)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(BuddyAppearance.deepColor(forColorIndex: colorIndex))
                Text("Documents, notes, PDFs and pictures")
                    .font(.system(size: 11))
                    .foregroundStyle(WispColor.textSecondary)
            }
        }
        .padding(14)
        .allowsHitTesting(false)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }
}

enum BuddyFormatting {
    /// "Working", "Done!", … for the rail and header.
    static func moodWord(_ mood: BuddyMood, specialty: BuddySpecialty?) -> String {
        switch mood {
        case .working: return "Working…"
        case .happy: return "Done!"
        case .oops: return "Hit a snag"
        case .waiting: return "Needs your ok"
        case .sleepy: return "Zzz"
        case .idle: return specialty?.title ?? "Ready"
        }
    }

    static func moodColor(_ mood: BuddyMood, colorIndex: Int) -> Color {
        switch mood {
        case .oops: return DS.Colors.destructive
        case .waiting: return DS.Colors.warning
        default: return BuddyAppearance.deepColor(forColorIndex: colorIndex)
        }
    }

    static func nextRunPhrase(for buddy: WispBuddy) -> String {
        guard let nextScheduledRunAt = buddy.nextScheduledRunAt else { return "when you ask" }
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

    static func byteText(_ byteCount: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }
}
