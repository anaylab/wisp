//
//  BrowserPlanCache.swift
//  leanring-buddy
//
//  Remembers plans by the shape of the request, not its wording.
//
//  "find nvidia on wikipedia" and "look up tesla on wikipedia" are the same
//  workflow with a different parameter. Keying a cache on the sentence would
//  treat them as unrelated and re-plan every time — two seconds each — so
//  requests are normalised to an intent like `wikipedia.search` with the query
//  carried separately and substituted at execution.
//
//  Deterministic and model-written plans are kept apart on purpose. A
//  deterministic plan is a pure function of the intent and is safe to reuse
//  indefinitely. A model-written plan was reasoned against a particular page at
//  a particular moment, and reusing one after the page has moved on produces a
//  confident sequence of clicks on elements that are no longer there. So those
//  are cached only when they contain nothing page-specific, and dropped the
//  moment anything suggests the assumption has expired.
//
//  Nothing here bypasses validation. A cached plan is re-validated before it
//  runs, because a cache is a performance structure and must never also become
//  a way around the security boundary.
//

import Foundation

/// A request reduced to its reusable shape.
struct BrowserIntent: Sendable, Hashable {
    /// e.g. "wikipedia.search", "github.open", "url.open"
    let shape: String
    /// The part that varies. Never part of the cache key.
    let parameter: String?

    var description: String {
        parameter.map { "\(shape)(\($0))" } ?? shape
    }
}

@MainActor
final class BrowserPlanCache {
    static let shared = BrowserPlanCache()

    private struct CachedPlan {
        let steps: [BrowserStep]
        let cachedAt: Date
        let wasModelWritten: Bool
    }

    /// Model plans go stale as sites change; deterministic ones do not, but a
    /// ceiling costs nothing and bounds the damage from a site redesign.
    private static let modelPlanLifetime: TimeInterval = 30 * 60

    private var deterministicPlans: [String: CachedPlan] = [:]
    private var modelPlans: [String: CachedPlan] = [:]

    // MARK: - Metrics

    private(set) var totalRequests = 0
    private(set) var deterministicHits = 0
    private(set) var cacheHits = 0
    private(set) var modelPlanningCalls = 0
    private(set) var replans = 0
    private(set) var failures = 0

    /// The number this whole design exists to move.
    var proportionAvoidingModelPlanning: Double {
        guard totalRequests > 0 else { return 0 }
        return Double(deterministicHits + cacheHits) / Double(totalRequests)
    }

    func recordRequest() { totalRequests += 1 }
    func recordDeterministicHit() { deterministicHits += 1 }
    func recordCacheHit() { cacheHits += 1 }
    func recordModelPlanningCall() { modelPlanningCalls += 1 }
    func recordReplan() { replans += 1 }
    func recordFailure() { failures += 1 }

    func metricsSummary() -> String {
        let avoided = Int(proportionAvoidingModelPlanning * 100)
        return """
        browser requests        \(totalRequests)
        deterministic hits      \(deterministicHits)
        cached plan hits        \(cacheHits)
        model planning calls    \(modelPlanningCalls)
        replans                 \(replans)
        failures                \(failures)
        avoided planning        \(avoided)%
        """
    }

    // MARK: - Lookup

    func cachedSteps(for intent: BrowserIntent) -> (steps: [BrowserStep], wasModelWritten: Bool)? {
        if let hit = deterministicPlans[intent.shape] {
            return (substituted(hit.steps, parameter: intent.parameter), false)
        }
        if let hit = modelPlans[intent.shape] {
            guard Date().timeIntervalSince(hit.cachedAt) < Self.modelPlanLifetime else {
                modelPlans[intent.shape] = nil
                return nil
            }
            return (substituted(hit.steps, parameter: intent.parameter), true)
        }
        return nil
    }

    /// Stores a plan under its shape.
    ///
    /// The caller must pass *templated* steps for anything parameterised —
    /// steps carrying a literal placeholder rather than this request's values.
    /// Storing the concrete plan is the subtle failure: it executes perfectly
    /// and returns the previous caller's results.
    func store(steps: [BrowserStep], for intent: BrowserIntent, wasModelWritten: Bool) {
        guard !steps.isEmpty else { return }
        // A literal URL has no shape worth reusing, and caching one under a
        // shared key would hand it to unrelated requests.
        guard intent.shape != "url.open" else { return }

        if wasModelWritten {
            // Only shapes with nothing page-specific in them. A plan that
            // clicks a particular element was reasoned about a page that has
            // since had every opportunity to change.
            guard isReusable(steps) else { return }
            modelPlans[intent.shape] = CachedPlan(steps: steps, cachedAt: Date(), wasModelWritten: true)
        } else {
            deterministicPlans[intent.shape] = CachedPlan(steps: steps, cachedAt: Date(), wasModelWritten: false)
        }
    }

    /// Drops a plan that has stopped working.
    ///
    /// Called on failure, so a site redesign costs one bad run rather than
    /// every run until something expires.
    func invalidate(_ intent: BrowserIntent) {
        deterministicPlans[intent.shape] = nil
        modelPlans[intent.shape] = nil
    }

    func invalidateAll() {
        deterministicPlans.removeAll()
        modelPlans.removeAll()
    }

    // MARK: - Reuse rules

    /// Whether a model-written plan is safe to reuse.
    ///
    /// Navigation and reading are properties of the site. Clicking and typing
    /// are properties of a page as it looked at one moment, and are what makes
    /// a replayed plan land on the wrong element.
    private func isReusable(_ steps: [BrowserStep]) -> Bool {
        steps.allSatisfy { step in
            switch step {
            case .open, .navigate, .read, .scroll: return true
            case .clickMatching, .typeInto, .back, .forward: return false
            }
        }
    }

    /// Puts the current parameter into a cached shape.
    private func substituted(_ steps: [BrowserStep], parameter: String?) -> [BrowserStep] {
        guard let parameter,
              let encoded = parameter.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return steps }

        return steps.map { step in
            switch step {
            case .open(let url):
                return URL(string: url.absoluteString.replacingOccurrences(of: "%7Bquery%7D", with: encoded))
                    .map { BrowserStep.open(url: $0) } ?? step
            case .navigate(let url):
                return URL(string: url.absoluteString.replacingOccurrences(of: "%7Bquery%7D", with: encoded))
                    .map { BrowserStep.navigate(url: $0) } ?? step
            case .typeInto(let field, _, let submit):
                return .typeInto(fieldQuery: field, text: parameter, submit: submit)
            default:
                return step
            }
        }
    }
}
