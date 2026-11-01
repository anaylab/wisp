//
//  StudyPage.swift
//  leanring-buddy
//
//  The Study page: set up a focus session (drag the dial or pick a preset, say what
//  you're working on, choose what to hold back), run it (ring, rounds, pause / skip /
//  hold to give up) and see how it went. Everything is driven by `StudySessionController`.
//

import AppKit
import SwiftUI

struct StudyPage: View {
    @ObservedObject private var controller = StudySessionController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let session = controller.session {
                    StudyRunningView(controller: controller, session: session)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else if let finished = controller.finishedSummary {
                    StudyFinishedView(controller: controller, entry: finished)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    StudySetupView(controller: controller)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: 880)
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.86),
                   value: controller.session != nil)
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.86),
                   value: controller.finishedSummary?.id)
    }
}

// MARK: - Setup

private struct StudySetupView: View {
    @ObservedObject var controller: StudySessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Study")
                    .font(WispFont.hero)
                    .foregroundColor(WispColor.textPrimary)
                Text("Pick a length, say what you're working on, and Wisp holds your distractions back until the break.")
                    .font(WispFont.body)
                    .foregroundColor(WispColor.textSecondary)
            }
            .wispEntrance(order: 0)

            HStack(alignment: .top, spacing: 20) {
                timerCard.wispEntrance(order: 1)
                VStack(spacing: 20) {
                    goalCard.wispEntrance(order: 2)
                    StudyBlocklistCard(controller: controller).wispEntrance(order: 3)
                }
            }

            StudyStatsCard(controller: controller).wispEntrance(order: 4)
        }
    }

    private var timerCard: some View {
        VStack(spacing: 18) {
            StudyDurationDial(minutes: Binding(
                get: { controller.plan.focusMinutes },
                set: { newMinutes in
                    controller.plan.focusMinutes = newMinutes
                    // Breaks scale with the block, so a long block isn't followed by a token pause.
                    controller.plan.shortBreakMinutes = max(3, Int((Double(newMinutes) / 5).rounded()))
                    controller.plan.longBreakMinutes = max(10, min(30, Int((Double(newMinutes) * 0.6).rounded())))
                }
            ))
            .frame(width: 250, height: 250)

            presetRow

            VStack(spacing: 10) {
                roundsRow
                HStack {
                    Text("Breaks")
                        .font(WispFont.bodyMedium)
                        .foregroundColor(WispColor.textPrimary)
                    Spacer()
                    Text("\(controller.plan.shortBreakMinutes) min · \(controller.plan.longBreakMinutes) min after round \(controller.plan.roundsBeforeLongBreak)")
                        .font(WispFont.callout)
                        .foregroundColor(WispColor.textSecondary)
                }
                Toggle(isOn: $controller.plan.autoStartNextPhase) {
                    Text("Start the next phase automatically")
                        .font(WispFont.bodyMedium)
                }
                .toggleStyle(.switch)
                .pointerCursor()
            }

            Button {
                controller.startSession()
            } label: {
                Label("Start studying", systemImage: "play.fill")
                    .font(WispFont.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(WispPillButtonStyle())
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .pointerCursor()
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .wispBentoSurface()
    }

    private var presetRow: some View {
        HStack(spacing: 8) {
            ForEach(StudyPlan.presets) { preset in
                let isSelected = controller.plan.matchingPresetID == preset.id
                Button {
                    withAnimation(WispMotion.settle) { controller.plan = preset.plan }
                } label: {
                    VStack(spacing: 1) {
                        Text(preset.title).font(.system(size: 11, weight: .semibold))
                        Text(preset.detail).font(.system(size: 10).monospacedDigit())
                            .foregroundColor(isSelected ? WispColor.textOnAccent.opacity(0.8) : WispColor.textTertiary)
                    }
                    .foregroundColor(isSelected ? WispColor.textOnAccent : WispColor.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isSelected ? WispColor.accent : WispColor.surface2.opacity(0.7))
                    )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    private var roundsRow: some View {
        HStack {
            Text("Rounds")
                .font(WispFont.bodyMedium)
                .foregroundColor(WispColor.textPrimary)
            Spacer()
            HStack(spacing: 6) {
                ForEach(1...StudyPlan.totalRoundsRange.upperBound, id: \.self) { round in
                    Circle()
                        .fill(round <= controller.plan.totalRounds ? WispColor.accent : WispColor.surface3)
                        .frame(width: 12, height: 12)
                        .scaleEffect(round == controller.plan.totalRounds ? 1.2 : 1)
                        .contentShape(Rectangle().inset(by: -4))
                        .onTapGesture {
                            withAnimation(WispMotion.bouncy) { controller.plan.totalRounds = round }
                        }
                        .pointerCursor()
                }
            }
            Text("\(controller.plan.totalRounds)")
                .font(WispFont.bodyMedium.monospacedDigit())
                .foregroundColor(WispColor.textSecondary)
                .frame(width: 18, alignment: .trailing)
        }
    }

    private var goalCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What are you working on?")
                .font(WispFont.headline)
                .foregroundColor(WispColor.textPrimary)
            TextField("e.g. Chapter 6 practice problems", text: $controller.goal)
                .textFieldStyle(.plain)
                .font(WispFont.body)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(WispColor.surface2.opacity(0.7)))
            Text("\(controller.plan.summary) · about \(StudyTimeFormatter.duration(totalSessionSeconds)) with breaks")
                .font(WispFont.callout)
                .foregroundColor(WispColor.textSecondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wispBentoSurface()
    }

    private var totalSessionSeconds: TimeInterval {
        let plan = controller.plan.clamped()
        var total: TimeInterval = 0
        for round in 1...plan.totalRounds {
            total += plan.durationSeconds(of: .focus)
            guard round < plan.totalRounds else { break }
            total += plan.durationSeconds(of: round % plan.roundsBeforeLongBreak == 0 ? .longBreak : .shortBreak)
        }
        return total
    }
}

// MARK: - Blocklist

private struct StudyBlocklistCard: View {
    @ObservedObject var controller: StudySessionController
    @State private var newSiteText = ""
    @State private var siteErrorShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Hold back", systemImage: "shield.lefthalf.filled")
                    .font(WispFont.headline)
                    .foregroundColor(WispColor.textPrimary)
                Spacer()
                Text("Focus blocks only, never breaks")
                    .font(WispFont.caption)
                    .foregroundColor(WispColor.textTertiary)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(StudyBlocklist.categories) { category in
                    StudyChip(
                        title: category.title,
                        symbolName: category.symbolName,
                        isOn: controller.blocklist.enabledCategoryIDs.contains(category.id)
                    ) {
                        withAnimation(WispMotion.bouncy) { toggle(category.id) }
                    }
                }
            }

            Divider().opacity(0.5)

            customSites
            customApps

            HStack(spacing: 14) {
                Toggle("Websites", isOn: $controller.blocklist.blocksWebsites)
                Toggle("Apps", isOn: $controller.blocklist.blocksApps)
            }
            .toggleStyle(.switch)
            .font(WispFont.callout)
            .pointerCursor()

            if let note = controller.browserPermissionNote {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(WispFont.caption)
                    .foregroundColor(WispColor.warningText)
            } else {
                Text("Blocked apps are hidden when you switch to them. Blocked sites in Chrome, Safari, Brave, Edge or Arc are swapped for a calm page; macOS asks once to let Wisp control the browser.")
                    .font(WispFont.caption)
                    .foregroundColor(WispColor.textTertiary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wispBentoSurface()
    }

    private var customSites: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "globe").foregroundColor(WispColor.textTertiary)
                TextField("Add a site, e.g. reddit.com", text: $newSiteText)
                    .textFieldStyle(.plain)
                    .font(WispFont.body)
                    .onSubmit(addSite)
                Button("Add", action: addSite)
                    .buttonStyle(WispPillButtonStyle(isProminent: false))
                    .controlSize(.small)
                    .disabled(newSiteText.trimmingCharacters(in: .whitespaces).isEmpty)
                    .pointerCursor()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(WispColor.surface2.opacity(0.7)))

            if siteErrorShown {
                Text("That doesn't look like a website address.")
                    .font(WispFont.caption)
                    .foregroundColor(WispColor.destructiveText)
            }
            if !controller.blocklist.customDomains.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(controller.blocklist.customDomains, id: \.self) { domain in
                        removableChip(title: domain, symbolName: "globe") {
                            controller.blocklist.customDomains.removeAll { $0 == domain }
                        }
                    }
                }
            }
        }
    }

    private var customApps: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Menu {
                    ForEach(addableRunningApps(), id: \.bundleIdentifier) { app in
                        Button(app.name) {
                            controller.blocklist.customApps.append(app)
                        }
                    }
                } label: {
                    Label("Add a running app", systemImage: "plus.app")
                        .font(WispFont.callout)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .pointerCursor()
                Spacer()
            }
            if !controller.blocklist.customApps.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(controller.blocklist.customApps) { app in
                        removableChip(title: app.name, symbolName: "app") {
                            controller.blocklist.customApps.removeAll { $0.bundleIdentifier == app.bundleIdentifier }
                        }
                    }
                }
            }
        }
    }

    private func removableChip(title: String, symbolName: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbolName).font(.system(size: 10))
            Text(title).font(WispFont.caption).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("Remove \(title)")
        }
        .foregroundColor(WispColor.textPrimary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(WispColor.accentSubtle))
    }

    private func toggle(_ categoryID: String) {
        if controller.blocklist.enabledCategoryIDs.contains(categoryID) {
            controller.blocklist.enabledCategoryIDs.remove(categoryID)
        } else {
            controller.blocklist.enabledCategoryIDs.insert(categoryID)
        }
    }

    private func addSite() {
        guard let domain = StudyBlocklist.normalizedDomain(fromUserText: newSiteText) else {
            siteErrorShown = !newSiteText.trimmingCharacters(in: .whitespaces).isEmpty
            return
        }
        siteErrorShown = false
        if !controller.blocklist.customDomains.contains(domain) {
            controller.blocklist.customDomains.append(domain)
        }
        newSiteText = ""
    }

    private func addableRunningApps() -> [StudyBlockedApp] {
        let alreadyAdded = Set(controller.blocklist.customApps.map(\.bundleIdentifier))
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { application -> StudyBlockedApp? in
                guard let bundleIdentifier = application.bundleIdentifier,
                      bundleIdentifier != Bundle.main.bundleIdentifier,
                      !StudyBlocklist.protectedBundleIdentifiers.contains(bundleIdentifier),
                      !alreadyAdded.contains(bundleIdentifier) else { return nil }
                return StudyBlockedApp(bundleIdentifier: bundleIdentifier, name: application.localizedName ?? bundleIdentifier)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

private struct StudyChip: View {
    let title: String
    let symbolName: String
    let isOn: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.circle.fill" : symbolName)
                    .font(.system(size: 12, weight: .medium))
                Text(title)
                    .font(WispFont.bodyMedium)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundColor(isOn ? WispColor.accentText : WispColor.textSecondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isOn ? WispColor.accentSubtle : WispColor.surface2.opacity(isHovered ? 1 : 0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isOn ? WispColor.accent.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerCursor()
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - Stats

private struct StudyStatsCard: View {
    @ObservedObject var controller: StudySessionController

    var body: some View {
        let days = controller.lastSevenDays
        let maximumSeconds = max(days.map(\.seconds).max() ?? 0, 30 * 60)
        HStack(alignment: .bottom, spacing: 28) {
            stat(value: StudyTimeFormatter.duration(controller.todayFocusSeconds), label: "focused today")
            stat(value: "\(controller.streakDays)", label: controller.streakDays == 1 ? "day streak" : "day streak")
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, entry in
                    VStack(spacing: 5) {
                        Capsule()
                            .fill(index == days.count - 1 ? WispColor.accent : WispColor.accent.opacity(0.4))
                            .frame(width: 14, height: max(4, CGFloat(entry.seconds / maximumSeconds) * 54))
                        Text(entry.day, format: .dateTime.weekday(.narrow))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(WispColor.textTertiary)
                    }
                    .help("\(StudyTimeFormatter.duration(entry.seconds))")
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .wispBentoSurface()
    }

    private func stat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(WispFont.title.monospacedDigit())
                .foregroundColor(WispColor.textPrimary)
            Text(label)
                .font(WispFont.callout)
                .foregroundColor(WispColor.textSecondary)
        }
    }
}

// MARK: - Running

private struct StudyRunningView: View {
    @ObservedObject var controller: StudySessionController
    let session: StudySession

    private var tint: Color {
        session.phase.isBreak ? WispColor.intelligence : WispColor.accent
    }

    var body: some View {
        let now = controller.now
        VStack(spacing: 22) {
            VStack(spacing: 4) {
                Text(session.goal.isEmpty ? "Focus session" : session.goal)
                    .font(WispFont.title)
                    .foregroundColor(WispColor.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(WispFont.callout)
                    .foregroundColor(WispColor.textSecondary)
            }

            windowBuddyRow

            StudyProgressRing(
                progress: session.progress(at: now),
                timeText: StudyTimeFormatter.clock(session.remainingSeconds(at: now)),
                phase: session.phase,
                isPaused: session.isPaused,
                caption: ringCaption,
                tint: tint
            )
            .frame(width: 330, height: 330)

            roundPips

            controls
        }
        .padding(30)
        .frame(maxWidth: .infinity)
        .background(
            RadialGradient(colors: [tint.opacity(0.14), .clear], center: .top, startRadius: 20, endRadius: 520)
                .animation(.easeInOut(duration: 0.8), value: session.phase)
        )
        .wispBentoSurface(isLive: session.isRunning && !session.phase.isBreak)
    }

    /// The study buddy beside what it is saying (nothing is shown while it is quiet, only the buddy).
    private var windowBuddyRow: some View {
        HStack(spacing: 12) {
            StudyBuddyView(size: 52)
            if let message = controller.buddyMessage {
                HStack(spacing: 10) {
                    Text(message.text)
                        .font(WispFont.callout)
                        .foregroundColor(WispColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let offer = message.offer {
                        Button(offer.buttonTitle) { controller.acceptBuddyOffer() }
                            .buttonStyle(WispPillButtonStyle())
                            .pointerCursor()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.opacity(0.12)))
                .transition(.scale(scale: 0.94, anchor: .leading).combined(with: .opacity))
            }
        }
        .animation(WispMotion.pop, value: controller.buddyMessage?.id)
    }

    private var subtitle: String {
        if session.isAwaitingStart { return "\(session.phase.title) is ready when you are" }
        switch session.phase {
        case .focus: return "Round \(session.focusRound) of \(session.plan.totalRounds) · distractions on hold"
        case .shortBreak, .longBreak: return "Stretch, drink some water. Distractions are back until the next round."
        }
    }

    private var ringCaption: String {
        session.phase == .focus ? "Round \(session.focusRound) of \(session.plan.totalRounds)" : "Rest your eyes"
    }

    private var roundPips: some View {
        let now = controller.now
        return VStack(spacing: 8) {
            StudyGarden(
                totalRounds: session.plan.totalRounds,
                finishedRounds: session.completedFocusRounds,
                currentRoundGrowth: session.phase == .focus && !session.isAwaitingStart ? studyPlantGrowth(forProgress: session.progress(at: now)) : nil,
                plantWidth: session.plan.totalRounds > 5 ? 30 : 38,
                plantHeight: session.plan.totalRounds > 5 ? 38 : 48,
                spacing: 6
            )
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if session.isAwaitingStart {
                Button {
                    controller.startNextPhase()
                } label: {
                    Label("Start \(session.phase.title.lowercased())", systemImage: "play.fill")
                }
                .buttonStyle(WispPillButtonStyle())
                .pointerCursor()
            } else {
                Button {
                    session.isPaused ? controller.resume() : controller.pause()
                } label: {
                    Label(session.isPaused ? "Resume" : "Pause", systemImage: session.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(WispPillButtonStyle())
                .keyboardShortcut(.space, modifiers: [])
                .pointerCursor()
            }

            Button {
                controller.skipPhase()
            } label: {
                Label(session.phase.isBreak ? "Skip break" : "Skip to break", systemImage: "forward.end.fill")
            }
            .buttonStyle(WispPillButtonStyle(isProminent: false))
            .pointerCursor()

            StudyHoldToConfirmButton(title: "Hold to end", holdSeconds: 1.2) {
                controller.endSession()
            }
        }
        .controlSize(.large)
    }
}

// MARK: - Finished

private struct StudyFinishedView: View {
    @ObservedObject var controller: StudySessionController
    let entry: StudyLogEntry

    var body: some View {
        VStack(spacing: 18) {
            if entry.completedRounds > 0 {
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(0..<min(entry.completedRounds, 8), id: \.self) { roundIndex in
                        StudyGrowingPlant(delay: 0.25 + Double(roundIndex) * 0.4)
                            .frame(width: 46, height: 58)
                    }
                }
                .padding(.top, 4)
            } else {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 44))
                    .foregroundColor(WispColor.accent)
            }
            Text("Nice work")
                .font(WispFont.hero)
                .foregroundColor(WispColor.textPrimary)
            if !entry.goal.isEmpty {
                Text(entry.goal)
                    .font(WispFont.body)
                    .foregroundColor(WispColor.textSecondary)
            }
            HStack(spacing: 36) {
                summaryStat(StudyTimeFormatter.duration(entry.focusSeconds), "focused")
                summaryStat("\(entry.completedRounds)", entry.completedRounds == 1 ? "round" : "rounds")
                summaryStat("\(entry.distractionsHeldBack)", "held back")
                summaryStat("\(controller.streakDays)", "day streak")
            }
            .padding(.vertical, 6)
            HStack(spacing: 12) {
                Button {
                    controller.dismissFinishedSummary()
                    controller.startSession()
                } label: {
                    Label("Another session", systemImage: "arrow.clockwise")
                }
                .buttonStyle(WispPillButtonStyle())
                .pointerCursor()
                Button("Done") { controller.dismissFinishedSummary() }
                    .buttonStyle(WispPillButtonStyle(isProminent: false))
                    .pointerCursor()
            }
            .controlSize(.large)
        }
        .padding(36)
        .frame(maxWidth: .infinity)
        .wispBentoSurface()
    }

    private func summaryStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(WispFont.title.monospacedDigit()).foregroundColor(WispColor.textPrimary)
            Text(label).font(WispFont.callout).foregroundColor(WispColor.textSecondary)
        }
    }
}
