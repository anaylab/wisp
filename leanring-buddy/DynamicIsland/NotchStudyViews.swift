//
//  NotchStudyViews.swift
//  leanring-buddy
//
//  Study mode on the island. While a session runs the notch stays up: the study buddy on the
//  left flank (a dot when it has an offer for you), a live ring and countdown on the right
//  ("Break!" for a few seconds after a phase changes). Hovering opens a card: the buddy in a
//  progress ring, the time (tap it for when the block ends), a garden of your rounds, the
//  buddy's speech bubble (tap its chip to take an offer like +5 min) and Pause / +5 / Skip /
//  hold-to-end. Poke the buddy for a word of encouragement. With no session the same spot
//  is a launcher: the buddy's greeting, today's garden and one-tap presets, with your usual
//  one outlined.
//
//  Each view observes the controller itself, so the half-second tick redraws only these
//  small views and not the whole island.
//

import SwiftUI

private func studyTint(for phase: StudyPhase) -> Color {
    phase.isBreak ? WispColor.Island.activityAccent : WispColor.Island.accent
}

/// The left flank while a session runs: the study buddy, with a dot when it has an offer waiting.
struct NotchStudyLeadingGlyph: View {
    @ObservedObject private var controller = StudySessionController.shared

    var body: some View {
        if let session = controller.session {
            StudyBuddyView(size: 20, liveliness: .working)
                .overlay(alignment: .topTrailing) {
                    if controller.buddyMessage?.offer != nil {
                        Circle()
                            .fill(WispColor.Island.accent)
                            .frame(width: 6, height: 6)
                            .offset(x: 2, y: -2)
                            .transition(.scale)
                    }
                }
                .animation(WispMotion.pop, value: controller.buddyMessage?.offer != nil)
                .nativeTooltip("\(session.phase.title) · round \(session.focusRound) of \(session.plan.totalRounds)")
        }
    }
}

/// What the buddy is saying: a small speech bubble, with a one-tap chip when it can do something for you.
struct NotchStudyBuddyBubble: View {
    let message: StudyBuddyMessage
    let tint: Color
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(message.text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(WispColor.Island.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let offer = message.offer {
                Button(action: onAccept) {
                    Text(offer.buttonTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 2)
                }
                .buttonStyle(WispIslandButtonStyle(prominence: .prominent))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.14))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(tint.opacity(0.25), lineWidth: 0.5))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
    }
}

/// The right flank while a session runs: a progress ring and the time left.
struct NotchStudyFlank: View {
    @ObservedObject private var controller = StudySessionController.shared

    var body: some View {
        if let session = controller.session {
            let tint = studyTint(for: session.phase)
            HStack(spacing: 5) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.15), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: max(session.progress(at: controller.now), 0.02))
                        .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 12, height: 12)

                Text(flankText(for: session))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundColor(controller.phaseBanner != nil ? tint : WispColor.Island.textPrimary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
            .animation(WispMotion.quick, value: controller.phaseBanner)
            .nativeTooltip(controller.menuBarStatusText)
        }
    }

    private func flankText(for session: StudySession) -> String {
        if let banner = controller.phaseBanner { return banner }
        if session.isAwaitingStart { return "Ready" }
        return StudyTimeFormatter.clock(session.remainingSeconds(at: controller.now))
    }
}

/// The section at the top of the hover panel: the running timer, or the launcher.
struct NotchStudyPanelSection: View {
    @ObservedObject private var controller = StudySessionController.shared

    var body: some View {
        Group {
            if let session = controller.session {
                runningCard(session)
                    .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            } else {
                launcherCard
                    .transition(.opacity)
            }
        }
        .animation(WispMotion.smooth, value: controller.session != nil)
    }

    // MARK: Running

    private func runningCard(_ session: StudySession) -> some View {
        let tint = studyTint(for: session.phase)
        let now = controller.now
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                medallion(for: session, tint: tint, now: now)

                VStack(alignment: .leading, spacing: 2) {
                    Text(headline(for: session))
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.8)
                        .foregroundColor(tint)
                    Text(StudyTimeFormatter.clock(session.remainingSeconds(at: now)))
                        .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundColor(WispColor.Island.textPrimary.opacity(session.isPaused ? 0.5 : 1))
                        .contentTransition(.numericText())
                }

                Spacer(minLength: 0)

                // One plant per round: the garden doubles as the round counter.
                StudyGarden(
                    totalRounds: session.plan.totalRounds,
                    finishedRounds: session.completedFocusRounds,
                    currentRoundGrowth: session.phase == .focus && !session.isAwaitingStart ? studyPlantGrowth(forProgress: session.progress(at: now)) : nil,
                    plantWidth: session.plan.totalRounds > 5 ? 13 : 16,
                    plantHeight: session.plan.totalRounds > 5 ? 17 : 21
                )
            }

            if let message = controller.buddyMessage {
                NotchStudyBuddyBubble(
                    message: message,
                    tint: tint,
                    onAccept: { controller.acceptBuddyOffer() },
                    onDismiss: { controller.dismissBuddyMessage() }
                )
                .transition(.scale(scale: 0.92, anchor: .topLeading).combined(with: .opacity))
            }

            controls(for: session)
        }
        .animation(WispMotion.pop, value: controller.buddyMessage?.id)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(WispColor.Island.controlFill.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(RadialGradient(colors: [tint.opacity(0.16), .clear], center: .topLeading, startRadius: 4, endRadius: 190))
                )
        )
        .animation(.easeInOut(duration: 0.6), value: session.phase)
    }

    /// The ring with the buddy inside it; during a break a breathing halo joins it.
    private func medallion(for session: StudySession, tint: Color, now: Date) -> some View {
        ZStack {
            if session.phase.isBreak {
                StudyBreathingHalo(tint: tint).padding(4)
            }
            Circle().stroke(Color.white.opacity(0.12), lineWidth: 4)
            Circle()
                .trim(from: 0, to: max(session.progress(at: now), 0.01))
                .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.5), value: session.progress(at: now))
            StudyBuddyView(size: 46)
        }
        .frame(width: 72, height: 72)
    }

    private func headline(for session: StudySession) -> String {
        let phaseName = session.phase.title.uppercased()
        return session.isPaused ? "PAUSED · \(phaseName)" : phaseName
    }

    private func controls(for session: StudySession) -> some View {
        HStack(spacing: 6) {
            if session.isAwaitingStart {
                controlButton("Start \(session.phase.title.lowercased())", symbol: "play.fill", prominent: true) {
                    controller.startNextPhase()
                }
            } else {
                controlButton(session.isPaused ? "Resume" : "Pause",
                              symbol: session.isPaused ? "play.fill" : "pause.fill",
                              prominent: true) {
                    session.isPaused ? controller.resume() : controller.pause()
                }
            }
            controlButton(nil, symbol: "forward.end.fill", prominent: false) {
                controller.skipPhase()
            }
            .nativeTooltip(session.phase.isBreak ? "Skip the break" : "Skip to the break")
            Spacer(minLength: 0)
            StudyHoldToConfirmButton(title: "End", holdSeconds: 1.2) {
                controller.endSession()
            }
            .font(.system(size: 11))
            .scaleEffect(0.88, anchor: .trailing)
        }
    }

    private func controlButton(_ title: String?, symbol: String?, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
                if let title { Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1) }
            }
            .fixedSize()
            .padding(.horizontal, 2)
        }
        .buttonStyle(WispIslandButtonStyle(prominence: prominent ? .prominent : .subtle))
    }

    // MARK: Launcher

    private var launcherCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                StudyBuddyView(size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(controller.buddyMessage?.text ?? greetingText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(WispColor.Island.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .id(controller.buddyMessage?.id)
                        .transition(.opacity)
                    todayGarden
                }
                .animation(WispMotion.quick, value: controller.buddyMessage?.id)
                Spacer(minLength: 0)
                holdBackToggle
            }
            HStack(spacing: 6) {
                ForEach(StudyPlan.presets) { preset in
                    let isSuggested = preset.id == controller.recommendedPresetID
                    Button {
                        controller.startSession(using: preset.plan)
                    } label: {
                        VStack(spacing: 1) {
                            Text(preset.detail)
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            Text(preset.title)
                                .font(.system(size: 9.5))
                                .foregroundColor(isSuggested ? WispColor.Island.accent : WispColor.Island.textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .foregroundColor(WispColor.Island.textPrimary)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(WispColor.Island.controlFill)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .stroke(WispColor.Island.accent.opacity(isSuggested ? 0.55 : 0), lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(PressableScaleButtonStyle())
                    .pointerCursor()
                    .nativeTooltip(isSuggested ? "Start \(preset.title.lowercased()), your usual: \(preset.plan.summary)"
                                               : "Start \(preset.title.lowercased()): \(preset.plan.summary)")
                }
            }
        }
    }

    private var greetingText: String {
        StudyBuddyVoice.greeting(
            todayRounds: controller.todayCompletedRounds,
            streakDays: controller.streakDays,
            hour: Calendar.current.component(.hour, from: Date())
        )
    }

    /// Today's finished rounds as a row of blooms, so an idle notch shows how the day is going.
    @ViewBuilder
    private var todayGarden: some View {
        let rounds = controller.todayCompletedRounds
        if rounds > 0 {
            HStack(alignment: .bottom, spacing: 8) {
                StudyGarden(totalRounds: min(rounds, 8), finishedRounds: min(rounds, 8), currentRoundGrowth: nil,
                            plantWidth: 15, plantHeight: 19)
                Text("\(StudyTimeFormatter.duration(controller.todayFocusSeconds)) today"
                     + (controller.streakDays > 1 ? " · \(controller.streakDays)-day streak" : ""))
                    .font(.system(size: 10.5))
                    .foregroundColor(WispColor.Island.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private var holdBackToggle: some View {
        let isOn = controller.blocklist.blocksWebsites || controller.blocklist.blocksApps
        return Button {
            controller.blocklist.blocksWebsites = !isOn
            controller.blocklist.blocksApps = !isOn
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isOn ? "shield.lefthalf.filled" : "shield.slash")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(isOn ? WispColor.Island.accent : WispColor.Island.textTertiary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule(style: .continuous).fill(WispColor.Island.controlFill))
        }
        .buttonStyle(PressableScaleButtonStyle())
        .pointerCursor()
        .nativeTooltip(isOn ? "Blocked apps and sites are held back during focus. Click to turn off." : "Click to hold distractions back during focus.")
    }
}
