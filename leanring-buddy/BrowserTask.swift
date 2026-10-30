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
    /// The agent's own finished answer, when it gave one.
    ///
    /// When present it replaces the final page dump in the tool result: the
    /// agent has already read that page and distilled it, and handing the
    /// conversation sixty elements it no longer needs only buries the answer.
    var answer: String? = nil

    /// What the model is given to answer from. One read, at the end.
    func promptRepresentation() -> String {
        var lines = ["BROWSER TASK: \(goal)", "STEPS:"]
        lines.append(contentsOf: stepLog.map { "  \($0)" })
        if let answer, !answer.isEmpty {
            lines.append("")
            lines.append("ANSWER: \(answer)")
            if let finalSnapshot {
                lines.append("ENDED ON: \(finalSnapshot.title) — \(finalSnapshot.url)")
            }
        } else if let finalSnapshot {
            lines.append("")
            lines.append(finalSnapshot.promptRepresentation())
        }
        if let failureReason {
            lines.append("")
            lines.append("STOPPED: \(failureReason)")
        } else if didSucceed, let finalSnapshot {
            // The turn's screenshot was taken before the browser moved and may
            // be resent on this pass (providers that must stay append-only), so
            // it can show a blank tab or the previous site. Say outright which
            // one to believe, or the closing message describes the old screen.
            lines.append("")
            lines.append("STATUS: completed. The browser is now on \"\(finalSnapshot.title)\" (\(finalSnapshot.url)). Any screenshot earlier in this conversation was taken before the browser task ran and is out of date; report from this result.")
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
        // Password and card fields are never a target: the controller refuses
        // them anyway, and picking one here would turn a search into an error.
        let named = try controller.findElements(matching: query).filter { !$0.isSensitiveInput }
        if let match = named.first(where: { $0.role.contains("text") || $0.role == "search" }) {
            return match
        }
        if let anyMatch = named.first { return anyMatch }

        let typeable = try controller.snapshot().elements.filter {
            !$0.isSensitiveInput
                && ($0.role.contains("text") || $0.role.contains("search") || $0.role == "email")
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
    /// Requests that name a site but are not a public search of it.
    ///
    /// "Find my open GitHub issues" contains "github" and a plausible query, so
    /// a naive matcher confidently turns it into a GitHub search for the phrase
    /// "my open github issues" — a page of nothing, delivered with certainty.
    /// Whose data is meant is exactly what a deterministic planner cannot know,
    /// so possessive language sends the request to the model instead.
    private static let personalDataMarkers = [
        "my ", "my_", "our ", "mine", "i have", "i've", "assigned to me",
        "for me", "my account", "logged in", "signed in",
    ]

    /// Verbs that mean "show me this site", with nothing else asked for.
    private static let navigationPrefixes = ["open ", "go to ", "navigate to ", "launch ", "visit "]

    /// Verbs that mean "search".
    private static let searchMarkers = ["search ", "look up ", "find ", "google "]

    /// Recognises common requests without asking the model.
    ///
    /// Returns nil for anything whose workflow is not genuinely predictable.
    /// A miss costs one planning call; a confident wrong plan costs the user's
    /// trust, so this refuses far more readily than it guesses.
    static func plan(for request: String) -> BrowserTaskPlan? {
        intent(for: request).flatMap { steps(for: $0).map { BrowserTaskPlan(goal: request, steps: $0) } }
    }

    /// Normalises a request to a reusable shape, or nil if it is not one.
    ///
    /// Separate from planning so the cache can key on the shape while the
    /// parameter varies — "nvidia on wikipedia" and "tesla on wikipedia" are one
    /// cached plan, not two.
    static func intent(for request: String) -> BrowserIntent? {
        let text = request.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        guard !text.isEmpty else { return nil }

        // Anything about the user's own account needs a real page read.
        guard !personalDataMarkers.contains(where: { text.contains($0) }) else { return nil }

        // A literal address is unambiguous whatever the phrasing around it.
        if let url = explicitURL(in: text) {
            return BrowserIntent(shape: "url.open", parameter: url.absoluteString)
        }

        guard let site = BrowserSiteRegistry.site(namedIn: text) else { return nil }

        if let query = searchQuery(in: text, site: site), !query.isEmpty {
            guard site.searchURLTemplate != nil else { return nil }
            return BrowserIntent(shape: "\(site.name).search", parameter: query)
        }

        // "open wikipedia" — a site named, nothing else asked.
        if navigationPrefixes.contains(where: { text.hasPrefix($0) }) {
            let remainder = text
                .replacingOccurrences(of: "the ", with: " ")
                .split(separator: " ")
                .filter { part in !navigationPrefixes.contains(where: { $0.trimmingCharacters(in: .whitespaces) == part }) }
            // Only when the site name is essentially the whole request.
            let words = remainder.filter { word in
                !site.allNames.contains(where: { $0.contains(word) })
            }
            if words.count <= 1 {
                return BrowserIntent(shape: "\(site.name).open", parameter: nil)
            }
        }
        return nil
    }

    /// Turns an intent into steps.
    ///
    /// - Parameter templated: builds the plan with a literal `{query}` where
    ///   the parameter goes, for storing in the cache. A cache that stored the
    ///   concrete URL would return the first caller's results to every later
    ///   one — silently, since the plan still executes perfectly.
    static func steps(for intent: BrowserIntent, templated: Bool = false) -> [BrowserStep]? {
        let parameter = templated ? "{query}" : intent.parameter
        if intent.shape == "url.open" {
            // Never templated: a literal address has no reusable shape.
            guard let raw = intent.parameter, let url = URL(string: raw) else { return nil }
            return [.open(url: url), .read]
        }

        let parts = intent.shape.split(separator: ".")
        guard parts.count == 2,
              let site = BrowserSiteRegistry.sites.first(where: { $0.name == String(parts[0]) })
        else { return nil }

        switch parts[1] {
        case "search":
            guard let query = parameter else { return nil }
            // The placeholder must survive percent-encoding to be findable later.
            let url = templated
                ? site.searchURLTemplate.flatMap { URL(string: $0.replacingOccurrences(of: "{query}", with: "%7Bquery%7D")) }
                : site.searchURL(for: query)
            guard let url else { return nil }
            // Straight to the results URL rather than driving the site's own
            // search box: fewer steps, and no dependence on its markup.
            return [.open(url: url), .read]
        case "open":
            guard let url = site.homeURLValue else { return nil }
            return [.open(url: url), .read]
        default:
            return nil
        }
    }

    // MARK: - Parsing

    /// The search terms, if this is a search of the named site.
    private static func searchQuery(in text: String, site: BrowserSiteDefinition) -> String? {
        guard searchMarkers.contains(where: { text.contains($0) }) || text.hasPrefix(site.name) else {
            return nil
        }

        // "... for <query>" and "... <query> on <site>" are the two reliable
        // shapes. Anything else is phrasing that varies too much to parse
        // without guessing.
        if let range = text.range(of: " for ") {
            return cleaned(String(text[range.upperBound...]), site: site)
        }
        if let range = text.range(of: " on ") {
            let before = String(text[..<range.lowerBound])
            let after = String(text[range.upperBound...])
            // "find X on wikipedia" — the site is after, the query before.
            if site.allNames.contains(where: { after.contains($0) }) {
                return cleaned(before, site: site)
            }
        }
        // "google the weather in boston"
        if let range = text.range(of: site.name) {
            return cleaned(String(text[range.upperBound...]), site: site)
        }
        return nil
    }

    /// Removes the leading verb and the site's own name from a query.
    private static func cleaned(_ raw: String, site: BrowserSiteDefinition) -> String {
        var query = raw.trimmingCharacters(in: .whitespaces)
        for marker in searchMarkers + navigationPrefixes where query.hasPrefix(marker) {
            query = String(query.dropFirst(marker.count))
        }
        for name in site.allNames {
            query = query.replacingOccurrences(of: name, with: " ")
        }
        for filler in ["the ", "a ", "an "] where query.hasPrefix(filler) {
            query = String(query.dropFirst(filler.count))
        }
        return query.trimmingCharacters(in: .whitespaces)
    }

    private static func explicitURL(in text: String) -> URL? {
        for word in text.split(separator: " ") {
            let candidate = String(word).trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
            if candidate.hasPrefix("http"), let url = URL(string: candidate) { return url }
            if candidate.contains("."), !candidate.hasSuffix("."),
               candidate.range(of: "^[a-z0-9.-]+\\.[a-z]{2,}(/.*)?$", options: [.regularExpression]) != nil,
               let url = URL(string: "https://" + candidate) {
                return url
            }
        }
        return nil
    }
}
