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

/// A panel rather than a plain window so it can be `.nonactivatingPanel`: while
/// a confirmation card with editable fields is up, the overlay has to take key
/// focus for typing, and a non-activating panel can do that without activating
/// Wisp — the user's app stays the active one (the same approach as
/// `NotchPanel.allowsBecomingKey`).
class OverlayWindow: NSPanel {
    /// Turned on by `OverlayWindowManager` only while a confirmation card with
    /// editable fields is showing. Off, the overlay never takes focus.
    var allowsBecomingKey = false

    init(screen: NSScreen) {
        // Create window covering entire screen
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
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

    // No focus stealing: key only while an editable confirmation card needs typing.
    override var canBecomeKey: Bool {
        return allowsBecomingKey
    }

    override var canBecomeMain: Bool {
        return false
    }

    /// Esc while editing a card field just leaves the field. It never closes
    /// the overlay (a panel's default) and never answers the prompt — the
    /// Cancel and Allow buttons, or the voice, do that.
    override func cancelOperation(_ sender: Any?) {
        makeFirstResponder(nil)
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far below the top of the screen the confirmation card starts: under
    /// the notch (its height is the screen's top safe-area inset) or, on a Mac
    /// without one, under the menu bar — plus a small gap, so the card hangs
    /// from the island instead of overlapping it.
    private var confirmationCardTopInset: CGFloat {
        let notchHeight = NSScreen.screens.first { $0.frame == screenFrame }?.safeAreaInsets.top ?? 0
        let topObstructionHeight = notchHeight > 0 ? notchHeight : NSStatusBar.system.thickness
        return topObstructionHeight + WispSpacing.md
    }

    /// VoiceOver says nothing when a window appears under a background app, so
    /// the card would wait silently for an answer the user can't know is
    /// wanted. Announced once, from the screen showing the card.
    private func announceConfirmationForVoiceOver() {
        guard let confirmation = companionManager.pendingToolConfirmation,
              screenFrame.contains(NSEvent.mouseLocation) else { return }
        let firstCardTitle = confirmation.confirmationCard?.blocks.lazy.compactMap { block -> String? in
            if case .header(let title, _, _) = block { return title }
            return nil
        }.first
        let announcementText = ["Wisp needs your OK.", firstCardTitle, "Allow or Cancel, or say yes."]
            .compactMap { $0 }
            .joined(separator: " ")
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcementText,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

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
                // Anchored by its top edge just below the notch. It used to be
                // placed by its centre at a fixed height, so a taller card (a
                // glance card, editable fields) grew upward behind the notch and
                // hid its own header.
                VStack(spacing: 0) {
                    ToolConfirmationView(
                        confirmation: confirmation,
                        confirmationCoordinator: ToolConfirmationCoordinator.shared,
                        onApprove: {
                            companionManager.flashIsland(.success)
                            ToolConfirmationCoordinator.shared.approveFromUserInterface()
                        },
                        onDeny: {
                            // A choice, not a failure: no red flash, no error thud.
                            WispSoundPlayer.shared.play(.declined)
                            ToolConfirmationCoordinator.shared.declineFromUserInterface()
                        }
                    )
                    // A new request is a new card, so one prompt replacing another
                    // animates instead of rewriting the old card in place.
                    .id(confirmation.id)
                    .padding(.top, confirmationCardTopInset)
                    Spacer(minLength: 0)
                }
                .frame(width: screenFrame.width, height: screenFrame.height, alignment: .top)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
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

            // Live browser-task progress, in the badge's spot while no gesture
            // badge needs it. Shown on the main screen's overlay only, where the
            // notch is, so one task does not print its progress on every monitor.
            if companionManager.activeCommandMode == nil,
               !companionManager.browserActivityText.isEmpty,
               screenFrame == NSScreen.screens.first?.frame {
                BrowserActivityIndicator(activityText: companionManager.browserActivityText)
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
                    displaySize: screenFrame.size,
                    visibleNoteLimit: companionManager.visibleNoteLimit
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
        // Without this the card's transition had nothing to animate it, so it
        // popped in and out.
        .animation(reduceMotion ? nil : WispMotion.island, value: companionManager.pendingToolConfirmation?.id)
        .onChange(of: companionManager.pendingToolConfirmation?.id) { _ in
            announceConfirmationForVoiceOver()
        }
        .animation(.easeOut(duration: 0.18), value: companionManager.activeCommandMode)
        .animation(.easeOut(duration: 0.18), value: companionManager.browserActivityText.isEmpty)
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
        currentlyAcceptsMouseEvents = acceptsMouseEvents
        for window in overlayWindows {
            window.ignoresMouseEvents = !acceptsMouseEvents
            // Only while a card is up is there anything here to name; VoiceOver
            // otherwise read the window as just "window".
            window.setAccessibilityTitle(acceptsMouseEvents ? "Wisp needs your OK" : nil)
        }
    }

    /// Remembered so windows rebuilt while a card is up (a push-to-talk can
    /// rebuild the overlay) come back in the same state.
    private var currentlyAcceptsMouseEvents = false
    private var currentlyAllowsKeyboardFocus = false

    /// Lets the overlay take key focus, for typing into a confirmation card's
    /// editable fields. Turning it off hands the keyboard back: ordering a key
    /// panel out and in makes the window server return focus to the user's
    /// app, and with `allowsBecomingKey` off the overlay can't take it again.
    func setAllowsKeyboardFocus(_ allowsKeyboardFocus: Bool) {
        currentlyAllowsKeyboardFocus = allowsKeyboardFocus
        for window in overlayWindows {
            window.allowsBecomingKey = allowsKeyboardFocus
            if !allowsKeyboardFocus && window.isKeyWindow {
                window.orderOut(nil)
                window.orderFrontRegardless()
            }
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
            //
            // First-mouse hosting, as in the notch: the overlay belongs to a
            // background app, so without it the first click on the card (a
            // button, or an editable field) would only bring the window forward.
            let hostingView = FirstMouseHostingView(rootView: contentView.environment(\.colorScheme, .dark))
            hostingView.frame = screen.frame
            window.contentView = hostingView
            window.ignoresMouseEvents = !currentlyAcceptsMouseEvents
            window.allowsBecomingKey = currentlyAllowsKeyboardFocus

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
