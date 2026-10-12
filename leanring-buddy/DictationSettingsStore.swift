//
//  DictationSettingsStore.swift
//  leanring-buddy
//
//  User-facing dictation settings: the recognition language and a personal
//  dictionary of words the recogniser should spell right (names, jargon,
//  product names). The language picks Parakeet's language hint (or, for a
//  language Parakeet doesn't cover, the Apple Speech fallback's locale). The
//  dictionary drives Parakeet's vocabulary boosting on the final transcript,
//  and on the Apple fallback is passed as contextual strings that bias
//  recognition toward those exact spellings.
//

import Combine
import Foundation
import Speech

@MainActor
final class DictationSettingsStore: ObservableObject {
    static let shared = DictationSettingsStore()

    /// The chosen recognition locale identifier, or nil for Automatic (follow
    /// the system language).
    @Published var selectedLanguageLocaleIdentifier: String? {
        didSet { persist() }
    }

    /// Words the recogniser should spell correctly. Fed to the session as
    /// contextual strings.
    @Published var customDictionaryWords: [String] {
        didSet { persist() }
    }

    private static let languageKey = "wisp.dictation.languageLocaleIdentifier"
    private static let dictionaryKey = "wisp.dictation.customDictionaryWords"

    private init() {
        let userDefaults = UserDefaults.standard
        selectedLanguageLocaleIdentifier = userDefaults.string(forKey: Self.languageKey)
        customDictionaryWords = (userDefaults.array(forKey: Self.dictionaryKey) as? [String]) ?? []
    }

    func resetToDefaults() {
        selectedLanguageLocaleIdentifier = nil
        customDictionaryWords = []
    }

    func addDictionaryWord(_ word: String) {
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedWord.isEmpty else { return }
        // Case-insensitive de-dupe so the same term is not added twice.
        let alreadyPresent = customDictionaryWords.contains {
            $0.caseInsensitiveCompare(trimmedWord) == .orderedSame
        }
        guard !alreadyPresent else { return }
        customDictionaryWords.append(trimmedWord)
    }

    func removeDictionaryWord(_ word: String) {
        customDictionaryWords.removeAll { $0 == word }
    }

    /// A readable name for the current language selection, for the settings row.
    var selectedLanguageDisplayName: String {
        guard let identifier = selectedLanguageLocaleIdentifier else { return "Automatic" }
        return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    struct SelectableLanguage: Identifiable {
        let localeIdentifier: String
        let displayName: String
        var id: String { localeIdentifier }
    }

    /// The languages Apple Speech can recognise on this Mac, sorted by name.
    static func availableLanguages() -> [SelectableLanguage] {
        let referenceLocale = Locale.current
        return SFSpeechRecognizer.supportedLocales()
            .map { locale in
                SelectableLanguage(
                    localeIdentifier: locale.identifier,
                    displayName: referenceLocale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
                )
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func persist() {
        let userDefaults = UserDefaults.standard
        if let identifier = selectedLanguageLocaleIdentifier {
            userDefaults.set(identifier, forKey: Self.languageKey)
        } else {
            userDefaults.removeObject(forKey: Self.languageKey)
        }
        userDefaults.set(customDictionaryWords, forKey: Self.dictionaryKey)
    }
}
