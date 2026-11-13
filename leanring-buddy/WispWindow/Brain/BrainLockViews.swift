//
//  BrainLockViews.swift
//  leanring-buddy
//
//  The Touch ID lock's two faces: `BrainLockGate`, which stands in for any
//  Brain page while `BrainLockController` is locked, and the settings card
//  that turns it on, picks the auto-lock delay and locks it now.
//

import SwiftUI

/// Shows the page, or the locked screen when it is a Brain page and the
/// brain is locked. Other pages pass straight through.
struct BrainLockGate<PageContent: View>: View {
    let page: WispPage
    @ViewBuilder let pageContent: () -> PageContent

    @ObservedObject private var lockController = BrainLockController.shared
    @ObservedObject private var brainPreferences = BrainPreferences.shared

    var body: some View {
        if page.section == .brain && brainPreferences.isLockEnabled && lockController.isLocked {
            BrainLockedView()
        } else {
            pageContent()
        }
    }
}

private struct BrainLockedView: View {
    @ObservedObject private var lockController = BrainLockController.shared

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(WispColor.textSecondary)
            Text("Your brain is locked")
                .font(.title3.weight(.semibold))
                .foregroundStyle(WispColor.textPrimary)
            Text("Unlock with \(lockController.unlockMethodName) to see your pages, graph and review.")
                .font(.callout)
                .foregroundStyle(WispColor.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await lockController.unlock() }
            } label: {
                Label("Unlock", systemImage: "touchid")
            }
            .buttonStyle(WispPillButtonStyle())
            .disabled(lockController.isAuthenticating)
            .pointerCursor(isEnabled: !lockController.isAuthenticating)
            .keyboardShortcut(.defaultAction)
            if let lastFailureMessage = lockController.lastFailureMessage {
                Text(lastFailureMessage)
                    .font(.caption)
                    .foregroundStyle(WispColor.warningText)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WispColor.windowBackground)
    }
}

struct BrainLockSettingsCard: View {
    @ObservedObject private var lockController = BrainLockController.shared
    @ObservedObject private var brainPreferences = BrainPreferences.shared

    var body: some View {
        DashboardCard(title: "Lock") {
            VStack(alignment: .leading, spacing: 12) {
                SettingRow(
                    title: "Lock the Brain with \(lockController.unlockMethodName)",
                    detail: "The Brain pages in this window ask for \(lockController.unlockMethodName) first. Wisp still uses your brain to answer, and the files stay readable in ~/.wisp/brain — this keeps someone at your unlocked Mac from browsing it."
                ) {
                    Toggle("Lock the Brain", isOn: Binding(
                        get: { brainPreferences.isLockEnabled },
                        set: { shouldEnable in Task { await lockController.setLockEnabled(shouldEnable) } }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!lockController.isLockAvailable || lockController.isAuthenticating)
                    .pointerCursor(isEnabled: lockController.isLockAvailable)
                }
                if brainPreferences.isLockEnabled {
                    Divider()
                    SettingRow(title: "Lock again", detail: "Counted from when you switch away from Wisp.") {
                        Picker("Lock again", selection: $brainPreferences.autoLockMinutes) {
                            ForEach(BrainLockPolicy.autoLockMinuteChoices, id: \.self) { minutes in
                                Text(BrainLockPolicy.autoLockChoiceTitle(minutes: minutes)).tag(minutes)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .pointerCursor()
                    }
                    Divider()
                    HStack {
                        Spacer()
                        Button("Lock Now", systemImage: "lock") { lockController.lockNow() }
                            .buttonStyle(WispPillButtonStyle(isProminent: false))
                            .pointerCursor()
                    }
                }
                if let lastFailureMessage = lockController.lastFailureMessage {
                    Label(lastFailureMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(WispColor.warningText)
                }
            }
        }
    }
}
