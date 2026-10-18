//
//  DailyChecklistView.swift
//  leanring-buddy
//
//  The tickable "Wisp Today" checklist in the notch. A tick goes through
//  `JobsEngine.setChecklistItem`, which writes the Reminders list, so the notch and
//  Reminders never disagree. Island styling only (WispColor.Island.*).
//
//  Finishing the last item is a small moment when Playful is on: the "All done"
//  label bounces, a soft burst of dots plays, and the day streak ticks up. The
//  island stays black; only the burst takes a colour (the day's buddy, else the
//  theme accent).
//

import SwiftUI

struct DailyChecklistView: View {
    @ObservedObject private var jobsEngine = JobsEngine.shared
    @ObservedObject private var streakStore = ChecklistStreakStore.shared
    @ObservedObject private var themeStore = WispThemeStore.shared
    @ObservedObject private var buddyStore = BuddyStore.shared

    /// Rows to show before "+ N more". The compact drop-down card shows fewer than
    /// the hover panel.
    let maximumVisibleRows: Int
    /// Hides the section label when the host already supplies one.
    var showsHeader: Bool = true

    private var checklistItems: [ChecklistItem] { jobsEngine.todayChecklist }

    private var remainingCount: Int {
        checklistItems.filter { !$0.isCompleted }.count
    }

    private var isEveryItemComplete: Bool {
        !checklistItems.isEmpty && remainingCount == 0
    }

    /// The burst takes the day's buddy colour, so the celebration is theirs.
    private var celebrationAccentColor: Color {
        buddyStore.dayBuddy(on: Date()).map { BuddyAppearance.lightColor(forColorIndex: $0.colorIndex) }
            ?? WispColor.accentText
    }

    /// Unfinished first (in the builder's order), done ones sink so ticking
    /// something reads as it leaving the way, without the row vanishing.
    private var orderedItems: [ChecklistItem] {
        checklistItems.filter { !$0.isCompleted } + checklistItems.filter { $0.isCompleted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsHeader {
                HStack(spacing: 6) {
                    Text("TODAY")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(WispColor.Island.textTertiary)
                        .tracking(0.6)
                    Spacer(minLength: 0)
                    if themeStore.isPlayful && isEveryItemComplete && streakStore.currentStreakDays >= 2 {
                        Text("\(streakStore.currentStreakDays)-day streak")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundColor(WispColor.Island.textSecondary)
                            .transition(.opacity)
                    }
                    Text(remainingCount == 0 ? "All done" : "\(remainingCount) left")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundColor(WispColor.Island.textTertiary)
                        .playfulBounce(trigger: streakStore.celebrationTrigger)
                        .background {
                            PlayfulBurst(trigger: streakStore.celebrationTrigger, accentColor: celebrationAccentColor)
                                .frame(width: 80, height: 80)
                        }
                }
            }

            let visibleItems = Array(orderedItems.prefix(maximumVisibleRows))
            ForEach(visibleItems) { checklistItem in
                DailyChecklistRow(checklistItem: checklistItem) { newCompletion in
                    Task { await jobsEngine.setChecklistItem(id: checklistItem.id, isCompleted: newCompletion) }
                }
            }

            let hiddenCount = orderedItems.count - visibleItems.count
            if hiddenCount > 0 {
                Text("+ \(hiddenCount) more in Wisp")
                    .font(.system(size: 10.5))
                    .foregroundColor(WispColor.Island.textTertiary)
                    .padding(.leading, 9)
            }
        }
        .onChange(of: isEveryItemComplete) { _, isNowComplete in
            // The last item was just ticked (here or in Reminders). Recording is
            // idempotent per day, so un-ticking and re-ticking doesn't celebrate twice.
            if isNowComplete { streakStore.recordChecklistFinished(today: Date()) }
        }
        .onAppear { streakStore.refreshStreak(today: Date()) }
        .task {
            // Reminders is the source of truth, so a tick made over there shows
            // up as soon as the user looks here.
            await jobsEngine.refreshChecklistCompletion()
        }
    }
}

private struct DailyChecklistRow: View {
    let checklistItem: ChecklistItem
    let onToggle: (Bool) -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            onToggle(!checklistItem.isCompleted)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: checklistItem.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(checklistItem.isCompleted ? WispColor.Brand.lavender : WispColor.Island.textSecondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(checklistItem.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(checklistItem.isCompleted ? WispColor.Island.textTertiary : WispColor.Island.textPrimary)
                        .strikethrough(checklistItem.isCompleted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let subtitleText = subtitleText {
                        Text(subtitleText)
                            .font(.system(size: 10))
                            .foregroundColor(WispColor.Island.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovered ? WispColor.Island.controlFillHovered : WispColor.Island.controlFill)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(PressableScaleButtonStyle())
        .pointerCursor()
        .onHover { isHovered = $0 }
        .accessibilityLabel(checklistItem.title)
        .accessibilityValue(checklistItem.isCompleted ? "Done" : "Not done")
        .accessibilityHint("Double tap to mark \(checklistItem.isCompleted ? "not done" : "done")")
    }

    /// The builder's subtitle, with a rollover note once an item has slipped.
    private var subtitleText: String? {
        guard !checklistItem.isCompleted else { return nil }
        if checklistItem.rolloverCount >= 3 {
            return "overdue \(checklistItem.rolloverCount)d"
        }
        if checklistItem.rolloverCount > 0 {
            return [checklistItem.subtitle, "from yesterday"].compactMap { $0 }.joined(separator: " · ")
        }
        return checklistItem.subtitle
    }
}
