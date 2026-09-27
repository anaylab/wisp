//
//  NotchGeometry.swift
//  leanring-buddy
//
//  Resolves where Wisp's notch HUD sits on a given screen, and how large the
//  collapsed pill is, working on both notched and non-notched Macs.
//
//  On a notched Mac the collapsed pill is sized to the physical notch so the
//  HUD reads as a natural extension of it. On a Mac without a notch there is no
//  cutout to grow out of, so the pill becomes a small floating tab tucked just
//  under the menu bar at the top center of the screen — the documented fallback.
//
//  All returned frames are in AppKit screen coordinates (bottom-left origin,
//  y increasing upward), ready to hand straight to `NSWindow.setFrame`.
//

import AppKit

struct NotchGeometry {
    /// Whether the screen physically has a notch.
    let hasNotch: Bool

    /// The full screen frame, in AppKit screen coordinates.
    let screenFrame: CGRect

    /// The size of the collapsed pill. Matches the physical notch on a notched
    /// Mac; a fixed floating-tab size otherwise.
    let collapsedPillSize: CGSize

    /// Reads the geometry for `screen`. Falls back to a synthetic floating pill
    /// when the screen has no notch or the OS does not report auxiliary areas.
    init(screen: NSScreen) {
        let frame = screen.frame
        self.screenFrame = frame

        // A positive top safe-area inset is the notch. A menu-bar-only screen
        // reports zero here even though the menu bar occupies space at the top.
        let topSafeAreaInset = screen.safeAreaInsets.top
        let screenPhysicallyHasNotch = topSafeAreaInset > 0

        // The physical notch width is the gap between the usable areas to its
        // left and right. Both are nil on non-notched Macs and older systems.
        var physicalNotchWidth: CGFloat = 0
        if let leftAuxiliaryArea = screen.auxiliaryTopLeftArea,
           let rightAuxiliaryArea = screen.auxiliaryTopRightArea {
            physicalNotchWidth = max(0, rightAuxiliaryArea.minX - leftAuxiliaryArea.maxX)
        }

        if screenPhysicallyHasNotch && physicalNotchWidth > 0 {
            self.hasNotch = true
            self.collapsedPillSize = CGSize(width: physicalNotchWidth, height: topSafeAreaInset)
        } else {
            // No notch: float a small pill just under the menu bar. Sized so the
            // wisp glyph and a state dot sit comfortably without crowding.
            self.hasNotch = false
            self.collapsedPillSize = CGSize(width: 120, height: 24)
        }
    }

    // MARK: - Window frames

    /// The collapsed pill window frame, centered at the top of the screen.
    ///
    /// A notched Mac gets a pill flush with the very top edge so it merges with
    /// the cutout; the floating fallback sits two points below the top so it
    /// reads as a distinct tab rather than part of the menu bar.
    var collapsedWindowFrame: CGRect {
        let size = collapsedPillSize
        let originX = screenFrame.midX - size.width / 2
        let originY = hasNotch
            ? screenFrame.maxY - size.height
            : screenFrame.maxY - size.height - 2
        return CGRect(x: originX, y: originY, width: size.width, height: size.height)
    }

    /// The expanded quick-panel window frame, centered and hanging down from the
    /// top of the screen by `size.height`.
    func expandedWindowFrame(size: CGSize) -> CGRect {
        let originX = screenFrame.midX - size.width / 2
        let originY = screenFrame.maxY - size.height
        return CGRect(x: originX, y: originY, width: size.width, height: size.height)
    }
}
