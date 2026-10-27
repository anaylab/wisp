//
//  LearnedShortcutStore.swift
//  leanring-buddy
//
//  The saved learned shortcuts: one small JSON file in `~/Library/Application Support/Wisp/`,
//  owner-only (0600). It holds the user's phrases and tool arguments, so it stays on this Mac:
//  never logged, never in the usage log, never part of a `.wisp` share bundle, never sent to a
//  model.
//
//  An unreadable file is left alone and the store runs empty (same rule as `AutomationStore` and
//  `RoutineStore`); the first save after that keeps a copy of the unreadable file beside it so
//  nothing is lost.
//

import Combine
import Foundation

@MainActor
final class LearnedShortcutStore: ObservableObject {
    static let shared = LearnedShortcutStore()

    static let defaultFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Wisp/learned-shortcuts.json")

    static let maximumShortcutCount = 200

    enum AddResult: Equatable {
        case added(LearnedShortcut)
        /// Another shortcut already has this exact phrase.
        case duplicatePhrase
        /// The phrase isn't a template that can be matched safely (see `LearnedShortcutPhraseTemplate.parse`),
        /// or its blanks don't agree with the slots, or it has no steps.
        case invalidShortcut
        case tooManyShortcuts
    }

    /// Creation order.
    @Published private(set) var shortcuts: [LearnedShortcut] = []

    private struct StoredFile: Codable {
        var version: Int
        var shortcuts: [LearnedShortcut]
    }

    private static let currentFileVersion = 1

    private let fileURL: URL
    private var loadedFileWasUnreadable = false

    /// `fileURL` nil = the real file. (A default argument cannot name a main-actor static.)
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        load()
    }

    // MARK: - Queries

    func shortcut(withID shortcutID: UUID) -> LearnedShortcut? {
        shortcuts.first { $0.id == shortcutID }
    }

    /// Only enabled shortcuts are considered; see `LearnedShortcutMatcher`.
    func match(
        transcript: String,
        applicationNameResolver: (String) -> String? = { $0 }
    ) -> LearnedShortcutMatchResult {
        LearnedShortcutMatcher.match(
            transcript: transcript,
            among: shortcuts,
            applicationNameResolver: applicationNameResolver
        )
    }

    // MARK: - Editing

    @discardableResult
    func add(_ newShortcut: LearnedShortcut) -> AddResult {
        guard shortcuts.count < Self.maximumShortcutCount else { return .tooManyShortcuts }
        guard let newTemplate = newShortcut.parsedPhraseTemplate,
              Set(newTemplate.slotNames) == Set(newShortcut.slots.map(\.name)),
              newShortcut.slots.count == newTemplate.slotNames.count,
              !newShortcut.steps.isEmpty else { return .invalidShortcut }
        let isDuplicatePhrase = shortcuts.contains { $0.parsedPhraseTemplate?.canonicalText == newTemplate.canonicalText }
        guard !isDuplicatePhrase else { return .duplicatePhrase }

        var shortcutToStore = newShortcut
        shortcutToStore.phraseTemplate = newTemplate.canonicalText
        shortcuts.append(shortcutToStore)
        save()
        return .added(shortcutToStore)
    }

    func delete(shortcutID: UUID) {
        shortcuts.removeAll { $0.id == shortcutID }
        save()
    }

    /// Turning one back on clears the failure streak and the reason it was turned off, so it
    /// gets two fresh tries rather than being switched off again by its old failures.
    func setEnabled(_ isEnabled: Bool, shortcutID: UUID) {
        guard let index = shortcuts.firstIndex(where: { $0.id == shortcutID }) else { return }
        shortcuts[index].isEnabled = isEnabled
        if isEnabled {
            shortcuts[index].disabledReason = nil
            shortcuts[index].consecutiveFailures = 0
        }
        save()
    }

    /// Call once per replay that ended. A declined confirmation is neither: don't call this.
    func recordRun(shortcutID: UUID, succeeded: Bool, at runDate: Date = Date()) {
        guard let index = shortcuts.firstIndex(where: { $0.id == shortcutID }) else { return }
        shortcuts[index] = LearnedShortcutDriftPolicy.applying(
            runSucceeded: succeeded,
            at: runDate,
            to: shortcuts[index]
        )
        save()
    }

    // MARK: - Persistence

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func load() {
        guard let fileData = try? Data(contentsOf: fileURL) else { return }
        do {
            shortcuts = try Self.makeDecoder().decode(StoredFile.self, from: fileData).shortcuts
        } catch {
            print("⚠️ Learned shortcuts: could not read \(fileURL.lastPathComponent): \(error)")
            loadedFileWasUnreadable = true
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if loadedFileWasUnreadable, FileManager.default.fileExists(atPath: fileURL.path) {
                let backupURL = fileURL.deletingLastPathComponent()
                    .appendingPathComponent(fileURL.lastPathComponent + ".unreadable-\(Int(Date().timeIntervalSince1970))")
                try? FileManager.default.copyItem(at: fileURL, to: backupURL)
                loadedFileWasUnreadable = false
            }
            let storedFile = StoredFile(version: Self.currentFileVersion, shortcuts: shortcuts)
            try Self.makeEncoder().encode(storedFile).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            print("⚠️ Learned shortcuts: failed to save \(fileURL.lastPathComponent): \(error)")
        }
    }
}
