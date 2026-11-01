//
//  StudyDial.swift
//  leanring-buddy
//
//  The two rings of Study mode. `StudyDurationDial` is the setup control: drag the
//  knob around the circle to choose focus minutes. `StudyProgressRing` is the running
//  timer: it fills as the phase goes and breathes during a break.
//

import AppKit
import SwiftUI

/// Drag the knob round the ring; a full turn is two hours, snapping to 5 minutes.
struct StudyDurationDial: View {
    @Binding var minutes: Int

    private let ringWidth: CGFloat = 16
    private let snapMinutes = 5
    private let fullTurnMinutes = 120

    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let diameter = min(proxy.size.width, proxy.size.height)
            let radius = (diameter - ringWidth) / 2
            let fraction = Double(minutes) / Double(fullTurnMinutes)
            let knobAngle = Angle.degrees(fraction * 360 - 90)

            ZStack {
                Circle()
                    .stroke(WispColor.surface3.opacity(0.7), lineWidth: ringWidth)

                // Tick marks every 15 minutes so the dial reads like a real timer.
                ForEach(0..<8, id: \.self) { tickIndex in
                    Capsule()
                        .fill(WispColor.textTertiary.opacity(0.5))
                        .frame(width: 2, height: 6)
                        .offset(y: -(radius - ringWidth / 2 - 10))
                        .rotationEffect(.degrees(Double(tickIndex) * 45))
                }

                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(
                        AngularGradient(
                            colors: [WispColor.accent.opacity(0.65), WispColor.accent, WispColor.intelligence],
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(max(fraction * 360, 1))
                        ),
                        style: StrokeStyle(lineWidth: ringWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                Circle()
                    .fill(Color.white)
                    .frame(width: ringWidth + (isDragging ? 10 : 6), height: ringWidth + (isDragging ? 10 : 6))
                    .shadow(color: .black.opacity(0.25), radius: isDragging ? 6 : 3, y: 1)
                    .offset(x: radius * CGFloat(cos(knobAngle.radians)), y: radius * CGFloat(sin(knobAngle.radians)))

                VStack(spacing: 2) {
                    Text("\(minutes)")
                        .font(.system(size: 62, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundColor(WispColor.textPrimary)
                        .contentTransition(.numericText(value: Double(minutes)))
                    Text("minutes of focus")
                        .font(WispFont.callout)
                        .foregroundColor(WispColor.textSecondary)
                }
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        updateMinutes(for: value.location, in: diameter)
                    }
                    .onEnded { _ in isDragging = false }
            )
            .pointerCursor()
            .animation(WispMotion.hover, value: isDragging)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: minutes)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Focus length")
        .accessibilityValue("\(minutes) minutes")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: minutes = min(minutes + snapMinutes, StudyPlan.focusMinutesRange.upperBound)
            case .decrement: minutes = max(minutes - snapMinutes, StudyPlan.focusMinutesRange.lowerBound)
            @unknown default: break
            }
        }
    }

    private func updateMinutes(for location: CGPoint, in diameter: CGFloat) {
        let deltaX = location.x - diameter / 2
        let deltaY = location.y - diameter / 2
        // 0 at twelve o'clock, growing clockwise.
        var turns = atan2(deltaX, -deltaY) / (2 * .pi)
        if turns < 0 { turns += 1 }
        var newMinutes = Int((turns * Double(fullTurnMinutes) / Double(snapMinutes)).rounded()) * snapMinutes

        // Crossing twelve o'clock must not jump from the top of the range to the bottom.
        if minutes >= 90 && newMinutes < 30 { newMinutes = StudyPlan.focusMinutesRange.upperBound }
        if minutes <= 30 && newMinutes > 90 { newMinutes = StudyPlan.focusMinutesRange.lowerBound }
        newMinutes = min(max(newMinutes, StudyPlan.focusMinutesRange.lowerBound), StudyPlan.focusMinutesRange.upperBound)

        if newMinutes != minutes {
            minutes = newMinutes
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }
}

/// The running timer: progress ring, the time, and a breathing circle during breaks.
struct StudyProgressRing: View {
    let progress: Double
    let timeText: String
    let phase: StudyPhase
    let isPaused: Bool
    let caption: String
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let ringWidth: CGFloat = 14

    var body: some View {
        ZStack {
            if phase.isBreak {
                StudyBreathingHalo(tint: tint)
                    .padding(ringWidth + 14)
            }

            Circle().stroke(WispColor.surface3.opacity(0.7), lineWidth: ringWidth)

            Circle()
                .trim(from: 0, to: max(progress, 0.002))
                .stroke(
                    AngularGradient(
                        colors: [tint.opacity(0.6), tint],
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(max(progress * 360, 1))
                    ),
                    style: StrokeStyle(lineWidth: ringWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.5), value: progress)

            VStack(spacing: 6) {
                Text(phase.title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.4)
                    .foregroundColor(tint)
                Text(timeText)
                    .font(.system(size: 64, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(WispColor.textPrimary)
                    .opacity(isPaused ? 0.45 : 1)
                Group {
                    if isPaused {
                        Text("Paused")
                    } else if phase.isBreak {
                        StudyBreathingCaption()
                    } else {
                        Text(caption)
                    }
                }
                .font(WispFont.callout)
                .foregroundColor(WispColor.textSecondary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(phase.title), \(timeText) left")
    }
}

/// Press and hold to confirm. Forest-style commitment: quitting takes a deliberate second,
/// so a stray click can't end a block, but nothing locks the user in.
struct StudyHoldToConfirmButton: View {
    let title: String
    let holdSeconds: Double
    let action: () -> Void

    @State private var holdProgress: CGFloat = 0
    @State private var didFire = false

    var body: some View {
        Text(title)
            .font(WispFont.bodyMedium)
            .lineLimit(1)
            .fixedSize()
            .foregroundColor(WispColor.destructiveText)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background {
                ZStack(alignment: .leading) {
                    Capsule().fill(WispColor.destructive.opacity(0.10))
                    GeometryReader { proxy in
                        Capsule()
                            .fill(WispColor.destructive.opacity(0.30))
                            .frame(width: proxy.size.width * holdProgress)
                    }
                    .clipShape(Capsule())
                }
            }
            .overlay(Capsule().strokeBorder(WispColor.destructive.opacity(0.35), lineWidth: 0.5))
            .contentShape(Capsule())
            .pointerCursor()
            .onLongPressGesture(minimumDuration: holdSeconds, maximumDistance: 60, perform: {
                didFire = true
                action()
                holdProgress = 0
            }, onPressingChanged: { isPressing in
                if isPressing {
                    didFire = false
                    withAnimation(.linear(duration: holdSeconds)) { holdProgress = 1 }
                } else if !didFire {
                    withAnimation(.easeOut(duration: 0.2)) { holdProgress = 0 }
                }
            })
            .help("Hold to \(title.lowercased())")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}
