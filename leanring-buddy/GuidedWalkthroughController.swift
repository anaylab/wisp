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
}

@MainActor
final class GuidedWalkthroughSession: ObservableObject {
    @Published private(set) var plan: GuidedWalkthroughPlan?
    @Published private(set) var currentTargetStatus: GuidedWalkthroughTargetStatus = .searching
    /// Set for a moment after the last step so the checklist can say it's done.
    @Published private(set) var didFinishAllSteps = false

    var currentTargetLocation: GuidedWalkthroughTargetLocation?
    var targetSearchTask: Task<Void, Never>?
    var globalClickMonitor: Any?
    var finishedDismissalTask: Task<Void, Never>?

    var isActive: Bool { plan != nil }

    func begin(with newPlan: GuidedWalkthroughPlan) {
        reset()
        plan = newPlan
        currentTargetStatus = .located
    }

    func updatePlan(_ updatedPlan: GuidedWalkthroughPlan) {
        plan = updatedPlan
    }

    func updateTargetStatus(_ newStatus: GuidedWalkthroughTargetStatus) {
        currentTargetStatus = newStatus
    }

    func markAllStepsFinished() {
        didFinishAllSteps = true
    }

    /// Stops everything the walkthrough started and forgets the plan.
    func reset() {
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
        plan = nil
        currentTargetStatus = .searching
    }
}

extension CompanionManager {
    /// How long Wisp keeps looking for a step's target before it stops trying
    /// (the user can still tap Next). Menus and panes take a moment to open, so
    /// the search is patient but not endless — each try is a capture plus OCR.
    private static let guidedStepSearchDurationSeconds: TimeInterval = 40
    private static let guidedStepFirstSearchDelaySeconds: TimeInterval = 0.7
    private static let guidedStepSearchIntervalSeconds: TimeInterval = 0.9
    /// Tries before the checklist admits it can't see the target.
    private static let guidedStepAttemptsBeforeAdmittingNotFound = 5
    private static let guidedWalkthroughFinishedLingerSeconds: TimeInterval = 2.5

    // MARK: - Starting and ending

    /// Starts a walkthrough if the reply's annotations are a multi-step one, and
    /// returns whether it did. When it does, only the first step is drawn — the
    /// caller must not also draw the whole set.
    func beginGuidedWalkthrough(
        from annotations: [ScreenAnnotation],
        screenCaptures: [CompanionScreenCapture]
    ) -> Bool {
        guard !screenCaptures.isEmpty,
              let newPlan = GuidedWalkthroughPlan(annotations: annotations),
              let firstStepAnnotation = annotations
                  .filter({ $0.stepNumber != nil })
                  .min(by: { ($0.stepNumber ?? 0) < ($1.stepNumber ?? 0) }) else {
            return false
        }

        guidedWalkthrough.begin(with: newPlan)
        if firstStepAnnotation.isUnplacedWalkthroughStep {
            // A [STEP:] tag has only words, so even the first step is found on
            // the live screen like the rest.
            findCurrentGuidedStepTarget()
        } else {
            applyAnnotations([firstStepAnnotation], from: screenCaptures)
            guidedWalkthrough.currentTargetLocation = locationOfActiveAnnotation()
        }
        startWatchingForGuidedWalkthroughClicks()
        print("🧭 Guided walkthrough: \(newPlan.steps.map(\.instruction).joined(separator: " → "))")
        return true
    }

    /// Ends the walkthrough and takes its marks off the screen.
    func endGuidedWalkthrough() {
        guard guidedWalkthrough.isActive else { return }
        guidedWalkthrough.reset()
        activeAnnotationsByDisplayFrame.removeAll()
        annotationScreenshotSizeByDisplayFrame.removeAll()
        scheduleTransientHideIfNeeded()
    }

    // MARK: - Moving through the steps

    /// The user did the current step (a click on its target, or Next after
    /// doing it another way).
    func completeGuidedWalkthroughStep() {
        advanceGuidedWalkthrough(creditingStep: true)
    }

    /// Move past the current step without crediting it.
    func skipGuidedWalkthroughStep() {
        advanceGuidedWalkthrough(creditingStep: false)
    }

    private func advanceGuidedWalkthrough(creditingStep: Bool) {
        guard var updatedPlan = guidedWalkthrough.plan, !updatedPlan.isFinished else { return }

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
    private func findCurrentGuidedStepTarget() {
        guard let currentStep = guidedWalkthrough.plan?.currentStep,
              let currentStepIndex = guidedWalkthrough.plan?.currentStepIndex else { return }

        let currentStepID = currentStep.id
        let pointingRequest = GuidedWalkthroughTargetText.pointingRequest(forInstruction: currentStep.instruction)
        guidedWalkthrough.updateTargetStatus(.searching)

        guidedWalkthrough.targetSearchTask = Task { [weak self] in
            let searchDeadline = Date().addingTimeInterval(Self.guidedStepSearchDurationSeconds)
            var attemptCount = 0

            while !Task.isCancelled, Date() < searchDeadline {
                let delaySeconds = attemptCount == 0
                    ? Self.guidedStepFirstSearchDelaySeconds
                    : Self.guidedStepSearchIntervalSeconds
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                // The user moved on (Next, or a click) while this was waiting.
                guard self.guidedWalkthrough.plan?.currentStep?.id == currentStepID else { return }

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
                if let bestMatch = PointingTargetMatcher
                    .bestPlaces(for: pointingRequest, among: pointingCandidates, maximumPlaceCount: 1)
                    .first {
                    self.markGuidedStepTarget(
                        bestMatch.candidate,
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
        applyAnnotations([stepAnnotation], from: screenCaptures)
        guidedWalkthrough.currentTargetLocation = locationOfActiveAnnotation()
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
            regionInScreenshotPixels: annotation.regionInScreenshotPixels
        )
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
                    Text(currentStepHint)
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
        case .notFound: return "Can\u{2019}t see it \u{2014} do it yourself, then tap Next."
        }
    }

    private var controlRow: some View {
        HStack(spacing: 8) {
            Button(action: onNextStep) {
                Text("Next")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(WispIslandButtonStyle(prominence: .prominent))
            .help("Done with this step — move on")

            Button(action: onStop) {
                Text("Stop")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(WispIslandButtonStyle(prominence: .subtle))
            .help("End the walkthrough")
        }
    }
}
