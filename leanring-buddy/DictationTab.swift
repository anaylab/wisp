//
//  DictationTab.swift
//  leanring-buddy
//
//  The dashboard's Dictation tab: choose the recognition language and maintain a
//  personal dictionary of words the recogniser should spell right. Both read and
//  write `DictationSettingsStore` and take effect on the next dictation session.
//

import SwiftUI

struct DictationTab: View {
    @ObservedObject private var dictationSettings = DictationSettingsStore.shared
    @State private var newWordDraft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                languageCard
                dictionaryCard
            }
            .padding(16)
        }
        .background(DS.Colors.background)
    }

    // MARK: - Language

    private var languageCard: some View {
        DashboardCard(title: "Language") {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Recognition language")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.Colors.textPrimary)
                    Text("Automatic follows your Mac's language. Pick a specific language if you dictate in one Wisp keeps mishearing.")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                languagePicker
            }
        }
    }

    private var languagePicker: some View {
        Menu {
            Button {
                dictationSettings.selectedLanguageLocaleIdentifier = nil
            } label: {
                if dictationSettings.selectedLanguageLocaleIdentifier == nil {
                    Label("Automatic", systemImage: "checkmark")
                } else {
                    Text("Automatic")
                }
            }
            Divider()
            ForEach(DictationSettingsStore.availableLanguages()) { language in
                Button {
                    dictationSettings.selectedLanguageLocaleIdentifier = language.localeIdentifier
                } label: {
                    if dictationSettings.selectedLanguageLocaleIdentifier == language.localeIdentifier {
                        Label(language.displayName, systemImage: "checkmark")
                    } else {
                        Text(language.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(dictationSettings.selectedLanguageDisplayName)
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

    // MARK: - Dictionary

    private var dictionaryCard: some View {
        DashboardCard(title: "Dictionary") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Custom words Wisp should spell right — names, jargon, product names. Added as context for the recogniser.")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                addWordRow

                if dictationSettings.customDictionaryWords.isEmpty {
                    Text("No custom words yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textTertiary)
                } else {
                    FlowingWordChips(
                        words: dictationSettings.customDictionaryWords,
                        onRemove: { word in dictationSettings.removeDictionaryWord(word) }
                    )
                }
            }
        }
    }

    private var addWordRow: some View {
        HStack(spacing: 8) {
            TextField("Add a word…", text: $newWordDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(DS.Colors.textPrimary)
                .onSubmit(commitNewWord)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.surface2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                )
                .overlay(IBeamCursorView())

            Button(action: commitNewWord) {
                Text("Add")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.Colors.textOnAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(newWordDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  ? DS.Colors.disabledBackground
                                  : DS.Colors.accent)
                    )
            }
            .buttonStyle(.plain)
            .disabled(newWordDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .pointerCursor()
        }
    }

    private func commitNewWord() {
        dictationSettings.addDictionaryWord(newWordDraft)
        newWordDraft = ""
    }
}

/// A simple left-aligned wrapping row of removable word chips.
/// Also used by the Routines tab for its suggested-app chips.
struct FlowingWordChips: View {
    let words: [String]
    let onRemove: (String) -> Void

    var body: some View {
        // A grid adapts to the available width and wraps automatically, which is
        // enough for a dictionary list without a full flow-layout implementation.
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 90), spacing: 6, alignment: .leading)],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(words, id: \.self) { word in
                HStack(spacing: 5) {
                    Text(word)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Button {
                        onRemove(word)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .nativeTooltip("Remove")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
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
