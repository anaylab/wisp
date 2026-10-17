//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// Captures all connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen. This gives the AI
    /// full context across multiple monitors.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        // Sort displays so the cursor screen is always first
        let sortedDisplays = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = frameA.contains(mouseLocation)
            let bContainsCursor = frameB.contains(mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in sortedDisplays.enumerated() {
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation
            // and the overlay window's screenFrame in OverlayContentView.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

            let configuration = SCStreamConfiguration()
            // Vision-model prompt evaluation dominates local inference and
            // scales with image area, not file size. Measured against
            // qwen2.5-vl on an M3 Pro: a 1280px capture costs 4049 image
            // tokens and ~33s to encode, while 896px costs 1095 tokens and
            // ~7s. Below 896px the token count stops falling (Ollama floors
            // at its --image-min-tokens setting), so 896 is the point where
            // the image is as large as it can be without costing extra time.
            let maxDimension = 896
            let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
            if display.width >= display.height {
                configuration.width = maxDimension
                configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
            } else {
                configuration.height = maxDimension
                configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
            }

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            guard let freshJPEGData = NSBitmapImageRep(cgImage: cgImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                continue
            }

            // Hand back the previous frame's bytes when the screen has not
            // changed. Ollama keys its encoded-image cache on the exact bytes,
            // and a fresh capture of an unchanged screen is never byte-identical
            // — JPEG noise and a ticking clock are enough — so without this a
            // follow-up question re-encodes the same picture for 6.4s.
            let (jpegData, didReuse) = await MainActor.run {
                ScreenshotReuseCache.bytesToSend(
                    forDisplay: display.displayID,
                    freshData: freshJPEGData,
                    freshImage: cgImage
                )
            }
            if didReuse {
                print("🖼️ Screen unchanged — reusing the cached frame (skips ~6s of image encoding)")
            }

            // Start on-device OCR of this frame now, off the main actor, so it
            // is usually finished by the time the turn wants it — the
            // push-to-talk capture runs while the user is still speaking.
            // Keyed on the bytes actually sent, so an unchanged (reused) frame
            // is never recognised twice. See `ScreenTextRecognizer`.
            ScreenTextRecognizer.shared.beginRecognitionIfNeeded(
                forDisplay: display.displayID,
                imageData: jpegData,
                screenshotImage: cgImage
            )

            let screenLabel: String
            if sortedDisplays.count == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — secondary screen"
            }

            capturedScreens.append(CompanionScreenCapture(
                imageData: jpegData,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                screenshotWidthInPixels: configuration.width,
                screenshotHeightInPixels: configuration.height
            ))
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }

    /// A native-resolution close-up of one selected part of the screen, so the
    /// model can read text and symbols the 896px full-screen capture blurs.
    /// Capped at 1400px on its longest side to keep the image cheap. Nil if the
    /// display can't be found or the capture fails — the turn then just goes
    /// without a close-up.
    static func captureCloseUpAsJPEG(of focusedRegion: FocusedScreenRegion) async -> Data? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return nil
        }

        // Match the display by its AppKit frame, as the full capture does.
        guard let display = content.displays.first(where: { display in
            NSScreen.screens.contains { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
                    && screen.frame == focusedRegion.displayFrameInAppKitCoordinates
            }
        }) else { return nil }

        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundleIdentifier }
        let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

        let regionInDisplayPoints = focusedRegion.rectInDisplayPointsTopLeftOrigin
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = regionInDisplayPoints

        let longestSideInPixels: CGFloat = 1400
        let scale = min(2.0, longestSideInPixels / max(regionInDisplayPoints.width, regionInDisplayPoints.height))
        configuration.width = max(1, Int(regionInDisplayPoints.width * scale))
        configuration.height = max(1, Int(regionInDisplayPoints.height * scale))

        guard let cgImage = try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        ) else { return nil }

        return NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    /// A fresh capture of ONE display at its native pixel resolution (not the
    /// 896px model copy), with all of Wisp's own windows left out, so a saved
    /// picture shows the user's content and Wisp can draw its explanation over
    /// it afterwards. The display is matched by its AppKit frame, as the
    /// drawings are keyed. Nil if the display can't be found or the capture fails.
    static func captureDisplayAtNativeResolution(displayFrameInAppKitCoordinates: CGRect) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return nil
        }

        guard let matchingScreen = NSScreen.screens.first(where: { $0.frame == displayFrameInAppKitCoordinates }),
              let matchingDisplayID = matchingScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let display = content.displays.first(where: { $0.displayID == matchingDisplayID }) else {
            return nil
        }

        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundleIdentifier }
        let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

        let configuration = SCStreamConfiguration()
        let pixelsPerPoint = matchingScreen.backingScaleFactor
        configuration.width = max(1, Int(displayFrameInAppKitCoordinates.width * pixelsPerPoint))
        configuration.height = max(1, Int(displayFrameInAppKitCoordinates.height * pixelsPerPoint))

        return try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }
}
