//
//  NoteCard.swift
//  leanring-buddy
//
//  The pure side of note cards (docs/note-cards-plan.md): what a card is, how a
//  reply's handwritten notes become one, where it sits beside the thing it explains,
//  and which cards survive which event. No AppKit windows here — the windows are
//  `NoteCardManager`'s — so all of it is tested by `Tests/NoteCards`.
//
//  Two coordinate spaces appear, and are named in every property:
//  - "overlay" points: top-left origin, relative to one display (what annotations use);
//  - "AppKit" points: bottom-left origin, global screen space (what windows use).
//

import CoreGraphics
import Foundation

/// One line of an explanation, and the spot on screen it is about.
struct NoteCardStep: Identifiable, Equatable {
    let id: UUID
    let text: String
    /// The thing this step points at, in overlay points. A zero-size rect is a point.
    let anchorRectInOverlayPoints: CGRect
}

/// One line of the conversation held inside a card.
struct NoteCardMessage: Identifiable, Equatable {
    enum Role: Equatable { case user, assistant }

    let id: UUID
    let role: Role
    var text: String
    /// The reply is still arriving; its text grows until `finishReply`.
    var isStreaming = false
    /// Shown in place of an answer when the turn failed.
    var isFailure = false
}

struct NoteCard: Identifiable, Equatable {
    let id: UUID
    /// The display the explained content is on, in AppKit points.
    let displayFrameInAppKitPoints: CGRect
    var steps: [NoteCardStep]
    /// Everything the reply drew (shapes and notes) merged into one rect, in overlay
    /// points: the area the card must not cover.
    let explainedAreaInOverlayPoints: CGRect
    /// Everything the reply drew on this display (shapes and notes, as placed), kept so the card
    /// can be saved as a worked solution after the overlay has cleared them.
    var sourceAnnotations: [ScreenAnnotation]
    /// The pixel size of the screenshot those annotations' coordinates are in.
    let screenshotSizeInPixels: CGSize
    /// What the user asked that produced this explanation, for the saved file.
    var originalQuestion: String?
    var activeStepIndex: Int = 0
    var isPinned = false
    var isCollapsed = false
    /// The user has dragged it, stepped it or asked about it: it is theirs now, so a
    /// new question or the dwell timer no longer clears it.
    var hasBeenEngaged = false
    /// The screen scrolled or moved on: the card is kept but no longer points at anything.
    var isDetached = false
    /// Follow-ups asked in the card and their answers, oldest first.
    var thread: [NoteCardMessage] = []

    static let maximumThreadMessages = 20

    /// A reply is arriving, so a second question has to wait.
    var isAnswering: Bool { thread.last?.isStreaming == true }

    /// Splits one step off into a card of its own. Nil when the card has a single step (there
    /// would be nothing left) or the index is out of range. Both cards count as engaged, since
    /// the user just shaped them; the new one carries only the shapes and its own note, and
    /// starts without a thread (the thread stays with the card it was asked in).
    func tearingOffStep(at stepIndex: Int) -> (remaining: NoteCard, torn: NoteCard)? {
        guard steps.count > 1, steps.indices.contains(stepIndex) else { return nil }
        let tornStep = steps[stepIndex]

        func annotations(keepingNotesFrom keptSteps: [NoteCardStep]) -> [ScreenAnnotation] {
            let keptNoteIDs = Set(keptSteps.map(\.id))
            return sourceAnnotations.filter { $0.style != .note || keptNoteIDs.contains($0.id) }
        }

        var remaining = self
        remaining.steps.remove(at: stepIndex)
        remaining.sourceAnnotations = annotations(keepingNotesFrom: remaining.steps)
        if activeStepIndex > stepIndex {
            remaining.activeStepIndex = activeStepIndex - 1
        } else {
            remaining.activeStepIndex = min(activeStepIndex, remaining.steps.count - 1)
        }
        remaining.hasBeenEngaged = true

        var torn = NoteCard(
            id: UUID(),
            displayFrameInAppKitPoints: displayFrameInAppKitPoints,
            steps: [tornStep],
            explainedAreaInOverlayPoints: tornStep.anchorRectInOverlayPoints,
            sourceAnnotations: annotations(keepingNotesFrom: [tornStep]),
            screenshotSizeInPixels: screenshotSizeInPixels
        )
        torn.originalQuestion = originalQuestion
        torn.hasBeenEngaged = true
        torn.isDetached = isDetached
        return (remaining, torn)
    }

    /// Adds the user's question and an empty, streaming answer under it. Refused while an
    /// answer is still arriving and for a blank question.
    @discardableResult
    mutating func beginFollowUp(question: String) -> Bool {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuestion.isEmpty, !isAnswering else { return false }
        thread.append(NoteCardMessage(id: UUID(), role: .user, text: trimmedQuestion))
        thread.append(NoteCardMessage(id: UUID(), role: .assistant, text: "", isStreaming: true))
        if thread.count > Self.maximumThreadMessages {
            thread.removeFirst(thread.count - Self.maximumThreadMessages)
        }
        return true
    }

    /// The answer being written, as far as it has got (the caller passes everything so
    /// far, cleaned, not a delta); ignored when no answer is arriving.
    mutating func setStreamingReplyText(_ text: String) {
        guard let lastIndex = thread.indices.last, thread[lastIndex].isStreaming else { return }
        thread[lastIndex].text = text
    }

    /// Ends the answer, replacing what streamed with its cleaned-up final text.
    mutating func finishReply(finalText: String) {
        guard let lastIndex = thread.indices.last, thread[lastIndex].isStreaming else { return }
        thread[lastIndex].text = finalText
        thread[lastIndex].isStreaming = false
    }

    mutating func failReply(message: String) {
        guard let lastIndex = thread.indices.last, thread[lastIndex].isStreaming else { return }
        thread[lastIndex].text = message
        thread[lastIndex].isStreaming = false
        thread[lastIndex].isFailure = true
    }

    var activeStep: NoteCardStep? {
        steps.indices.contains(activeStepIndex) ? steps[activeStepIndex] : steps.first
    }

    /// Kept through a new question or the dwell timer.
    var isEngagedOrPinned: Bool { isPinned || hasBeenEngaged }
}

// MARK: - Building a card from a reply

enum NoteCardBuilder {
    /// A card for the handwritten notes among one display's annotations, or nil when
    /// there are none (cards are for answers that point at something and say something).
    static func card(
        fromAnnotations annotations: [ScreenAnnotation],
        screenshotSize: CGSize,
        displayFrameInAppKitPoints: CGRect
    ) -> NoteCard? {
        let displaySize = displayFrameInAppKitPoints.size
        let steps: [NoteCardStep] = annotations.compactMap { annotation in
            guard annotation.style == .note,
                  let text = annotation.label?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return NoteCardStep(
                id: annotation.id,
                text: text,
                anchorRectInOverlayPoints: annotation.regionInOverlayCoordinates(
                    screenshotSize: screenshotSize,
                    displaySize: displaySize
                )
            )
        }
        guard !steps.isEmpty else { return nil }

        // Merged by min/max rather than `CGRect.union`, which skips zero-size rects, and
        // a point (a note's anchor, a marker) is part of the area too.
        let regions = annotations.map {
            $0.regionInOverlayCoordinates(screenshotSize: screenshotSize, displaySize: displaySize)
        }
        let explainedArea = CGRect(
            x: regions.map(\.minX).min() ?? 0,
            y: regions.map(\.minY).min() ?? 0,
            width: (regions.map(\.maxX).max() ?? 0) - (regions.map(\.minX).min() ?? 0),
            height: (regions.map(\.maxY).max() ?? 0) - (regions.map(\.minY).min() ?? 0)
        )

        return NoteCard(
            id: UUID(),
            displayFrameInAppKitPoints: displayFrameInAppKitPoints,
            steps: steps,
            explainedAreaInOverlayPoints: explainedArea,
            sourceAnnotations: annotations,
            screenshotSizeInPixels: screenshotSize
        )
    }
}

// MARK: - Geometry

enum NoteCardGeometry {
    static let cardWidth: CGFloat = 340
    static let headerHeight: CGFloat = 44
    static let collapsedHeight: CGFloat = 44
    static let gapFromExplainedArea: CGFloat = 16
    static let edgeMargin: CGFloat = 8

    /// Before the real content is measured: header, a footer, and about 18pt for each
    /// ~40 characters of each step. Only the first guess at where to put the card.
    static func estimatedHeight(forStepTexts stepTexts: [String]) -> CGFloat {
        let charactersPerLine = 40.0
        let textHeight = stepTexts.reduce(CGFloat(0)) { total, text in
            let lineCount = max(1, ceil(Double(text.count) / charactersPerLine))
            return total + CGFloat(lineCount) * 18 + 12
        }
        let estimated = headerHeight + textHeight + 24 + 48
        return min(max(estimated, 130), 440)
    }

    static func appKitRect(fromOverlayRect overlayRect: CGRect, displayFrameInAppKitPoints displayFrame: CGRect) -> CGRect {
        CGRect(
            x: displayFrame.minX + overlayRect.minX,
            y: displayFrame.maxY - overlayRect.maxY,
            width: overlayRect.width,
            height: overlayRect.height
        )
    }

    /// Beside the explained area (right, then left, below, above), fully on screen and
    /// clear of cards already out. When nothing fits cleanly, the right-hand spot is
    /// clamped onto the screen rather than failing — a card that overlaps a bit is better
    /// than none.
    static func cardFrame(
        explainedAreaInAppKitPoints area: CGRect,
        cardSize: CGSize,
        visibleFrame: CGRect,
        occupiedFrames: [CGRect]
    ) -> CGRect {
        let gap = gapFromExplainedArea
        let rightSpot = CGPoint(x: area.maxX + gap, y: area.midY - cardSize.height / 2)
        let leftSpot = CGPoint(x: area.minX - gap - cardSize.width, y: area.midY - cardSize.height / 2)
        let belowSpot = CGPoint(x: area.midX - cardSize.width / 2, y: area.minY - gap - cardSize.height)
        let aboveSpot = CGPoint(x: area.midX - cardSize.width / 2, y: area.maxY + gap)

        let safeArea = visibleFrame.insetBy(dx: edgeMargin, dy: edgeMargin)
        var candidates: [(spot: CGPoint, fitsOnMainAxis: Bool)] = [
            (rightSpot, rightSpot.x + cardSize.width <= safeArea.maxX),
            (leftSpot, leftSpot.x >= safeArea.minX),
            (belowSpot, belowSpot.y >= safeArea.minY),
            (aboveSpot, aboveSpot.y + cardSize.height <= safeArea.maxY)
        ]

        for candidate in candidates where candidate.fitsOnMainAxis {
            let clamped = clamp(CGRect(origin: candidate.spot, size: cardSize), into: safeArea)
            let overlapsAnother = occupiedFrames.contains { $0.intersects(clamped) }
            if !overlapsAnother { return clamped }
        }

        // Every clean spot is taken. Take the first one on screen and step it down past
        // whatever it lands on, so stacked cards cascade instead of hiding each other.
        candidates.sort { $0.fitsOnMainAxis && !$1.fitsOnMainAxis }
        var fallback = clamp(CGRect(origin: candidates[0].spot, size: cardSize), into: safeArea)
        for _ in 0..<6 {
            guard occupiedFrames.contains(where: { $0.intersects(fallback) }) else { break }
            fallback = clamp(fallback.offsetBy(dx: 0, dy: -(cardSize.height * 0.25)), into: safeArea)
        }
        return fallback
    }

    static func clamp(_ rect: CGRect, into bounds: CGRect) -> CGRect {
        var clamped = rect
        clamped.origin.x = min(max(clamped.origin.x, bounds.minX), max(bounds.minX, bounds.maxX - rect.width))
        clamped.origin.y = min(max(clamped.origin.y, bounds.minY), max(bounds.minY, bounds.maxY - rect.height))
        return clamped
    }

    /// Where the tether lands on the anchored thing: the point of its rect nearest the
    /// card, so a line to a wide element meets its edge instead of crossing its middle.
    /// A zero-size anchor is just that point.
    static func tetherEndPoint(anchorRect: CGRect, nearestTo point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, anchorRect.minX), anchorRect.maxX),
            y: min(max(point.y, anchorRect.minY), anchorRect.maxY)
        )
    }

    /// The region "Ask about this" focuses: the active step's anchor, grown to a size a
    /// close-up can actually show when the anchor is just a point.
    static func askRegionRect(forAnchorRect anchorRect: CGRect) -> CGRect {
        let minimumSize = CGSize(width: 140, height: 80)
        let width = max(anchorRect.width, minimumSize.width)
        let height = max(anchorRect.height, minimumSize.height)
        return CGRect(x: anchorRect.midX - width / 2, y: anchorRect.midY - height / 2, width: width, height: height)
    }
}

// MARK: - Lifecycle

enum NoteCardLifecycle {
    static let maximumCards = 4
    /// How long an untouched card stays before it fades, the same as handwritten notes did.
    static let untouchedDwellSeconds: TimeInterval = 120

    /// A new question clears what the user never touched; kept cards stay.
    static func afterNewUtterance(_ cards: [NoteCard]) -> [NoteCard] {
        cards.filter(\.isEngagedOrPinned)
    }

    /// Esc closes everything except pinned cards.
    static func afterEscape(_ cards: [NoteCard]) -> [NoteCard] {
        cards.filter(\.isPinned)
    }

    /// Scrolling moves the content the cards point at: untouched cards go, kept ones
    /// stay but no longer claim to point at anything.
    static func afterContentScrolled(_ cards: [NoteCard]) -> [NoteCard] {
        cards.filter(\.isEngagedOrPinned).map { card in
            var detached = card
            detached.isDetached = true
            return detached
        }
    }

    /// The set of displays changed (one unplugged, a resolution change). A card's anchors are
    /// positions on the display it was built for, so a card whose display frame no longer exists
    /// can't point at anything: untouched ones go, kept ones stay but detach.
    static func afterDisplaysChanged(_ cards: [NoteCard], availableDisplayFrames: [CGRect]) -> [NoteCard] {
        cards.compactMap { card in
            if availableDisplayFrames.contains(card.displayFrameInAppKitPoints) { return card }
            guard card.isEngagedOrPinned else { return nil }
            var detached = card
            detached.isDetached = true
            return detached
        }
    }

    /// Adds a card, evicting the oldest unpinned ones past the cap. If everything is
    /// pinned nothing is evicted: pinning is the user's explicit choice to keep a card.
    static func adding(_ newCard: NoteCard, to cards: [NoteCard]) -> (cards: [NoteCard], evictedIDs: [UUID]) {
        var result = cards + [newCard]
        var evictedIDs: [UUID] = []
        while result.count > maximumCards,
              let oldestUnpinnedIndex = result.dropLast().firstIndex(where: { !$0.isPinned }) {
            evictedIDs.append(result[oldestUnpinnedIndex].id)
            result.remove(at: oldestUnpinnedIndex)
        }
        return (result, evictedIDs)
    }

    /// Moves the active step, staying inside the list.
    static func steppedIndex(from index: Int, by step: Int, stepCount: Int) -> Int {
        guard stepCount > 0 else { return 0 }
        return min(max(index + step, 0), stepCount - 1)
    }
}
