//
//  UsageLogStore.swift
//  leanring-buddy
//
//  A private, local record of what each model turn used and roughly what it
//  would cost at API prices, shown in Settings -> Model.
//
//  The file is `~/Library/Application Support/Wisp/usage-log.json` (0600),
//  30-day retention, debounced saves like `AgentTaskRegistry`. It holds
//  numbers only (see `UsageLogRecord`) — never prompt text, answers,
//  screenshots or anything the user typed — and never leaves this Mac.
//

import Combine
import Foundation

@MainActor
final class UsageLogStore: ObservableObject {
    static let shared = UsageLogStore()

    /// Oldest first.
    @Published private(set) var records: [UsageLogRecord] = []

    private var persistenceObserver: AnyCancellable?
    private let fileURL: URL

    /// Serial queue so overlapping saves land in the order they were made.
    private static let writeQueue = DispatchQueue(label: "wisp.usageLog.write", qos: .utility)

    nonisolated static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wisp/usage-log.json")
    }

    init(fileURL: URL = UsageLogStore.defaultFileURL) {
        self.fileURL = fileURL
        if let savedData = try? Data(contentsOf: fileURL), let savedRecords = UsageLogCodec.decode(savedData) {
            records = UsageLogCodec.pruned(savedRecords, now: Date())
        }
        persistenceObserver = $records
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [fileURL] changedRecords in
                Self.write(changedRecords, to: fileURL)
            }
    }

    var summary: UsageSummary {
        UsageAggregator.summary(of: records, now: Date())
    }

    /// Records one finished model turn. `counts` is empty when the provider
    /// reported nothing; the turn is still logged so turn counts stay honest.
    func recordTurn(
        providerKind: BuddyChatProviderKind,
        modelName: String,
        counts: UsageTokenCounts,
        durationSeconds: TimeInterval,
        screenshotWasAttached: Bool,
        isBackgroundRun: Bool
    ) {
        let now = Date()
        let newRecord = UsageLogRecord(
            id: UUID(),
            timestamp: now,
            providerKind: providerKind,
            modelName: modelName,
            inputTokens: counts.inputTokens,
            outputTokens: counts.outputTokens,
            cachedInputTokens: counts.cacheReadTokens,
            estimatedCostUSD: UsageCostEstimator.estimatedCostUSD(
                providerKind: providerKind, modelName: modelName, counts: counts),
            durationSeconds: durationSeconds,
            screenshotWasAttached: screenshotWasAttached,
            isBackgroundRun: isBackgroundRun
        )
        records = UsageLogCodec.pruned(records + [newRecord], now: now)
    }

    /// Records a turn from the provider that ran it. An identifier this file
    /// does not recognise (a test double) is skipped rather than guessed at.
    func recordTurn(
        providerIdentifier: String,
        counts: UsageTokenCounts,
        durationSeconds: TimeInterval,
        screenshotWasAttached: Bool,
        isBackgroundRun: Bool
    ) {
        guard let parsedProvider = UsageProviderIdentifier.parse(providerIdentifier) else { return }
        recordTurn(
            providerKind: parsedProvider.providerKind,
            modelName: parsedProvider.modelName,
            counts: counts,
            durationSeconds: durationSeconds,
            screenshotWasAttached: screenshotWasAttached,
            isBackgroundRun: isBackgroundRun
        )
    }

    func clear() {
        records = []
        // Write at once: "Clear" should not leave the old file around for a second.
        Self.write([], to: fileURL)
    }

    /// Flushes pending changes; called on quit.
    func saveImmediately() {
        Self.write(records, to: fileURL)
    }

    private static func write(_ recordsToWrite: [UsageLogRecord], to fileURL: URL) {
        guard let encodedLog = UsageLogCodec.encode(recordsToWrite) else { return }
        writeQueue.sync {
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try encodedLog.write(to: fileURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            } catch {
                print("⚠️ UsageLogStore: failed to write usage log: \(error)")
            }
        }
    }
}
