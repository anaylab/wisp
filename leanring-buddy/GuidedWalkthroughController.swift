//
//  GuidedWalkthroughController.swift
//  leanring-buddy
//
//  Runs a guided walkthrough: one step marked on screen at a time, a checklist
//  in the notch, and the next step found and marked as the user completes the
//  one before. See GuidedWalkthrough.swift for why only the first step's
//  position comes from the model.
//
//  Two things move it forward, neither of which calls the model:
//  - a click that lands on the marked target (a global mouse-down monitor,
//    which needs no extra permission), and
//  - the user's own Next / Stop in the checklist, for steps that aren't a
//    click (typing a name) or that Wisp couldn't find.
//

import AppKit
import Combine
import SwiftUI

/// Whether Wisp has the current step's target marked on screen.
enum GuidedWalkthroughTargetStatus: Equatable {
    /// Looking at the live screen for it.
    case searching
    /// Marked on screen.
    case located
    /// Not seen after several tries; still looking quietly, but the user is
    /// told they can do the step and tap Next.
    case notFound
}

/// Where the current step's target is drawn, in the units a click is tested in.
struct GuidedWalkthroughTargetLocation {
    let displayFrameInAppKitCoordinates: CGRect
    let screenshotSize: CGSize
    let regionInScreenshotPixels: CGRect
    /// The text of the marked control, for judging whether Wisp may click it.
    let label: String?
    /// False when the match was loose — an OCR line that only partly says what
    /// the step names, which may be text in some other window. Wisp won't click
    /// those for the user; the box still guides them.
    var isConfidentEnoughToClick = true
    /// The app that was in front when the step was marked. A click must land in
    /// a window of this app, or Wisp could end up pressing something in another.
    var expectedApplicationBundleIdentifier: String?
}

@MainActor
final class GuidedWalkthroughSession: ObservableObject {
    @Published private(set) var plan: GuidedWalkthroughPlan?
    @Published private(set) var currentTargetStatus: GuidedWalkthroughTargetStatus = .searching
    /// What the user asked for, kept so a re-plan can say what the steps were for.
    private(set) var originalRequestText: String?
    /// Why "Do it for me" didn't click, shown under the current step.
    @Published private(set) var autoClickNote: String?
    /// Set for a moment after the last step so the checklist can say it's done.
    @Published private(set) var didFinishAllSteps = false

    var currentTargetLocation: GuidedWalkthroughTargetLocation?
    var targetSearchTask: Task<Void, Never>?
    var globalClickMonitor: Any?
    var finishedDismissalTask: Task<Void, Never>?

    var isActive: Bool { plan != nil }

    func begin(with newPlan: GuidedWalkthroughPlan, requestText: String) {
        reset()
        originalRequestText = requestText
        plan = newPlan
        currentTargetStatus = .located
    }

    func updatePlan(_ updatedPlan: GuidedWalkthroughPlan) {
        plan = updatedPlan
        autoClickNote = nil
        // A step marked inside a Chrome page goes with the step.
        ChromeInPagePointing.shared.forgetWalkthroughStep()
    }

    func showAutoClickNote(_ note: String) {
        autoClickNote = note
    }

    func updateTargetStatus(_ newStatus: GuidedWalkthroughTargetStatus) {
        currentTargetStatus = newStatus
    }

    func markAllStepsFinished() {
        didFinishAllSteps = true
    }

    /// Stops everything the walkthrough started and forgets the plan.
    func reset() {
        ChromeInPagePointing.shared.endWalkthrough()
        targetSearchTask?.cancel()
        targetSearchTask = nil
        finishedDismissalTask?.cancel()
        finishedDismissalTask = nil
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
        }
        globalClickMonitor = nil
        currentTargetLocation = nil
        didFinishAllSteps = false
        autoClickNote = nil
        originalRequestText = nil
        plan = nil
        currentTargetStatus = .searching
    }
}

extension CompanionManager {
    /// How long Wisp keeps looking for a step's target before it stops trying
    /// (the user can still tap Next). Menus and panes take a moment to open, and
    /// the target may be below the fold until the user scrolls, so the search
    /// outlasts the first few quick tries — slowly, since each try is a capture
    /// plus OCR.
    private static let guidedStepSearchDurationSeconds: TimeInterval = 300
    private static let guidedStepFirstSearchDelaySeconds: TimeInterval = 0.7
    private static let guidedStepSearchIntervalSeconds: TimeInterval = 0.9
    /// The pace once the checklist has admitted it can't see the target.
    private static let guidedStepSlowSearchIntervalSeconds: TimeInterval = 2.0
    /// Tries before the checklist admits it can't see the target.
    private static let guidedStepAttemptsBeforeAdmittingNotFound = 5
    private static let guidedWalkthroughFinishedLingerSeconds: TimeInterval = 2.5

    // MARK: - Starting and ending

    /// Starts a walkthrough if the reply's annotations are a multi-step one, and
    /// returns whether it did. When it does, only the first step is drawn — the
    /// caller must not also draw the whole set.
    func beginGuidedWalkthrough(
        from annotations: [ScreenAnnotation],
        screenCaptures: [CompanionScreenCapture],
        requestText: String
    ) -> Bool {
        guard !screenCaptures.isEmpty,
              let newPlan = GuidedWalkthroughPlan(annotations: annotations),
              let firstStepAnnotation = annotations
                  .filter({ $0.stepNumber != nil })
                  .min(by: { ($0.stepNumber ?? 0) < ($1.stepNumber ?? 0) }) else {
            return false
        }

        guidedWalkthrough.begin(with: newPlan, requestText: requestText)
        keepOverlayVisibleForGuidedWalkthrough()
        if firstStepAnnotation.isUnplacedWalkthroughStep {
            // A [STEP:] tag has only words, so even the first step is found on
            // the live screen like the rest.
            findCurrentGuidedStepTarget()
        } else {
            applyAnnotations([firstStepAnnotation], from: screenCaptures)
            guidedWalkthrough.currentTargetLocation = locationOfActiveAnnotation()
            moveFirstGuidedStepIntoChromePageIfPossible(firstStepAnnotation: firstStepAnnotation, screenCaptures: screenCaptures)
        }
        startWatchingForGuidedWalkthroughClicks()
        print("🧭 Guided walkthrough: \(newPlan.steps.map(\.instruction).joined(separator: " → "))")
        return true
    }

    /// Ends the walkthrough and takes its marks off the screen.
    func endGuidedWalkthrough() {
        guard guidedWalkthrough.isActive else { return }
        print("🧭 Guided walkthrough ended")
        guidedWalkthrough.reset()
        activeAnnotationsByDisplayFrame.removeAll()
        annotationScreenshotSizeByDisplayFrame.removeAll()
        scheduleTransientHideIfNeeded()
    }

    // MARK: - Moving through the steps

    /// The user did the current step (a click on its target, or Next after
    /// doing it another way).
    func completeGuidedWalkthroughStep() {
        // Not while Wisp is still looking for the step's target: a press then
        // would credit a step the user hasn't seen marked, and repeated presses
        // would race through the list. Once the box is up, or Wisp has said it
        // can't find it, the user's word that they did it is taken.
        guard guidedWalkthrough.currentTargetStatus != .searching else { return }
        advanceGuidedWalkthrough(creditingStep: true)
    }

    /// Move past the current step without crediting it.
    func skipGuidedWalkthroughStep() {
        advanceGuidedWalkthrough(creditingStep: false)
    }

    private func advanceGuidedWalkthrough(creditingStep: Bool) {
        guard var updatedPlan = guidedWalkthrough.plan, !updatedPlan.isFinished else { return }
        print("🧭 Step \(creditingStep ? "done" : "skipped"): \"\(updatedPlan.currentStep?.instruction ?? "")\"")

        if creditingStep {
            updatedPlan.completeCurrentStep()
        } else {
            updatedPlan.skipCurrentStep()
        }
        guidedWalkthrough.updatePlan(updatedPlan)
        guidedWalkthrough.targetSearchTask?.cancel()
        guidedWalkthrough.currentTargetLocation = nil
        // The previous step's mark is stale the moment it's done.
        activeAnnotationsByDisplayFrame.removeAll()
        annotationScreenshotSizeByDisplayFrame.removeAll()

        if updatedPlan.isFinished {
            finishGuidedWalkthrough(completedStepCount: updatedPlan.completedStepCount)
        } else {
            findCurrentGuidedStepTarget()
        }
    }

    private func finishGuidedWalkthrough(completedStepCount: Int) {
        guidedWalkthrough.markAllStepsFinished()
        if completedStepCount > 0 {
            flashIsland(.success)
        }
        guidedWalkthrough.finishedDismissalTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.guidedWalkthroughFinishedLingerSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.endGuidedWalkthrough()
        }
    }

    // MARK: - Finding the next step on the live screen

    /// Looks for the current step's label on the live screen — the Accessibility
    /// tree plus OCR, matched deterministically like "where is X" — and boxes it.
    /// Retries for a while because the screen is usually still changing from the
    /// click that finished the step before.
    func findCurrentGuidedStepTarget() {
        guard let currentStep = guidedWalkthrough.plan?.currentStep,
              let currentStepIndex = guidedWalkthrough.plan?.currentStepIndex else { return }

        let currentStepID = currentStep.id
        let pointingRequest = GuidedWalkthroughTargetText.pointingRequest(forInstruction: currentStep.instruction)
        guidedWalkthrough.updateTargetStatus(.searching)

        guidedWalkthrough.targetSearchTask = Task { [weak self] in
            let searchDeadline = Date().addingTimeInterval(Self.guidedStepSearchDurationSeconds)
            var attemptCount = 0

            while !Task.isCancelled, Date() < searchDeadline {
                let delaySeconds: TimeInterval
                if attemptCount == 0 {
                    delaySeconds = Self.guidedStepFirstSearchDelaySeconds
                } else if attemptCount >= Self.guidedStepAttemptsBeforeAdmittingNotFound {
                    delaySeconds = Self.guidedStepSlowSearchIntervalSeconds
                } else {
                    delaySeconds = Self.guidedStepSearchIntervalSeconds
                }
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                // The user moved on (Next, or a click) while this was waiting.
                guard self.guidedWalkthrough.plan?.currentStep?.id == currentStepID else { return }

                // In Chrome the step is looked for in the page first, where its
                // mark follows the element and its real click finishes it.
                if await self.markCurrentGuidedStepInChromeIfPossible(
                    stepID: currentStepID,
                    stepNumber: currentStepIndex + 1,
                    instruction: currentStep.instruction
                ) { return }
                guard !Task.isCancelled else { return }

                let accessibilityElementSnapshotTask = Task {
                    await AccessibilityElementSnapshotter.captureFrontmostApplicationSnapshot()
                }
                let screenCaptures = (try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()) ?? []
                let accessibilityElementSnapshot = await accessibilityElementSnapshotTask.value
                let screenTextSnapshot = screenCaptures.isEmpty
                    ? nil
                    : await ScreenTextRecognizer.shared.snapshot(
                        for: screenCaptures,
                        waitingAtMost: FastPointingTiming.screenTextWaitBudgetSeconds,
                        maximumLineCount: FastPointingTiming.maximumMatchedScreenTextLineCount,
                        maximumCharacterCount: FastPointingTiming.maximumMatchedScreenTextCharacterCount
                    )
                guard !Task.isCancelled,
                      self.guidedWalkthrough.plan?.currentStep?.id == currentStepID else { return }

                let pointingCandidates = Self.pointingCandidates(
                    accessibilityElementSnapshot: accessibilityElementSnapshot,
                    screenTextSnapshot: screenTextSnapshot,
                    screenCaptures: screenCaptures
                )
                // Near-equal places come back best first (an Accessibility
                // element ahead of OCR text); a step needs just one, so take
                // the top. Capping the matcher at one place instead would make
                // it reject any label that shows up twice as "ambiguous".
                if let bestMatch = PointingTargetMatcher
                    .bestPlaces(for: pointingRequest, among: pointingCandidates)
                    .first {
                    self.markGuidedStepTarget(
                        bestMatch.candidate,
                        targetText: pointingRequest.targetText,
                        stepNumber: currentStepIndex + 1,
                        instruction: currentStep.instruction,
                        screenCaptures: screenCaptures
                    )
                    return
                }

                attemptCount += 1
                if attemptCount == Self.guidedStepAttemptsBeforeAdmittingNotFound {
                    self.guidedWalkthrough.updateTargetStatus(.notFound)
                }
            }
        }
    }

    private func markGuidedStepTarget(
        _ candidate: PointingCandidate,
        targetText: String,
        stepNumber: Int,
        instruction: String,
        screenCaptures: [CompanionScreenCapture]
    ) {
        // A little air around the text so the box doesn't sit on the letters.
        let paddedRegion = candidate.regionInScreenshotPixels.insetBy(dx: -5, dy: -4)
        let stepAnnotation = ScreenAnnotation(
            style: .box,
            regionInScreenshotPixels: paddedRegion,
            label: Self.shortPointingLabel(for: candidate.text),
            screenNumber: candidate.screenNumber,
            stepNumber: stepNumber
        )
        keepOverlayVisibleForGuidedWalkthrough()
        applyAnnotations([stepAnnotation], from: screenCaptures)
        guidedWalkthrough.currentTargetLocation = locationOfActiveAnnotation()
        // A real control (Accessibility) or text that says exactly what the step
        // names is safe to click; an OCR line with extra words is not — it may be
        // a sentence in another window that happens to contain the label.
        let candidateSaysExactlyTheTarget = PointingTargetMatcher.words(in: candidate.text)
            == PointingTargetMatcher.words(in: targetText)
        guidedWalkthrough.currentTargetLocation?.isConfidentEnoughToClick =
            candidate.isAccessibilityElement || candidateSaysExactlyTheTarget
        guidedWalkthrough.updateTargetStatus(.located)
        print("🧭 Step \(stepNumber) found: \"\(instruction)\" → \"\(candidate.text)\"")
    }

    /// The single annotation `applyAnnotations` just placed, as a click-testable
    /// location.
    private func locationOfActiveAnnotation() -> GuidedWalkthroughTargetLocation? {
        guard let (displayFrame, annotationsOnDisplay) = activeAnnotationsByDisplayFrame.first,
              let annotation = annotationsOnDisplay.first,
              let screenshotSize = annotationScreenshotSizeByDisplayFrame[displayFrame] else { return nil }
        return GuidedWalkthroughTargetLocation(
            displayFrameInAppKitCoordinates: displayFrame,
            screenshotSize: screenshotSize,
            regionInScreenshotPixels: annotation.regionInScreenshotPixels,
            label: annotation.label,
            expectedApplicationBundleIdentifier: Self.frontmostExternalApplicationBundleIdentifier()
        )
    }

    // MARK: - Re-planning

    /// The model plans from the one screenshot it saw, so a step can name a
    /// control that isn't where it guessed. This asks again from the screen as it
    /// is now, saying which steps are done and which one can't be found.
    func replanGuidedWalkthrough() {
        guard let plan = guidedWalkthrough.plan,
              let currentStep = plan.currentStep else { return }

        let finishedInstructions = plan.steps
            .filter { $0.status == .done }
            .map(\.instruction)
        var question = "I\u{2019}m following your steps to"
            + " \u{201C}\(guidedWalkthrough.originalRequestText ?? "do this")\u{201D}"
            + " but I can\u{2019}t find \u{201C}\(currentStep.instruction)\u{201D} on my screen."
        if !finishedInstructions.isEmpty {
            question += " I\u{2019}ve already done: \(finishedInstructions.joined(separator: ", "))."
        }
        question += " Looking at my screen now, what are the remaining steps?"
        print("🧭 Re-planning from step \"\(currentStep.instruction)\"")
        // The new answer starts a fresh walkthrough; end this one now so a reply
        // with no steps doesn't leave the old checklist up.
        endGuidedWalkthrough()
        askTypedQuestion(question)
    }

    // MARK: - Doing a step for the user

    /// "Do it for me": Wisp clicks the marked control itself, then moves on.
    /// Pressing the button is the user's consent, but a control whose name
    /// reads as irreversible (Send, Delete, Pay…) is never clicked this way —
    /// the same vocabulary the confirmation floor uses — and Wisp says so.
    func performCurrentGuidedStepForUser() {
        if performCurrentGuidedStepInChromeIfPossible() { return }
        guard guidedWalkthrough.currentTargetStatus == .located,
              let targetLocation = guidedWalkthrough.currentTargetLocation,
              let currentStep = guidedWalkthrough.plan?.currentStep else { return }

        let wordsNamingTheAction = Set(
            PointingTargetMatcher.words(in: currentStep.instruction)
                + PointingTargetMatcher.words(in: targetLocation.label ?? "")
        )
        if ToolCallSafety.namesIrreversibleAction(actionNameWords: wordsNamingTheAction) {
            guidedWalkthrough.showAutoClickNote("That one can\u{2019}t be undone \u{2014} click it yourself.")
            return
        }
        guard targetLocation.isConfidentEnoughToClick else {
            guidedWalkthrough.showAutoClickNote("I\u{2019}m not sure that\u{2019}s the right spot \u{2014} click it yourself.")
            return
        }
        guard AXIsProcessTrusted() else {
            guidedWalkthrough.showAutoClickNote("Wisp needs Accessibility access to click for you.")
            return
        }
        guard let primaryDisplayHeight = NSScreen.screens.first?.frame.height,
              let clickPoint = GuidedWalkthroughAutoClickPoint.quartzGlobalPoint(
                  displayFrameInAppKitCoordinates: targetLocation.displayFrameInAppKitCoordinates,
                  screenshotSize: targetLocation.screenshotSize,
                  regionInScreenshotPixels: targetLocation.regionInScreenshotPixels,
                  primaryDisplayHeight: primaryDisplayHeight
              ) else { return }

        // The window under the click must belong to the app the step was marked
        // in. A box can sit over text that is really in another window.
        if let expectedBundleIdentifier = targetLocation.expectedApplicationBundleIdentifier,
           let windowOwnerBundleIdentifier = Self.bundleIdentifierOfTopmostWindow(atQuartzPoint: clickPoint),
           windowOwnerBundleIdentifier != expectedBundleIdentifier {
            print("🧭 Not clicking: the window there belongs to \(windowOwnerBundleIdentifier), not \(expectedBundleIdentifier)")
            guidedWalkthrough.showAutoClickNote("That spot is in a different app \u{2014} click it yourself.")
            return
        }

        print("🧭 Doing step for the user: \"\(currentStep.instruction)\" at (\(Int(clickPoint.x)), \(Int(clickPoint.y)))")
        // Move on first: it puts the status back to searching, so the click
        // monitor ignores the click Wisp is about to make instead of counting
        // it as a second completion.
        completeGuidedWalkthroughStep()

        // The overlay ignores mouse events, so the click lands on the app below.
        Task {
            for eventType in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                CGEvent(
                    mouseEventSource: nil,
                    mouseType: eventType,
                    mouseCursorPosition: clickPoint,
                    mouseButton: .left
                )?.post(tap: .cghidEventTap)
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
        }
    }

    /// The bundle id of the app the user is working in: the frontmost app, or
    /// the last one before Wisp if Wisp itself is in front.
    private static func frontmostExternalApplicationBundleIdentifier() -> String? {
        if let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           frontmostBundleIdentifier != Bundle.main.bundleIdentifier {
            return frontmostBundleIdentifier
        }
        return FrontmostAppTracker.shared.lastExternalApplication?.bundleIdentifier
    }

    /// The app owning the frontmost ordinary window at a point (Quartz global
    /// coordinates), or nil if there is none — e.g. the menu bar, which has no
    /// ordinary window under it. Menus, the Dock and Wisp's overlays sit on other
    /// layers and are skipped, so only app windows are compared.
    private static func bundleIdentifierOfTopmostWindow(atQuartzPoint point: CGPoint) -> String? {
        guard let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        // The list is ordered front to back.
        for windowInfo in windowInfoList {
            guard let layer = windowInfo[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.contains(point),
                  let ownerProcessID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerProcessID != ProcessInfo.processInfo.processIdentifier else { continue }
            return NSRunningApplication(processIdentifier: ownerProcessID)?.bundleIdentifier
        }
        return nil
    }

    // MARK: - Clicks

    private func startWatchingForGuidedWalkthroughClicks() {
        guard guidedWalkthrough.globalClickMonitor == nil else { return }
        // A global monitor sees clicks in other apps only, never ones on Wisp's
        // own windows — exactly right, since the overlay ignores the mouse.
        guidedWalkthrough.globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            let clickLocation = NSEvent.mouseLocation
            Task { @MainActor in
                self?.handleGuidedWalkthroughClick(at: clickLocation)
            }
        }
    }

    private func handleGuidedWalkthroughClick(at clickLocation: CGPoint) {
        guard guidedWalkthrough.currentTargetStatus == .located,
              let targetLocation = guidedWalkthrough.currentTargetLocation else { return }

        let clickLandedOnTarget = GuidedWalkthroughClickMatcher.clickLandsOnRegion(
            clickLocationInAppKitGlobalPoints: clickLocation,
            displayFrameInAppKitCoordinates: targetLocation.displayFrameInAppKitCoordinates,
            screenshotSize: targetLocation.screenshotSize,
            regionInScreenshotPixels: targetLocation.regionInScreenshotPixels
        )
        if clickLandedOnTarget {
            completeGuidedWalkthroughStep()
        }
    }
}

// MARK: - Checklist in the notch

/// The step list the island shows while a walkthrough runs: finished steps
/// ticked and struck through, the current one lit with a line saying what to do,
/// the rest dim. Next and Stop sit underneath.
struct GuidedWalkthroughChecklistView: View {
    @ObservedObject var guidedWalkthrough: GuidedWalkthroughSession
    let onDoItForMe: () -> Void
    let onReplan: () -> Void
    let onNextStep: () -> Void
    let onStop: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let plan = guidedWalkthrough.plan {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(plan.steps.enumerated()), id: \.element.id) { stepIndex, step in
                        stepRow(step, number: stepIndex + 1)
                    }
                }

                if guidedWalkthrough.didFinishAllSteps {
                    Text("All done.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(WispColor.Island.textSecondary)
                } else {
                    controlRow
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(reduceMotion ? nil : WispMotion.quick, value: plan)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Guided steps")
        }
    }

    private func stepRow(_ step: GuidedWalkthroughStep, number: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            stepMarker(for: step, number: number)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.instruction)
                    .font(.system(size: 12.5, weight: step.status == .current ? .semibold : .regular))
                    .foregroundColor(textColor(for: step))
                    .strikethrough(step.status == .done, color: WispColor.Island.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if step.status == .current && !guidedWalkthrough.didFinishAllSteps {
                    Text(guidedWalkthrough.autoClickNote ?? currentStepHint)
                        .font(.system(size: 11))
                        .foregroundColor(WispColor.Island.textSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private func stepMarker(for step: GuidedWalkthroughStep, number: Int) -> some View {
        switch step.status {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(WispColor.Island.textPrimary)
        case .skipped:
            Image(systemName: "minus.circle")
                .font(.system(size: 14))
                .foregroundColor(WispColor.Island.textTertiary)
        case .current:
            Text("\(number)")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(WispColor.Island.prominentText)
                .frame(width: 16, height: 16)
                .background(Circle().fill(WispColor.Island.prominentFill))
        case .upcoming:
            Text("\(number)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(WispColor.Island.textTertiary)
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(WispColor.Island.separator, lineWidth: 1))
        }
    }

    private func textColor(for step: GuidedWalkthroughStep) -> Color {
        switch step.status {
        case .current: return WispColor.Island.textPrimary
        case .upcoming: return WispColor.Island.textSecondary
        case .done, .skipped: return WispColor.Island.textTertiary
        }
    }

    private var currentStepHint: String {
        switch guidedWalkthrough.currentTargetStatus {
        case .searching: return "Looking for it…"
        case .located: return "Click the highlighted spot."
        case .notFound: return "Can\u{2019}t see it \u{2014} it may be off-screen. Scroll and I\u{2019}ll keep looking, or tap Next."
        }
    }

    private var controlRow: some View {
        HStack(spacing: 8) {
            if guidedWalkthrough.currentTargetStatus == .located {
                Button(action: onDoItForMe) {
                    Text("Do it for me")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(WispIslandButtonStyle(prominence: .prominent))
                .help("Wisp clicks the highlighted spot for you")
            }

            if guidedWalkthrough.currentTargetStatus == .notFound {
                Button(action: onReplan) {
                    Text("Re-plan")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(WispIslandButtonStyle(prominence: .prominent))
                .help("Ask again, from the screen as it is now")
            }

            Button(action: onNextStep) {
                Text("Next")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(WispIslandButtonStyle(prominence: guidedWalkthrough.currentTargetStatus == .searching ? .prominent : .subtle))
            .disabled(guidedWalkthrough.currentTargetStatus == .searching)
            .opacity(guidedWalkthrough.currentTargetStatus == .searching ? 0.4 : 1)
            .help(guidedWalkthrough.currentTargetStatus == .searching
                  ? "Wisp is still looking for this step"
                  : "Done with this step — move on")

            Button(action: onStop) {
                Text("Stop")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(WispIslandButtonStyle(prominence: .subtle))
            .help("End the walkthrough")
        }
    }
}
