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
    /// Short state flags a person would see — "checked", "disabled",
    /// "expanded", "selected" — joined by commas, or nil when there are none.
    /// Without these a multi-step agent cannot tell whether its last click on a
    /// checkbox or a disclosure actually took.
    let state: String?
    /// A password or payment-card field. The agent never types into one:
    /// credentials and card numbers are the user's to enter, not the model's.
    let isSensitiveInput: Bool

    init(
        id: String,
        role: String,
        label: String,
        href: String?,
        value: String?,
        state: String? = nil,
        isSensitiveInput: Bool = false
    ) {
        self.id = id
        self.role = role
        self.label = label
        self.href = href
        self.value = value
        self.state = state
        self.isSensitiveInput = isSensitiveInput
    }
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
                if let state = element.state, !state.isEmpty { line += " {\(state)}" }
                if element.isSensitiveInput { line += " {sensitive — user only}" }
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

/// A tab the user had open, named the way they would name it.
struct BrowserTabDescription: Sendable, Equatable {
    let url: String
    let title: String
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
    /// The tab a browser task was working in went away mid-task.
    case dedicatedTabClosed

    var errorDescription: String? {
        switch self {
        case .unavailable(let availability):
            if case .javaScriptFromAppleEventsDisabled(_, let instructions) = availability {
                return instructions
            }
            return "The browser isn't available to control right now."
        case .scriptFailed(let detail): return detail
        case .elementNotFound(let id): return "No element \(id) on the page any more."
        case .dedicatedTabClosed: return "The tab Wisp was working in was closed, so it stopped."
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
    ///
    /// `elementLimit` is a budget, not a filter: elements in the viewport are
    /// listed first, so a small budget still covers what the user can see.
    /// Element ids are stable across snapshots of the same page, so an id the
    /// agent saw one step ago still means the same element now.
    func snapshot(maximumTextCharacters: Int, elementLimit: Int) throws -> BrowserPageSnapshot

    /// Finds elements whose label matches `query`, best match first.
    ///
    /// Returns candidates rather than one answer: "login" legitimately matches
    /// a button and a link on many pages, and picking silently would hide that
    /// from the caller who has to live with the click.
    func findElements(matching query: String) throws -> [BrowserElement]

    func click(elementID: String) throws
    func typeText(_ text: String, intoElementID: String, pressEnter: Bool) throws
    /// Moves the pointer over an element, for menus that only open on hover.
    func hover(elementID: String) throws
    /// Sends one key to whatever has focus: "Enter", "Escape", "Tab",
    /// "ArrowDown", "ArrowUp", "Backspace"… Closing a modal or stepping through
    /// an autocomplete list needs these; a click alone cannot do it.
    func pressKey(_ keyName: String) throws
    func scroll(_ direction: BrowserScrollDirection) throws

    /// Chooses an option in a `<select>` by visible text.
    func selectOption(_ optionLabel: String, inElementID elementID: String) throws

    /// Blocks until the page has finished loading, or the deadline passes.
    ///
    /// Every step after a navigation depends on this. Without it a snapshot
    /// reads the outgoing page and a click lands on an element that is about
    /// to be replaced — the kind of failure that looks like flakiness rather
    /// than a missing wait.
    func waitUntilLoaded(timeout: TimeInterval) async -> Bool

    /// Waits for the page to load *and then stop changing*.
    ///
    /// `readyState` says nothing about a single-page app, which is "complete"
    /// from the first paint while it goes on fetching and re-rendering. Reading
    /// such a page straight after a click snapshots the spinner. This waits
    /// until the DOM has been quiet for a moment, which is what a person does
    /// by eye.
    func waitUntilSettled(timeout: TimeInterval) async -> Bool

    /// A screenshot of the page, for the cases the DOM genuinely cannot answer.
    ///
    /// Present so vision remains reachable as a deliberate fallback rather than
    /// the default. Everything above should be tried first.
    func captureScreenshot() async throws -> Data

    /// Where an element sits on screen, so the cursor overlay can be flown to it.
    ///
    /// Returns the element's centre in global AppKit coordinates (bottom-left
    /// origin) together with the frame of the display it is on. Nil when the
    /// element cannot be placed — scrolled out of the viewport, in a cross-origin
    /// frame, or gone. This is purely for the watching user; nothing depends on
    /// it to actually click, so a nil answer is a missing animation, not a
    /// missing action.
    func screenPoint(ofElementID elementID: String) throws -> (point: CGPoint, displayFrame: CGRect)?

    /// Opens a tab of Wisp's own (or reuses the one from the last task) and
    /// points every operation at it until `endDedicatedTabSession`.
    ///
    /// A browser task never drives the tab the user is reading: it works in its
    /// own, so the user can keep browsing — and so an agent mistake can never
    /// land on a page the user had open. Returns the page the user was looking
    /// at when the task began, so a request about "this page" can still reach it.
    func beginDedicatedTabSession() async throws -> BrowserTabDescription?

    /// Points operations back at the user's front tab. The working tab stays
    /// open, holding the result, and is reused by the next task.
    func endDedicatedTabSession()

    /// Brings the working tab to the front, for the one action that needs it
    /// visible: a screenshot.
    func revealDedicatedTab()
}

extension BrowserController {
    /// Default page budget for callers that do not care.
    ///
    /// Protocol requirements cannot carry default arguments, so this exists to
    /// keep every call site from having to restate a number whose value is
    /// argued for in one place — and whose whole point is that it stays small.
    func snapshot() throws -> BrowserPageSnapshot {
        try snapshot(maximumTextCharacters: AppleScriptBrowserController.defaultTextCharacterLimit)
    }

    func snapshot(maximumTextCharacters: Int) throws -> BrowserPageSnapshot {
        try snapshot(
            maximumTextCharacters: maximumTextCharacters,
            elementLimit: AppleScriptBrowserController.defaultElementLimit
        )
    }

    func waitUntilSettled() async -> Bool {
        await waitUntilSettled(timeout: 8)
    }

    func waitUntilLoaded() async -> Bool {
        await waitUntilLoaded(timeout: 10)
    }

    /// Controllers without tabs of their own act wherever they already act.
    func beginDedicatedTabSession() async throws -> BrowserTabDescription? { nil }
    func endDedicatedTabSession() {}
    func revealDedicatedTab() {}

    /// Controllers that cannot place an element on screen simply do not animate.
    func screenPoint(ofElementID elementID: String) throws -> (point: CGPoint, displayFrame: CGRect)? {
        nil
    }
}

// MARK: - Load readiness

/// Decides whether a page that was just asked to navigate has actually been
/// replaced and finished loading.
///
/// `document.readyState` alone is not enough: for a moment after a navigation
/// is requested the browser still holds the *outgoing* document, and that one
/// reports "complete". Waiting on it returns at once, and the snapshot taken
/// next reads the page that was there before (a blank tab, a dashboard) while
/// the task goes on to claim success. The outgoing document is therefore
/// tagged before the action, and a navigation only counts as arrived once the
/// document no longer carries the tag.
enum BrowserLoadReadiness {
    /// How long a click or a submitted form is given to replace the document.
    /// Most clicks never navigate (menus, toggles), so this only bounds the
    /// extra wait they cost; a direct navigation waits for the full timeout.
    static let maximumWaitForClickedNavigationSeconds: TimeInterval = 2

    /// - Parameters:
    ///   - readyState: `document.readyState` of the current document; nil when
    ///     the page can't be scripted yet (still being created).
    ///   - outgoingDocumentStillShowing: the document still carries the tag put
    ///     on it before the navigation was triggered.
    ///   - expectsNavigation: an action that may have navigated was just taken.
    ///   - secondsWaitedForReplacement: time spent since that action.
    ///   - maximumWaitForReplacementSeconds: how long to wait for the document
    ///     to be replaced before deciding no navigation happened (a same-page
    ///     update).
    static func isLoaded(
        readyState: String?,
        outgoingDocumentStillShowing: Bool,
        expectsNavigation: Bool,
        secondsWaitedForReplacement: TimeInterval,
        maximumWaitForReplacementSeconds: TimeInterval
    ) -> Bool {
        guard readyState == "complete" else { return false }
        guard expectsNavigation, outgoingDocumentStillShowing else { return true }
        return secondsWaitedForReplacement >= maximumWaitForReplacementSeconds
    }
}
