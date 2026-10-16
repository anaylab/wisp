//
//  NotchWindowController.swift
//  leanring-buddy
//
//  Hosts Wisp's notch HUD in a borderless, non-activating panel at the top of
//  the primary screen. It mirrors the discipline of OverlayWindow — never
//  becomes key or main, joins all Spaces, floats above other windows.
//
//  The window is a FIXED size (the expanded panel's bounds) and never moves.
//  This is deliberate: an earlier version resized the window on hover, but that
//  fed back on itself — resizing moved the very tracking area that detected the
//  hover, so near the edges it oscillated between collapsed and expanded, and
//  animating the NSWindow frame while SwiftUI re-laid-out the content each frame
//  was visibly janky.
//
//  Instead, expand/collapse is decided from the global mouse position against
//  two fixed hot-zones (a small one around the pill, a larger one around the
//  panel, with hysteresis), and the morph is animated entirely inside SwiftUI on
//  the GPU. Click-through is preserved by toggling `ignoresMouseEvents`: the
//  transparent window is click-through while collapsed and only intercepts mouse
//  events while the panel is actually open.
//

import AppKit
import Combine
import SwiftUI

/// The expand/collapse state and current geometry, shared between the controller
/// (which decides hover from the global mouse position) and the SwiftUI HUD
/// (which renders and animates the morph).
@MainActor
final class NotchViewModel: ObservableObject {
    @Published var isExpanded: Bool = false
    /// When the island is expanded, whether it shows the FULL panel (header
    /// controls, activity, Chat/Manage — a deliberate hover) or the compact
    /// MESSAGE card (just the reply/glance card — an auto-presented answer). The
    /// message form is deliberately small so a short reply doesn't drop a whole
    /// dashboard from the notch.
    @Published var isFullPanel: Bool = false
    /// Whether this screen physically has a notch. When it does, the island's
    /// content is inset below the notch so the camera housing never covers it.
    @Published var hasNotch: Bool = false
    /// The collapsed pill's size — matches the physical notch when there is one.
    @Published var collapsedSize: CGSize = CGSize(width: 180, height: 32)
    /// The expanded quick panel's size.
    @Published var expandedSize: CGSize = CGSize(width: 360, height: 404)
    /// The window's current size: the quick panel's bounds normally, the
    /// workspace's while chat or settings is open. The SwiftUI root fills it.
    @Published var windowSize: CGSize = CGSize(width: 360, height: 404)
    /// The chat or settings page open in the notch's large surface, or nil.
    @Published var workspacePage: NotchWorkspacePage?
    /// Set by the controller: asks it to open a workspace page (or close the
    /// workspace with nil), since that also resizes the window and moves focus.
    var requestWorkspacePage: ((NotchWorkspacePage?) -> Void)?

    /// The notch's large surface — chat and settings, HeyClicky-style.
    static let workspaceSize = CGSize(width: 760, height: 480)

    var isWorkspaceOpen: Bool { workspacePage != nil }

    /// A file is being dragged near the notch and would be added to the brain.
    @Published var isFileDragNearby: Bool = false
    /// A short result line shown after a drop ("Added 2 files to your brain").
    @Published var fileDropFeedback: String?
}

@MainActor
final class NotchWindowController {
    private var panel: NotchPanel?
    private let companionManager: CompanionManager
    private let viewModel = NotchViewModel()
    private var clickThroughObserver: AnyCancellable?
    private var hoverPollTimer: Timer?
    private var fileDragDetector = NotchFileDragDetector()
    private var fileDropFeedbackClearTask: Task<Void, Never>?
    private var screenParametersObserver: NSObjectProtocol?
    private var dismissObserver: NSObjectProtocol?

    /// Combine subscriptions that auto-present the panel the moment an answer
    /// lands — the reply text (silent mode's only surface) and any glance card.
    /// Without these the answer is generated but stays invisible until the user
    /// happens to hover the notch, which is why silent mode looked broken.
    private var replyPresentationObserver: AnyCancellable?
    private var cardPresentationObserver: AnyCancellable?
    /// Drops the morning suggestions banner out of the notch when a briefing arrives.
    private var morningBriefingPresentationObserver: AnyCancellable?
    /// Marks the "new" background results seen once the user has opened the
    /// full panel (where they are listed) and then closed it again.
    private var finishedWorkSeenObserver: AnyCancellable?

    /// Hover is ignored until this moment. Set when the HUD is force-collapsed
    /// (e.g. a skill was launched) so the click that triggered it — or the
    /// screenshot about to be taken — does not immediately reopen the panel.
    private var hoverSuspendedUntil: Date = .distantPast

    /// While `Date() < presentationHoldUntil` the panel is held open on its own,
    /// independent of hover, so a freshly arrived answer is shown long enough to
    /// read. Hovering the panel keeps it open past the hold through the normal
    /// hover logic; moving away after the hold expires collapses it as usual.
    private var presentationHoldUntil: Date = .distantPast

    /// When the notch last folded away with an answer still lingering in it
    /// (idle, collapsed, no hold), or nil while the answer is on screen or there
    /// is none. An answer left alone this long is cleared, so the notch stops
    /// carrying — and a later hover stops re-showing — a reply to a question
    /// asked minutes ago. The full thread stays in History and the chat.
    private var answerLingeringSinceDate: Date?
    private let lingeringAnswerExpirySeconds: TimeInterval = 20

    /// The expanded panel's fixed size. Kept compact — it holds the scrollable
    /// answer surface, live activity and the footer, and the answer surface scrolls rather than growing the window.
    private let panelSize = CGSize(width: 360, height: 404)

    /// Extra slack added around the panel so a small overshoot at the edge does
    /// not immediately collapse it — the hysteresis that keeps the hover stable.
    private let expandedZoneMargin: CGFloat = 10

    /// How long the cursor must rest on the notch before the panel opens. Without
    /// this, simply sweeping the cursor across the top of the screen (to reach a
    /// menu bar item, a browser tab, a window's title bar) popped the panel open.
    /// A short dwell separates "I'm aiming at Wisp" from "I'm passing through".
    private let hoverOpenDwellSeconds: TimeInterval = 0.2

    /// When the cursor entered the collapsed hot-zone, or nil while it is outside.
    /// The panel opens only once it has stayed inside for `hoverOpenDwellSeconds`.
    private var cursorEnteredCollapsedZoneDate: Date?

    /// When the cursor left the open workspace, or nil while it's inside. The
    /// workspace closes after a short grace outside, so a brief overshoot while
    /// reaching for its edge doesn't slam it shut.
    private var cursorLeftWorkspaceDate: Date?
    private let workspaceCloseGraceSeconds: TimeInterval = 0.6

    /// The pending shrink back to the quick panel's size after the workspace
    /// closes — delayed so the collapse animates inside the still-large window.
    private var workspaceCloseResizeWorkItem: DispatchWorkItem?
    private var closeWorkspaceObserver: NSObjectProtocol?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    deinit {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
        if let dismissObserver {
            NotificationCenter.default.removeObserver(dismissObserver)
        }
        if let closeWorkspaceObserver {
            NotificationCenter.default.removeObserver(closeWorkspaceObserver)
        }
        hoverPollTimer?.invalidate()
    }

    // MARK: - Lifecycle

    func show() {
        if panel == nil {
            createPanel()
        }
        positionWindow()
        panel?.orderFrontRegardless()
        startHoverTracking()
        // Feeds the island's ambient next-meeting countdown.
        UpcomingEventMonitor.shared.start()
        // Quiet mode first, so the briefing's first check already knows about a call.
        QuietModeMonitor.shared.start()
        MorningBriefingController.shared.start()
        // Buddies' scheduled runs; each run is a background task started here.
        BuddyStore.shared.start { [weak companionManager] buddy, runRequest in
            companionManager?.startBuddyRun(buddy, request: runRequest)
        }
        // Buddies' event triggers: new files, app launches, calendar events.
        BuddyTriggerMonitor.shared.start()
    }

    func hide() {
        stopHoverTracking()
        panel?.orderOut(nil)
    }

    // MARK: - Panel construction

    private func createPanel() {
        guard let geometry = currentGeometry() else { return }

        viewModel.collapsedSize = geometry.collapsedPillSize
        viewModel.hasNotch = geometry.hasNotch
        viewModel.expandedSize = panelSize
        viewModel.windowSize = panelSize
        viewModel.requestWorkspacePage = { [weak self] requestedPage in
            self?.setWorkspacePage(requestedPage)
        }

        let notchHUDView = NotchHUDView(
            viewModel: viewModel,
            companionManager: companionManager
        )

        // A first-mouse-accepting hosting view is what makes the panel's buttons
        // and skill chips actually usable. Wisp is a menu-bar-only app, so it is
        // almost never the frontmost application; without accepting the first
        // mouse, the initial click on any control in this non-activating panel is
        // swallowed just to focus the window and the button never fires, which is
        // why the skills and toggles felt dead — you had to click twice.
        let hostingView = FirstMouseHostingView(rootView: notchHUDView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let notchPanel = NotchPanel(
            contentRect: geometry.expandedWindowFrame(size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        notchPanel.isFloatingPanel = true
        // One above the cursor overlay (.screenSaver) so the HUD is never
        // occluded by the full-screen cursor layer.
        notchPanel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        notchPanel.isOpaque = false
        notchPanel.backgroundColor = .clear
        notchPanel.hasShadow = false
        notchPanel.hidesOnDeactivate = false
        notchPanel.isExcludedFromWindowsMenu = true
        notchPanel.isMovableByWindowBackground = false
        notchPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Collapsed to begin with, so the transparent window is click-through.
        notchPanel.ignoresMouseEvents = true
        // Dropping a file on the notch adds it to the brain. The drop view is a
        // sibling above the hosting view (not a wrapper, not SwiftUI's onDrop —
        // neither received drags on this panel); it ignores clicks.
        let panelContentContainerView = NSView(frame: NSRect(origin: .zero, size: panelSize))
        hostingView.frame = panelContentContainerView.bounds
        hostingView.autoresizingMask = [.width, .height]
        let fileDropView = NotchFileDropView(frame: panelContentContainerView.bounds)
        fileDropView.autoresizingMask = [.width, .height]
        fileDropView.canAcceptFiles = { BrainPreferences.shared.isBrainEnabled }
        fileDropView.onFilesDropped = { [weak self] droppedFileURLs in
            self?.addDroppedFilesToBrain(droppedFileURLs) ?? false
        }
        panelContentContainerView.addSubview(hostingView)
        panelContentContainerView.addSubview(fileDropView)
        notchPanel.contentView = panelContentContainerView
        notchPanel.onEscapePressed = { [weak self] in
            self?.setWorkspacePage(nil)
        }
        self.panel = notchPanel

        // The window itself never resizes; it only stops being click-through
        // while the panel is open so its buttons can be used. Opening the panel
        // also refreshes the skill list, so a skill the user just dropped into
        // ~/.wisp/skills shows up without relaunching.
        clickThroughObserver = viewModel.$isExpanded
            .removeDuplicates()
            .sink { [weak self] isExpanded in
                self?.panel?.ignoresMouseEvents = !isExpanded
                if isExpanded {
                    _ = SkillManager.shared.loadSkills()
                }
            }

        // Auto-present the panel when a new answer arrives. The reply text is
        // cleared to "" at the start of every turn, so a non-empty value is a
        // freshly generated answer; that is the moment to open the notch. The
        // hold is scaled by the answer's length so a longer reply stays up
        // longer. This is what makes silent mode usable — the answer opens on
        // its own instead of waiting for a hover.
        replyPresentationObserver = companionManager.$currentReplyText
            .removeDuplicates()
            .sink { [weak self] replyText in
                let trimmed = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                // The open workspace's chat already shows the answer as it lands.
                guard self?.viewModel.isWorkspaceOpen == false else { return }
                self?.autoPresentAnswer(readingLength: trimmed.count)
            }

        // A glance card is also an answer surface, so open the panel for one even
        // when the turn produced no reply text (e.g. a card-only reply).
        cardPresentationObserver = companionManager.$resolvedGlanceCard
            .sink { [weak self] resolvedGlanceCard in
                guard resolvedGlanceCard != nil else { return }
                guard self?.viewModel.isWorkspaceOpen == false else { return }
                self?.autoPresentAnswer(readingLength: 0)
            }

        // A fresh morning briefing drops its banner from the notch — but only
        // onto an idle notch. Mid-turn, or with an answer still up, it would
        // bury what the user is looking at; it waits in the flank's ✦ count and
        // the hover panel's TODAY list instead.
        morningBriefingPresentationObserver = MorningBriefingController.shared.$presentationSequenceNumber
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                let isNotchShowingAnswer = !self.companionManager.currentReplyText
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || self.companionManager.resolvedGlanceCard != nil
                guard self.companionManager.voiceState == .idle,
                      !isNotchShowingAnswer,
                      !self.viewModel.isWorkspaceOpen else { return }
                self.autoPresentMorningBriefing()
            }

        finishedWorkSeenObserver = viewModel.$isFullPanel
            .removeDuplicates()
            .dropFirst()
            .sink { isFullPanel in
                guard !isFullPanel else { return }
                FinishedWorkInbox.shared.markAllSeen()
            }

        // When the app clears its surfaces off the screen (a skill launching, a
        // push-to-talk turn starting), collapse the HUD too and ignore hover
        // briefly so the click that launched it does not immediately reopen it
        // and so the notch is out of the way of the screenshot being captured.
        dismissObserver = NotificationCenter.default.addObserver(
            forName: .wispDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The workspace is where the user is talking to Wisp, so a turn
                // starting (push-to-talk posts this) must not close it — Wisp's
                // own windows are left out of the screenshot anyway. Only drop
                // the auto-present hold so it can't reopen the quick panel.
                if self.viewModel.isWorkspaceOpen {
                    self.presentationHoldUntil = .distantPast
                    return
                }
                self.viewModel.isExpanded = false
                self.viewModel.isFullPanel = false
                // A dismiss means the current answer surface is being cleared off
                // the screen, so the glance card goes with it.
                self.companionManager.resolvedGlanceCard = nil
                // Drop any lingering auto-present hold from the previous turn's
                // answer; otherwise the hover poll would re-open the panel the
                // dismiss just closed (e.g. over the screenshot being captured).
                self.presentationHoldUntil = .distantPast
                self.hoverSuspendedUntil = Date().addingTimeInterval(1.0)
            }
        }

        // Anything that needs the notch's workspace out of the way (e.g. the
        // Agent page's "Show now", which drops the morning banner) posts this.
        closeWorkspaceObserver = NotificationCenter.default.addObserver(
            forName: .wispCloseNotchWorkspace,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setWorkspacePage(nil)
            }
        }

        // Re-place and re-measure the HUD when the display arrangement changes.
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let geometry = self.currentGeometry() {
                    self.viewModel.collapsedSize = geometry.collapsedPillSize
                    self.viewModel.hasNotch = geometry.hasNotch
                }
                self.positionWindow()
            }
        }
    }

    private func positionWindow() {
        guard let panel, let geometry = currentGeometry() else { return }
        panel.setFrame(geometry.expandedWindowFrame(size: viewModel.windowSize), display: true)
    }

    // MARK: - Workspace (chat + settings in the notch)

    /// Opens a workspace page, switches between pages, or closes the workspace
    /// (nil). Unlike hover, this is a deliberate click, so resizing the window
    /// here can't feed back into the hover detection the way the old
    /// resize-on-hover did. The window grows before the morph starts and shrinks
    /// only after the collapse has animated, so neither is ever clipped.
    private func setWorkspacePage(_ requestedPage: NotchWorkspacePage?) {
        guard let panel, let geometry = currentGeometry() else { return }

        if let requestedPage {
            workspaceCloseResizeWorkItem?.cancel()
            workspaceCloseResizeWorkItem = nil
            if !viewModel.isWorkspaceOpen {
                viewModel.windowSize = NotchViewModel.workspaceSize
                panel.setFrame(geometry.expandedWindowFrame(size: NotchViewModel.workspaceSize), display: true)
                // Typing (the Type field, search, dictionary words) needs key
                // focus. A non-activating panel can take it without activating
                // Wisp, so the user's app stays the active one.
                panel.allowsBecomingKey = true
            }
            presentationHoldUntil = .distantPast
            cursorLeftWorkspaceDate = nil
            viewModel.workspacePage = requestedPage
            viewModel.isExpanded = true
            viewModel.isFullPanel = true
            return
        }

        guard viewModel.isWorkspaceOpen else { return }
        viewModel.workspacePage = nil
        viewModel.isExpanded = false
        viewModel.isFullPanel = false
        panel.allowsBecomingKey = false
        cursorLeftWorkspaceDate = nil
        // Don't let the cursor, still near the notch, reopen the quick panel
        // the instant the workspace closes.
        hoverSuspendedUntil = Date().addingTimeInterval(0.6)
        performHUDHaptic()

        let shrinkWindowWorkItem = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel, !self.viewModel.isWorkspaceOpen else { return }
            self.viewModel.windowSize = self.panelSize
            self.positionWindow()
            // Hand the keyboard back: ordering the key panel out and in makes the
            // window server return key focus to the user's app, and with
            // `allowsBecomingKey` off it can't take it back.
            if panel.isKeyWindow {
                panel.orderOut(nil)
                panel.orderFrontRegardless()
            }
        }
        workspaceCloseResizeWorkItem = shrinkWindowWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: shrinkWindowWorkItem)
    }

    /// While the workspace is open it stays open as long as the cursor is over
    /// it, the user is typing in it, a turn is listening, or a mouse button is
    /// held (e.g. a scroll-bar drag that strays outside); otherwise it closes
    /// after a short grace outside.
    private func updateWorkspaceHover(geometry: NotchGeometry, mouseLocation: CGPoint) {
        let workspaceZone = geometry.expandedWindowFrame(size: NotchViewModel.workspaceSize)
            .insetBy(dx: -expandedZoneMargin, dy: -expandedZoneMargin)
        let isTypingInWorkspace = panel?.isKeyWindow == true && panel?.firstResponder is NSText
        let shouldStayOpen = workspaceZone.contains(mouseLocation)
            || isTypingInWorkspace
            || companionManager.voiceState == .listening
            || NSEvent.pressedMouseButtons != 0
        if shouldStayOpen {
            cursorLeftWorkspaceDate = nil
            return
        }
        guard let cursorLeftWorkspaceDate else {
            self.cursorLeftWorkspaceDate = Date()
            return
        }
        if Date().timeIntervalSince(cursorLeftWorkspaceDate) >= workspaceCloseGraceSeconds {
            setWorkspacePage(nil)
        }
    }

    // MARK: - Hover from the mouse position

    /// Polls the cursor position rather than listening for mouse events. A
    /// global event monitor cannot see events over Wisp's own window (so it
    /// could not tell when the cursor leaves the open panel) and does not
    /// observe synthetic events; reading `NSEvent.mouseLocation` on a light
    /// timer sidesteps both and needs no extra permissions. The check is a
    /// couple of rect containments, so the cost at this rate is negligible.
    private func startHoverTracking() {
        stopHoverTracking()
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateHoverFromMousePosition()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverPollTimer = timer
        updateHoverFromMousePosition()
    }

    private func stopHoverTracking() {
        hoverPollTimer?.invalidate()
        hoverPollTimer = nil
    }

    /// Decides expand/collapse from where the mouse is now. Uses a small zone
    /// around the pill to open and a larger zone around the panel to stay open,
    /// so the state does not flicker at the boundary.
    private func updateHoverFromMousePosition() {
        expireLingeringAnswerIfStale()

        // Respect a brief suspension after a force-collapse so the panel does not
        // snap back open under a cursor that is still sitting over it.
        if Date() < hoverSuspendedUntil { return }

        guard let geometry = currentGeometry() else { return }
        let mouseLocation = NSEvent.mouseLocation

        if updateFileDragState(geometry: geometry, mouseLocation: mouseLocation) { return }

        if viewModel.isWorkspaceOpen {
            updateWorkspaceHover(geometry: geometry, mouseLocation: mouseLocation)
            return
        }

        // While an answer is being auto-presented, the panel stays open on its
        // own regardless of hover. Once the hold expires the normal hover logic
        // resumes, so if the cursor is over the panel it stays open and
        // otherwise it collapses.
        let isWithinPresentationHold = Date() < presentationHoldUntil

        if viewModel.isExpanded {
            // Hovering the surface is a deliberate look — upgrade a compact
            // auto-presented message to the full panel (skills, toggles, …). This
            // runs even during a presentation hold so a hover always reveals more.
            if !viewModel.isFullPanel, expandedHotZone(geometry).contains(mouseLocation) {
                viewModel.isFullPanel = true
            }
            if isWithinPresentationHold { return }
            if !expandedHotZone(geometry).contains(mouseLocation) {
                viewModel.isExpanded = false
                viewModel.isFullPanel = false
                performHUDHaptic()
            }
        } else {
            // A collapsed panel during an active hold means something closed it
            // (e.g. a display change) — re-open it so the answer stays visible.
            if isWithinPresentationHold {
                viewModel.isExpanded = true
                return
            }
            // A held mouse button means the user is dragging a window or selecting
            // text near the top of the screen, not reaching for Wisp.
            let isMouseButtonHeld = NSEvent.pressedMouseButtons != 0
            guard collapsedHotZone(geometry).contains(mouseLocation), !isMouseButtonHeld else {
                cursorEnteredCollapsedZoneDate = nil
                return
            }
            guard let cursorEnteredCollapsedZoneDate else {
                cursorEnteredCollapsedZoneDate = Date()
                return
            }
            if Date().timeIntervalSince(cursorEnteredCollapsedZoneDate) >= hoverOpenDwellSeconds {
                // A deliberate, resting hover opens the full panel.
                self.cursorEnteredCollapsedZoneDate = nil
                viewModel.isExpanded = true
                viewModel.isFullPanel = true
                performHUDHaptic()
            }
        }
    }

    /// Opens the island under a file being dragged to the notch so it can be
    /// dropped. Returns true while a drag is handling the panel, so the normal
    /// hover logic (which ignores a held mouse button) stays out of the way.
    private func updateFileDragState(geometry: NotchGeometry, mouseLocation: CGPoint) -> Bool {
        let isFileDragInProgress = fileDragDetector.isFileDragInProgress()
        if !isFileDragInProgress { exitFileDragPanelMode() }
        guard isFileDragInProgress, BrainPreferences.shared.isBrainEnabled, !viewModel.isWorkspaceOpen else {
            if viewModel.isFileDragNearby { viewModel.isFileDragNearby = false }
            return false
        }
        let isNearNotch = fileDragHotZone(geometry).contains(mouseLocation)
            || (viewModel.isExpanded && expandedHotZone(geometry).contains(mouseLocation))
        if isNearNotch {
            viewModel.isFileDragNearby = true
            viewModel.fileDropFeedback = nil
            if !viewModel.isExpanded || viewModel.isFullPanel {
                viewModel.isFullPanel = false
                viewModel.isExpanded = true
            }
            // The panel must not be click-through or the drag goes to whatever
            // is behind it (the desktop).
            panel?.ignoresMouseEvents = false
            enterFileDragPanelMode()
        } else if viewModel.isFileDragNearby {
            viewModel.isFileDragNearby = false
            viewModel.isExpanded = false
        }
        return true
    }

    private var normalPanelLevel: NSWindow.Level?

    /// While a file is dragged near the notch, the panel drops to a window
    /// level just above the menu bar and may become key. At its normal level
    /// (above the screen saver) and non-key, macOS never delivered the drag to
    /// the drop view and the file landed on the desktop behind it. Restored as
    /// soon as the drag ends.
    private func enterFileDragPanelMode() {
        guard let panel, normalPanelLevel == nil else { return }
        normalPanelLevel = panel.level
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.allowsBecomingKey = true
    }

    private func exitFileDragPanelMode() {
        guard let panel, let normalPanelLevel else { return }
        panel.level = normalPanelLevel
        panel.allowsBecomingKey = viewModel.isWorkspaceOpen
        self.normalPanelLevel = nil
    }

    /// Queues dropped files for the brain and reports the result in the island.
    /// Returns whether anything readable was taken.
    private func addDroppedFilesToBrain(_ droppedFileURLs: [URL]) -> Bool {
        guard BrainPreferences.shared.isBrainEnabled else { return false }
        let readableFileURLs = droppedFileURLs.filter {
            BrainIngestFileRules.isSupported(fileExtension: $0.pathExtension.lowercased())
        }
        viewModel.isFileDragNearby = false
        guard !readableFileURLs.isEmpty else {
            showFileDropFeedback("Wisp can't read that kind of file")
            companionManager.flashIsland(.error)
            return false
        }
        for readableFileURL in readableFileURLs {
            BrainIngestQueue.shared.enqueue(fileURL: readableFileURL)
        }
        let fileCountDescription = readableFileURLs.count == 1 ? "1 file" : "\(readableFileURLs.count) files"
        showFileDropFeedback("Added \(fileCountDescription) to your brain")
        companionManager.flashIsland(.success)
        return true
    }

    private func showFileDropFeedback(_ message: String) {
        viewModel.fileDropFeedback = message
        fileDropFeedbackClearTask?.cancel()
        fileDropFeedbackClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.viewModel.fileDropFeedback = nil
        }
    }

    /// Clears an answer once it has sat folded away in the notch, untouched, for
    /// `lingeringAnswerExpirySeconds`. The clock only runs while the answer is
    /// out of sight (collapsed, idle, past its presentation hold), so reading or
    /// hovering it never races the expiry. A running timer's card is kept — its
    /// countdown is still live information.
    private func expireLingeringAnswerIfStale() {
        let hasReplyText = !companionManager.currentReplyText
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAnswer = hasReplyText || companionManager.resolvedGlanceCard != nil
        let isAnswerOutOfSight = hasAnswer
            && !viewModel.isExpanded
            && companionManager.voiceState == .idle
            && Date() >= presentationHoldUntil
            && !companionManager.guidedWalkthrough.isActive
        guard isAnswerOutOfSight, !isShowingRunningTimerCard else {
            answerLingeringSinceDate = nil
            return
        }
        guard let answerLingeringSinceDate else {
            self.answerLingeringSinceDate = Date()
            return
        }
        guard Date().timeIntervalSince(answerLingeringSinceDate) >= lingeringAnswerExpirySeconds else { return }
        self.answerLingeringSinceDate = nil
        companionManager.currentReplyText = ""
        companionManager.resolvedGlanceCard = nil
    }

    private var isShowingRunningTimerCard: Bool {
        guard case let .timer(timerCardState) = companionManager.resolvedGlanceCard,
              let timer = WispTimerStore.shared.timer(withID: timerCardState.timerID) else { return false }
        return timer.status == .running
    }

    /// Opens the panel on its own and holds it open long enough to read the
    /// answer, scaled by its length. Called from the reply/card observers the
    /// moment a new answer lands, so the notch presents results without the user
    /// having to hover it — the behaviour a dynamic island is expected to have.
    private func autoPresentAnswer(readingLength: Int) {
        // Floor of 6s so even a one-word answer is seen; ~22 characters/second
        // of reading time on top of that; capped at 20s so it never lingers.
        let holdSeconds = min(max(6.0, Double(readingLength) / 22.0), 20.0)
        presentationHoldUntil = Date().addingTimeInterval(holdSeconds)
        // The turn that produced this answer began with a force-collapse that
        // briefly suspends hover; clear that so the answer can open immediately.
        hoverSuspendedUntil = .distantPast
        // An answer auto-presents as the COMPACT message, not the full panel — a
        // short reply shouldn't drop a whole dashboard. A deliberate hover upgrades
        // it to the full panel (see the hover logic above).
        viewModel.isFullPanel = false
        if !viewModel.isExpanded {
            viewModel.isExpanded = true
            performHUDHaptic()
        }
    }

    /// Opens the compact morning banner and holds it long enough to notice and
    /// decide on. A hover upgrades it to the full panel's TODAY list, like an
    /// answer; left alone, it tucks back into the notch's ✦ count.
    private func autoPresentMorningBriefing() {
        let morningBannerHoldSeconds: TimeInterval = 30
        presentationHoldUntil = Date().addingTimeInterval(morningBannerHoldSeconds)
        hoverSuspendedUntil = .distantPast
        viewModel.isFullPanel = false
        if !viewModel.isExpanded {
            viewModel.isExpanded = true
            performHUDHaptic()
        }
        WispSoundPlayer.shared.play(.reply)
    }

    /// A light, smooth "alignment" tick when the HUD opens or closes — the same
    /// gentle feedback macOS uses when a dragged guide snaps into place. It is a
    /// no-op on Macs without a Force Touch trackpad and respects the user's
    /// system haptics setting, so it never needs a preference of its own.
    private func performHUDHaptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }

    /// A tight target hugging the notch at the very top-center of the screen —
    /// only the notch itself plus a small margin, confined to the menu bar strip,
    /// so passing over nearby menu bar items or the top of a window doesn't open
    /// it. Only while the island is actually showing something (listening,
    /// thinking, a lingering answer) does the zone reach down to cover the
    /// surface hanging below the notch, so hovering that visible island opens it.
    private func collapsedHotZone(_ geometry: NotchGeometry) -> CGRect {
        let width = geometry.collapsedPillSize.width + 24
        let isIslandShowingBelowNotch = geometry.hasNotch
            && (companionManager.voiceState != .idle || !companionManager.currentReplyText.isEmpty)
        let hangingBarReach: CGFloat = isIslandShowingBelowNotch ? 48 : 0
        let height = max(geometry.collapsedPillSize.height + hangingBarReach, 34)
        let originX = geometry.screenFrame.midX - width / 2
        let originY = geometry.screenFrame.maxY - height
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    /// Where a dragged file opens the island: a generous band across the top
    /// centre of the screen. A held file sits well below the cursor's hot spot
    /// and people aim loosely, so the pill's own 34pt hover strip is far too
    /// small — the drag missed it and the drop went to the desktop.
    private func fileDragHotZone(_ geometry: NotchGeometry) -> CGRect {
        let width = panelSize.width
        let height: CGFloat = 140
        return CGRect(
            x: geometry.screenFrame.midX - width / 2,
            y: geometry.screenFrame.maxY - height,
            width: width,
            height: height
        )
    }

    /// The visible panel rect plus a hysteresis margin.
    private func expandedHotZone(_ geometry: NotchGeometry) -> CGRect {
        let width = panelSize.width + expandedZoneMargin * 2
        let height = panelSize.height + expandedZoneMargin
        let originX = geometry.screenFrame.midX - width / 2
        let originY = geometry.screenFrame.maxY - height
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    // MARK: - Geometry

    /// The HUD lives on whichever screen holds the menu bar — the first screen,
    /// whose origin is (0, 0) in the global coordinate space.
    private func currentGeometry() -> NotchGeometry? {
        guard let menuBarScreen = NSScreen.screens.first else { return nil }
        return NotchGeometry(screen: menuBarScreen)
    }
}

/// Non-activating panel that never steals focus — except while the notch's
/// workspace (chat + settings) is open, when it may become key so its text
/// fields take typing. Being non-activating, it takes key focus without
/// activating Wisp, so the user's app stays in front.
final class NotchPanel: NSPanel {
    /// Turned on by the controller only while the workspace is open.
    var allowsBecomingKey = false
    /// Esc while the panel is key (the workspace is open and focused).
    var onEscapePressed: (() -> Void)?

    override var canBecomeKey: Bool { allowsBecomingKey }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscapePressed?()
    }
}

/// An `NSHostingView` that accepts the first mouse click. On a menu-bar-only app
/// the notch panel is hosted by a background (non-frontmost) application, so by
/// default the first click on any SwiftUI control is consumed just to bring the
/// window forward and the control never receives it. Returning `true` here
/// delivers that first click straight to the control, so a single click on a
/// skill chip or a toggle works — no throwaway click required.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
