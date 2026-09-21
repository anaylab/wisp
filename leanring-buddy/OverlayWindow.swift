//
//  OverlayWindow.swift
//  leanring-buddy
//
//  System-wide transparent overlay window. One OverlayWindow is created per
//  screen so the assistant's on-screen surfaces — the tool-confirmation card
//  and the drawn markers, boxes, arrows and highlights — appear on whichever
//  monitor they belong to. The window itself draws nothing and is click-through
//  except while a confirmation card is up.
//

import AppKit
import SwiftUI

class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        // Create window covering entire screen
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Make window transparent and non-interactive
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver  // Always on top, above submenus and popups
        self.ignoresMouseEvents = true  // Click-through
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false

        // Important: Allow the window to appear even when app is not active
        self.hidesOnDeactivate = false

        // Cover the entire screen
        self.setFrame(screen.frame, display: true)

        // Make sure it's on the right screen
        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    // Prevent window from becoming key (no focus stealing)
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }
}

// Cursor-like triangle shape (equilateral). Retained as a shared glyph used by
// the dashboard, the text composer, and the Cursor settings tab — it is no
// longer drawn as a live on-screen cursor.
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let size = min(rect.width, rect.height)
        let height = size * sqrt(3.0) / 2.0

        // Top vertex
        path.move(to: CGPoint(x: rect.midX, y: rect.midY - height / 1.5))
        // Bottom left vertex
        path.addLine(to: CGPoint(x: rect.midX - size / 2, y: rect.midY + height / 3))
        // Bottom right vertex
        path.addLine(to: CGPoint(x: rect.midX + size / 2, y: rect.midY + height / 3))
        path.closeSubpath()
        return path
    }
}

/// The content of one screen's overlay window.
///
/// It hosts the assistant's non-interactive surfaces: the ambient listening glow
/// (on every screen while the mic is live), the tool-confirmation card and the
/// command-mode badge (both on the screen the cursor is on, so the user sees one
/// of each), and the layer that draws the markers, boxes, arrows and highlights
/// for this screen. It tracks no cursor and runs no idle animation — there is
/// nothing to draw while the assistant is at rest.
struct OverlayContentView: View {
    let screenFrame: CGRect
    @ObservedObject var companionManager: CompanionManager

    /// Whether the mouse was on this screen at the moment a confirmation or a
    /// command-mode badge appeared. Recomputed only when one of those arrives, so
    /// the resident overlay does no work while idle.
    @State private var isCursorOnThisScreen: Bool = false

    var body: some View {
        ZStack {
            // Nearly transparent background (helps with compositing)
            Color.black.opacity(0.001)

            // Ambient "Wisp is listening" glow around the screen edges. Drawn on
            // every screen while the mic is live, behind everything else so it
            // never obscures the badge, a card, or an annotation.
            if companionManager.voiceState == .listening {
                ScreenListeningGlow()
                    .transition(.opacity)
            }

            // Permission prompt, on the screen the user is looking at. Shown
            // on the cursor's screen alone — one question needs one answer,
            // and a copy on every monitor would suggest otherwise.
            if isCursorOnThisScreen,
               let confirmation = companionManager.pendingToolConfirmation {
                ToolConfirmationView(
                    confirmation: confirmation,
                    onApprove: {
                        companionManager.flashIsland(.success)
                        ToolConfirmationCoordinator.shared.approveFromUserInterface()
                    },
                    onDeny: {
                        companionManager.flashIsland(.error)
                        ToolConfirmationCoordinator.shared.declineFromUserInterface()
                    }
                )
                // Sits just under the notch, so the request reads as the Dynamic
                // Island expanding into a confirmation rather than a card in the
                // corner of the screen.
                .position(
                    x: screenFrame.width / 2,
                    y: 150
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // The command-mode badge — naming which push-to-talk gesture just
            // fired (Talk / Dictate / Type / Hands-free). Tucked just under the
            // notch, above where a confirmation card would sit, on the screen the
            // user is looking at.
            if isCursorOnThisScreen,
               let commandMode = companionManager.activeCommandMode {
                CommandModeIndicator(mode: commandMode)
                    .position(x: screenFrame.width / 2, y: 64)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Assistant-drawn markers, boxes, arrows and highlights for this
            // screen. A [POINT:] coordinate arrives here as a pulsing marker —
            // the replacement for the old flying cursor's pointing gesture.
            if let annotations = companionManager.activeAnnotationsByDisplayFrame[screenFrame],
               let screenshotSize = companionManager.annotationScreenshotSizeByDisplayFrame[screenFrame],
               !annotations.isEmpty {
                ScreenAnnotationLayer(
                    annotations: annotations,
                    screenshotSize: screenshotSize,
                    displaySize: screenFrame.size
                )
                .transition(.opacity)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onAppear {
            isCursorOnThisScreen = screenFrame.contains(NSEvent.mouseLocation)
        }
        .onChange(of: companionManager.pendingToolConfirmation != nil) { hasConfirmation in
            // Only the screen the cursor is on when the prompt appears shows it.
            if hasConfirmation {
                isCursorOnThisScreen = screenFrame.contains(NSEvent.mouseLocation)
            }
        }
        .onChange(of: companionManager.activeCommandMode != nil) { hasCommandMode in
            // Pin the badge to whichever screen the cursor is on when the gesture
            // fires, the same way the confirmation card picks its screen.
            if hasCommandMode {
                isCursorOnThisScreen = screenFrame.contains(NSEvent.mouseLocation)
            }
        }
        .animation(.easeOut(duration: 0.18), value: companionManager.activeCommandMode)
        .animation(WispMotion.smooth, value: companionManager.voiceState == .listening)
    }
}

// Manager for overlay windows — creates one per screen so the assistant's
// on-screen surfaces appear on the correct monitor.
@MainActor
class OverlayWindowManager {
    private var overlayWindows: [OverlayWindow] = []
    var hasShownOverlayBefore = false

    /// Lets the overlay receive clicks, for as long as something in it needs
    /// them.
    ///
    /// The overlay is normally click-through, and must be: it covers the whole
    /// screen at a level above nearly everything, so while it accepts mouse
    /// events nothing behind it can be clicked. That is tolerable only for the
    /// moment a confirmation is on screen, and only because the card is the
    /// sole thing inside that hit-tests — every other layer, including the
    /// near-invisible backdrop, stays transparent to the mouse so clicks
    /// outside the card still reach whatever is underneath.
    func setAcceptsMouseEvents(_ acceptsMouseEvents: Bool) {
        for window in overlayWindows {
            window.ignoresMouseEvents = !acceptsMouseEvents
        }
    }

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        // Hide any existing overlays
        hideOverlay()

        hasShownOverlayBefore = true

        // Create one overlay window per screen
        for screen in screens {
            let window = OverlayWindow(screen: screen)

            let contentView = OverlayContentView(
                screenFrame: screen.frame,
                companionManager: companionManager
            )

            // The overlay's cards (e.g. the tool-confirmation panel) are dark
            // glass surfaces like the notch, so pin a dark colour scheme so their
            // adaptive tokens resolve dark regardless of the system appearance.
            let hostingView = NSHostingView(rootView: contentView.environment(\.colorScheme, .dark))
            hostingView.frame = screen.frame
            window.contentView = hostingView

            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
    }

    func hideOverlay() {
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
    }

    /// Fades out overlay windows over `duration` seconds, then removes them.
    func fadeOutAndHideOverlay(duration: TimeInterval = 0.4) {
        let windowsToFade = overlayWindows
        overlayWindows.removeAll()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in windowsToFade {
                window.animator().alphaValue = 0
            }
        }, completionHandler: {
            for window in windowsToFade {
                window.orderOut(nil)
                window.contentView = nil
            }
        })
    }

    func isShowingOverlay() -> Bool {
        return !overlayWindows.isEmpty
    }
}
