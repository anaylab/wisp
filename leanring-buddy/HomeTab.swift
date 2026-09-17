//
//  HomeTab.swift
//  leanring-buddy
//
//  The dashboard's Home — Wisp's personal command centre. The brief's hero
//  conversational moment lives in the Dynamic Island, not here, so this surface
//  is calm rather than a chat box: it says "Wisp is here and ready", shows how
//  to summon it, offers a few quiet quick actions into the rest of the app, and
//  lists what Wisp has recently done. It is fully adaptive (light/dark) via the
//  `DS`/`WispColor` tokens, so it reads as native paper in light mode and dark
//  material in dark mode.
//

import SwiftUI

struct HomeTab: View {
    @ObservedObject var taskRegistry: AgentTaskRegistry
    @ObservedObject private var bindingStore = ShortcutBindingStore.shared
    @ObservedObject private var companionManager: CompanionManager

    /// Navigates the dashboard to another tab when a quick action is tapped.
    let onSelectTab: (DashboardView.DashboardTab) -> Void

    init(
        taskRegistry: AgentTaskRegistry,
        companionManager: CompanionManager,
        onSelectTab: @escaping (DashboardView.DashboardTab) -> Void
    ) {
        self.taskRegistry = taskRegistry
        self.companionManager = companionManager
        self.onSelectTab = onSelectTab
    }

    private let quickActions: [QuickAction] = [
        QuickAction(symbol: .system("bubble.left.and.bubble.right"), title: "Conversation", tab: .conversation),
        QuickAction(symbol: .system("keyboard"), title: "Shortcuts", tab: .shortcuts),
        QuickAction(symbol: .mic, title: "Dictation", tab: .dictation),
        QuickAction(symbol: .system("antenna.radiowaves.left.and.right"), title: "Sources", tab: .sources),
        QuickAction(symbol: .settings, title: "Tools", tab: .tools),
        QuickAction(symbol: .system("speedometer"), title: "Performance", tab: .performance)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WispSpacing.xxxl) {
                hero
                summonCard
                quickActionsSection
                recentActivitySection
            }
            .padding(.horizontal, WispSpacing.xxxl)
            .padding(.vertical, WispSpacing.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .center, spacing: WispSpacing.md) {
            WispMark(state: companionManager.islandState.markState, size: 48)
                .padding(.bottom, WispSpacing.xs)
            Text("wisp")
                .font(WispFont.wordmark(size: 30))
                .foregroundColor(DS.Colors.textPrimary)
            Text("What can I help with?")
                .font(WispFont.hero)
                .foregroundColor(DS.Colors.textPrimary)
            Text("Hold your shortcut anywhere to talk, or tap it to type. Wisp answers in the notch.")
                .font(WispFont.callout)
                .foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, WispSpacing.lg)
    }

    // MARK: - How to summon Wisp

    private var summonCard: some View {
        HStack(spacing: WispSpacing.lg) {
            summonItem(name: "Talk", gesture: "hold", keys: bindingStore.primaryHoldChord.keyCapsuleLabels)
            divider
            summonItem(name: "Type", gesture: "tap", keys: bindingStore.primaryHoldChord.keyCapsuleLabels)
            divider
            summonItem(name: "Dictate", gesture: "hold", keys: bindingStore.primaryHoldChord.keyCapsuleLabels + ["shift"])
            Spacer(minLength: 0)
        }
        .padding(WispSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: WispRadius.large, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: WispRadius.large, style: .continuous)
                .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    private func summonItem(name: String, gesture: String, keys: [String]) -> some View {
        VStack(alignment: .leading, spacing: WispSpacing.sm) {
            Text(name)
                .font(WispFont.caption)
                .foregroundColor(DS.Colors.textSecondary)
            HStack(spacing: WispSpacing.xs) {
                Text(gesture)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.Colors.accentText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(DS.Colors.accentSubtle))
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(WispFont.mono)
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: WispRadius.small, style: .continuous)
                                .fill(DS.Colors.surface3)
                        )
                }
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(DS.Colors.borderSubtle)
            .frame(width: 1, height: 34)
    }

    // MARK: - Quick actions

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: WispSpacing.md) {
            Text("QUICK ACTIONS")
                .font(WispFont.overline)
                .tracking(0.6)
                .foregroundColor(DS.Colors.textTertiary)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: WispSpacing.md)],
                spacing: WispSpacing.md
            ) {
                ForEach(quickActions) { action in
                    quickActionTile(action)
                }
            }
        }
    }

    private func quickActionTile(_ action: QuickAction) -> some View {
        Button {
            onSelectTab(action.tab)
        } label: {
            HStack(spacing: WispSpacing.md) {
                WispIcon(symbol: action.symbol, size: 20, tint: DS.Colors.accentText)
                Text(action.title)
                    .font(WispFont.bodyMedium)
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, WispSpacing.lg)
            .padding(.vertical, WispSpacing.md + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: WispRadius.large, style: .continuous)
                    .fill(DS.Colors.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: WispRadius.large, style: .continuous)
                    .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: WispRadius.large, style: .continuous))
        }
        .buttonStyle(PressableScaleButtonStyle())
        .pointerCursor()
    }

    // MARK: - Recent activity

    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: WispSpacing.md) {
            HStack {
                Text("RECENT")
                    .font(WispFont.overline)
                    .tracking(0.6)
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer()
                if !taskRegistry.records.isEmpty {
                    Button("View all") { onSelectTab(.activity) }
                        .dsTextButtonStyle(fontSize: 11)
                        .pointerCursor()
                }
            }

            if taskRegistry.records.isEmpty {
                Text("Nothing yet — the things Wisp does will show up here.")
                    .font(WispFont.callout)
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, WispSpacing.sm)
            } else {
                VStack(spacing: 0) {
                    ForEach(recentRecords) { record in
                        recentRow(record)
                        if record.id != recentRecords.last?.id {
                            Divider().overlay(DS.Colors.borderSubtle)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: WispRadius.large, style: .continuous)
                        .fill(DS.Colors.surface1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: WispRadius.large, style: .continuous)
                        .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
                )
            }
        }
    }

    /// The five most recent records, newest first.
    private var recentRecords: [AgentTaskRecord] {
        Array(taskRegistry.records.sorted { $0.startedAt > $1.startedAt }.prefix(5))
    }

    private func recentRow(_ record: AgentTaskRecord) -> some View {
        HStack(spacing: WispSpacing.md) {
            Circle()
                .fill(statusColor(record.status))
                .frame(width: 7, height: 7)
            Text(record.title)
                .font(WispFont.body)
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
            Spacer(minLength: WispSpacing.md)
            Text(relativeTime(record.startedAt))
                .font(WispFont.caption)
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.horizontal, WispSpacing.lg)
        .padding(.vertical, WispSpacing.md)
    }

    private func statusColor(_ status: AgentTaskRecord.Status) -> Color {
        switch status {
        case .running, .waitingForApproval: return DS.Colors.accentText
        case .succeeded:                    return DS.Colors.success
        case .failed:                       return DS.Colors.destructive
        case .cancelled, .interrupted:      return DS.Colors.textTertiary
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Quick action model

    struct QuickAction: Identifiable {
        let symbol: WispIconSymbol
        let title: String
        let tab: DashboardView.DashboardTab
        var id: String { title }
    }
}
