//
//  AppBundleConfiguration.swift
//  leanring-buddy
//
//  Reads settings that ship inside the built app's Info.plist (which voice
//  engine to use, whether agent mode is on, the Ollama model name, and so on).
//

import Foundation

enum AppBundleConfiguration {

    /// The trimmed string stored under `key` in Info.plist, or nil when it is
    /// missing, not a string, or blank. The loaded bundle dictionary is tried
    /// first and the Info.plist file on disk second.
    static func stringValue(forKey key: String) -> String? {
        if let loadedValue = Bundle.main.object(forInfoDictionaryKey: key) as? String,
           let usable = nonBlank(loadedValue) {
            return usable
        }

        guard let plistPath = Bundle.main.path(forResource: "Info", ofType: "plist"),
              let plistContents = NSDictionary(contentsOfFile: plistPath),
              let fileValue = plistContents[key] as? String else {
            return nil
        }
        return nonBlank(fileValue)
    }

    private static func nonBlank(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
