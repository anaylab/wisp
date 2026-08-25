//
//  BrowserController.swift
//  leanring-buddy
//
//  Deterministic browser control, deliberately without the vision model.
//
//  A screenshot of a web page costs 6.4 seconds of prompt evaluation on this
//  machine and yields pixel coordinates the model has to guess at. The same
//  page read through the DOM costs a few hundred milliseconds and yields the
//  actual elements, with their real labels and a handle that can be clicked
//  exactly. For anything the DOM can answer, vision is both slower and worse.
//
//  So the contract here is built around *element handles* rather than
//  coordinates. A snapshot assigns every interactive element a stable id; the
//  model then says "click e7", not "click at 412, 380". That removes visual
//  grounding from the loop entirely for ordinary browsing, and leaves vision
//  as the fallback for the genuine cases — canvas, video, an image with no
//  accessible text.
//
//  Vision stays available. This is not a replacement for it, it is a way of
//  not paying for it when the page can simply be read.
//

import Foundation

// MARK: - Types

/// One interactive thing on the page.
struct BrowserElement: Sendable, Identifiable {
    /// Stable within a snapshot. What actions refer to.
    let id: String
    /// "button", "link", "textbox", "checkbox"…
    let role: String
    /// What a person would call it: visible text, aria-label, placeholder.
    let label: String
    /// Present for links, so the agent can decide without clicking.
    let href: String?
    /// Current value, for inputs.
    let value: String?
}

/// A page, described in text rather than pixels.
struct BrowserPageSnapshot: Sendable {
    let url: String
    let title: String
    let headings: [String]
    let elements: [BrowserElement]
    /// Main readable content, already truncated.
    let text: String

    /// Compact rendering for a model prompt.
    ///
    /// Token budget is the binding constraint: this competes with the same
    /// context an image would have occupied, and the whole point is to be
    /// dramatically cheaper. Elements are one line each and the body text is
    /// capped by the caller.
    func promptRepresentation() -> String {
        var lines: [String] = ["PAGE: \(title)", "URL: \(url)"]

        if !headings.isEmpty {
            lines.append("HEADINGS: " + headings.prefix(8).joined(separator: " | "))
        }

        if !elements.isEmpty {
            lines.append("INTERACTIVE ELEMENTS (refer to these by id):")
            for element in elements {
                var line = "  \(element.id) [\(element.role)] \(element.label)"
                if let value = element.value, !value.isEmpty { line += " (value: \(value))" }
                lines.append(line)
            }
        }

        if !text.isEmpty {
            lines.append("TEXT:")
            lines.append(text)
        }
        return lines.joined(separator: "\n")
    }
}

enum BrowserScrollDirection: String, Sendable {
    case up, down, top, bottom
}

/// Why the browser cannot be driven, when it cannot.
enum BrowserAvailability: Sendable, Equatable {
    case ready(browserName: String)
    case notRunning(browserName: String)
    /// The one that actually bites: both Chrome and Safari ship with
    /// JavaScript-from-Apple-Events disabled, and it is a setting only the user
    /// can turn on.
    case javaScriptFromAppleEventsDisabled(browserName: String, instructions: String)
    case noSupportedBrowser

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

enum BrowserControllerError: LocalizedError {
    case unavailable(BrowserAvailability)
    case scriptFailed(String)
    case elementNotFound(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let availability):
            if case .javaScriptFromAppleEventsDisabled(_, let instructions) = availability {
                return instructions
            }
            return "The browser isn't available to control right now."
        case .scriptFailed(let detail): return detail
        case .elementNotFound(let id): return "No element \(id) on the page any more."
        }
    }
}

// MARK: - Protocol

/// The operations an agent needs, none of which require a model.
@MainActor
protocol BrowserController: AnyObject {
    var browserName: String { get }

    func checkAvailability() -> BrowserAvailability

    func openURL(_ url: URL) throws
    /// Points the current tab at `url`, rather than opening a new one.
    func navigate(to url: URL) throws
    func goBack() throws
    func goForward() throws

    func currentURL() throws -> String
    func pageTitle() throws -> String

    /// Reads the page as structured text. The replacement for a screenshot.
    func snapshot(maximumTextCharacters: Int) throws -> BrowserPageSnapshot

    /// Finds elements whose label matches `query`, best match first.
    ///
    /// Returns candidates rather than one answer: "login" legitimately matches
    /// a button and a link on many pages, and picking silently would hide that
    /// from the caller who has to live with the click.
    func findElements(matching query: String) throws -> [BrowserElement]

    func click(elementID: String) throws
    func typeText(_ text: String, intoElementID: String, pressEnter: Bool) throws
    func scroll(_ direction: BrowserScrollDirection) throws

    /// Chooses an option in a `<select>` by visible text.
    func selectOption(_ optionLabel: String, inElementID elementID: String) throws

    /// A screenshot of the page, for the cases the DOM genuinely cannot answer.
    ///
    /// Present so vision remains reachable as a deliberate fallback rather than
    /// the default. Everything above should be tried first.
    func captureScreenshot() async throws -> Data
}
