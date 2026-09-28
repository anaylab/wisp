//
//  ShortcutsTab.swift
//  leanring-buddy
//
//  The dashboard's Shortcuts tab: view and rebind Wisp's global shortcuts, and
//  reset them to defaults. Everything here reads and writes the one
//  `ShortcutBindingStore`, which pushes changes straight to the CGEvent tap, so
//  edits take effect immediately with no relaunch.
//

import SwiftUI

struct ShortcutsTab: View {
    @ObservedObject private var bindingStore = ShortcutBindingStore.shared
    @ObservedObject private var voiceOutputPreference = VoiceOutputPreference.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                pushToTalkCard
                handsFreeCard
                voiceModeCard
                resetRow
            }
            .padding(16)
        }
        .background(WispColor.windowBackground)
    }

    // MARK: - Voice / silent mode

    private var voiceModeCard: some View {
        DashboardCard(title: "Voice output") {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Speak replies")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.Colors.textPrimary)
                    Text("On, Wisp speaks replies aloud (and decides per reply what's worth saying). Off is silent mode: replies appear only in the notch. You still push-to-talk either way.")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: $voiceOutputPreference.isReplySpeechEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .pointerCursor()
            }
        }
    }

    // MARK: - Push to talk (hold)

    private var pushToTalkCard: some View {
        DashboardCard(title: "Push to talk") {
            VStack(alignment: .leading, spacing: 12) {
                bindingRow(
                    name: "Talk",
                    description: "Hold to ask a question out loud; release to send.",
                    keys: bindingStore.primaryHoldChord.keyCapsuleLabels,
                    trailing: AnyView(primaryChordPicker)
                )

                Divider().overlay(DS.Colors.borderSubtle)

                bindingRow(
                    name: "Dictate",
                    description: "Hold to type what you say into the focused field.",
                    keys: bindingStore.primaryHoldChord.keyCapsuleLabels + ["shift"],
                    trailing: AnyView(
                        Text("Talk chord + Shift")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.Colors.textTertiary)
                    )
                )
            }
        }
    }

    private var primaryChordPicker: some View {
        Menu {
            ForEach(BuddyPushToTalkShortcut.ShortcutOption.allCases) { chordOption in
                Button {
                    bindingStore.primaryHoldChord = chordOption
                } label: {
                    if chordOption == bindingStore.primaryHoldChord {
                        Label(chordOption.displayText, systemImage: "checkmark")
                    } else {
                        Text(chordOption.displayText)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("Change")
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(DS.Colors.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointerCursor()
    }

    // MARK: - Hands-free dictation (double-tap)

    private var handsFreeCard: some View {
        DashboardCard(title: "Hands-free dictation") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Hands-free")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DS.Colors.textPrimary)
                        Text("Double-tap to start dictating without holding a key; double-tap again to stop and insert.")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Toggle("", isOn: $bindingStore.handsFreeDictationEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .pointerCursor()
                }

                if bindingStore.handsFreeDictationEnabled {
                    Divider().overlay(DS.Colors.borderSubtle)
                    HStack(spacing: 8) {
                        keyCapsules([bindingStore.handsFreeDictationModifier.capsuleLabel, "×2"])
                        Spacer()
                        handsFreeModifierPicker
                    }
                }
            }
        }
    }

    private var handsFreeModifierPicker: some View {
        Menu {
            ForEach(BareModifier.allCases) { modifier in
                Button {
                    bindingStore.handsFreeDictationModifier = modifier
                } label: {
                    if modifier == bindingStore.handsFreeDictationModifier {
                        Label(modifier.displayName, systemImage: "checkmark")
                    } else {
                        Text(modifier.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("Change")
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(DS.Colors.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointerCursor()
    }

    // MARK: - Reset

    private var resetRow: some View {
        HStack {
            Spacer()
            Button {
                bindingStore.resetToDefaults()
            } label: {
                Text("Reset to defaults")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(DS.Colors.surface2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    // MARK: - Building blocks

    private func bindingRow(name: String, description: String, keys: [String], trailing: AnyView) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Colors.textPrimary)
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                keyCapsules(keys)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
            trailing
        }
    }

    private func keyCapsules(_ labels: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(labels, id: \.self) { label in
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                            .fill(DS.Colors.surface2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                    )
            }
        }
    }
}
