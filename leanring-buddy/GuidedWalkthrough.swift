//
//  GuidedWalkthrough.swift
//  leanring-buddy
//
//  The pure side of the live guided walkthrough: a multi-step answer ("open
//  Appearance, then pick Dark") that is walked through one step at a time
//  instead of being drawn all at once.
//
//  The model's step tags describe the screen as it is *now*, so only the
//  first step's position is trustworthy — opening a menu or a pane changes
//  everything after it. The plan therefore keeps just each step's words, and
//  the controller finds each next target on the live screen once the user
//  has done the one before, with the same deterministic Accessibility + OCR
//  matcher fast pointing uses. Nothing here touches the screen or the model.
//

import Foundation
import CoreGraphics

nonisolated struct GuidedWalkthroughStep: Identifiable, Equatable {
    enum Status: Equatable {
        case upcoming
        case current
        case done
        case skipped
    }

    let id: UUID
    /// What to do, in the model's words ("click export", "then choose pdf").
    let instruction: String
    var status: Status
}

nonisolated struct GuidedWalkthroughPlan: Equatable {
    /// A single step is a pointer, not a walkthrough.
    static let minimumStepCount = 2

    private(set) var steps: [GuidedWalkthroughStep]

    /// Builds a plan from a reply's numbered annotations, or nil when the reply
    /// isn't a multi-step walkthrough (fewer than two labelled, numbered steps).
    init?(annotations: [ScreenAnnotation]) {
        let numberedSteps = annotations
            .filter { $0.stepNumber != nil }
            .sorted { ($0.stepNumber ?? 0) < ($1.stepNumber ?? 0) }
        let builtSteps: [GuidedWalkthroughStep] = numberedSteps.compactMap { annotation in
            let instruction = (annotation.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instruction.isEmpty else { return nil }
            return GuidedWalkthroughStep(id: UUID(), instruction: instruction, status: .upcoming)
        }
        guard builtSteps.count >= Self.minimumStepCount else { return nil }
        steps = builtSteps
        steps[0].status = .current
    }

    var currentStepIndex: Int? {
        steps.firstIndex { $0.status == .current }
    }

    var currentStep: GuidedWalkthroughStep? {
        currentStepIndex.map { steps[$0] }
    }

    var isFinished: Bool {
        currentStepIndex == nil
    }

    var completedStepCount: Int {
        steps.filter { $0.status == .done }.count
    }

    /// Marks the current step done and makes the next one current.
    mutating func completeCurrentStep() {
        closeCurrentStep(as: .done)
    }

    /// Moves past the current step without crediting it, for a step the user
    /// did another way or one Wisp couldn't find.
    mutating func skipCurrentStep() {
        closeCurrentStep(as: .skipped)
    }

    private mutating func closeCurrentStep(as closedStatus: GuidedWalkthroughStep.Status) {
        guard let currentIndex = currentStepIndex else { return }
        steps[currentIndex].status = closedStatus
        let nextIndex = currentIndex + 1
        if nextIndex < steps.count {
            steps[nextIndex].status = .current
        }
    }
}

// MARK: - Turning an instruction into something to find

nonisolated enum GuidedWalkthroughTargetText {
    /// Words that lead an instruction without naming what to act on.
    private static let leadingFillerWords: Set<String> = [
        "then", "next", "now", "and", "first", "finally", "also", "just", "simply",
        "click", "tap", "press", "choose", "select", "pick", "open", "hit", "go",
        "to", "on", "the", "a", "an", "turn", "switch", "toggle", "head",
    ]

    /// Words that start a location clause ("appearance in the sidebar") — the
    /// part after them describes where, which a label match can't use.
    private static let locationClauseWords: Set<String> = [
        "in", "on", "from", "at", "under", "near", "inside", "within", "of",
    ]

    /// The label to look for on screen, from a step's instruction: "then choose
    /// Appearance in the sidebar" → "appearance". A role word the user would
    /// say ("export button") is split off as the matcher's tie-breaking hint.
    /// Falls back to the whole instruction rather than nothing.
    static func pointingRequest(forInstruction instruction: String) -> PointingRequest {
        let originalWords = instruction
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || ",.;:!?\"“”".contains($0) })
            .map(String.init)

        var remainingWords = originalWords[...]
        while let firstWord = remainingWords.first, leadingFillerWords.contains(firstWord) {
            remainingWords = remainingWords.dropFirst()
        }

        if let locationClauseIndex = remainingWords.firstIndex(where: { locationClauseWords.contains($0) }),
           locationClauseIndex > remainingWords.startIndex {
            remainingWords = remainingWords[remainingWords.startIndex..<locationClauseIndex]
        }

        var roleHint: String?
        var labelWords: [String] = []
        for word in remainingWords {
            if PointingRequestParser.roleWords.contains(word) {
                if roleHint == nil { roleHint = word }
            } else {
                labelWords.append(word)
            }
        }

        if labelWords.isEmpty {
            labelWords = originalWords
            roleHint = nil
        }
        return PointingRequest(targetText: labelWords.joined(separator: " "), roleHint: roleHint)
    }
}

// MARK: - Did the click land on the step's target?

nonisolated enum GuidedWalkthroughClickMatcher {
    /// Extra reach around a drawn box, in points, so a click on the edge of a
    /// button counts.
    static let slopAroundBoxInPoints: CGFloat = 8
    /// A point marker has no extent, so its reach is a generous circle.
    static let slopAroundPointInPoints: CGFloat = 24

    /// Whether a click at a global AppKit position (origin bottom-left of the
    /// primary display) landed on the step's region, which is held in the
    /// screenshot's pixel space (origin top-left) on the display it was drawn.
    static func clickLandsOnRegion(
        clickLocationInAppKitGlobalPoints clickLocation: CGPoint,
        displayFrameInAppKitCoordinates displayFrame: CGRect,
        screenshotSize: CGSize,
        regionInScreenshotPixels region: CGRect
    ) -> Bool {
        guard displayFrame.contains(clickLocation),
              screenshotSize.width > 0, screenshotSize.height > 0,
              displayFrame.width > 0, displayFrame.height > 0 else { return false }

        // To the display's top-left space, then to the screenshot's pixels.
        let horizontalPixelsPerPoint = screenshotSize.width / displayFrame.width
        let verticalPixelsPerPoint = screenshotSize.height / displayFrame.height
        let clickInScreenshotPixels = CGPoint(
            x: (clickLocation.x - displayFrame.minX) * horizontalPixelsPerPoint,
            y: (displayFrame.maxY - clickLocation.y) * verticalPixelsPerPoint
        )

        let isPointMarker = region.width == 0 && region.height == 0
        let slopInPoints = isPointMarker ? slopAroundPointInPoints : slopAroundBoxInPoints
        let reachedRegion = region.insetBy(
            dx: -slopInPoints * horizontalPixelsPerPoint,
            dy: -slopInPoints * verticalPixelsPerPoint
        )
        return reachedRegion.contains(clickInScreenshotPixels)
    }
}

// MARK: - Where to click when Wisp does a step

nonisolated enum GuidedWalkthroughAutoClickPoint {
    /// The centre of a step's region as a point in Quartz global coordinates
    /// (origin top-left of the primary display), which is what a synthesised
    /// mouse event takes. The region is in the screenshot's pixel space on
    /// `displayFrame`, an AppKit frame (origin bottom-left of the primary).
    static func quartzGlobalPoint(
        displayFrameInAppKitCoordinates displayFrame: CGRect,
        screenshotSize: CGSize,
        regionInScreenshotPixels region: CGRect,
        primaryDisplayHeight: CGFloat
    ) -> CGPoint? {
        guard screenshotSize.width > 0, screenshotSize.height > 0,
              displayFrame.width > 0, displayFrame.height > 0 else { return nil }

        let offsetFromDisplayLeftInPoints = region.midX * displayFrame.width / screenshotSize.width
        let offsetFromDisplayTopInPoints = region.midY * displayFrame.height / screenshotSize.height

        let appKitX = displayFrame.minX + offsetFromDisplayLeftInPoints
        let appKitY = displayFrame.maxY - offsetFromDisplayTopInPoints
        return CGPoint(x: appKitX, y: primaryDisplayHeight - appKitY)
    }
}
