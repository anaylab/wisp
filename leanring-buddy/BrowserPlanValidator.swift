//
//  BrowserPlanValidator.swift
//  leanring-buddy
//
//  Turns model-written JSON into a BrowserTaskPlan, or refuses.
//
//  This is the security boundary of the browser agent. Everything downstream —
//  BrowserTaskRunner, BrowserController — executes without further checking,
//  because checking here means it only has to happen once. So the rule is that
//  nothing crosses this line except a fixed set of actions with validated
//  arguments.
//
//  What that rules out is as important as what it allows. The model cannot name
//  an AppleScript to run, cannot supply JavaScript to evaluate, cannot reach a
//  shell, and cannot address an element by CSS selector or coordinate — only by
//  the visible label a person would use, which BrowserController then resolves
//  itself. A plan is a list of intentions, never a script.
//
//  Rejection is cheap and silent failure is not, so this errs heavily toward
//  refusing: an unparseable plan costs one replan, where a plan that half-runs
//  leaves the browser somewhere nobody predicted.
//

import Foundation

enum BrowserPlanValidationError: LocalizedError, Equatable {
    case notJSON
    case missingSteps
    case emptyPlan
    case tooManySteps(count: Int)
    case unknownAction(String)
    case missingArgument(action: String, argument: String)
    case unsupportedURLScheme(String)
    case actionBeforeAnyPage(String)

    var errorDescription: String? {
        switch self {
        case .notJSON:
            return "The plan wasn't valid JSON."
        case .missingSteps:
            return "The plan had no \"steps\" array."
        case .emptyPlan:
            return "The plan had no steps in it."
        case .tooManySteps(let count):
            return "The plan had \(count) steps, which is more than a browser task should need."
        case .unknownAction(let action):
            return "\"\(action)\" isn't an action I can run."
        case .missingArgument(let action, let argument):
            return "The \"\(action)\" step is missing its \"\(argument)\"."
        case .unsupportedURLScheme(let scheme):
            return "\"\(scheme)\" isn't a web address I'll open."
        case .actionBeforeAnyPage(let action):
            return "The plan tries to \(action) before opening any page."
        }
    }
}

enum BrowserPlanValidator {
    /// Ceiling on plan length.
    ///
    /// Long plans are almost always a model looping rather than a genuinely
    /// long task, and every extra step is another chance to act on a page that
    /// has moved on since the plan was written.
    static let maximumSteps = 12

    /// The complete set of actions a plan may contain. Anything else is refused.
    private static let allowedActions: Set<String> = [
        "open_url", "navigate", "read_page", "find", "click",
        "type", "scroll", "back", "forward",
    ]

    /// Parses and validates model output into an executable plan.
    ///
    /// Tolerant about *where* the JSON is — models wrap it in prose and code
    /// fences — and strict about what it contains once found.
    /// - Parameter continuesFromCurrentPage: True when revising after a
    ///   failure. A replan legitimately starts with a click or a type, because
    ///   the browser is already sitting on the page it failed on — requiring
    ///   open_url there rejects every sensible correction and burns the replan
    ///   budget on a rule that only makes sense for a first attempt.
    static func plan(
        from modelOutput: String,
        goal: String,
        continuesFromCurrentPage: Bool = false
    ) throws -> BrowserTaskPlan {
        guard let jsonText = extractJSONObject(from: modelOutput),
              let data = jsonText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw BrowserPlanValidationError.notJSON }

        guard let rawSteps = root["steps"] as? [[String: Any]] else {
            throw BrowserPlanValidationError.missingSteps
        }
        guard !rawSteps.isEmpty else { throw BrowserPlanValidationError.emptyPlan }
        guard rawSteps.count <= maximumSteps else {
            throw BrowserPlanValidationError.tooManySteps(count: rawSteps.count)
        }

        var steps: [BrowserStep] = []
        var hasOpenedAPage = continuesFromCurrentPage
        // `find` sets a target that the following `click` or `type` consumes.
        // Models produce that pair naturally, and collapsing it here means the
        // executor never carries selection state between steps.
        var pendingFindTarget: String?

        for rawStep in rawSteps {
            guard let action = (rawStep["action"] as? String)?.lowercased() else {
                throw BrowserPlanValidationError.missingArgument(action: "step", argument: "action")
            }
            guard allowedActions.contains(action) else {
                throw BrowserPlanValidationError.unknownAction(action)
            }

            switch action {
            case "open_url", "navigate":
                guard let urlString = rawStep["url"] as? String, !urlString.isEmpty else {
                    throw BrowserPlanValidationError.missingArgument(action: action, argument: "url")
                }
                let url = try validatedURL(from: urlString)
                steps.append(action == "open_url" ? .open(url: url) : .navigate(url: url))
                hasOpenedAPage = true

            case "read_page":
                steps.append(.read)

            case "find":
                // Not an action by itself. Held for the step that uses it.
                guard let target = rawStep["target"] as? String, !target.isEmpty else {
                    throw BrowserPlanValidationError.missingArgument(action: "find", argument: "target")
                }
                pendingFindTarget = cleanedTarget(target)

            case "click":
                let target = (rawStep["target"] as? String).map(cleanedTarget) ?? pendingFindTarget
                guard let target, !target.isEmpty else {
                    throw BrowserPlanValidationError.missingArgument(action: "click", argument: "target")
                }
                guard hasOpenedAPage else {
                    throw BrowserPlanValidationError.actionBeforeAnyPage("click")
                }
                pendingFindTarget = nil
                steps.append(.clickMatching(query: target))

            case "type":
                guard let text = rawStep["text"] as? String else {
                    throw BrowserPlanValidationError.missingArgument(action: "type", argument: "text")
                }
                let target = (rawStep["target"] as? String).map(cleanedTarget) ?? pendingFindTarget ?? "search"
                guard hasOpenedAPage else {
                    throw BrowserPlanValidationError.actionBeforeAnyPage("type")
                }
                pendingFindTarget = nil
                let submit = (rawStep["submit"] as? Bool) ?? true
                steps.append(.typeInto(fieldQuery: target, text: text, submit: submit))

            case "scroll":
                let raw = (rawStep["direction"] as? String)?.lowercased() ?? "down"
                let direction = BrowserScrollDirection(rawValue: raw) ?? .down
                steps.append(.scroll(direction))

            case "back":
                steps.append(.back)

            case "forward":
                steps.append(.forward)

            default:
                throw BrowserPlanValidationError.unknownAction(action)
            }
        }

        guard !steps.isEmpty else { throw BrowserPlanValidationError.emptyPlan }

        // Always finish by reading, so the caller has page state to answer from
        // without the plan having had to remember to ask for it.
        if steps.last != .read { steps.append(.read) }

        return BrowserTaskPlan(goal: goal, steps: steps)
    }

    /// Strips role annotations from a target.
    ///
    /// Failure context shows the model the page as `Search [textbox]`, and it
    /// sensibly copies that string back as the target — which then matches
    /// nothing, because the element's actual label is just "Search". Trimming
    /// the bracketed part is what makes a replan land on the element it named.
    private static func cleanedTarget(_ target: String) -> String {
        let withoutRole = target.replacingOccurrences(
            of: "\\s*\\[[^\\]]*\\]", with: "", options: .regularExpression
        )
        return withoutRole.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Argument validation

    /// Only ordinary web addresses.
    ///
    /// Rejecting other schemes matters more than it looks: file:// would turn a
    /// browser plan into a local file reader, and javascript: would turn the
    /// url field into the arbitrary-code channel this whole type exists to
    /// prevent.
    private static func validatedURL(from string: String) throws -> URL {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed

        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased() else {
            throw BrowserPlanValidationError.unsupportedURLScheme(trimmed)
        }
        guard scheme == "http" || scheme == "https" else {
            throw BrowserPlanValidationError.unsupportedURLScheme(scheme)
        }
        guard url.host()?.contains(".") == true else {
            throw BrowserPlanValidationError.unsupportedURLScheme(trimmed)
        }
        return url
    }

    /// Pulls the first balanced JSON object out of model prose.
    private static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }

        var depth = 0
        var isInsideString = false
        var isEscaped = false
        var index = start

        while index < text.endIndex {
            let character = text[index]
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                isInsideString.toggle()
            } else if !isInsideString {
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 { return String(text[start...index]) }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
