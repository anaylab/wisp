//
//  WispVoiceAffordance.swift
//  leanring-buddy
//
//  The shared voice "affordance" — a single glass surface that visualises the
//  companion's current state (idle / listening / processing / responding) as the
//  centerpiece of the dynamic island and the menu bar panel. It is deliberately
//  reusable so both surfaces show the same living element rather than each
//  re-inventing a status readout.
//
//  The look is a soft, breathing glass capsule that holds a live waveform. While
//  listening, the waveform bars are driven by the real microphone power
//  (`CompanionManager.currentAudioPowerLevel`); in every other state they animate
//  on their own so the element always feels alive rather than frozen. All motion
//  is smoothed with a `TimelineView` clock so nothing thrashes `@Published` state
//  frame-by-frame.
//

import SwiftUI

/// A compact, self-animating voice waveform + status pill. Reflects the
/// companion's `voiceState` and, while listening, the live audio power level.
struct WispVoiceAffordance: View {
    /// The companion's current voice state, driving colour, label, and motion.
    let voiceState: CompanionVoiceState
    /// The live microphone power (0...1-ish) while listening. Ignored in other
    /// states, where the bars self-animate.
    let audioPowerLevel: CGFloat
    /// The accent colour for the active glow — the user's chosen cursor colour,
    /// so the affordance matches the pointer everywhere it appears.
    let accentColor: Color

    /// Number of bars in the waveform. Odd so there is a clear centre bar that
    /// reads as the "loudest" point of a symmetric waveform.
    private let barCount = 21

    var body: some View {
        // A smooth wall-clock drives all self-animation without mutating any
        // observable state, so the waveform is buttery even between turns.
        //
        // The clock is paused while idle. This matters: in the notch the
        // affordance is always laid out (merely faded out when collapsed), so an
        // always-running 60fps timeline would redraw continuously on a resident
        // menu-bar app for no benefit. Paused, the `TimelineView` still renders a
        // single static baseline waveform; it only ticks while the companion is
        // actually listening/thinking/responding.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isActive)) { timeline in
            let elapsedSeconds = timeline.date.timeIntervalSinceReferenceDate
            waveform(atElapsedSeconds: elapsedSeconds)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(affordanceGlassBackground)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge + 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge + 6, style: .continuous)
                .strokeBorder(activeGlowColor.opacity(isActive ? 0.45 : 0.0), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.3), value: voiceState.isActiveForAffordance)
    }

    // MARK: - Waveform

    private func waveform(atElapsedSeconds elapsedSeconds: TimeInterval) -> some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<barCount, id: \.self) { barIndex in
                Capsule(style: .continuous)
                    .fill(barGradient(forBarAt: barIndex))
                    .frame(width: 3, height: barHeight(forBarAt: barIndex, elapsedSeconds: elapsedSeconds))
            }
        }
        .frame(maxWidth: .infinity)
        .shadow(color: activeGlowColor.opacity(isActive ? 0.55 : 0.0), radius: 8)
    }

    /// The height of a single bar, blending a smooth travelling wave with the
    /// live audio envelope so the centre bars swell when the user speaks louder.
    private func barHeight(forBarAt barIndex: Int, elapsedSeconds: TimeInterval) -> CGFloat {
        let minimumHeight: CGFloat = 4
        let maximumHeight: CGFloat = 36

        // Distance of this bar from the centre, normalised to 0 (centre) ... 1
        // (edge). A raised-cosine envelope makes the middle of the waveform the
        // tallest, which reads as a natural symmetric voice trace.
        let centreIndex = CGFloat(barCount - 1) / 2
        let normalisedDistanceFromCentre = abs(CGFloat(barIndex) - centreIndex) / centreIndex
        let centreEnvelope = pow(cos(normalisedDistanceFromCentre * .pi / 2), 1.4)

        // A travelling wave keeps the bars in gentle motion in every state.
        let phase = elapsedSeconds * waveSpeed + Double(barIndex) * 0.5
        let travellingWave = (sin(phase) + 1) / 2  // 0 ... 1

        // The live level dominates while listening; otherwise a soft baseline so
        // the element still breathes when idle/processing/responding.
        let level: CGFloat
        switch voiceState {
        case .listening:
            level = max(0.12, min(1.0, audioPowerLevel * 1.4))
        case .processing:
            level = 0.5
        case .responding:
            level = 0.7
        case .idle:
            level = 0.18
        }

        let animatedFraction = centreEnvelope * (0.45 + 0.55 * CGFloat(travellingWave)) * level
        return minimumHeight + (maximumHeight - minimumHeight) * animatedFraction
    }

    /// How fast the travelling wave sweeps across the bars, per state.
    private var waveSpeed: Double {
        switch voiceState {
        case .listening: return 6.0
        case .processing: return 9.0
        case .responding: return 4.0
        case .idle: return 1.6
        }
    }

    private func barGradient(forBarAt barIndex: Int) -> LinearGradient {
        let topColor = isActive ? activeGlowColor : DS.Colors.textTertiary
        let bottomColor = isActive ? activeGlowColor.opacity(0.55) : DS.Colors.textTertiary.opacity(0.5)
        return LinearGradient(
            colors: [topColor, bottomColor],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Glass background

    private var affordanceGlassBackground: some View {
        // A darker inner glass so the waveform stays legible over any desktop,
        // with a faint accent wash while active to lift the element.
        ZStack {
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge + 6, style: .continuous)
                .fill(Color.black.opacity(0.28))
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge + 6, style: .continuous)
                .fill(activeGlowColor.opacity(isActive ? 0.14 : 0.0))
        }
    }

    // MARK: - State helpers

    private var isActive: Bool { voiceState.isActiveForAffordance }

    /// Always the user's chosen cursor colour, in every state. The state is
    /// communicated by the waveform's motion (speed and level) and the label,
    /// never by changing the colour — an earlier version flipped to a fixed blue
    /// while "processing", which looked like the island randomly changing colour
    /// partway through a turn.
    private var activeGlowColor: Color { accentColor }
}

extension CompanionVoiceState {
    /// Whether the affordance should render its "lit" (glowing, accent-coloured)
    /// treatment. Idle stays dim so the element recedes between turns.
    var isActiveForAffordance: Bool {
        switch self {
        case .idle: return false
        case .listening, .processing, .responding: return true
        }
    }

    /// A short human label for the current state, shown beside the affordance.
    var affordanceLabel: String {
        switch self {
        case .idle: return "Ready"
        case .listening: return "Listening…"
        case .processing: return "Thinking…"
        case .responding: return "Responding…"
        }
    }
}
