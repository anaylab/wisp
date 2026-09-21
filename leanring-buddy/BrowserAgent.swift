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
    ///
    /// - Parameter cursorGuide: flies the on-screen cursor to each element the
    ///   tier-2 step loop acts on, so the user watches the work. Nil disables the
    ///   animation; nothing depends on it to act.
    static func run(
        request: String,
        controller: BrowserController,
        chatClient: any BuddyVisionChatClient,
        cursorGuide: BrowserCursorGuide? = nil,
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
            chatClient: chatClient, cursorGuide: cursorGuide, onStep: onStep
        )
    }

    // MARK: - Model planning

    /// Plans once, executes, and on a genuine execution failure hands the live
    /// page to the tier-2 step loop rather than re-planning the whole workflow
    /// blind. A plan written against an imagined page is sometimes wrong about a
    /// real one; when it is, the loop is what looks at the real one.
    private static func runWithModelPlanning(
        request: String,
        controller: BrowserController,
        chatClient: any BuddyVisionChatClient,
        cursorGuide: BrowserCursorGuide?,
        onStep: (@MainActor (String) -> Void)?
    ) async -> BrowserAgentOutcome {
        var planningCalls = 0
        var malformedRetries = 0
        var totalPlanningDuration: TimeInterval = 0
        var tokenEstimate = 0
        var malformedContext: String?

        // Get one valid plan. A malformed reply is recoverable — the model is
        // told what was wrong and gets one more attempt — but a malformed reply
        // is not an execution failure, so it does not go to the step loop.
        var plan: BrowserTaskPlan?
        while malformedRetries <= maximumReplans {
            onStep?(malformedContext == nil ? "planning…" : "re-reading the request…")

            let planningStartedAt = Date()
            let promptText = planningPrompt(for: request, failureContext: malformedContext)
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
                                     planningCalls: planningCalls, replans: malformedRetries,
                                     duration: totalPlanningDuration, tokens: tokenEstimate)
            }
            planningCalls += 1
            BrowserPlanCache.shared.recordModelPlanningCall()
            totalPlanningDuration += Date().timeIntervalSince(planningStartedAt)
            tokenEstimate += (promptText.count + modelOutput.count) / 4

            do {
                plan = try BrowserPlanValidator.plan(
                    from: modelOutput, goal: request, continuesFromCurrentPage: false
                )
                break
            } catch {
                malformedContext = "rejected: \(error.localizedDescription) reply with plan lines only."
                malformedRetries += 1
                BrowserPlanCache.shared.recordReplan()
            }
        }

        guard let plan else {
            return failedOutcome(
                request: request, reason: "Couldn't turn that into a plan.",
                planningCalls: planningCalls, replans: malformedRetries,
                duration: totalPlanningDuration, tokens: tokenEstimate
            )
        }

        onStep?("plan: " + plan.steps.map(\.description).joined(separator: " → "))
        let result = await BrowserTaskRunner.execute(plan, using: controller, onStep: onStep)

        // A login wall is not a failure to work around. Stop and hand it back.
        if let authPrompt = authenticationPrompt(in: result.finalSnapshot) {
            return BrowserAgentOutcome(
                result: result, planningCallCount: planningCalls, replanCount: malformedRetries,
                planningDuration: totalPlanningDuration, planTokenEstimate: tokenEstimate,
                authenticationRequiredAt: authPrompt
            )
        }

        if result.didSucceed {
            return BrowserAgentOutcome(
                result: result, planningCallCount: planningCalls, replanCount: malformedRetries,
                planningDuration: totalPlanningDuration, planTokenEstimate: tokenEstimate,
                authenticationRequiredAt: nil
            )
        }

        // The plan hit a real page it was wrong about. Hand the step loop what a
        // correction needs — what broke and where the browser is now — and let
        // it drive from here, one action at a time, cursor in tow.
        let state = stepState(from: result)
        let failureContext = """
        a first plan failed here: \(result.failureReason ?? "a step failed")
        now at: \(state.url)
        """
        onStep?("working through it step by step…")
        let loopOutcome = await BrowserStepLoop.run(
            goal: request,
            controller: controller,
            chatClient: chatClient,
            startingFailureContext: failureContext,
            cursorGuide: cursorGuide,
            onStep: onStep
        )

        // Fold the tier-1 planning cost into the loop's own counters so the
        // caller sees the whole request's expense, not just the loop's part.
        return BrowserAgentOutcome(
            result: loopOutcome.result,
            planningCallCount: planningCalls + loopOutcome.planningCallCount,
            replanCount: malformedRetries + loopOutcome.replanCount,
            planningDuration: totalPlanningDuration + loopOutcome.planningDuration,
            planTokenEstimate: tokenEstimate + loopOutcome.planTokenEstimate,
            authenticationRequiredAt: loopOutcome.authenticationRequiredAt
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
    static func authenticationPrompt(in snapshot: BrowserPageSnapshot?) -> String? {
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
