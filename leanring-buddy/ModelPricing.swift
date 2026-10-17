//
//  ModelPricing.swift
//  leanring-buddy
//
//  Pure price table and cost estimator behind the usage log.
//
//  THESE ARE ESTIMATES. The numbers are public list prices for the API, copied
//  by hand on `ModelPricing.pricesSetOn`; providers change them, and batch,
//  fast-mode and long-context rates are not modelled. The usage log uses them
//  to answer "roughly what would this have cost on the API", never to bill
//  anyone. Nothing here touches the network or the disk.
//

import Foundation

/// Dollar prices per one million tokens for one model.
struct ModelPricing: Equatable, Sendable {
    let inputDollarsPerMillionTokens: Double
    let outputDollarsPerMillionTokens: Double
    /// Input served from the provider's prompt cache.
    let cacheReadDollarsPerMillionTokens: Double
    /// Input written to the prompt cache (Anthropic charges a premium; the
    /// other providers do not charge separately, so this equals plain input).
    let cacheWriteDollarsPerMillionTokens: Double

    /// The date the table below was last checked against the providers'
    /// published prices.
    static let pricesSetOn = "2026-10-17"

    // Claude: Anthropic list prices. Cache writes are 1.25x input (5-minute cache).
    static let claudeOpus55 = ModelPricing(
        inputDollarsPerMillionTokens: 4.00, outputDollarsPerMillionTokens: 20.00,
        cacheReadDollarsPerMillionTokens: 0.20, cacheWriteDollarsPerMillionTokens: 5.00)
    static let claudeSonnet55 = ModelPricing(
        inputDollarsPerMillionTokens: 2.00, outputDollarsPerMillionTokens: 10.00,
        cacheReadDollarsPerMillionTokens: 0.20, cacheWriteDollarsPerMillionTokens: 2.50)
    static let claudeHaiku45 = ModelPricing(
        inputDollarsPerMillionTokens: 1.00, outputDollarsPerMillionTokens: 5.00,
        cacheReadDollarsPerMillionTokens: 0.10, cacheWriteDollarsPerMillionTokens: 1.25)
    // OpenAI and Google: standard (non-batch) list prices; cached input discounted.
    static let gpt4o = ModelPricing(
        inputDollarsPerMillionTokens: 2.50, outputDollarsPerMillionTokens: 10.00,
        cacheReadDollarsPerMillionTokens: 1.25, cacheWriteDollarsPerMillionTokens: 2.50)
    static let gemini25Flash = ModelPricing(
        inputDollarsPerMillionTokens: 0.30, outputDollarsPerMillionTokens: 2.50,
        cacheReadDollarsPerMillionTokens: 0.075, cacheWriteDollarsPerMillionTokens: 0.30)
    /// A model on this Mac costs nothing per token.
    static let free = ModelPricing(
        inputDollarsPerMillionTokens: 0, outputDollarsPerMillionTokens: 0,
        cacheReadDollarsPerMillionTokens: 0, cacheWriteDollarsPerMillionTokens: 0)

    /// The prices for a provider + model, or nil when the model is not in the
    /// table (a cost is then left unknown rather than guessed).
    static func pricing(for providerKind: BuddyChatProviderKind, modelName: String) -> ModelPricing? {
        if providerKind == .localOllama { return .free }
        let normalizedModelName = modelName.lowercased()
        // Prefix match so a dated suffix (gpt-4o-2024-08-06) still finds its row.
        let table: [(prefix: String, pricing: ModelPricing)] = [
            ("claude-opus-5-5", .claudeOpus55),
            ("claude-sonnet-5-5", .claudeSonnet55),
            ("claude-haiku-4-5", .claudeHaiku45),
            ("gpt-4o", .gpt4o),
            ("gemini-2.5-flash", .gemini25Flash),
        ]
        return table.first { normalizedModelName.hasPrefix($0.prefix) }?.pricing
    }
}

enum UsageCostEstimator {
    /// Estimated API-equivalent dollars for one turn, or nil when it cannot be
    /// known (unpriced model, or no token counts and no provider-reported cost).
    /// A provider-reported cost wins over the table.
    static func estimatedCostUSD(
        providerKind: BuddyChatProviderKind,
        modelName: String,
        counts: UsageTokenCounts
    ) -> Double? {
        if let reportedCostUSD = counts.reportedCostUSD { return reportedCostUSD }
        guard let pricing = ModelPricing.pricing(for: providerKind, modelName: modelName) else { return nil }
        if pricing == .free { return 0 }
        guard counts.inputTokens != nil || counts.outputTokens != nil else { return nil }

        let totalInputTokens = counts.inputTokens ?? 0
        let cacheReadTokens = min(counts.cacheReadTokens ?? 0, totalInputTokens)
        let cacheWriteTokens = min(counts.cacheWriteTokens ?? 0, totalInputTokens - cacheReadTokens)
        let freshInputTokens = totalInputTokens - cacheReadTokens - cacheWriteTokens
        let millionTokens = 1_000_000.0

        return Double(freshInputTokens) * pricing.inputDollarsPerMillionTokens / millionTokens
            + Double(cacheReadTokens) * pricing.cacheReadDollarsPerMillionTokens / millionTokens
            + Double(cacheWriteTokens) * pricing.cacheWriteDollarsPerMillionTokens / millionTokens
            + Double(counts.outputTokens ?? 0) * pricing.outputDollarsPerMillionTokens / millionTokens
    }

    /// How a cost is worded. A subscription turn is not billed per token, so
    /// its figure is shown as what the API would have charged.
    static func costLabel(providerKind: BuddyChatProviderKind, estimatedCostUSD: Double?) -> String {
        if providerKind == .localOllama { return "free (runs on this Mac)" }
        guard let estimatedCostUSD else { return "cost unknown" }
        let amount = formattedDollars(estimatedCostUSD)
        if providerKind == .claudeSubscription {
            return "included in subscription (≈ API cost \(amount))"
        }
        return "≈ \(amount)"
    }

    static func formattedDollars(_ dollars: Double) -> String {
        if dollars == 0 { return "$0.00" }
        if dollars < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", dollars)
    }
}
