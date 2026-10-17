//
//  UsageLogRecord.swift
//  leanring-buddy
//
//  Pure side of the usage log: the one-record-per-turn shape, its on-disk
//  codec, 30-day retention, and the today / 7-day / 30-day aggregation shown in
//  Settings -> Model.
//
//  Privacy by construction: a record holds only numbers, a model name and two
//  flags. There is deliberately no field that could carry the prompt, the
//  answer, a screenshot or anything the user typed, so logging content later
//  would need a new field here (the test suite asserts the persisted keys).
//

import Foundation

struct UsageLogRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let providerKind: BuddyChatProviderKind
    /// The model's API name (e.g. "claude-opus-5-5"), never a conversation.
    let modelName: String
    let inputTokens: Int?
    let outputTokens: Int?
    let cachedInputTokens: Int?
    let estimatedCostUSD: Double?
    let durationSeconds: Double
    let screenshotWasAttached: Bool
    /// True for buddy / background runs, false for a live conversation turn.
    let isBackgroundRun: Bool

    var totalTokens: Int { (inputTokens ?? 0) + (outputTokens ?? 0) }
}

enum UsageLogCodec {
    static let retentionPeriodSeconds: TimeInterval = 30 * 24 * 60 * 60
    private static let currentFileFormatVersion = 1

    private struct UsageLogFile: Codable {
        let formatVersion: Int
        let records: [UsageLogRecord]
    }

    static func encode(_ records: [UsageLogRecord]) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(UsageLogFile(formatVersion: currentFileFormatVersion, records: records))
    }

    /// Nil when the data is not a usage log of the current format.
    static func decode(_ data: Data) -> [UsageLogRecord]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(UsageLogFile.self, from: data),
              file.formatVersion == currentFileFormatVersion else { return nil }
        return file.records
    }

    /// Drops records older than the retention period (also bounds file size).
    static func pruned(_ records: [UsageLogRecord], now: Date) -> [UsageLogRecord] {
        let oldestRetainedDate = now.addingTimeInterval(-retentionPeriodSeconds)
        return records.filter { $0.timestamp >= oldestRetainedDate }
    }
}

/// Splits a `ModelProvider.identifier` ("anthropic/claude-opus-5-5") into the
/// provider kind and model name, so the log can be written from whichever
/// provider actually ran (a buddy's own model included) without a second
/// source of truth.
enum UsageProviderIdentifier {
    static func parse(_ identifier: String) -> (providerKind: BuddyChatProviderKind, modelName: String)? {
        let kindByPrefix: [(prefix: String, kind: BuddyChatProviderKind)] = [
            ("ollama/", .localOllama),
            ("anthropic/", .anthropic),
            ("claude-subscription/", .claudeSubscription),
            ("openai/", .openAI),
            ("gemini/", .gemini),
        ]
        for (prefix, kind) in kindByPrefix where identifier.hasPrefix(prefix) {
            return (kind, String(identifier.dropFirst(prefix.count)))
        }
        return nil
    }
}

struct UsageTotals: Equatable, Sendable {
    var turnCount = 0
    var inputTokens = 0
    var outputTokens = 0
    var estimatedCostUSD = 0.0

    var totalTokens: Int { inputTokens + outputTokens }

    mutating func add(_ record: UsageLogRecord) {
        turnCount += 1
        inputTokens += record.inputTokens ?? 0
        outputTokens += record.outputTokens ?? 0
        estimatedCostUSD += record.estimatedCostUSD ?? 0
    }
}

struct UsageProviderBreakdown: Equatable, Identifiable, Sendable {
    let providerKind: BuddyChatProviderKind
    let totals: UsageTotals
    var id: String { providerKind.rawValue }
}

struct UsageSummary: Equatable, Sendable {
    let today: UsageTotals
    let lastSevenDays: UsageTotals
    let lastThirtyDays: UsageTotals
    /// Over the 30-day window, busiest provider first.
    let providerBreakdown: [UsageProviderBreakdown]
}

enum UsageAggregator {
    /// "Today" is the calendar day containing `now`; the other windows are
    /// rolling 7 and 30 days back from `now`.
    static func summary(of records: [UsageLogRecord], now: Date, calendar: Calendar = .current) -> UsageSummary {
        let startOfToday = calendar.startOfDay(for: now)
        let sevenDaysAgo = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let thirtyDaysAgo = now.addingTimeInterval(-UsageLogCodec.retentionPeriodSeconds)

        var today = UsageTotals()
        var lastSevenDays = UsageTotals()
        var lastThirtyDays = UsageTotals()
        var totalsByProvider: [BuddyChatProviderKind: UsageTotals] = [:]

        for record in records where record.timestamp >= thirtyDaysAgo && record.timestamp <= now {
            lastThirtyDays.add(record)
            totalsByProvider[record.providerKind, default: UsageTotals()].add(record)
            if record.timestamp >= sevenDaysAgo { lastSevenDays.add(record) }
            if record.timestamp >= startOfToday { today.add(record) }
        }

        let breakdown = totalsByProvider
            .map { UsageProviderBreakdown(providerKind: $0.key, totals: $0.value) }
            .sorted { first, second in
                first.totals.turnCount != second.totals.turnCount
                    ? first.totals.turnCount > second.totals.turnCount
                    : first.providerKind.rawValue < second.providerKind.rawValue
            }
        return UsageSummary(today: today, lastSevenDays: lastSevenDays,
                            lastThirtyDays: lastThirtyDays, providerBreakdown: breakdown)
    }

    /// 12,345 -> "12.3k"; keeps the card compact.
    static func formattedTokenCount(_ tokenCount: Int) -> String {
        if tokenCount >= 1_000_000 { return String(format: "%.1fM", Double(tokenCount) / 1_000_000) }
        if tokenCount >= 1_000 { return String(format: "%.1fk", Double(tokenCount) / 1_000) }
        return "\(tokenCount)"
    }
}
