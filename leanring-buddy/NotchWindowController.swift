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
    /// The collapsed pill's size — matches the physical notch when there is one.
    @Published var collapsedSize: CGSize = CGSize(width: 180, height: 32)
    /// The expanded panel's size, and therefore the fixed window size.
    @Published var expandedSize: CGSize = CGSize(width: 360, height: 404)
}

@MainActor
final class NotchWindowController {
    private var panel: NotchPanel?
    private let companionManager: CompanionManager
    private let viewModel = NotchViewModel()
    private var clickThroughObserver: AnyCancellable?
    private var hoverPollTimer: Timer?
    private var screenParametersObserver: NSObjectProtocol?
    private var dismissObserver: NSObjectProtocol?

    /// Combine subscriptions that auto-present the panel the moment an answer
    /// lands — the reply text (silent mode's only surface) and any glance card.
    /// Without these the answer is generated but stays invisible until the user
    /// happens to hover the notch, which is why silent mode looked broken.
    private var replyPresentationObserver: AnyCancellable?
    private var cardPresentationObserver: AnyCancellable?

    /// Hover is ignored until this moment. Set when the HUD is force-collapsed
    /// (e.g. a skill was launched) so the click that triggered it — or the
    /// screenshot about to be taken — does not immediately reopen the panel.
    private var hoverSuspendedUntil: Date = .distantPast

    /// While `Date() < presentationHoldUntil` the panel is held open on its own,
    /// independent of hover, so a freshly arrived answer is shown long enough to
    /// read. Hovering the panel keeps it open past the hold through the normal
    /// hover logic; moving away after the hold expires collapses it as usual.
    private var presentationHoldUntil: Date = .distantPast

    /// The expanded panel's fixed size. Kept compact — it holds the voice
    /// affordance, the scrollable answer surface, the sideways skills strip and
    /// the footer, and the answer surface scrolls rather than growing the window.
    private let panelSize = CGSize(width: 360, height: 404)

    /// Extra slack added around the panel so a small overshoot at the edge does
    /// not immediately collapse it — the hysteresis that keeps the hover stable.
    private let expandedZoneMargin: CGFloat = 10

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
    }

    func hide() {
        stopHoverTracking()
        panel?.orderOut(nil)
    }

    // MARK: - Panel construction

    private func createPanel() {
        guard let geometry = currentGeometry() else { return }

        viewModel.collapsedSize = geometry.collapsedPillSize
        viewModel.expandedSize = panelSize

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
        notchPanel.contentView = hostingView
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
                self?.autoPresentAnswer(readingLength: trimmed.count)
            }

        // A glance card is also an answer surface, so open the panel for one even
        // when the turn produced no reply text (e.g. a card-only reply).
        cardPresentationObserver = companionManager.$resolvedGlanceCard
            .sink { [weak self] resolvedGlanceCard in
                guard resolvedGlanceCard != nil else { return }
                self?.autoPresentAnswer(readingLength: 0)
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
                self.viewModel.isExpanded = false
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
                }
                self.positionWindow()
            }
        }
    }

    private func positionWindow() {
        guard let panel, let geometry = currentGeometry() else { return }
        panel.setFrame(geometry.expandedWindowFrame(size: panelSize), display: true)
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
        // Respect a brief suspension after a force-collapse so the panel does not
        // snap back open under a cursor that is still sitting over it.
        if Date() < hoverSuspendedUntil { return }

        guard let geometry = currentGeometry() else { return }
        let mouseLocation = NSEvent.mouseLocation

        // While an answer is being auto-presented, the panel stays open on its
        // own regardless of hover. Once the hold expires the normal hover logic
        // resumes, so if the cursor is over the panel it stays open and
        // otherwise it collapses.
        let isWithinPresentationHold = Date() < presentationHoldUntil

        if viewModel.isExpanded {
            if isWithinPresentationHold { return }
            if !expandedHotZone(geometry).contains(mouseLocation) {
                viewModel.isExpanded = false
                performHUDHaptic()
            }
        } else {
            // A collapsed panel during an active hold means something closed it
            // (e.g. a display change) — re-open it so the answer stays visible.
            if isWithinPresentationHold {
                viewModel.isExpanded = true
                return
            }
            if collapsedHotZone(geometry).contains(mouseLocation) {
                viewModel.isExpanded = true
                performHUDHaptic()
            }
        }
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
        if !viewModel.isExpanded {
            viewModel.isExpanded = true
            performHUDHaptic()
        }
    }

    /// A light, smooth "alignment" tick when the HUD opens or closes — the same
    /// gentle feedback macOS uses when a dragged guide snaps into place. It is a
    /// no-op on Macs without a Force Touch trackpad and respects the user's
    /// system haptics setting, so it never needs a preference of its own.
    private func performHUDHaptic() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }

    /// A generous target around the pill at the very top-center of the screen.
    private func collapsedHotZone(_ geometry: NotchGeometry) -> CGRect {
        let width = max(geometry.collapsedPillSize.width + 48, 240)
        let height = max(geometry.collapsedPillSize.height, 34)
        let originX = geometry.screenFrame.midX - width / 2
        let originY = geometry.screenFrame.maxY - height
        return CGRect(x: originX, y: originY, width: width, height: height)
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

/// Non-activating panel that never steals focus. Kept distinct from the menu
/// bar's `KeyablePanel` because the notch HUD, in this phase, has nothing that
/// needs to become first responder; a later text-composer phase can revisit it.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
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
