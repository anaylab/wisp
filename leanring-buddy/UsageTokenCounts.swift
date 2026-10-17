//
//  UsageTokenCounts.swift
//  leanring-buddy
//
//  The token counts (and provider-reported cost) of a model turn, summed over
//  its model calls. Dependency-free on purpose so the agent loop can carry it
//  without pulling in the price table.
//

import Foundation

/// Token counts as providers report them, summed over a turn's model calls.
struct UsageTokenCounts: Equatable, Sendable {
    /// All input tokens, cached ones included (how the providers report it).
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    /// A dollar figure the provider itself reported, summed over calls.
    var reportedCostUSD: Double?

    init(inputTokens: Int? = nil, outputTokens: Int? = nil, cacheReadTokens: Int? = nil,
         cacheWriteTokens: Int? = nil, reportedCostUSD: Double? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reportedCostUSD = reportedCostUSD
    }

    /// Adds one model call's numbers. A field stays nil until some call
    /// reports it, so "not reported" is never turned into a false zero.
    mutating func add(inputTokens: Int?, outputTokens: Int?, cacheReadTokens: Int?,
                      cacheWriteTokens: Int?, reportedCostUSD: Double?) {
        func sum(_ existing: Int?, _ addition: Int?) -> Int? {
            guard let addition else { return existing }
            return (existing ?? 0) + addition
        }
        self.inputTokens = sum(self.inputTokens, inputTokens)
        self.outputTokens = sum(self.outputTokens, outputTokens)
        self.cacheReadTokens = sum(self.cacheReadTokens, cacheReadTokens)
        self.cacheWriteTokens = sum(self.cacheWriteTokens, cacheWriteTokens)
        if let reportedCostUSD { self.reportedCostUSD = (self.reportedCostUSD ?? 0) + reportedCostUSD }
    }
}
