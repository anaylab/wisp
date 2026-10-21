//
//  AutomationStore.swift
//  leanring-buddy
//
//  The saved automations and their run history. Two small JSON files in
//  `~/Library/Application Support/Wisp/`, owner-only (0600):
//    - `automations.json`     the automations
//    - `automation-runs.json` run records (numbers, status, capped result text; 30 days)
//
//  An unreadable file is left alone and the store runs empty (same rule as `RoutineStore`); the
//  first save after that keeps a copy of the unreadable file beside it so nothing is lost.
//

import Combine
import Foundation

private nonisolated enum AutomationPrivateJSONFile {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    enum LoadResult<Value> {
        case missing
        case unreadable
        case loaded(Value)
    }

    static func load<Value: Decodable>(_ valueType: Value.Type, from fileURL: URL) -> LoadResult<Value> {
        guard let fileData = try? Data(contentsOf: fileURL) else { return .missing }
        do {
            return .loaded(try makeDecoder().decode(valueType, from: fileData))
        } catch {
            print("⚠️ Automations: could not read \(fileURL.lastPathComponent): \(error)")
            return .unreadable
        }
    }

    static func save<Value: Encodable>(_ value: Value, to fileURL: URL, backingUpUnreadableFile: Bool) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if backingUpUnreadableFile, FileManager.default.fileExists(atPath: fileURL.path) {
                let backupURL = fileURL.deletingLastPathComponent()
                    .appendingPathComponent(fileURL.lastPathComponent + ".unreadable-\(Int(Date().timeIntervalSince1970))")
                try? FileManager.default.copyItem(at: fileURL, to: backupURL)
            }
            try makeEncoder().encode(value).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            print("⚠️ Automations: failed to save \(fileURL.lastPathComponent): \(error)")
        }
    }
}

@MainActor
final class AutomationStore: ObservableObject {
    static let shared = AutomationStore()

    static let defaultFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Wisp/automations.json")

    /// Creation order.
    @Published private(set) var automations: [Automation] = []

    /// Who owns an automation saved without a buddy (the day's Planner or Briefer). Set by the
    /// live wiring so the store itself knows nothing about `BuddyStore`.
    var defaultBuddyIDProvider: (@MainActor () -> UUID?)?

    private let fileURL: URL
    private let currentDate: () -> Date
    private let calendar: Calendar
    private var loadedFileWasUnreadable = false

    /// `fileURL` nil = the real file. (A default argument cannot name a main-actor static.)
    init(
        fileURL: URL? = nil,
        currentDate: @escaping () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        self.currentDate = currentDate
        self.calendar = calendar
        load()
    }

    // MARK: - Queries

    func automation(withID automationID: UUID) -> Automation? {
        automations.first { $0.id == automationID }
    }

    func automations(ownedByBuddyID buddyID: UUID) -> [Automation] {
        automations.filter { $0.buddyID == buddyID }
    }

    // MARK: - Editing

    @discardableResult
    func add(_ newAutomation: Automation) -> Automation {
        var automationToAdd = newAutomation
        if automationToAdd.buddyID == nil {
            automationToAdd.buddyID = defaultBuddyIDProvider?()
        }
        if let shortcutDigit = automationToAdd.shortcutDigit, isShortcutDigitTaken(shortcutDigit, byAnotherThan: automationToAdd.id) {
            // Digits are informational for migrated routines; two automations never both claim one.
            automationToAdd.shortcutDigit = nil
        }
        automationToAdd.nextRunAt = computedNextRunDate(for: automationToAdd)
        automations.append(automationToAdd)
        save()
        return automationToAdd
    }

    func update(_ updatedAutomation: Automation) {
        guard let index = automations.firstIndex(where: { $0.id == updatedAutomation.id }) else { return }
        let previousAutomation = automations[index]
        var automationToStore = updatedAutomation
        if automationToStore.buddyID == nil {
            automationToStore.buddyID = previousAutomation.buddyID ?? defaultBuddyIDProvider?()
        }
        // A changed schedule starts counting from now, so slots from before the edit are not "missed".
        if automationToStore.trigger != previousAutomation.trigger {
            automationToStore.scheduleBaselineAt = currentDate()
        }
        automationToStore.nextRunAt = computedNextRunDate(for: automationToStore)
        automations[index] = automationToStore
        save()
    }

    func delete(automationID: UUID) {
        automations.removeAll { $0.id == automationID }
        save()
    }

    func setEnabled(_ isEnabled: Bool, forAutomationID automationID: UUID) {
        guard let index = automations.firstIndex(where: { $0.id == automationID }),
              automations[index].isEnabled != isEnabled else { return }
        automations[index].isEnabled = isEnabled
        if isEnabled {
            // Resuming after a pause must not fire a slot that came due while it was paused.
            automations[index].scheduleBaselineAt = currentDate()
            automations[index].pausedReason = nil
        }
        automations[index].nextRunAt = isEnabled ? computedNextRunDate(for: automations[index]) : nil
        save()
    }

    /// Records why Wisp paused this automation itself; cleared when it is switched back on.
    func setPausedReason(_ pausedReason: String?, forAutomationID automationID: UUID) {
        guard let index = automations.firstIndex(where: { $0.id == automationID }) else { return }
        automations[index].pausedReason = pausedReason
        save()
    }

    func markRan(automationID: UUID, at date: Date, nextRunAt: Date?) {
        guard let index = automations.firstIndex(where: { $0.id == automationID }) else { return }
        automations[index].lastRunAt = date
        automations[index].nextRunAt = nextRunAt
        save()
    }

    /// Remembers what was typed for the blanks of a manual run, to prefill the next one.
    func rememberParameterValues(_ values: [String: String], forAutomationID automationID: UUID) {
        guard let index = automations.firstIndex(where: { $0.id == automationID }) else { return }
        automations[index].parameterValues = values.isEmpty ? nil : values
        save()
    }

    private func isShortcutDigitTaken(_ shortcutDigit: Int, byAnotherThan automationID: UUID) -> Bool {
        automations.contains { $0.id != automationID && $0.shortcutDigit == shortcutDigit }
    }

    private func computedNextRunDate(for automation: Automation) -> Date? {
        guard automation.isEnabled, case .schedule(let schedule) = automation.trigger else { return nil }
        return schedule.nextRunDate(after: currentDate(), calendar: calendar)
    }

    // MARK: - Persistence

    private func load() {
        switch AutomationPrivateJSONFile.load([Automation].self, from: fileURL) {
        case .missing:
            automations = []
        case .unreadable:
            // Leave the file alone (it's the user's) and run without automations.
            loadedFileWasUnreadable = true
            automations = []
        case .loaded(let loadedAutomations):
            automations = loadedAutomations
        }
    }

    private func save() {
        AutomationPrivateJSONFile.save(automations, to: fileURL, backingUpUnreadableFile: loadedFileWasUnreadable)
        loadedFileWasUnreadable = false
    }
}

/// The run history behind each automation's page, Today's "Needs you" and the notch faces.
@MainActor
final class AutomationRunHistoryStore: ObservableObject {
    static let shared = AutomationRunHistoryStore()
    static let maximumRecordsPerAutomation = 30
    static let retentionDays = 30

    static let defaultFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Wisp/automation-runs.json")

    /// Newest first.
    @Published private(set) var records: [AutomationRunRecord] = []

    private let fileURL: URL
    private let currentDate: () -> Date
    private var loadedFileWasUnreadable = false

    init(fileURL: URL? = nil, currentDate: @escaping () -> Date = { Date() }) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        self.currentDate = currentDate
        load()
    }

    func records(forAutomationID automationID: UUID) -> [AutomationRunRecord] {
        records.filter { $0.automationID == automationID }
    }

    func latestRecord(forAutomationID automationID: UUID) -> AutomationRunRecord? {
        records.first { $0.automationID == automationID }
    }

    /// The buddy a finished background task belonged to, for the notch's NEW list faces.
    func buddyID(forTaskID taskID: UUID) -> UUID? {
        records.first { $0.backgroundTaskID == taskID }?.buddyID
    }

    func clear(forAutomationID automationID: UUID) {
        records.removeAll { $0.automationID == automationID }
        save()
    }

    func append(_ record: AutomationRunRecord) {
        // Test runs write nothing, anywhere.
        guard !record.isTestRun else { return }
        records.insert(record, at: 0)
        trimToLimits()
        save()
    }

    func update(_ updatedRecord: AutomationRunRecord) {
        guard !updatedRecord.isTestRun, let index = records.firstIndex(where: { $0.id == updatedRecord.id }) else { return }
        records[index] = updatedRecord
        save()
    }

    func remove(recordID: UUID) {
        records.removeAll { $0.id == recordID }
        save()
    }

    // MARK: - Persistence

    private func trimToLimits() {
        let oldestAllowedDate = currentDate().addingTimeInterval(-TimeInterval(Self.retentionDays) * 24 * 60 * 60)
        var keptCountByAutomationID: [UUID: Int] = [:]
        records = records.filter { record in
            guard record.startedAt >= oldestAllowedDate else { return false }
            let keptCount = keptCountByAutomationID[record.automationID, default: 0]
            guard keptCount < Self.maximumRecordsPerAutomation else { return false }
            keptCountByAutomationID[record.automationID] = keptCount + 1
            return true
        }
    }

    private func load() {
        switch AutomationPrivateJSONFile.load([AutomationRunRecord].self, from: fileURL) {
        case .missing:
            records = []
        case .unreadable:
            loadedFileWasUnreadable = true
            records = []
        case .loaded(let loadedRecords):
            // A run that was still going when the app quit never finished; say so.
            records = loadedRecords
                .sorted { $0.startedAt > $1.startedAt }
                .map { record in
                    guard record.outcome == nil else { return record }
                    var interruptedRecord = record
                    interruptedRecord.finishedAt = record.startedAt
                    interruptedRecord.outcome = .failed(reason: "Wisp quit before this finished.")
                    // Quitting is not the automation's fault, so it never counts toward the pause.
                    interruptedRecord.failureDoesNotCountTowardPause = true
                    return interruptedRecord
                }
            trimToLimits()
        }
    }

    private func save() {
        AutomationPrivateJSONFile.save(records.filter { !$0.isTestRun }, to: fileURL, backingUpUnreadableFile: loadedFileWasUnreadable)
        loadedFileWasUnreadable = false
    }
}
