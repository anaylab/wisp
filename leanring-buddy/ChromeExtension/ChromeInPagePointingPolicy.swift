//
//  ChromeInPagePointingPolicy.swift
//  leanring-buddy
//
//  The pure rules behind pointing inside a Chrome page (phase 05): when a mark
//  Wisp is about to draw goes into the page instead of onto the screen
//  overlay, which page element a pointing target or walkthrough step means,
//  and which extension events move a walkthrough on.
//
//  Why in-page at all: the overlay's marks are pinned to screen positions, so
//  Wisp drops them the moment the content under them scrolls. A mark drawn by
//  the extension (content/highlight.js) is anchored to the element and follows
//  it through scrolling, resizing and zoom, and a walkthrough step can finish on
//  the page's real click event instead of a screen-position guess.
//
//  Foundation + CoreGraphics only, so `Tests/ChromeExtInPagePointing` compiles
//  it with FastPointing.swift and GuidedWalkthrough.swift; the bridge calls and
//  the CompanionManager glue live in ChromeInPagePointing.swift.
//

import CoreGraphics
import Foundation

/// How a mark looks in the page; the wire values `highlightElements` takes.
nonisolated enum ChromeInPageMarkKind: String, Equatable, Sendable {
    /// A pulsing outline ("here it is"), from a `[POINT:]` or fast pointing.
    case ring
    /// A steady outline, from a `[BOX:]`.
    case box
    /// A translucent band, from a `[HIGHLIGHT:]`.
    case highlight
    /// A numbered outline for a guided walkthrough step.
    case step
}

/// One element a `findElements` query returned (the DOM controller's shape).
nonisolated struct ChromeInPageElement: Decodable, Equatable, Sendable {
    /// `e7`, or `f12e3` in a cross-origin frame.
    let id: String
    let role: String?
    let label: String?
}

/// Everything the in-page route needs to know about the browser right now.
nonisolated struct ChromeInPagePointingInputs: Equatable, Sendable {
    let frontmostApplication: BrowserControllerSelectionInputs.FrontmostApplication
    let isExtensionConnected: Bool
    let extensionCanReadPages: Bool
}

nonisolated enum ChromeInPagePointingDecision: Equatable, Sendable {
    /// Ask the extension for the element and draw in the page.
    case tryInPage
    /// Keep the screen overlay, and why (for the log).
    case useOverlay(reason: String)
}

nonisolated enum ChromeInPagePointingPolicy {
    /// How many elements a `findElements` query ranks: far past the snapshot's
    /// default 25, since the target can be any control near the view.
    static let findElementLimit = 150
    /// Most page elements marked for one pointing target, matching fast
    /// pointing's limit for the screen.
    static let maximumMarkedElements = 3
    /// How long a plain pointing mark stays in the page. Longer than the
    /// overlay's few seconds because it follows the element, so it can't end up
    /// over the wrong thing; walkthrough steps stay until the step is done.
    static let pointingMarkLifetimeSeconds: TimeInterval = 15
    /// How long Wisp waits for the extension before drawing on the overlay
    /// after all. A snapshot is ~50–200ms; a stuck page shouldn't hold the answer.
    static let findTimeoutSeconds: TimeInterval = 2
    /// Longest label shown beside an in-page mark.
    static let maximumLabelCharacters = 40

    /// Whether to try the page at all. Only Chrome (or another Chromium
    /// browser the extension runs in) in front, the extension connected, and
    /// allowed to read pages — otherwise the overlay, exactly as before.
    static func decision(for inputs: ChromeInPagePointingInputs) -> ChromeInPagePointingDecision {
        guard inputs.frontmostApplication == .chromiumBrowser else {
            return .useOverlay(reason: "chrome isn't in front")
        }
        guard inputs.isExtensionConnected else {
            return .useOverlay(reason: "the chrome extension isn't connected")
        }
        guard inputs.extensionCanReadPages else {
            return .useOverlay(reason: "the chrome extension can't read pages yet")
        }
        return .tryInPage
    }

    /// The in-page look for an annotation, or nil when it stays on the overlay:
    /// arrows, circles and handwritten notes have no in-page form, and a mark
    /// with no label gives nothing to find the element by.
    static func markKind(for style: ScreenAnnotation.Style, label: String?, isWalkthroughStep: Bool) -> ChromeInPageMarkKind? {
        guard let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if isWalkthroughStep { return .step }
        switch style {
        case .marker: return .ring
        case .box: return .box
        case .highlight: return .highlight
        case .arrow, .circle, .note: return nil
        }
    }

    /// What to look for in the page for a mark's label. A model's label is
    /// often an instruction ("click the Settings button"), so it is read the
    /// way a walkthrough step is: filler verbs and location clauses dropped, a
    /// role word kept as the tie-breaking hint. Nil when nothing is left.
    static func pointingRequest(forAnnotationLabel label: String) -> PointingRequest? {
        let request = GuidedWalkthroughTargetText.pointingRequest(forInstruction: label)
        return PointingTargetMatcher.words(in: request.targetText).isEmpty ? nil : request
    }

    /// Whether a point Wisp was going to mark (Quartz global coordinates)
    /// lies in the browser's front window. A target elsewhere — the Dock, the
    /// menu bar, another app's window beside Chrome — is never moved into the
    /// page just because the page happens to have a control of the same name.
    static func isPoint(_ pointInQuartzCoordinates: CGPoint, insideBrowserWindow browserWindowBoundsInQuartzCoordinates: CGRect?) -> Bool {
        guard let browserWindowBoundsInQuartzCoordinates else { return false }
        return browserWindowBoundsInQuartzCoordinates.contains(pointInQuartzCoordinates)
    }

    /// The label shown beside the mark: short, one line.
    static func shortLabel(_ label: String) -> String {
        let collapsed = label.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > maximumLabelCharacters else { return collapsed }
        return String(collapsed.prefix(maximumLabelCharacters - 1)) + "\u{2026}"
    }

    /// The user's marker colour as CSS for the extension, from sRGB
    /// components 0…1. The colour itself comes from `CursorAppearanceStore`.
    static func cssColor(red: Double, green: Double, blue: Double) -> String {
        func channel(_ component: Double) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
        return "rgb(\(channel(red)), \(channel(green)), \(channel(blue)))"
    }
}

// MARK: - Which element a target means

/// Picks the page element a pointing target or walkthrough step names, from the
/// candidates `findElements` ranked. Uses fast pointing's own word scoring
/// (every target word present, least unexplained text wins, a role word breaks
/// ties), so "where is settings" means the same thing on the page as on the
/// screen. Declines rather than guesses: nothing confident → no element, and
/// the caller falls back to the overlay.
nonisolated enum ChromeInPageElementMatcher {
    /// Matches within this of the best count as the same answer ("Settings" in
    /// the header and the footer are both right).
    static let equalMatchTolerance = 0.05

    static func bestElements(
        for request: PointingRequest,
        among elements: [ChromeInPageElement],
        maximumCount: Int = ChromeInPagePointingPolicy.maximumMarkedElements
    ) -> [ChromeInPageElement] {
        let targetWords = PointingTargetMatcher.words(in: request.targetText)
        guard !targetWords.isEmpty, maximumCount > 0 else { return [] }

        // Page elements are real controls, so they score like Accessibility
        // elements (role bonus included). Their region is irrelevant here.
        let scoredElements = elements.enumerated().compactMap { elementIndex, element -> (element: ChromeInPageElement, score: Double, order: Int)? in
            let label = element.label ?? ""
            guard !label.isEmpty, label != "(unlabelled)" else { return nil }
            let candidate = PointingCandidate(
                elementID: element.id,
                text: label,
                accessibilityRoleName: normalizedRoleName(element.role),
                regionInScreenshotPixels: .zero,
                screenNumber: 1
            )
            guard let score = PointingTargetMatcher.score(targetWords: targetWords, roleHint: request.roleHint, candidate: candidate),
                  score >= PointingTargetMatcher.minimumConfidentScore else { return nil }
            return (element, score, elementIndex)
        }
        guard let bestScore = scoredElements.map(\.score).max() else { return [] }

        // The snapshot lists a dialog's elements first, then what's in view,
        // then below; equal matches keep that order, so the first is the one
        // the user is most likely looking at.
        let equalMatches = scoredElements
            .filter { bestScore - $0.score <= equalMatchTolerance }
            .sorted { $0.order < $1.order }
            .map(\.element)
        // A label on the page more times than can be marked (a column of
        // "Edit" links) isn't an answer.
        guard equalMatches.count <= maximumCount else { return [] }
        return equalMatches
    }

    /// `textbox:email` → `textbox`, so a spoken "field"/"box" hint still
    /// lines up with the page's role names the way it does with Accessibility's.
    private static func normalizedRoleName(_ role: String?) -> String {
        let roleName = (role ?? "control").split(separator: ":").first.map(String.init) ?? "control"
        switch roleName {
        case "textbox", "searchbox", "combobox": return "\(roleName) field box"
        default: return roleName
        }
    }
}

// MARK: - Walkthrough events

/// A walkthrough step currently marked in a page.
nonisolated struct ChromeInPageWalkthroughTarget: Equatable, Sendable {
    let stepID: UUID
    let tabID: Int
    let elementID: String
    /// The element's own label, for judging whether Wisp may click it.
    let elementLabel: String
}

nonisolated enum ChromeInPageWalkthroughEventPolicy {
    /// Whether a `page.elementClicked` finishes the current step: the click
    /// must be on the very element marked for that step, in its tab.
    static func clickCompletesStep(
        clickedTabID: Int,
        clickedElementID: String,
        currentTarget: ChromeInPageWalkthroughTarget?,
        currentStepID: UUID?
    ) -> Bool {
        guard let currentTarget, let currentStepID else { return false }
        return currentTarget.stepID == currentStepID
            && currentTarget.tabID == clickedTabID
            && currentTarget.elementID == clickedElementID
    }

    /// Whether a finished navigation should send Wisp looking for the current
    /// step again: it happened in the tab the walkthrough is working in, so the
    /// old page's mark (and element ids) are gone with it.
    static func navigationRequiresRefind(navigatedTabID: Int, walkthroughTabID: Int?) -> Bool {
        guard let walkthroughTabID else { return false }
        return navigatedTabID == walkthroughTabID
    }

    /// Whether Wisp may click the step for the user ("Do it for me"): never a
    /// control whose label or the step's instruction reads as irreversible
    /// (Send, Delete, Pay…) — the same floor the confirmation card uses.
    static func mayClickForUser(
        instruction: String,
        elementLabel: String,
        namesIrreversibleAction: (Set<String>) -> Bool
    ) -> Bool {
        let wordsNamingTheAction = Set(
            PointingTargetMatcher.words(in: instruction) + PointingTargetMatcher.words(in: elementLabel)
        )
        return !namesIrreversibleAction(wordsNamingTheAction)
    }
}
