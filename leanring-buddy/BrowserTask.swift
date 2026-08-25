//
//  BrowserTask.swift
//  leanring-buddy
//
//  Runs a whole browser workflow without going back to the model between steps.
//
//  The obvious shape for a browser agent is a loop: ask the model what to do,
//  do it, show it the page, ask again. It is also the slow one. Each round trip
//  is a prompt evaluation plus generation — a couple of seconds here — so a
//  five-action task spends ten seconds thinking about mechanics that were never
//  in doubt. Typing into a search box and pressing return does not need a
//  language model's opinion.
//
//  So a task is a *plan* of mechanical steps, executed end to end by
//  BrowserController, producing one structured result the model reads once. The
//  model decides what the workflow is; it does not participate in carrying it
//  out.
//
//  Most common requests do not need the model even to plan. "Search Google for
//  X" has one obvious shape, and recognising it deterministically removes the
//  last round trip, which is why the planner tries that first.
//

import Foundation

// MARK: - Plan

/// One mechanical action. Deliberately coarse: each step is a thing a person
/// would name, not a DOM primitive, so a plan reads like the task it came from.
enum BrowserStep: Sendable, Equatable {
    case open(url: URL)
    case navigate(url: URL)
    /// Finds a field by label and types into it, optionally submitting.
    case typeInto(fieldQuery: String, text: String, submit: Bool)
    case clickMatching(query: String)
    case scroll(BrowserScrollDirection)
    case back
    case forward
    /// Reads the page into the result. Implicit at the end of every plan.
    case read

    var description: String {
        switch self {
        case .open(let url): return "open \(url.host() ?? url.absoluteString)"
        case .navigate(let url): return "go to \(url.host() ?? url.absoluteString)"
        case .typeInto(let field, let text, let submit):
            return "type \"\(text)\" into \(field)\(submit ? " and submit" : "")"
        case .clickMatching(let query): return "click \(query)"
        case .scroll(let direction): return "scroll \(direction.rawValue)"
        case .back: return "go back"
        case .forward: return "go forward"
        case .read: return "read the page"
        }
    }
}

struct BrowserTaskPlan: Sendable {
    let goal: String
    let steps: [BrowserStep]
}

// MARK: - Result

struct BrowserTaskResult: Sendable {
    let goal: String
    /// What actually happened, in order, with timings — so a task that went
    /// wrong can be read back rather than guessed at.
    let stepLog: [String]
    let finalSnapshot: BrowserPageSnapshot?
    let totalDuration: TimeInterval
    let browserOperationCount: Int
    let didSucceed: Bool
    let failureReason: String?

    /// What the model is given to answer from. One read, at the end.
    func promptRepresentation() -> String {
        var lines = ["BROWSER TASK: \(goal)", "STEPS:"]
        lines.append(contentsOf: stepLog.map { "  \($0)" })
        if let finalSnapshot {
            lines.append("")
            lines.append(finalSnapshot.promptRepresentation())
        }
        if let failureReason {
            lines.append("")
            lines.append("STOPPED: \(failureReason)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Runner

@MainActor
enum BrowserTaskRunner {
    /// Executes every step in order. No model calls happen in here at all.
    static func execute(
        _ plan: BrowserTaskPlan,
        using controller: BrowserController,
        onStep: (@MainActor (String) -> Void)? = nil
    ) async -> BrowserTaskResult {
        let startedAt = Date()
        var stepLog: [String] = []
        var operationCount = 0

        func note(_ text: String) {
            stepLog.append(text)
            onStep?(text)
        }

        for step in plan.steps {
            let stepStartedAt = Date()
            do {
                try await perform(step, using: controller)
                operationCount += 1
                let milliseconds = Int(Date().timeIntervalSince(stepStartedAt) * 1000)
                note("\(step.description) — \(milliseconds)ms")
            } catch {
                // Stops rather than continuing. Later steps assume the earlier
                // ones landed, so pressing on after a failed click means acting
                // on a page that is not the one the plan was written for.
                note("\(step.description) — failed: \(error.localizedDescription)")
                return BrowserTaskResult(
                    goal: plan.goal,
                    stepLog: stepLog,
                    finalSnapshot: try? controller.snapshot(),
                    totalDuration: Date().timeIntervalSince(startedAt),
                    browserOperationCount: operationCount,
                    didSucceed: false,
                    failureReason: error.localizedDescription
                )
            }
        }

        let snapshot = try? controller.snapshot()
        return BrowserTaskResult(
            goal: plan.goal,
            stepLog: stepLog,
            finalSnapshot: snapshot,
            totalDuration: Date().timeIntervalSince(startedAt),
            browserOperationCount: operationCount,
            didSucceed: true,
            failureReason: nil
        )
    }

    private static func perform(_ step: BrowserStep, using controller: BrowserController) async throws {
        switch step {
        case .open(let url):
            try controller.openURL(url)
            _ = await controller.waitUntilLoaded(timeout: 10)

        case .navigate(let url):
            try controller.navigate(to: url)
            _ = await controller.waitUntilLoaded(timeout: 10)

        case .typeInto(let fieldQuery, let text, let submit):
            let element = try resolveField(matching: fieldQuery, using: controller)
            try controller.typeText(text, intoElementID: element.id, pressEnter: submit)
            if submit { _ = await controller.waitUntilLoaded(timeout: 10) }

        case .clickMatching(let query):
            let candidates = try controller.findElements(matching: query)
            guard let best = candidates.first else {
                throw BrowserControllerError.elementNotFound(query)
            }
            try controller.click(elementID: best.id)
            _ = await controller.waitUntilLoaded(timeout: 10)

        case .scroll(let direction):
            try controller.scroll(direction)

        case .back:
            try controller.goBack()
            _ = await controller.waitUntilLoaded(timeout: 10)

        case .forward:
            try controller.goForward()
            _ = await controller.waitUntilLoaded(timeout: 10)

        case .read:
            _ = try controller.snapshot()
        }
    }

    /// Finds a text field, by label if possible and by role if not.
    ///
    /// Search boxes are the common case and are frequently unlabelled — a bare
    /// input with a placeholder the accessibility tree does not surface — so
    /// falling back to "the first thing you can type in" is what makes
    /// "search for X" work on sites that name nothing.
    private static func resolveField(
        matching query: String,
        using controller: BrowserController
    ) throws -> BrowserElement {
        let named = try controller.findElements(matching: query)
        if let match = named.first(where: { $0.role.contains("text") || $0.role == "search" }) {
            return match
        }
        if let anyMatch = named.first { return anyMatch }

        let typeable = try controller.snapshot().elements.filter {
            $0.role.contains("text") || $0.role == "search" || $0.role == "email"
        }
        guard let fallback = typeable.first else {
            throw BrowserControllerError.elementNotFound(query)
        }
        return fallback
    }
}

// MARK: - Planning

@MainActor
enum BrowserTaskPlanner {
    /// Sites people name by word rather than by address.
    private static let knownSites: [String: String] = [
        "google": "https://www.google.com/search?q=",
        "youtube": "https://www.youtube.com/results?search_query=",
        "wikipedia": "https://en.wikipedia.org/w/index.php?search=",
        "github": "https://github.com/search?q=",
        "amazon": "https://www.amazon.com/s?k=",
        "stack overflow": "https://stackoverflow.com/search?q=",
    ]

    /// Recognises common requests without asking the model.
    ///
    /// "Search Google for X" has exactly one sensible shape, and planning it
    /// with a language model costs a round trip to reach a conclusion that was
    /// never in doubt. Anything not recognised here returns nil and the caller
    /// falls back to the model, so this is a shortcut rather than a ceiling.
    static func plan(for request: String) -> BrowserTaskPlan? {
        let text = request.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // "search <site> for <query>" / "<site> search for <query>"
        for (siteName, searchPrefix) in knownSites {
            guard text.contains(siteName) else { continue }
            guard let query = extractSearchQuery(from: text, siteName: siteName), !query.isEmpty else { continue }
            guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: searchPrefix + encoded) else { continue }

            // Straight to the results URL rather than loading the homepage and
            // driving its search box: fewer steps, no dependence on that site's
            // markup, and the same destination.
            return BrowserTaskPlan(
                goal: request,
                steps: [.open(url: url), .read]
            )
        }

        // "open <url>" / "go to <domain>"
        if let url = extractURL(from: text) {
            return BrowserTaskPlan(goal: request, steps: [.open(url: url), .read])
        }
        return nil
    }

    private static func extractSearchQuery(from text: String, siteName: String) -> String? {
        // "... for <query>" is the reliable marker; everything before it is
        // phrasing that varies too much to parse.
        if let range = text.range(of: " for ") {
            return String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        if let range = text.range(of: "\(siteName) ") {
            let remainder = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            return remainder.isEmpty ? nil : remainder
        }
        return nil
    }

    private static func extractURL(from text: String) -> URL? {
        for word in text.split(separator: " ") {
            let candidate = String(word).trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
            if candidate.hasPrefix("http"), let url = URL(string: candidate) { return url }
            if candidate.contains("."), !candidate.hasSuffix("."),
               let url = URL(string: "https://" + candidate),
               url.host()?.contains(".") == true {
                return url
            }
        }
        return nil
    }
}
