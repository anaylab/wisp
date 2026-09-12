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
    @Published var expandedSize: CGSize = CGSize(width: 360, height: 272)
}

@MainActor
final class NotchWindowController {
    private var panel: NotchPanel?
    private let companionManager: CompanionManager
    private let viewModel = NotchViewModel()
    private var clickThroughObserver: AnyCancellable?
    private var hoverPollTimer: Timer?
    private var screenParametersObserver: NSObjectProtocol?

    /// The expanded panel's fixed size.
    private let panelSize = CGSize(width: 360, height: 272)

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

        let hostingView = NSHostingView(rootView: notchHUDView)
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
        // while the panel is open so its buttons can be used.
        clickThroughObserver = viewModel.$isExpanded
            .removeDuplicates()
            .sink { [weak self] isExpanded in
                self?.panel?.ignoresMouseEvents = !isExpanded
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
        guard let geometry = currentGeometry() else { return }
        let mouseLocation = NSEvent.mouseLocation

        if viewModel.isExpanded {
            if !expandedHotZone(geometry).contains(mouseLocation) {
                viewModel.isExpanded = false
                performHUDHaptic()
            }
        } else {
            if collapsedHotZone(geometry).contains(mouseLocation) {
                viewModel.isExpanded = true
                performHUDHaptic()
            }
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
