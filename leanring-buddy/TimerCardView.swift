//
//  TimerCardView.swift
//  leanring-buddy
//
//  The timer glance card: a live countdown in the notch with a draining
//  progress bar and a Cancel button, drawn on the notch's dark palette (DS.*).
//
//  The card holds only the timer's id (`TimerCardState`). The countdown itself
//  lives in `WispTimerStore`, so dismissing or replacing this card never stops
//  the timer — its notification and completion cue still fire. The card just
//  reads the store and redraws.
//
//  Redraws are driven by a `TimelineView` whose schedule ticks once per whole
//  second of the countdown (aligned to the end time, so "4:59" lands exactly a
//  second after "5:00"), and which stops ticking entirely while the card is not
//  on screen or the timer is no longer running. The notch is resident, so a
//  clock that never pauses would be a permanent redraw for nothing.
//

import SwiftUI

/// Which timer a timer card shows. The live state is read from
/// `WispTimerStore` by id, so the card stays correct after it is re-rendered
/// and the timer keeps going after the card is gone.
struct TimerCardState: Equatable {
    let timerID: UUID
}

struct TimerCardView: View {
    let state: TimerCardState

    @ObservedObject private var timerStore = WispTimerStore.shared

    /// Whether the card is currently in the view hierarchy. The countdown clock
    /// only runs while this is true.
    @State private var isCardVisible = false
    @State private var isCancelButtonHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let timer = timerStore.timer(withID: state.timerID) {
                TimelineView(CountdownSecondTickSchedule(
                    endDate: timer.endDate,
                    isPaused: !isCardVisible || timer.status != .running
                )) { timelineContext in
                    countdownBody(for: timer, at: timelineContext.date)
                }
            } else {
                // Only possible if the store was somehow reset under the card.
                Text("Timer unavailable")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            attribution
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
        )
        .onAppear { isCardVisible = true }
        .onDisappear { isCardVisible = false }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "timer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.accentText)
            Text(headerTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
        }
    }

    /// "Tea" for a labelled timer, "Timer" otherwise.
    private var headerTitle: String {
        guard let label = timerStore.timer(withID: state.timerID)?.label,
              let firstCharacter = label.first else { return "Timer" }
        return firstCharacter.uppercased() + label.dropFirst()
    }

    @ViewBuilder
    private func countdownBody(for timer: WispTimer, at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(countdownDisplayText(for: timer, at: date))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(countdownColor(for: timer))
                    .contentTransition(.numericText(countsDown: true))
                Spacer(minLength: 6)
                if timer.status == .running {
                    cancelButton(for: timer)
                } else {
                    Text(timer.status == .finished ? "Done" : "Cancelled")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }

            progressBar(fractionRemaining: timer.status == .running ? timer.fractionRemaining(at: date) : 0)
        }
    }

    private func countdownDisplayText(for timer: WispTimer, at date: Date) -> String {
        switch timer.status {
        case .running:
            return WispTimerDurationFormatter.countdownText(remainingSeconds: timer.remainingSeconds(at: date))
        case .finished:
            return WispTimerDurationFormatter.countdownText(remainingSeconds: 0)
        case .cancelled:
            return WispTimerDurationFormatter.countdownText(remainingSeconds: TimeInterval(timer.durationSeconds))
        }
    }

    private func countdownColor(for timer: WispTimer) -> Color {
        switch timer.status {
        case .running: return DS.Colors.textPrimary
        case .finished: return DS.Colors.success
        case .cancelled: return DS.Colors.textTertiary
        }
    }

    /// A thin bar that drains as the timer runs.
    private func progressBar(fractionRemaining: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DS.Colors.surface3)
                Capsule()
                    .fill(DS.Colors.accent)
                    .frame(width: proxy.size.width * fractionRemaining)
            }
        }
        .frame(height: 4)
        .animation(.linear(duration: 1), value: fractionRemaining)
    }

    /// Cancel: stops the timer and withdraws its notification. Pointer cursor
    /// and a hover fill so it reads as clickable in the notch.
    private func cancelButton(for timer: WispTimer) -> some View {
        Button {
            timerStore.cancelTimer(withID: timer.id)
        } label: {
            Text("Cancel")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isCancelButtonHovered ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(isCancelButtonHovered ? DS.Colors.surface4 : DS.Colors.surface3)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            isCancelButtonHovered = hovering
        }
        .accessibilityLabel("Cancel timer")
    }

    /// Run by Wisp on this Mac — no data source to credit.
    private var attribution: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(DS.Colors.textTertiary)
                .frame(width: 5, height: 5)
            Text("On this Mac · alerts when done")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }
}

// MARK: - Countdown schedule

/// A `TimelineSchedule` that ticks at each whole second remaining before
/// `endDate` (aligned to the end, not to when the view appeared), stops after
/// the end, and yields nothing further while paused.
///
/// A plain `.periodic` schedule cannot be paused, and `.animation` would
/// redraw every frame for a clock that changes once a second.
nonisolated struct CountdownSecondTickSchedule: TimelineSchedule {
    let endDate: Date
    let isPaused: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        // Paused: render once for the current moment, then never again until the
        // schedule is replaced (which SwiftUI does when `isPaused` flips).
        guard !isPaused else {
            var hasYieldedInitialEntry = false
            return AnyIterator {
                guard !hasYieldedInitialEntry else { return nil }
                hasYieldedInitialEntry = true
                return startDate
            }
        }

        // First entry is "now"; after that, every point where the rounded-up
        // seconds-remaining value changes, ending with `endDate` itself.
        let secondsRemainingAtStart = endDate.timeIntervalSince(startDate)
        var nextTickDate: Date? = secondsRemainingAtStart > 0
            ? endDate.addingTimeInterval(-floor(secondsRemainingAtStart))
            : nil
        var hasYieldedInitialEntry = false

        return AnyIterator {
            if !hasYieldedInitialEntry {
                hasYieldedInitialEntry = true
                return startDate
            }
            guard let tickDate = nextTickDate else { return nil }
            nextTickDate = tickDate < endDate ? tickDate.addingTimeInterval(1) : nil
            return tickDate
        }
    }
}
