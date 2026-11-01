//
//  NoteCardManager.swift
//  leanring-buddy
//
//  Owns the note cards on screen (docs/note-cards-plan.md): which cards exist, and the
//  two small windows each one gets — the card itself and a click-through window that
//  draws its tether and numbered pins. The rules for what survives what live in the
//  pure `NoteCardLifecycle`; this class applies them and keeps the windows in step.
//
//  Why windows and not views in the overlay: the overlay must stay click-through, or
//  the desktop under it becomes unclickable, and it can't take dragging or typing. A card
//  is its own non-activating panel, so everything outside it is click-through for free.
//  A card becomes key only while its composer is clicked into, so dragging or clicking a
//  card never takes typing focus from the user's app.
//

import AppKit
import Combine
import SwiftUI

/// A card's window. Non-activating, and key only while its composer is being used: a
/// card that could always be key would take typing focus from the user's app on every
/// drag or click. The manager turns `allowsBecomingKey` on when the composer is clicked
/// and off again when the panel stops being key.
final class NoteCardPanel: NSPanel {
    var allowsBecomingKey = false
    /// Esc while the composer holds the keyboard.
    var onEscapePressed: (() -> Void)?

    override var canBecomeKey: Bool { allowsBecomingKey }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscapePressed?()
    }
}

/// Click-through window over one display that draws a card's tether and pins.
private final class NoteCardTetherPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NoteCardManager: ObservableObject {
    @Published private(set) var cards: [NoteCard] = []
    /// Each card's window frame in AppKit points, published on every move so the tether
    /// follows a drag.
    @Published private(set) var cardFramesInAppKitPoints: [UUID: CGRect] = [:]

    /// "Save" on a card: the owner runs the worked-solution export for it.
    var onSaveWorkedSolutionRequested: ((NoteCard) -> Void)?

    /// A follow-up was asked in a card. The owner runs the model turn and reports back through
    /// `setStreamingReply` / `finishReply` / `failReply`; the returned task is kept so closing the
    /// card cancels the turn.
    var onFollowUpRequested: ((_ cardID: UUID, _ question: String, _ focusedRegion: FocusedScreenRegion?) -> Task<Void, Never>)?

    private struct CardWindows {
        let cardPanel: NoteCardPanel
        let tetherPanel: NoteCardTetherPanel
        var moveObserver: NSObjectProtocol?
        var resignKeyObserver: NSObjectProtocol?
        var expiryTask: Task<Void, Never>?
        var followUpTask: Task<Void, Never>?
        /// Where the panel was last put by code. A move to anywhere else was the user's.
        var lastProgrammaticOrigin: CGPoint
    }

    private var windowsByCardID: [UUID: CardWindows] = [:]
    private var dragStartByCardID: [UUID: (pointer: CGPoint, cardOrigin: CGPoint)] = [:]

    var hasCards: Bool { !cards.isEmpty }

    /// Pressing Esc in a composer must leave the composer, not close the card the global Esc
    /// handler would otherwise close at the same moment; the grace covers that handler running
    /// just after the panel has already given up the keyboard.
    private var composerEscapeGraceEndsAt = Date.distantPast
    var isComposerFocused: Bool {
        Date() < composerEscapeGraceEndsAt || windowsByCardID.values.contains { $0.cardPanel.isKeyWindow }
    }

    func card(withID cardID: UUID) -> NoteCard? {
        cards.first { $0.id == cardID }
    }

    // MARK: - Presenting

    func present(_ newCard: NoteCard) {
        let displayFrame = newCard.displayFrameInAppKitPoints
        let screen = NSScreen.screens.first { $0.frame == displayFrame } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? displayFrame

        let cardSize = CGSize(
            width: NoteCardGeometry.cardWidth,
            height: NoteCardGeometry.estimatedHeight(forStepTexts: newCard.steps.map(\.text))
        )
        let explainedArea = NoteCardGeometry.appKitRect(
            fromOverlayRect: newCard.explainedAreaInOverlayPoints,
            displayFrameInAppKitPoints: displayFrame
        )
        let occupiedFrames = cards
            .filter { $0.displayFrameInAppKitPoints == displayFrame }
            .compactMap { cardFramesInAppKitPoints[$0.id] }
        let frame = NoteCardGeometry.cardFrame(
            explainedAreaInAppKitPoints: explainedArea,
            cardSize: cardSize,
            visibleFrame: visibleFrame,
            occupiedFrames: occupiedFrames
        )

        let added = NoteCardLifecycle.adding(newCard, to: cards)
        added.evictedIDs.forEach(closeWindows(forCardID:))
        cards = added.cards

        openWindows(for: newCard, frame: frame)
        cardFramesInAppKitPoints[newCard.id] = frame
        scheduleExpiry(forCardID: newCard.id)
        announceForVoiceOver("Wisp has an explanation beside it on your screen. " + newCard.steps.map { NoteCardFollowUp.spokenText(fromMarkdown: $0.text) }.joined(separator: " "))
    }

    // MARK: - Events from the rest of the app

    /// A new question: what the user never touched goes.
    func clearForNewUtterance() {
        keepOnly(NoteCardLifecycle.afterNewUtterance(cards))
    }

    /// Esc: everything but pinned cards goes.
    func closeUnpinned() {
        keepOnly(NoteCardLifecycle.afterEscape(cards))
    }

    /// Another app's content scrolled: untouched cards go, kept ones stay but stop pointing.
    func detachAfterScroll() {
        keepOnly(NoteCardLifecycle.afterContentScrolled(cards))
    }

    /// A display was added, removed or resized. Cards on a display that no longer exists lose their
    /// anchors (see `NoteCardLifecycle.afterDisplaysChanged`), and any card left with its window off
    /// every screen is brought back onto the main one.
    func reconcileWithDisplays() {
        keepOnly(NoteCardLifecycle.afterDisplaysChanged(cards, availableDisplayFrames: NSScreen.screens.map(\.frame)))
        guard let mainVisibleFrame = NSScreen.main?.visibleFrame else { return }
        for (cardID, windows) in windowsByCardID {
            let frame = windows.cardPanel.frame
            let isOnSomeScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
            guard !isOnSomeScreen else { continue }
            let relocatedFrame = NoteCardGeometry.clamp(frame, into: mainVisibleFrame.insetBy(dx: NoteCardGeometry.edgeMargin, dy: NoteCardGeometry.edgeMargin))
            windowsByCardID[cardID]?.lastProgrammaticOrigin = relocatedFrame.origin
            windows.cardPanel.setFrame(relocatedFrame, display: true)
            cardFramesInAppKitPoints[cardID] = relocatedFrame
        }
    }

    func closeAll() {
        keepOnly([])
    }

    /// ⌃⌥→ / ⌃⌥← move the newest attached card through its steps.
    func stepNewestCard(by step: Int) {
        guard let newestCard = cards.last(where: { !$0.isDetached && $0.steps.count > 1 }) else { return }
        setActiveStep(
            forCardID: newestCard.id,
            to: NoteCardLifecycle.steppedIndex(from: newestCard.activeStepIndex, by: step, stepCount: newestCard.steps.count)
        )
    }

    // MARK: - Actions from a card

    func close(cardID: UUID) {
        closeWindows(forCardID: cardID)
        cards.removeAll { $0.id == cardID }
    }

    func togglePin(cardID: UUID) {
        updateCard(cardID, engaging: true) { $0.isPinned.toggle() }
    }

    func toggleCollapse(cardID: UUID) {
        updateCard(cardID, engaging: true) { $0.isCollapsed.toggle() }
    }

    func setActiveStep(forCardID cardID: UUID, to stepIndex: Int) {
        updateCard(cardID, engaging: true) { card in
            guard card.steps.indices.contains(stepIndex) else { return }
            card.activeStepIndex = stepIndex
        }
    }

    /// Splits one step off into a card of its own, placed beside that step.
    func tearOffStep(forCardID cardID: UUID, stepIndex: Int) {
        guard let card = card(withID: cardID),
              let split = card.tearingOffStep(at: stepIndex),
              let cardIndex = cards.firstIndex(where: { $0.id == cardID }) else { return }
        windowsByCardID[cardID]?.expiryTask?.cancel()
        windowsByCardID[cardID]?.expiryTask = nil
        cards[cardIndex] = split.remaining
        present(split.torn)
    }

    /// The card's text (steps and anything asked in it) onto the clipboard, as plain text.
    func copyText(forCardID cardID: UUID) {
        guard let card = card(withID: cardID) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(NoteCardFollowUp.clipboardText(for: card), forType: .string)
        engage(cardID)
    }

    /// Saving paints the notes over a fresh capture of the display, so it only makes sense while
    /// the card still points at what it described.
    func canSaveWorkedSolution(forCardID cardID: UUID) -> Bool {
        guard let card = card(withID: cardID) else { return false }
        return !card.isDetached && WorkedSolutionExport.isWorthSaving(card.sourceAnnotations)
    }

    func saveWorkedSolution(forCardID cardID: UUID) {
        guard canSaveWorkedSolution(forCardID: cardID), let card = card(withID: cardID) else { return }
        engage(cardID)
        onSaveWorkedSolutionRequested?(card)
    }

    /// Clicking the composer is what lets the panel take the keyboard.
    func requestKeyboardFocus(forCardID cardID: UUID) {
        guard let windows = windowsByCardID[cardID] else { return }
        engage(cardID)
        windows.cardPanel.allowsBecomingKey = true
        windows.cardPanel.makeKey()
    }

    /// The question typed in a card: filed in its thread at once, with the answer to stream in.
    func submitFollowUp(cardID: UUID, question: String) {
        guard let card = card(withID: cardID), !card.isDetached else { return }
        var didBegin = false
        updateCard(cardID, engaging: true) { didBegin = $0.beginFollowUp(question: question) }
        guard didBegin, let questionText = self.card(withID: cardID)?.thread.dropLast().last?.text else { return }
        let focusedRegion = card.activeStep.flatMap { activeStep -> FocusedScreenRegion? in
            let regionRect = NoteCardGeometry.askRegionRect(forAnchorRect: activeStep.anchorRectInOverlayPoints)
            return AnnotationClickTarget.focusedRegion(
                forClickedRectInOverlayCoordinates: regionRect,
                displayFrame: card.displayFrameInAppKitPoints
            )
        }
        windowsByCardID[cardID]?.followUpTask = onFollowUpRequested?(cardID, questionText, focusedRegion)
    }

    /// VoiceOver says nothing when a window appears under a background app, so a card would show up
    /// silently. Polite, so it doesn't talk over what VoiceOver is already reading.
    private func announceForVoiceOver(_ text: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    func setStreamingReply(forCardID cardID: UUID, text: String) {
        updateCard(cardID, engaging: false) { $0.setStreamingReplyText(text) }
    }

    func finishReply(forCardID cardID: UUID, text: String) {
        updateCard(cardID, engaging: false) { $0.finishReply(finalText: text) }
        windowsByCardID[cardID]?.followUpTask = nil
        announceForVoiceOver("Wisp answered: \(NoteCardFollowUp.spokenText(fromMarkdown: text))")
    }

    func failReply(forCardID cardID: UUID, message: String) {
        updateCard(cardID, engaging: false) { $0.failReply(message: message) }
        windowsByCardID[cardID]?.followUpTask = nil
    }

    /// Moves a card with the pointer. The first call of a drag remembers where the pointer and
    /// the card were; each call after puts the card the same distance from its start as the
    /// pointer has travelled. Uses the pointer's screen position, not the gesture's, because the
    /// card moves under the pointer as it is dragged.
    func dragCard(cardID: UUID) {
        guard var windows = windowsByCardID[cardID] else { return }
        let pointerLocation = NSEvent.mouseLocation
        if dragStartByCardID[cardID] == nil {
            dragStartByCardID[cardID] = (pointerLocation, windows.cardPanel.frame.origin)
            engage(cardID)
        }
        guard let start = dragStartByCardID[cardID] else { return }
        let newOrigin = CGPoint(
            x: start.cardOrigin.x + (pointerLocation.x - start.pointer.x),
            y: start.cardOrigin.y + (pointerLocation.y - start.pointer.y)
        )
        windows.lastProgrammaticOrigin = newOrigin
        windowsByCardID[cardID] = windows
        windows.cardPanel.setFrameOrigin(newOrigin)
        cardFramesInAppKitPoints[cardID] = windows.cardPanel.frame
    }

    func endDrag(cardID: UUID) {
        dragStartByCardID.removeValue(forKey: cardID)
    }

    /// The card view reports its real height once laid out; the window follows, keeping
    /// its top edge where the user left it.
    func contentHeightChanged(forCardID cardID: UUID, to height: CGFloat) {
        guard var windows = windowsByCardID[cardID], height > 1 else { return }
        let currentFrame = windows.cardPanel.frame
        guard abs(currentFrame.height - height) > 0.5 else { return }
        var resizedFrame = CGRect(
            x: currentFrame.minX,
            y: currentFrame.maxY - height,
            width: currentFrame.width,
            height: height
        )
        // A card that has grown (an answer arriving) must not run off the bottom of its screen.
        if let screen = windows.cardPanel.screen ?? NSScreen.main {
            resizedFrame = NoteCardGeometry.clamp(resizedFrame, into: screen.visibleFrame.insetBy(dx: 0, dy: NoteCardGeometry.edgeMargin))
        }
        windows.lastProgrammaticOrigin = resizedFrame.origin
        windowsByCardID[cardID] = windows
        windows.cardPanel.setFrame(resizedFrame, display: true)
        cardFramesInAppKitPoints[cardID] = resizedFrame
    }

    // MARK: - Bookkeeping

    private func engage(_ cardID: UUID) {
        updateCard(cardID, engaging: true) { _ in }
    }

    private func updateCard(_ cardID: UUID, engaging: Bool, _ change: (inout NoteCard) -> Void) {
        guard let index = cards.firstIndex(where: { $0.id == cardID }) else { return }
        var card = cards[index]
        change(&card)
        if engaging {
            card.hasBeenEngaged = true
            windowsByCardID[cardID]?.expiryTask?.cancel()
            windowsByCardID[cardID]?.expiryTask = nil
        }
        cards[index] = card
    }

    /// Applies a lifecycle result: closes the windows of cards that didn't make it and
    /// takes on the changed state (detached) of the ones that did.
    private func keepOnly(_ keptCards: [NoteCard]) {
        let keptIDs = Set(keptCards.map(\.id))
        for card in cards where !keptIDs.contains(card.id) {
            closeWindows(forCardID: card.id)
        }
        cards = keptCards
    }

    private func scheduleExpiry(forCardID cardID: UUID) {
        windowsByCardID[cardID]?.expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(NoteCardLifecycle.untouchedDwellSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self,
                  let card = self.cards.first(where: { $0.id == cardID }),
                  !card.isEngagedOrPinned else { return }
            self.close(cardID: cardID)
        }
    }

    // MARK: - Windows

    private func openWindows(for card: NoteCard, frame: CGRect) {
        let displayFrame = card.displayFrameInAppKitPoints

        let tetherPanel = NoteCardTetherPanel(
            contentRect: displayFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        tetherPanel.isOpaque = false
        tetherPanel.backgroundColor = .clear
        tetherPanel.hasShadow = false
        tetherPanel.level = .floating
        tetherPanel.ignoresMouseEvents = true
        tetherPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        tetherPanel.hidesOnDeactivate = false
        let tetherHostingView = NSHostingView(
            rootView: NoteCardTetherView(manager: self, cardID: card.id, displayFrameInAppKitPoints: displayFrame)
        )
        tetherHostingView.frame = CGRect(origin: .zero, size: displayFrame.size)
        tetherPanel.contentView = tetherHostingView

        let cardPanel = NoteCardPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        cardPanel.isOpaque = false
        cardPanel.backgroundColor = .clear
        cardPanel.hasShadow = true
        cardPanel.level = .floating
        cardPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        cardPanel.hidesOnDeactivate = false
        // Dragging is explicit (`dragCard`), driven by a gesture in the card's view.
        let cardHostingView = FirstMouseHostingView(
            rootView: NoteCardView(manager: self, cardID: card.id).environment(\.colorScheme, .dark)
        )
        cardHostingView.frame = CGRect(origin: .zero, size: frame.size)
        cardPanel.contentView = cardHostingView

        tetherPanel.orderFrontRegardless()
        cardPanel.orderFrontRegardless()

        var windows = CardWindows(
            cardPanel: cardPanel,
            tetherPanel: tetherPanel,
            moveObserver: nil,
            expiryTask: nil,
            lastProgrammaticOrigin: frame.origin
        )
        windows.moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: cardPanel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cardPanelMoved(cardID: card.id) }
        }
        // The keyboard goes back to the user's app the moment the composer is done with it.
        windows.resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: cardPanel, queue: .main
        ) { [weak cardPanel] _ in
            MainActor.assumeIsolated { cardPanel?.allowsBecomingKey = false }
        }
        cardPanel.onEscapePressed = { [weak self, weak cardPanel] in
            MainActor.assumeIsolated {
                guard let self, let cardPanel else { return }
                self.composerEscapeGraceEndsAt = Date().addingTimeInterval(0.4)
                cardPanel.allowsBecomingKey = false
                // Ordering a key panel out and in makes the window server hand focus back to the user's app.
                cardPanel.orderOut(nil)
                cardPanel.orderFrontRegardless()
            }
        }
        windowsByCardID[card.id] = windows
    }

    private func cardPanelMoved(cardID: UUID) {
        guard let windows = windowsByCardID[cardID] else { return }
        let frame = windows.cardPanel.frame
        cardFramesInAppKitPoints[cardID] = frame
        // Only a move away from where code put it was the user's drag.
        let movedByUser = hypot(
            frame.origin.x - windows.lastProgrammaticOrigin.x,
            frame.origin.y - windows.lastProgrammaticOrigin.y
        ) > 1
        if movedByUser { engage(cardID) }
    }

    private func closeWindows(forCardID cardID: UUID) {
        guard let windows = windowsByCardID.removeValue(forKey: cardID) else { return }
        windows.expiryTask?.cancel()
        windows.followUpTask?.cancel()
        if let moveObserver = windows.moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
        if let resignKeyObserver = windows.resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
        }
        // The tether and pins go at once; the card fades (the view keeps showing the last card it
        // had, since the card is already gone from `cards`). Reduce Motion: it just goes.
        windows.tetherPanel.orderOut(nil)
        cardFramesInAppKitPoints.removeValue(forKey: cardID)
        let closingPanel = windows.cardPanel
        if WispMotion.prefersReducedMotion {
            closingPanel.orderOut(nil)
        } else {
            NSAnimationContext.runAnimationGroup { animationContext in
                animationContext.duration = 0.16
                closingPanel.animator().alphaValue = 0
            } completionHandler: {
                closingPanel.orderOut(nil)
            }
        }
    }
}
