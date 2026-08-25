//
//  BrowserAgent.swift
//  leanring-buddy
//
//  The path for browser requests the deterministic planner does not recognise.
//
//  The model's job here is to write a plan, once. It does not drive Chrome, and
//  it is not consulted between steps — that loop is what makes browser agents
//  slow, since every round trip costs a prompt evaluation and a generation to
//  decide something mechanical. One planning call producing many mechanical
//  operations is the whole design.
//
//  It is consulted again only when a step actually fails, because a plan
//  written against an imagined page is sometimes wrong about a real one. That
//  is bounded hard: a broken or hostile site must not be able to spend the
//  user's afternoon in a replanning loop.
//
//  Authentication is deliberately a dead end rather than an obstacle to route
//  around. If a page wants a login, the task stops and says so. Nothing here
//  asks the model for credentials, and nothing tries to get past a challenge.
//

import Foundation

/// Structured state after a step, which is what makes replanning possible.
struct BrowserStepState: Sendable {
    let didSucceed: Bool
    let url: String
    let title: String
    /// A short description of what is on screen now.
    let pageState: String
    let error: String?
}

struct BrowserAgentOutcome: Sendable {
    let result: BrowserTaskResult
    let planningCallCount: Int
    let replanCount: Int
    let planningDuration: TimeInterval
    let planTokenEstimate: Int
    /// Set when the task stopped because a site wants the user to sign in.
    let authenticationRequiredAt: String?

    var needsAuthentication: Bool { authenticationRequiredAt != nil }
}

@MainActor
enum BrowserAgent {
    /// Most a plan may be revised after a failure.
    ///
    /// Two. Enough for "the button was named something else" and "the page
    /// needed scrolling first", and short of anything that could feel like a
    /// loop. A site that fails three plans is not going to yield to a fourth.
    static let maximumReplans = 2

    // MARK: - Entry point

    /// Runs a browser request, planning deterministically where possible.
    static func run(
        request: String,
        controller: BrowserController,
        chatClient: any BuddyVisionChatClient,
        onStep: (@MainActor (String) -> Void)? = nil
    ) async -> BrowserAgentOutcome {
        BrowserPlanCache.shared.recordRequest()

        // The fast path, unchanged. A recognised request never reaches the
        // model at all — measured at 964ms end to end, and worth protecting.
        if let intent = BrowserTaskPlanner.intent(for: request) {
            let cache = BrowserPlanCache.shared
            let steps: [BrowserStep]?

            if let cached = cache.cachedSteps(for: intent) {
                cache.recordCacheHit()
                steps = cached.steps
            } else if let computed = BrowserTaskPlanner.steps(for: intent) {
                cache.recordDeterministicHit()
                // Templated, so a later request with a different parameter gets
                // its own results rather than this one's.
                if let template = BrowserTaskPlanner.steps(for: intent, templated: true) {
                    cache.store(steps: template, for: intent, wasModelWritten: false)
                }
                steps = computed
            } else {
                steps = nil
            }

            if let steps {
                let deterministicPlan = BrowserTaskPlan(goal: request, steps: steps)
                onStep?("recognised as \(intent.description) — no planning call needed")
                let result = await BrowserTaskRunner.execute(deterministicPlan, using: controller, onStep: onStep)
                // A plan that stopped working is dropped, so a site redesign
                // costs one bad run rather than every run.
                if !result.didSucceed {
                    BrowserPlanCache.shared.invalidate(intent)
                    BrowserPlanCache.shared.recordFailure()
                }
                return BrowserAgentOutcome(
                    result: result,
                    planningCallCount: 0,
                    replanCount: 0,
                    planningDuration: 0,
                    planTokenEstimate: 0,
                    authenticationRequiredAt: authenticationPrompt(in: result.finalSnapshot)
                )
            }
        }

        return await runWithModelPlanning(
            request: request, controller: controller,
            chatClient: chatClient, onStep: onStep
        )
    }

    // MARK: - Model planning

    private static func runWithModelPlanning(
        request: String,
        controller: BrowserController,
        chatClient: any BuddyVisionChatClient,
        onStep: (@MainActor (String) -> Void)?
    ) async -> BrowserAgentOutcome {
        var planningCalls = 0
        var replans = 0
        var totalPlanningDuration: TimeInterval = 0
        var tokenEstimate = 0
        var failureContext: String?
        var lastResult: BrowserTaskResult?

        while replans <= maximumReplans {
            onStep?(failureContext == nil ? "planning…" : "replanning after a failed step…")

            let planningStartedAt = Date()
            let promptText = planningPrompt(for: request, failureContext: failureContext)
            let modelOutput: String
            do {
                let (text, _) = try await chatClient.analyzeImageStreaming(
                    images: [],
                    systemPrompt: Self.planningSystemPrompt,
                    conversationHistory: [],
                    userPrompt: promptText,
                    onTextChunk: { _ in }
                )
                modelOutput = text
            } catch {
                return failedOutcome(request: request, reason: error.localizedDescription,
                                     planningCalls: planningCalls, replans: replans,
                                     duration: totalPlanningDuration, tokens: tokenEstimate)
            }
            planningCalls += 1
            BrowserPlanCache.shared.recordModelPlanningCall()
            totalPlanningDuration += Date().timeIntervalSince(planningStartedAt)
            tokenEstimate += (promptText.count + modelOutput.count) / 4

            let plan: BrowserTaskPlan
            do {
                plan = try BrowserPlanValidator.plan(
                    from: modelOutput, goal: request,
                    continuesFromCurrentPage: failureContext != nil
                )
            } catch {
                // A malformed plan is itself a recoverable failure: the model is
                // told exactly what was wrong and gets one more attempt.
                failureContext = "rejected: \(error.localizedDescription) reply with plan lines only."
                replans += 1
                BrowserPlanCache.shared.recordReplan()
                continue
            }

            onStep?("plan: " + plan.steps.map(\.description).joined(separator: " → "))
            let result = await BrowserTaskRunner.execute(plan, using: controller, onStep: onStep)
            lastResult = result

            // A login wall is not a failure to replan around. Stop and hand it
            // back to the user, who is the only one who can answer it.
            if let authPrompt = authenticationPrompt(in: result.finalSnapshot) {
                return BrowserAgentOutcome(
                    result: result, planningCallCount: planningCalls, replanCount: replans,
                    planningDuration: totalPlanningDuration, planTokenEstimate: tokenEstimate,
                    authenticationRequiredAt: authPrompt
                )
            }

            if result.didSucceed {
                return BrowserAgentOutcome(
                    result: result, planningCallCount: planningCalls, replanCount: replans,
                    planningDuration: totalPlanningDuration, planTokenEstimate: tokenEstimate,
                    authenticationRequiredAt: nil
                )
            }

            // Failed. Give the model the structured state rather than the raw
            // error, so it revises against what the page actually shows.
            // Only what a correction needs: what broke, where the browser is
            // now, and what can be clicked. Not the page's text, not the
            // original plan, not the conversation — a replan that resends the
            // page body pays for it in prompt evaluation on every attempt.
            let state = stepState(from: result)
            failureContext = """
            failed: \(result.failureReason ?? "step failed")
            now at: \(state.url)
            clickable: \(state.pageState)
            plan again from this page.
            """
            replans += 1
        }

        return failedOutcome(
            request: request,
            reason: "Couldn't complete that after \(maximumReplans) attempts.",
            planningCalls: planningCalls, replans: replans,
            duration: totalPlanningDuration, tokens: tokenEstimate,
            lastResult: lastResult
        )
    }

    // MARK: - Prompts

    /// The planner's whole context, and deliberately nothing else.
    ///
    /// It gets the goal, the allowed actions, and — when replanning — the page
    /// it is standing on. It does not get MCP tools, filesystem tools, screen
    /// tools, conversation history or Wisp's own voice instructions, none of
    /// which bear on choosing a URL, and all of which would be re-evaluated on
    /// every planning call.
    ///
    /// The line form rather than JSON because generation dominates planning
    /// cost: measured at 12 output tokens against JSON's 40, which is 1.25s per
    /// call on this machine. The validator accepts both, so this is a request
    /// for the cheaper spelling rather than a constraint the model must satisfy.
    private static let planningSystemPrompt = """
    turn a browser request into a plan. one action per line, nothing else. no prose, no json.

    lines:
    open <url>
    click <visible text>
    type <field> = <text>
    scroll <up|down>
    back
    read

    rules:
    - first line must be open.
    - name things by visible text, never css or coordinates.
    - fewest lines that work. three is normal.
    - prefer a url that already shows what is wanted.
    - do not invent urls for sites you are unsure of.
    - type already submits. never add a line for pressing enter.
    - use only the lines listed above. any other word is rejected and costs a retry.
    """

    private static func planningPrompt(for request: String, failureContext: String?) -> String {
        guard let failureContext else { return "request: \(request)" }
        return "request: \(request)\n\n\(failureContext)"
    }

    // MARK: - State

    private static func stepState(from result: BrowserTaskResult) -> BrowserStepState {
        let snapshot = result.finalSnapshot
        let elementSummary = snapshot?.elements.prefix(8)
            .map { "\($0.label) [\($0.role)]" }
            .joined(separator: ", ") ?? "nothing readable"

        return BrowserStepState(
            didSucceed: result.didSucceed,
            url: snapshot?.url ?? "unknown",
            title: snapshot?.title ?? "unknown",
            pageState: elementSummary,
            error: result.failureReason
        )
    }

    /// Detects a page asking the user to sign in.
    ///
    /// Matched on the page's own words rather than on a URL list, so it works
    /// for sites nobody thought to enumerate. Deliberately conservative: a false
    /// positive stops a task that might have worked, which is recoverable, while
    /// a false negative means the agent keeps clicking around a login wall.
    private static func authenticationPrompt(in snapshot: BrowserPageSnapshot?) -> String? {
        guard let snapshot else { return nil }

        let haystack = (snapshot.title + " " + snapshot.url + " " +
                        snapshot.elements.map(\.label).joined(separator: " ")).lowercased()

        let signals = ["sign in", "log in", "login", "signin",
                       "two-factor", "verification code", "authenticator"]
        guard signals.contains(where: { haystack.contains($0) }) else { return nil }

        // A "sign in" link in a page's header is normal furniture; a page that
        // is *about* signing in usually says so in its title or address.
        let strongSignal = ["sign in", "log in", "login", "signin", "auth"]
            .contains { snapshot.title.lowercased().contains($0) || snapshot.url.lowercased().contains($0) }
        guard strongSignal else { return nil }

        return snapshot.url
    }

    private static func failedOutcome(
        request: String, reason: String,
        planningCalls: Int, replans: Int,
        duration: TimeInterval, tokens: Int,
        lastResult: BrowserTaskResult? = nil
    ) -> BrowserAgentOutcome {
        let result = lastResult ?? BrowserTaskResult(
            goal: request, stepLog: [], finalSnapshot: nil,
            totalDuration: 0, browserOperationCount: 0,
            didSucceed: false, failureReason: reason
        )
        return BrowserAgentOutcome(
            result: result, planningCallCount: planningCalls, replanCount: replans,
            planningDuration: duration, planTokenEstimate: tokens,
            authenticationRequiredAt: nil
        )
    }
}
