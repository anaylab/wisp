//
//  Usage-log suite: price table + cost estimator, aggregation windows,
//  retention pruning, codec round trip, the persisted shape (no content
//  fields), provider-identifier parsing and the store's file handling.
//

import Foundation

@MainActor func runAllTests() {
var failureCount = 0
var checkCount = 0

func check(_ condition: Bool, _ description: String) {
    checkCount += 1
    if !condition {
        failureCount += 1
        print("FAIL: \(description)")
    }
}

func isClose(_ first: Double?, _ second: Double, tolerance: Double = 1e-9) -> Bool {
    guard let first else { return false }
    return abs(first - second) < tolerance
}

// MARK: - Cost estimator

// Opus 5.5: 1M fresh input = $4, 1M output = $20.
let opusCost = UsageCostEstimator.estimatedCostUSD(
    providerKind: .anthropic, modelName: "claude-opus-5-5",
    counts: UsageTokenCounts(inputTokens: 1_000_000, outputTokens: 1_000_000))
check(isClose(opusCost, 24.0), "opus: 1M in + 1M out = $24")

// Cache: 1M input of which 600k read and 100k written; output 0.
// fresh 300k*4 + read 600k*0.20 + write 100k*5 = 1.2 + 0.12 + 0.5 = 1.82
let cachedCost = UsageCostEstimator.estimatedCostUSD(
    providerKind: .anthropic, modelName: "claude-opus-5-5",
    counts: UsageTokenCounts(inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 600_000, cacheWriteTokens: 100_000))
check(isClose(cachedCost, 1.82), "opus: cache read/write priced separately from fresh input")

check(isClose(UsageCostEstimator.estimatedCostUSD(
    providerKind: .anthropic, modelName: "claude-sonnet-5-5",
    counts: UsageTokenCounts(inputTokens: 500_000, outputTokens: 100_000)), 2.0), "sonnet: 0.5M in + 0.1M out = $2")
check(isClose(UsageCostEstimator.estimatedCostUSD(
    providerKind: .anthropic, modelName: "claude-haiku-4-5",
    counts: UsageTokenCounts(inputTokens: 1_000_000, outputTokens: 1_000_000)), 6.0), "haiku: $6")
check(isClose(UsageCostEstimator.estimatedCostUSD(
    providerKind: .openAI, modelName: "gpt-4o-2024-08-06",
    counts: UsageTokenCounts(inputTokens: 1_000_000, outputTokens: 100_000)), 3.5), "gpt-4o dated name matches by prefix")
check(isClose(UsageCostEstimator.estimatedCostUSD(
    providerKind: .gemini, modelName: "gemini-2.5-flash",
    counts: UsageTokenCounts(inputTokens: 1_000_000, outputTokens: 1_000_000)), 2.8), "gemini flash: $2.80")

// Local is free even with no counts; unknown model is unknown, not zero.
check(isClose(UsageCostEstimator.estimatedCostUSD(
    providerKind: .localOllama, modelName: "qwen2.5vl:3b", counts: UsageTokenCounts()), 0), "local Ollama costs $0")
check(UsageCostEstimator.estimatedCostUSD(
    providerKind: .openAI, modelName: "gpt-9", counts: UsageTokenCounts(inputTokens: 10, outputTokens: 10)) == nil, "unpriced model has unknown cost")
check(UsageCostEstimator.estimatedCostUSD(
    providerKind: .anthropic, modelName: "claude-opus-5-5", counts: UsageTokenCounts()) == nil, "no counts means unknown cost")

// Provider-reported cost wins (subscription CLI total_cost_usd).
check(isClose(UsageCostEstimator.estimatedCostUSD(
    providerKind: .claudeSubscription, modelName: "claude-opus-5-5",
    counts: UsageTokenCounts(inputTokens: 1_000_000, outputTokens: 1_000_000, reportedCostUSD: 0.123)), 0.123), "reported cost overrides the table")

// Cache counts larger than input cannot make the cost negative.
let oddCounts = UsageCostEstimator.estimatedCostUSD(
    providerKind: .anthropic, modelName: "claude-opus-5-5",
    counts: UsageTokenCounts(inputTokens: 100, outputTokens: 0, cacheReadTokens: 500, cacheWriteTokens: 500))
check((oddCounts ?? -1) >= 0, "inconsistent cache counts never give a negative cost")

// Labels.
check(UsageCostEstimator.costLabel(providerKind: .claudeSubscription, estimatedCostUSD: 0.5) == "included in subscription (≈ API cost $0.50)", "subscription label")
check(UsageCostEstimator.costLabel(providerKind: .anthropic, estimatedCostUSD: 0.5) == "≈ $0.50", "API label")
check(UsageCostEstimator.costLabel(providerKind: .gemini, estimatedCostUSD: nil) == "cost unknown", "unknown label")
check(UsageCostEstimator.formattedDollars(0.004) == "<$0.01", "tiny amounts are not shown as zero")
check(ModelPricing.pricesSetOn == "2026-10-17", "price table carries its date")

// Accumulating across passes: nil stays nil until reported.
var accumulated = UsageTokenCounts()
check(accumulated.inputTokens == nil, "fresh counts are unreported")
accumulated.add(inputTokens: 100, outputTokens: 10, cacheReadTokens: nil, cacheWriteTokens: nil, reportedCostUSD: nil)
accumulated.add(inputTokens: 50, outputTokens: nil, cacheReadTokens: 20, cacheWriteTokens: nil, reportedCostUSD: 0.01)
check(accumulated.inputTokens == 150 && accumulated.outputTokens == 10 && accumulated.cacheReadTokens == 20 && accumulated.cacheWriteTokens == nil, "counts sum across passes")
check(isClose(accumulated.reportedCostUSD, 0.01), "reported cost sums")

// MARK: - Provider identifier

check(UsageProviderIdentifier.parse("anthropic/claude-opus-5-5")?.providerKind == .anthropic, "parse anthropic")
check(UsageProviderIdentifier.parse("anthropic/claude-opus-5-5")?.modelName == "claude-opus-5-5", "parse model name")
check(UsageProviderIdentifier.parse("claude-subscription/claude-sonnet-5-5")?.providerKind == .claudeSubscription, "parse subscription")
check(UsageProviderIdentifier.parse("ollama/qwen2.5vl:3b")?.modelName == "qwen2.5vl:3b", "parse ollama model with colon")
check(UsageProviderIdentifier.parse("openai/gpt-4o")?.providerKind == .openAI, "parse openai")
check(UsageProviderIdentifier.parse("gemini/gemini-2.5-flash")?.providerKind == .gemini, "parse gemini")
check(UsageProviderIdentifier.parse("scripted-test-double") == nil, "unknown identifier is skipped")

// MARK: - Aggregation

var utcCalendar = Calendar(identifier: .gregorian)
utcCalendar.timeZone = TimeZone(identifier: "UTC")!
let now = utcCalendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 15))!

func makeRecord(
    hoursAgo: Double,
    provider: BuddyChatProviderKind = .anthropic,
    inputTokens: Int? = 100,
    outputTokens: Int? = 50,
    cost: Double? = 0.10
) -> UsageLogRecord {
    UsageLogRecord(
        id: UUID(), timestamp: now.addingTimeInterval(-hoursAgo * 3600), providerKind: provider,
        modelName: "claude-opus-5-5", inputTokens: inputTokens, outputTokens: outputTokens,
        cachedInputTokens: nil, estimatedCostUSD: cost, durationSeconds: 2,
        screenshotWasAttached: true, isBackgroundRun: false)
}

let sampleRecords = [
    makeRecord(hoursAgo: 1),                                   // today
    makeRecord(hoursAgo: 5),                                   // today (10:00)
    makeRecord(hoursAgo: 20),                                  // yesterday, within 7 days
    makeRecord(hoursAgo: 24 * 6),                              // within 7 days
    makeRecord(hoursAgo: 24 * 10, provider: .localOllama, inputTokens: 1000, outputTokens: 0, cost: 0),
    makeRecord(hoursAgo: 24 * 29),                             // within 30 days
    makeRecord(hoursAgo: 24 * 31),                             // outside 30 days
    makeRecord(hoursAgo: 24 * 2, inputTokens: nil, outputTokens: nil, cost: nil), // nothing reported
]
let summary = UsageAggregator.summary(of: sampleRecords, now: now, calendar: utcCalendar)
check(summary.today.turnCount == 2, "today counts 2 turns (got \(summary.today.turnCount))")
check(summary.lastSevenDays.turnCount == 5, "7-day window counts 5 turns (got \(summary.lastSevenDays.turnCount))")
check(summary.lastThirtyDays.turnCount == 7, "30-day window counts 7 turns (got \(summary.lastThirtyDays.turnCount))")
check(summary.today.totalTokens == 300 && summary.today.inputTokens == 200 && summary.today.outputTokens == 100, "today tokens add up")
check(isClose(summary.today.estimatedCostUSD, 0.2), "today cost adds up")
check(summary.lastThirtyDays.totalTokens == 100 * 5 + 50 * 5 + 1000, "unreported counts add zero, not garbage")
check(summary.providerBreakdown.first?.providerKind == .anthropic && summary.providerBreakdown.first?.totals.turnCount == 6, "busiest provider first")
check(summary.providerBreakdown.count == 2, "two providers in the breakdown")
check(UsageAggregator.summary(of: [], now: now, calendar: utcCalendar).lastThirtyDays.turnCount == 0, "empty log summarises to zero")
// A record from the future (clock change) is ignored rather than counted.
check(UsageAggregator.summary(of: [makeRecord(hoursAgo: -3)], now: now, calendar: utcCalendar).today.turnCount == 0, "future records are ignored")
check(UsageAggregator.formattedTokenCount(12_345) == "12.3k" && UsageAggregator.formattedTokenCount(950) == "950" && UsageAggregator.formattedTokenCount(2_500_000) == "2.5M", "token formatting")

// MARK: - Retention

let pruned = UsageLogCodec.pruned(sampleRecords, now: now)
check(pruned.count == 7, "retention drops only the record older than 30 days (kept \(pruned.count))")
check(UsageLogCodec.retentionPeriodSeconds == 30 * 24 * 60 * 60, "retention is 30 days")

// MARK: - Codec

let encodedData = UsageLogCodec.encode(sampleRecords)!
let decodedRecords = UsageLogCodec.decode(encodedData)!
check(decodedRecords == sampleRecords, "codec round trip is lossless")
check(UsageLogCodec.decode(Data("not json".utf8)) == nil, "garbage does not decode")
check(UsageLogCodec.decode(Data(#"{"formatVersion":99,"records":[]}"#.utf8)) == nil, "unknown format version is rejected")

// MARK: - No content fields in the persisted shape

let allowedRecordKeys: Set<String> = [
    "id", "timestamp", "providerKind", "modelName", "inputTokens", "outputTokens",
    "cachedInputTokens", "estimatedCostUSD", "durationSeconds", "screenshotWasAttached", "isBackgroundRun",
]
let fullRecord = makeRecord(hoursAgo: 1)
let fullRecordJSON = try! JSONSerialization.jsonObject(with: UsageLogCodec.encode([fullRecord])!) as! [String: Any]
let encodedRecordObject = (fullRecordJSON["records"] as! [[String: Any]])[0]
check(Set(encodedRecordObject.keys).isSubset(of: allowedRecordKeys), "persisted keys are only the allowed numeric/metadata keys: \(Set(encodedRecordObject.keys).subtracting(allowedRecordKeys))")
let forbiddenKeyFragments = ["prompt", "text", "answer", "transcript", "screenshot_data", "image", "content", "message", "reply"]
check(!encodedRecordObject.keys.contains { key in forbiddenKeyFragments.contains { key.lowercased() == $0 } }, "no content-like key is persisted")
check(Set(fullRecordJSON.keys) == ["formatVersion", "records"], "file has only version + records")
// Every persisted value is a number, bool, date string, UUID string or the model/provider name.
check(encodedRecordObject.values.allSatisfy { $0 is NSNumber || $0 is String }, "persisted values are scalars")

// MARK: - Store

func runStoreTests() {
    let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("usage-log-test-\(UUID().uuidString)")
    let temporaryFileURL = temporaryDirectory.appendingPathComponent("usage-log.json")
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let store = UsageLogStore(fileURL: temporaryFileURL)
    check(store.records.isEmpty, "new store is empty")
    store.recordTurn(
        providerIdentifier: "anthropic/claude-sonnet-5-5",
        counts: UsageTokenCounts(inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 1_000_000),
        durationSeconds: 1.5, screenshotWasAttached: true, isBackgroundRun: false)
    store.recordTurn(
        providerIdentifier: "scripted-test-double",
        counts: UsageTokenCounts(), durationSeconds: 1, screenshotWasAttached: false, isBackgroundRun: false)
    check(store.records.count == 1, "unknown provider identifiers are not logged")
    check(isClose(store.records.first?.estimatedCostUSD, 0.20), "store prices a fully cached million tokens at the cache-read rate")
    check(store.records.first?.cachedInputTokens == 1_000_000, "cached tokens recorded")

    store.saveImmediately()
    let attributes = try! FileManager.default.attributesOfItem(atPath: temporaryFileURL.path)
    check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "usage log file is mode 0600")
    let reloadedStore = UsageLogStore(fileURL: temporaryFileURL)
    check(reloadedStore.records.count == 1, "a new store reloads what was saved")

    store.clear()
    check(store.records.isEmpty, "clear empties the store")
    let afterClearData = try! Data(contentsOf: temporaryFileURL)
    check(UsageLogCodec.decode(afterClearData)?.isEmpty == true, "clear empties the file immediately")


}
print("\(checkCount - failureCount) passed, \(failureCount) failed, \(checkCount) total")
exit(failureCount == 0 ? 0 : 1)
}
MainActor.assumeIsolated { runAllTests() }
