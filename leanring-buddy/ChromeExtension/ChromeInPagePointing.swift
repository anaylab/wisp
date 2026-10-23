//
//  ChromeInPagePointing.swift
//  leanring-buddy
//
//  Pointing inside a Chrome page (phase 05). When the thing Wisp points at is
//  in the tab in front of the user, the mark is drawn by the extension inside
//  the page (content/highlight.js), anchored to the element, instead of on the
//  screen overlay — so it stays on the element through scrolling, resizing and
//  zoom, where the overlay's marks are dropped on the first scroll.
//
//  Three users:
//  - fast pointing and a model's `[POINT:]`/`[BOX:]`/`[HIGHLIGHT:]` tags, through
//    `applyPointingAnnotationsPreferringChromePage` (anything that can't be
//    found in the page still goes on the overlay, exactly as before);
//  - the guided walkthrough, which finds each step's element with
//    `findElements`, marks it as a numbered step, finishes the step on the
//    page's real click (`page.elementClicked`) rather than the screen-position
//    matcher, clicks through `clickElement` for "Do it for me", and looks again
//    after a navigation (`nav.completed`);
//  - clearing: a new question, Esc, or the walkthrough ending takes the marks
//    out of the page too.
//
//  The decisions themselves are pure, in ChromeInPagePointingPolicy.swift.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class ChromeInPagePointing {
    static let shared = ChromeInPagePointing()

    private let bridge: ChromeExtensionBridge
    private weak var companionManager: CompanionManager?
    private var extensionEventSubscription: AnyCancellable?

    /// The tab holding plain pointing marks (not a walkthrough step), so Esc
    /// and the next question know there is something to clear.
    private(set) var pointingMarkTabID: Int?
    private var pointingMarkExpiryTask: Task<Void, Never>?

    /// The walkthrough step currently marked in a page, if any.
    private(set) var walkthroughTarget: ChromeInPageWalkthroughTarget?
    /// The tab the walkthrough has been working in. Kept between steps (while
    /// the next step is being looked for), so a navigation there sends Wisp
    /// looking again at once.
    private(set) var walkthroughTabID: Int?

    // The bridge is read inside the (main-actor) body rather than as a default
    // argument, which is evaluated outside the actor.
    init() {
        self.bridge = ChromeExtensionBridge.shared
    }

    // MARK: - Availability

    /// Subscribes to the extension's events once, on first use.
    func attach(to companionManager: CompanionManager) {
        self.companionManager = companionManager
        guard extensionEventSubscription == nil else { return }
        let handledEventNames: Set<String> = ["page.elementClicked", "page.highlightDismissed", "nav.completed"]
        extensionEventSubscription = bridge.extensionEventPublisher
            .filter { handledEventNames.contains($0.eventName) }
            .sink { [weak self] event in
                MainActor.assumeIsolated {
                    self?.handleExtensionEvent(event)
                }
            }
    }

    func decision() -> ChromeInPagePointingDecision {
        let frontmostBundleIdentifier = Self.frontmostExternalApplication()?.bundleIdentifier
        return ChromeInPagePointingPolicy.decision(for: ChromeInPagePointingInputs(
            frontmostApplication: .init(bundleIdentifier: frontmostBundleIdentifier),
            isExtensionConnected: bridge.isExtensionConnected,
            extensionCanReadPages: bridge.hasCapability(.pagesRead),
            activeExtensionBrowserIsFrontmost: bridge.isActiveBrowser(bundleIdentifier: frontmostBundleIdentifier ?? "")
        ))
    }

    var hasPointingMarks: Bool { pointingMarkTabID != nil }

    // MARK: - Talking to the extension

    struct HighlightItem: Encodable {
        let elementId: String
        let kind: String
        let label: String
        let stepNumber: Int?
    }

    private struct FindElementsParameters: Encodable {
        let query: String
        let elementLimit: Int
    }

    private struct FoundElementsReply: Decodable {
        let tabId: Int
        let elements: [ChromeInPageElement]
    }

    private struct HighlightParameters: Encodable {
        let tabId: Int
        let items: [HighlightItem]
        let color: String
        let dismissOnEscape: Bool
    }

    private struct HighlightReply: Decodable {
        let shown: [String]
    }

    private struct TabElementsParameters: Encodable {
        let tabId: Int
        let elementIds: [String]
    }

    private struct ElementParameters: Encodable {
        let tabId: Int
        let elementId: String
    }

    private struct OptionalTabParameters: Encodable {
        let tabId: Int?
    }

    private struct IgnoredReply: Decodable {}

    /// The front tab's elements ranked against the request, or nil when the
    /// extension can't answer in time (a stuck page shouldn't hold the answer;
    /// the overlay is used instead).
    func findElements(matching request: PointingRequest) async -> (tabID: Int, elements: [ChromeInPageElement])? {
        let parameters = FindElementsParameters(
            query: request.targetText,
            elementLimit: ChromeInPagePointingPolicy.findElementLimit
        )
        // The bridge's own timeout bounds the wait (its requests can't be
        // cancelled midway, so a racing timer wouldn't return any sooner).
        let reply = try? await bridge.sendRequest(
            method: "findElements",
            parameters: parameters,
            resultType: FoundElementsReply.self,
            timeoutSeconds: ChromeInPagePointingPolicy.findTimeoutSeconds
        )
        guard let reply else {
            print("👉 In-page pointing: couldn't list the page's elements (not answered in time, or a page Wisp doesn't touch) — using the overlay")
            return nil
        }
        return (reply.tabId, reply.elements)
    }

    /// Draws marks in the tab (replacing what Wisp drew there before) and
    /// returns the ids actually drawn, or nil if the extension refused.
    private func highlight(tabID: Int, items: [HighlightItem], dismissOnEscape: Bool) async -> [String]? {
        do {
            let reply = try await bridge.sendRequest(
                method: "highlightElements",
                parameters: HighlightParameters(
                    tabId: tabID,
                    items: items,
                    color: Self.markerColorCSS(),
                    dismissOnEscape: dismissOnEscape
                ),
                resultType: HighlightReply.self
            )
            return reply.shown
        } catch {
            print("👉 In-page pointing: couldn't draw in the page (\(error.localizedDescription))")
            return nil
        }
    }

    /// Plain pointing marks: drawn, remembered for clearing, and taken away
    /// on their own after a while.
    func showPointingMarks(tabID: Int, items: [HighlightItem]) async -> [String] {
        guard let shownElementIDs = await highlight(tabID: tabID, items: items, dismissOnEscape: true),
              !shownElementIDs.isEmpty else { return [] }
        pointingMarkTabID = tabID
        pointingMarkExpiryTask?.cancel()
        pointingMarkExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ChromeInPagePointingPolicy.pointingMarkLifetimeSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.pointingMarkTabID == tabID, self.walkthroughTarget == nil else { return }
            self.clearMarks()
        }
        return shownElementIDs
    }

    /// A walkthrough step: drawn as a numbered step that Esc in the page
    /// doesn't dismiss (Esc in Wisp doesn't end a walkthrough either, and the
    /// page may use Esc to close its own dialog), with its real clicks watched.
    func showWalkthroughStep(_ target: ChromeInPageWalkthroughTarget, item: HighlightItem) async -> Bool {
        guard let shownElementIDs = await highlight(tabID: target.tabID, items: [item], dismissOnEscape: false),
              shownElementIDs.contains(target.elementID) else { return false }
        pointingMarkExpiryTask?.cancel()
        pointingMarkTabID = nil
        walkthroughTarget = target
        walkthroughTabID = target.tabID
        do {
            _ = try await bridge.sendRequest(
                method: "watchClicks",
                parameters: TabElementsParameters(tabId: target.tabID, elementIds: [target.elementID]),
                resultType: IgnoredReply.self
            )
        } catch {
            // The mark still guides the user; Next still moves on.
            print("👉 In-page pointing: couldn't watch the step's clicks (\(error.localizedDescription))")
        }
        return true
    }

    /// Clicks the element for "Do it for me", through the DOM controller.
    func click(tabID: Int, elementID: String) async {
        do {
            _ = try await bridge.sendRequest(
                method: "clickElement",
                parameters: ElementParameters(tabId: tabID, elementId: elementID),
                resultType: IgnoredReply.self
            )
        } catch {
            print("👉 In-page pointing: the click for the user failed (\(error.localizedDescription))")
        }
    }

    /// Takes every Wisp mark out of the pages and stops watching clicks.
    /// Sends nothing when nothing is marked, so it costs nothing per question.
    func clearMarks() {
        pointingMarkExpiryTask?.cancel()
        pointingMarkExpiryTask = nil
        let hadMarks = pointingMarkTabID != nil || walkthroughTarget != nil
        pointingMarkTabID = nil
        let hadWalkthroughTarget = walkthroughTarget != nil
        walkthroughTarget = nil
        guard hadMarks else { return }
        sendClearRequests(tabID: nil, stopsWatchingClicks: hadWalkthroughTarget)
    }

    /// The walkthrough moved past the marked step: its mark and click watch go.
    func forgetWalkthroughStep() {
        guard let finishedTarget = walkthroughTarget else { return }
        walkthroughTarget = nil
        sendClearRequests(tabID: finishedTarget.tabID, stopsWatchingClicks: true)
    }

    /// The walkthrough is over.
    func endWalkthrough() {
        forgetWalkthroughStep()
        walkthroughTabID = nil
    }

    private func sendClearRequests(tabID: Int?, stopsWatchingClicks: Bool) {
        guard bridge.isExtensionConnected else { return }
        let bridge = self.bridge
        Task {
            _ = try? await bridge.sendRequest(
                method: "clearHighlights",
                parameters: OptionalTabParameters(tabId: tabID),
                resultType: IgnoredReply.self
            )
            if stopsWatchingClicks {
                _ = try? await bridge.sendRequest(
                    method: "stopWatchingClicks",
                    parameters: OptionalTabParameters(tabId: tabID),
                    resultType: IgnoredReply.self
                )
            }
        }
    }

    // MARK: - Events

    private struct ElementClickedPayload: Decodable {
        let tabId: Int
        let elementId: String
    }

    private struct HighlightDismissedPayload: Decodable {
        let tabId: Int
        let elementIds: [String]?
    }

    private struct NavigationCompletedPayload: Decodable {
        let tabId: Int
    }

    private func handleExtensionEvent(_ event: ChromeExtensionEvent) {
        guard let companionManager else { return }
        switch event.eventName {
        case "page.elementClicked":
            guard let clicked = event.decodePayload(as: ElementClickedPayload.self) else { return }
            let walkthrough = companionManager.guidedWalkthrough
            guard walkthrough.currentTargetStatus == .located,
                  ChromeInPageWalkthroughEventPolicy.clickCompletesStep(
                      clickedTabID: clicked.tabId,
                      clickedElementID: clicked.elementId,
                      currentTarget: walkthroughTarget,
                      currentStepID: walkthrough.plan?.currentStep?.id
                  ) else { return }
            print("🧭 Step clicked in the page: \(clicked.elementId)")
            companionManager.completeGuidedWalkthroughStep()

        case "page.highlightDismissed":
            guard let dismissed = event.decodePayload(as: HighlightDismissedPayload.self) else { return }
            if dismissed.tabId == pointingMarkTabID {
                pointingMarkExpiryTask?.cancel()
                pointingMarkTabID = nil
            }
            // Dismissing a step's mark (its label) means "stop showing me this".
            if let walkthroughTarget, walkthroughTarget.tabID == dismissed.tabId,
               (dismissed.elementIds ?? []).contains(walkthroughTarget.elementID) {
                self.walkthroughTarget = nil
                companionManager.endGuidedWalkthrough()
            }

        case "nav.completed":
            guard let navigation = event.decodePayload(as: NavigationCompletedPayload.self) else { return }
            // A page that went away took its marks with it.
            if navigation.tabId == pointingMarkTabID {
                pointingMarkExpiryTask?.cancel()
                pointingMarkTabID = nil
            }
            guard ChromeInPageWalkthroughEventPolicy.navigationRequiresRefind(
                navigatedTabID: navigation.tabId,
                walkthroughTabID: walkthroughTabID
            ) else { return }
            companionManager.refindCurrentGuidedStepAfterChromeNavigation()

        default:
            return
        }
    }

    // MARK: - The browser on screen

    /// The app the user is working in: the frontmost one, or the last one
    /// before Wisp when a typed question brought Wisp to the front.
    static func frontmostExternalApplication() -> NSRunningApplication? {
        if let frontmostApplication = NSWorkspace.shared.frontmostApplication,
           frontmostApplication.bundleIdentifier != Bundle.main.bundleIdentifier {
            return frontmostApplication
        }
        guard let lastExternalBundleIdentifier = FrontmostAppTracker.shared.lastExternalApplication?.bundleIdentifier else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: lastExternalBundleIdentifier).first
    }

    /// The browser's frontmost window, in Quartz global coordinates (origin
    /// top-left of the primary display), or nil when it has none on screen.
    static func frontBrowserWindowBoundsInQuartzCoordinates() -> CGRect? {
        guard let browserProcessID = frontmostExternalApplication()?.processIdentifier,
              let windowInfoList = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID
              ) as? [[String: Any]] else { return nil }
        // Ordered front to back; the first ordinary window is the one in front.
        for windowInfo in windowInfoList {
            guard let ownerProcessID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerProcessID == browserProcessID,
                  let layer = windowInfo[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else { continue }
            return bounds
        }
        return nil
    }

    /// The user's marker colour (Settings → General → Notch), for the page.
    static func markerColorCSS() -> String {
        let markerColor = NSColor(CursorAppearanceStore.shared.color).usingColorSpace(.sRGB) ?? .systemBlue
        return ChromeInPagePointingPolicy.cssColor(
            red: Double(markerColor.redComponent),
            green: Double(markerColor.greenComponent),
            blue: Double(markerColor.blueComponent)
        )
    }
}

// MARK: - Pointing

extension CompanionManager {
    /// Draws pointing annotations (fast pointing, or a reply's tags), putting
    /// each one that names an element of the front Chrome tab into the page
    /// and the rest on the overlay. Outside Chrome, or without the extension,
    /// this is exactly `applyAnnotations`.
    func applyPointingAnnotationsPreferringChromePage(
        _ annotations: [ScreenAnnotation],
        from screenCaptures: [CompanionScreenCapture]
    ) async {
        let inPagePointing = ChromeInPagePointing.shared
        inPagePointing.attach(to: self)
        guard !screenCaptures.isEmpty, case .tryInPage = inPagePointing.decision() else {
            applyAnnotations(annotations, from: screenCaptures)
            return
        }

        let browserWindowBounds = ChromeInPagePointing.frontBrowserWindowBoundsInQuartzCoordinates()
        var foundElementsByQuery: [String: (tabID: Int, elements: [ChromeInPageElement])] = [:]
        var pageTabID: Int?
        var highlightItems: [ChromeInPagePointing.HighlightItem] = []
        var elementIDsByAnnotationID: [UUID: [String]] = [:]

        for annotation in annotations {
            guard let markKind = ChromeInPagePointingPolicy.markKind(
                      for: annotation.style,
                      label: annotation.label,
                      isWalkthroughStep: false
                  ),
                  let label = annotation.label,
                  let pointingRequest = ChromeInPagePointingPolicy.pointingRequest(forAnnotationLabel: label),
                  let annotationPoint = Self.quartzPoint(of: annotation, in: screenCaptures),
                  ChromeInPagePointingPolicy.isPoint(annotationPoint, insideBrowserWindow: browserWindowBounds) else { continue }

            // Several marks often name the same thing (fast pointing's places).
            let foundElements: (tabID: Int, elements: [ChromeInPageElement])
            if let alreadyFound = foundElementsByQuery[pointingRequest.targetText] {
                foundElements = alreadyFound
            } else {
                guard let newlyFound = await inPagePointing.findElements(matching: pointingRequest) else { break }
                foundElementsByQuery[pointingRequest.targetText] = newlyFound
                foundElements = newlyFound
            }
            guard !Task.isCancelled else { return }
            guard pageTabID == nil || pageTabID == foundElements.tabID else { continue }

            let matchedElements = ChromeInPageElementMatcher.bestElements(for: pointingRequest, among: foundElements.elements)
            guard !matchedElements.isEmpty else { continue }
            pageTabID = foundElements.tabID
            elementIDsByAnnotationID[annotation.id] = matchedElements.map(\.id)
            for matchedElement in matchedElements where !highlightItems.contains(where: { $0.elementId == matchedElement.id }) {
                highlightItems.append(ChromeInPagePointing.HighlightItem(
                    elementId: matchedElement.id,
                    kind: markKind.rawValue,
                    label: ChromeInPagePointingPolicy.shortLabel(label),
                    stepNumber: nil
                ))
            }
        }

        var shownElementIDs: Set<String> = []
        if let pageTabID, !highlightItems.isEmpty {
            shownElementIDs = Set(await inPagePointing.showPointingMarks(tabID: pageTabID, items: highlightItems))
        }
        guard !Task.isCancelled else {
            inPagePointing.clearMarks()
            return
        }

        // Whatever didn't make it into the page is drawn as before.
        let overlayAnnotations = annotations.filter { annotation in
            let elementIDs = elementIDsByAnnotationID[annotation.id] ?? []
            return !elementIDs.contains(where: shownElementIDs.contains)
        }
        if overlayAnnotations.count < annotations.count {
            print("👉 In-page pointing: \(annotations.count - overlayAnnotations.count) mark(s) drawn in the chrome page")
        }
        if !overlayAnnotations.isEmpty {
            applyAnnotations(overlayAnnotations, from: screenCaptures)
        }
    }

    /// Where an annotation sits on screen, in Quartz global coordinates — the
    /// same display choice `applyAnnotations` makes.
    private static func quartzPoint(of annotation: ScreenAnnotation, in screenCaptures: [CompanionScreenCapture]) -> CGPoint? {
        let captureIndex: Int
        if let screenNumber = annotation.screenNumber, screenNumber >= 1, screenNumber <= screenCaptures.count {
            captureIndex = screenNumber - 1
        } else {
            captureIndex = screenCaptures.firstIndex(where: \.isCursorScreen) ?? 0
        }
        let screenCapture = screenCaptures[captureIndex]
        guard let primaryDisplayHeight = NSScreen.screens.first?.frame.height else { return nil }
        return GuidedWalkthroughAutoClickPoint.quartzGlobalPoint(
            displayFrameInAppKitCoordinates: screenCapture.displayFrame,
            screenshotSize: CGSize(
                width: CGFloat(screenCapture.screenshotWidthInPixels),
                height: CGFloat(screenCapture.screenshotHeightInPixels)
            ),
            regionInScreenshotPixels: annotation.regionInScreenshotPixels,
            primaryDisplayHeight: primaryDisplayHeight
        )
    }

    /// Takes Wisp's marks out of Chrome pages too (a new question, Esc).
    func clearChromeInPageMarks() {
        ChromeInPagePointing.shared.clearMarks()
    }

    var hasChromeInPagePointingMarks: Bool {
        ChromeInPagePointing.shared.hasPointingMarks
    }
}

// MARK: - Guided walkthrough

extension CompanionManager {
    /// Looks for the current walkthrough step in the front Chrome tab and, if
    /// it is there, marks it in the page as a numbered step and waits for the
    /// real click on it. Returns false (and touches nothing) when Chrome isn't
    /// in front, the extension can't help, or the step isn't on the page, so
    /// the caller goes on to search the screen.
    func markCurrentGuidedStepInChromeIfPossible(
        stepID: UUID,
        stepNumber: Int,
        instruction: String
    ) async -> Bool {
        let inPagePointing = ChromeInPagePointing.shared
        inPagePointing.attach(to: self)
        guard case .tryInPage = inPagePointing.decision() else { return false }

        let pointingRequest = GuidedWalkthroughTargetText.pointingRequest(forInstruction: instruction)
        guard let foundElements = await inPagePointing.findElements(matching: pointingRequest),
              let stepElement = ChromeInPageElementMatcher.bestElements(
                  for: pointingRequest,
                  among: foundElements.elements,
                  maximumCount: 1
              ).first,
              !Task.isCancelled,
              guidedWalkthrough.plan?.currentStep?.id == stepID else { return false }

        let elementLabel = stepElement.label ?? instruction
        let stepTarget = ChromeInPageWalkthroughTarget(
            stepID: stepID,
            tabID: foundElements.tabID,
            elementID: stepElement.id,
            elementLabel: elementLabel
        )
        let didShowStep = await inPagePointing.showWalkthroughStep(
            stepTarget,
            item: ChromeInPagePointing.HighlightItem(
                elementId: stepElement.id,
                kind: ChromeInPageMarkKind.step.rawValue,
                label: ChromeInPagePointingPolicy.shortLabel(elementLabel),
                stepNumber: stepNumber
            )
        )
        guard didShowStep else { return false }
        // The user moved on while the page was being marked.
        guard guidedWalkthrough.plan?.currentStep?.id == stepID else {
            inPagePointing.forgetWalkthroughStep()
            return false
        }

        // The page's mark replaces any overlay mark for this step (step 1 from
        // the model's coordinates), and the screen-position click matcher
        // stands aside: the page reports the click itself.
        activeAnnotationsByDisplayFrame.removeAll()
        annotationScreenshotSizeByDisplayFrame.removeAll()
        guidedWalkthrough.currentTargetLocation = nil
        guidedWalkthrough.updateTargetStatus(.located)
        print("🧭 Step \(stepNumber) found in the chrome page: \"\(instruction)\" → \(stepElement.id) \"\(elementLabel)\"")
        return true
    }

    /// Step 1 of a reply is drawn from the model's coordinates at once; in
    /// Chrome it is then moved into the page if the element is found there.
    func moveFirstGuidedStepIntoChromePageIfPossible(
        firstStepAnnotation: ScreenAnnotation,
        screenCaptures: [CompanionScreenCapture]
    ) {
        guard case .tryInPage = ChromeInPagePointing.shared.decision(),
              let plan = guidedWalkthrough.plan,
              let currentStep = plan.currentStep,
              let currentStepIndex = plan.currentStepIndex,
              let annotationPoint = Self.quartzPoint(of: firstStepAnnotation, in: screenCaptures),
              ChromeInPagePointingPolicy.isPoint(
                  annotationPoint,
                  insideBrowserWindow: ChromeInPagePointing.frontBrowserWindowBoundsInQuartzCoordinates()
              ) else { return }
        Task { [weak self] in
            _ = await self?.markCurrentGuidedStepInChromeIfPossible(
                stepID: currentStep.id,
                stepNumber: currentStepIndex + 1,
                instruction: currentStep.instruction
            )
        }
    }

    /// "Do it for me" for a step marked in the page: clicks it through the
    /// extension. Returns false when the current step isn't in a page, so the
    /// screen path runs instead. The irreversible-action refusal is the same.
    func performCurrentGuidedStepInChromeIfPossible() -> Bool {
        guard let stepTarget = ChromeInPagePointing.shared.walkthroughTarget,
              let currentStep = guidedWalkthrough.plan?.currentStep,
              stepTarget.stepID == currentStep.id else { return false }
        guard guidedWalkthrough.currentTargetStatus == .located else { return true }

        guard ChromeInPageWalkthroughEventPolicy.mayClickForUser(
            instruction: currentStep.instruction,
            elementLabel: stepTarget.elementLabel,
            namesIrreversibleAction: { ToolCallSafety.namesIrreversibleAction(actionNameWords: $0) }
        ) else {
            guidedWalkthrough.showAutoClickNote("That one can\u{2019}t be undone \u{2014} click it yourself.")
            return true
        }

        print("🧭 Doing step for the user in the page: \"\(currentStep.instruction)\" → \(stepTarget.elementID)")
        // Move on first, as the screen path does. The page doesn't count this
        // click anyway: only a person's (trusted) click is reported.
        completeGuidedWalkthroughStep()
        Task {
            await ChromeInPagePointing.shared.click(tabID: stepTarget.tabID, elementID: stepTarget.elementID)
        }
        return true
    }

    /// The walkthrough's tab finished loading a new page: the step's mark (and
    /// the element ids) went with the old one, so look for the current step
    /// again now, rather than at the search's next slow retry.
    func refindCurrentGuidedStepAfterChromeNavigation() {
        guard guidedWalkthrough.isActive,
              !(guidedWalkthrough.plan?.isFinished ?? true) else { return }
        let wasMarkedInPage = ChromeInPagePointing.shared.walkthroughTarget != nil
        // A step marked on the overlay (Chrome's own toolbar, say) isn't affected.
        guard wasMarkedInPage || guidedWalkthrough.currentTargetStatus != .located else { return }
        print("🧭 The page changed — looking for the step again")
        ChromeInPagePointing.shared.forgetWalkthroughStep()
        guidedWalkthrough.targetSearchTask?.cancel()
        guidedWalkthrough.currentTargetLocation = nil
        findCurrentGuidedStepTarget()
    }
}
