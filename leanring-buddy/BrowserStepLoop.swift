//
//  BrowserStepLoop.swift
//  leanring-buddy
//
//  Tier 2. The bounded observe-act loop that runs only after a planned-once
//  workflow has failed on a real page.
//
//  Tier 0 (the deterministic planner) and tier 1 (one planning call, executed
//  end to end) exist precisely to avoid a per-step model loop, because that loop
//  is what makes browser agents slow: every step pays for a prompt evaluation
//  and a generation to decide something the plan should already have known. So
//  this is not the default path and never runs on the happy path. It is the
//  fallback for the case a static plan cannot handle — a page whose next control
//  only appears after the previous action, an app that reshapes itself as you go.
//
//  It is bounded hard. A fixed number of steps, no screenshots (the DOM snapshot
//  is read the same cheap way tier 1 reads it), and a login wall stops it dead
//  rather than becoming something to loop against. A hostile or broken site must
//  not be able to spend the user's afternoon here.
//
//  While it acts, the on-screen cursor is flown to each element just before the
//  loop clicks or types it, through the BrowserCursorGuide below, so the user
//  watches the work happen on their own screen rather than staring at a spinner.
//

import CoreGraphics
import Foundation

// MARK: - Cursor guidance

/// Lets the step loop fly the on-screen cursor to an element before acting on
/// it, without the loop knowing anything about the overlay. CompanionManager is
/// the only implementer; the loop stays UI-agnostic and testable without one.
@MainActor
protocol BrowserCursorGuide: AnyObject {
    /// Flies the cursor to `point` (global AppKit screen coordinates, bottom-left
    /// origin) on the display described by `displayFrame`, and returns once the
    /// hop has had time to play, so the click that follows is seen to land where
    /// the cursor went. `actionText` is a short label shown beside the cursor,
    /// e.g. "click Sign in".
    func guideCursor(to point: CGPoint, on displayFrame: CGRect, actionText: String) async

    /// Returns the cursor to normal cursor-following once the workflow ends.
    func endCursorGuidance()
}

// MARK: - Actions

/// One step the model may ask for. Element-id aware, unlike the tier-1 plan
/// grammar which names things by visible text: by the time the loop runs, the
/// page has been snapshotted and every element already carries a stable id, so
/// referring to ids removes the ambiguity of matching a label twice.
enum BrowserLoopAction: Equatable {
    case click(id: String)
    case type(id: String, text: String)
    case scroll(BrowserScrollDirection)
    case open(url: URL)
    case back
    /// The task is finished; the string is the short answer.
    case done(answer: String)
    /// The task cannot be finished from here; the string is why.
    case fail(reason: String)
}

// MARK: - Loop

@MainActor
enum BrowserStepLoop {
    /// Runs the loop from wherever the browser currently is.
    ///
    /// - Parameters:
    ///   - startingFailureContext: what the tier-1 plan hit on its way here, so
    ///     the first decision is made knowing why a static plan was not enough.
    ///   - maximumSteps: the hard cap. Reaching it is a failure, not a retry.
    ///   - cursorGuide: the overlay hook, or nil to run without the animation.
    static func run(
        goal: String,
        controller: BrowserController,
        chatClient: any BuddyVisionChatClient,
        startingFailureContext: String?,
        maximumSteps: Int = 5,
        cursorGuide: BrowserCursorGuide?,
        onStep: (@MainActor (String) -> Void)? = nil
    ) async -> BrowserAgentOutcome {
        let startedAt = Date()
        var stepLog: [String] = []
        var actionHistory: [String] = []
        var operationCount = 0
        var modelCalls = 0
        var totalModelDuration: TimeInterval = 0
        var tokenEstimate = 0

        // Whatever else happens, hand the cursor back to the user at the end.
        defer { cursorGuide?.endCursorGuidance() }

        // Records a step for both the human-readable result and the terse
        // history the next decision is given.
        func record(_ logLine: String, history historyLine: String) {
            stepLog.append(logLine)
            actionHistory.append(historyLine)
            onStep?(logLine)
        }

        func makeOutcome(
            didSucceed: Bool,
            failureReason: String?,
            snapshot: BrowserPageSnapshot?,
            authenticationRequiredAt: String? = nil
        ) -> BrowserAgentOutcome {
            let result = BrowserTaskResult(
                goal: goal,
                stepLog: stepLog,
                finalSnapshot: snapshot,
                totalDuration: Date().timeIntervalSince(startedAt),
                browserOperationCount: operationCount,
                didSucceed: didSucceed,
                failureReason: failureReason
            )
            return BrowserAgentOutcome(
                result: result,
                planningCallCount: modelCalls,
                replanCount: 0,
                planningDuration: totalModelDuration,
                planTokenEstimate: tokenEstimate,
                authenticationRequiredAt: authenticationRequiredAt
            )
        }

        for stepIndex in 0..<maximumSteps {
            // Observe. A tighter text budget than tier 1's read: the loop acts
            // on elements, not prose, and the body text is re-fetched every step
            // so it must stay cheap.
            let snapshot: BrowserPageSnapshot
            do {
                snapshot = try controller.snapshot(maximumTextCharacters: 500)
            } catch {
                return makeOutcome(didSucceed: false, failureReason: error.localizedDescription, snapshot: nil)
            }

            // A login wall is not a step to plan around. Stop and hand it to the
            // user, who is the only one who can answer it.
            if let authURL = BrowserAgent.authenticationPrompt(in: snapshot) {
                return makeOutcome(
                    didSucceed: false,
                    failureReason: "sign-in required",
                    snapshot: snapshot,
                    authenticationRequiredAt: authURL
                )
            }

            // Decide. Exactly one action.
            onStep?(stepIndex == 0 ? "looking at the page…" : "deciding the next step…")
            let prompt = decisionPrompt(
                goal: goal,
                history: actionHistory,
                page: snapshot.promptRepresentation(),
                failureContext: stepIndex == 0 ? startingFailureContext : nil
            )
            let modelStartedAt = Date()
            let modelOutput: String
            do {
                let (text, _) = try await chatClient.analyzeImageStreaming(
                    images: [],
                    systemPrompt: Self.systemPrompt,
                    conversationHistory: [],
                    userPrompt: prompt,
                    onTextChunk: { _ in }
                )
                modelOutput = text
            } catch {
                return makeOutcome(didSucceed: false, failureReason: error.localizedDescription, snapshot: snapshot)
            }
            modelCalls += 1
            totalModelDuration += Date().timeIntervalSince(modelStartedAt)
            tokenEstimate += (prompt.count + modelOutput.count) / 4

            guard let action = parseAction(from: modelOutput) else {
                // An unreadable reply costs a step rather than ending the task —
                // the model gets to look again — but it is still bounded by the
                // cap, so a model that never produces a clean line cannot loop.
                actionHistory.append("(previous reply was unclear)")
                continue
            }

            switch action {
            case .done(let answer):
                stepLog.append(answer.isEmpty ? "done" : "done: \(answer)")
                let finalSnapshot = (try? controller.snapshot()) ?? snapshot
                return makeOutcome(didSucceed: true, failureReason: nil, snapshot: finalSnapshot)

            case .fail(let reason):
                return makeOutcome(
                    didSucceed: false,
                    failureReason: reason.isEmpty ? "the model stopped without a reason" : reason,
                    snapshot: snapshot
                )

            case .click(let elementID):
                let label = labelForElement(id: elementID, in: snapshot)
                await guideCursor(toElementID: elementID, actionText: "click \(label)",
                                  controller: controller, cursorGuide: cursorGuide)
                do {
                    try controller.click(elementID: elementID)
                    _ = await controller.waitUntilLoaded()
                    operationCount += 1
                    record("clicked \(elementID) (\(label))", history: "clicked \(elementID) (\(label))")
                } catch {
                    record("click \(elementID) failed: \(error.localizedDescription)",
                           history: "clicking \(elementID) failed")
                }

            case .type(let elementID, let text):
                let label = labelForElement(id: elementID, in: snapshot)
                await guideCursor(toElementID: elementID, actionText: "type into \(label)",
                                  controller: controller, cursorGuide: cursorGuide)
                do {
                    try controller.typeText(text, intoElementID: elementID, pressEnter: true)
                    _ = await controller.waitUntilLoaded()
                    operationCount += 1
                    record("typed \"\(text)\" into \(elementID)", history: "typed \"\(text)\" into \(elementID)")
                } catch {
                    record("typing into \(elementID) failed: \(error.localizedDescription)",
                           history: "typing into \(elementID) failed")
                }

            case .scroll(let direction):
                try? controller.scroll(direction)
                operationCount += 1
                record("scrolled \(direction.rawValue)", history: "scrolled \(direction.rawValue)")

            case .open(let url):
                do {
                    try controller.navigate(to: url)
                    _ = await controller.waitUntilLoaded()
                    operationCount += 1
                    let host = url.host() ?? url.absoluteString
                    record("opened \(host)", history: "opened \(host)")
                } catch {
                    record("opening \(url.absoluteString) failed: \(error.localizedDescription)",
                           history: "opening the page failed")
                }

            case .back:
                try? controller.goBack()
                _ = await controller.waitUntilLoaded()
                operationCount += 1
                record("went back", history: "went back")
            }
        }

        // The cap is a failure, deliberately. A task that needs more than this
        // many mechanical steps is one the loop is not going to finish by trying
        // harder, and the user is better served by being told so.
        return makeOutcome(
            didSucceed: false,
            failureReason: "couldn't finish within \(maximumSteps) steps",
            snapshot: try? controller.snapshot()
        )
    }

    // MARK: - Cursor

    /// Flies the cursor to an element, if it can be located on screen. A miss is
    /// silent: pointing is a courtesy to the watching user, never a precondition
    /// for the click, so an element the browser cannot place (scrolled out, in a
    /// cross-origin frame) is acted on without the animation rather than skipped.
    private static func guideCursor(
        toElementID elementID: String,
        actionText: String,
        controller: BrowserController,
        cursorGuide: BrowserCursorGuide?
    ) async {
        guard let cursorGuide else { return }
        // `try?` on a method that already returns an optional flattens to a
        // single optional, so one unwrap covers both a thrown error and a nil.
        guard let located = try? controller.screenPoint(ofElementID: elementID) else { return }
        await cursorGuide.guideCursor(to: located.point, on: located.displayFrame, actionText: actionText)
    }

    private static func labelForElement(id elementID: String, in snapshot: BrowserPageSnapshot) -> String {
        snapshot.elements.first(where: { $0.id == elementID })?.label ?? elementID
    }

    // MARK: - Prompts

    /// The loop's whole context, and nothing else. No conversation, no MCP
    /// tools, no screen instructions — none of it bears on choosing the next
    /// click, and all of it would be re-evaluated on every step.
    private static let systemPrompt = """
    you are stepping through a web page one action at a time to finish a task. you are given the goal, what you have already done, and the current page as a list of elements each with an id like e7. reply with exactly ONE action and nothing else.

    actions:
    click <id>            click the element with that id
    type <id> = <text>    type into a field and submit
    scroll up
    scroll down
    open <url>            go to a web address
    back                  go back one page
    done <answer>         the task is finished — give the short answer
    fail <reason>         it can't be done from here — say why

    rules:
    - one line only. no prose, no json, no explanation.
    - refer to elements only by an id shown above. never invent an id.
    - when the page already answers the goal, reply: done <the answer>.
    - if a sign-in wall is in the way, reply: fail sign-in is needed.
    """

    private static func decisionPrompt(
        goal: String,
        history: [String],
        page: String,
        failureContext: String?
    ) -> String {
        var lines: [String] = []
        if let failureContext, !failureContext.isEmpty {
            lines.append(failureContext)
            lines.append("")
        }
        lines.append("goal: \(goal)")
        lines.append("")
        lines.append("so far:")
        if history.isEmpty {
            lines.append("- nothing yet.")
        } else {
            lines.append(contentsOf: history.map { "- \($0)" })
        }
        lines.append("")
        lines.append("current page:")
        lines.append(page)
        lines.append("")
        lines.append("reply with one action.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Parsing

    /// Reads the model's reply into a single action.
    ///
    /// Takes the first line that names a known action, so a model that adds a
    /// stray blank line or a leading acknowledgement still parses. An unreadable
    /// reply returns nil, which the loop treats as one wasted step rather than an
    /// error.
    static func parseAction(from modelOutput: String) -> BrowserLoopAction? {
        for rawLine in modelOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let lowercased = line.lowercased()

            if lowercased.hasPrefix("done") {
                return .done(answer: dropVerb("done", from: line))
            }
            if lowercased.hasPrefix("fail") {
                return .fail(reason: dropVerb("fail", from: line))
            }
            if lowercased.hasPrefix("click") {
                let elementID = dropVerb("click", from: line)
                if !elementID.isEmpty { return .click(id: firstToken(in: elementID)) }
            }
            if lowercased.hasPrefix("type") {
                let remainder = dropVerb("type", from: line)
                if let equals = remainder.range(of: "=") {
                    let elementID = firstToken(in: String(remainder[..<equals.lowerBound]))
                    let text = String(remainder[equals.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !elementID.isEmpty { return .type(id: elementID, text: text) }
                }
            }
            if lowercased.hasPrefix("scroll") {
                return .scroll(lowercased.contains("up") ? .up : .down)
            }
            if lowercased.hasPrefix("open") {
                let raw = dropVerb("open", from: line)
                let normalized = raw.hasPrefix("http") ? raw : "https://" + raw
                if let url = URL(string: firstToken(in: normalized)) { return .open(url: url) }
            }
            if lowercased.hasPrefix("back") {
                return .back
            }
        }
        return nil
    }

    /// Removes a leading verb and any whitespace after it, preserving the rest's
    /// original casing (element ids and typed text are case-sensitive).
    private static func dropVerb(_ verb: String, from line: String) -> String {
        String(line.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
    }

    /// The first whitespace-delimited token, with trailing punctuation removed —
    /// so "e7." and "e7:" both resolve to "e7".
    private static func firstToken(in text: String) -> String {
        let token = text.split(separator: " ").first.map(String.init) ?? text
        return token.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;"))
    }
}
