//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Screenshot capture for the companion flow: the downscaled all-display
//  frames sent to the model, a native-resolution close-up of a selected part,
//  and a full-resolution single display for saved worked solutions. Wisp's own
//  windows are always left out of every capture.
//

import AppKit
import ScreenCaptureKit

/// One captured display, ready to attach to a model request.
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

    /// Longest side of the picture sent to the model.
    ///
    /// Vision prompt evaluation dominates local inference and grows with image
    /// area, not file size. Measured with qwen2.5-vl on an M3 Pro, a 1280px frame
    /// costs 4049 image tokens and about 33s to encode, while 896px costs 1095
    /// tokens and about 7s. Under 896px the token count stops falling (Ollama
    /// floors it at `--image-min-tokens`), so this is the largest the image can
    /// be without costing extra time.
    private static let modelImageLongestSide = 896

    private static let displayNumberKey = NSDeviceDescriptionKey("NSScreenNumber")

    // MARK: - All displays

    /// Captures every connected display as JPEG, cursor display first, each
    /// labelled so the model knows which screen the user is looking at.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !shareableContent.displays.isEmpty else {
            throw captureError(code: -1, "No display available for capture")
        }

        let pointerLocation = NSEvent.mouseLocation
        let wispWindows = windowsOwnedByWisp(in: shareableContent)

        // SCDisplay.frame is in Core Graphics coordinates (top-left origin) while
        // NSEvent.mouseLocation and NSScreen.frame use AppKit's (bottom-left). The
        // two disagree on Y for secondary displays, which would break the
        // cursor-containment test and later conversions, so frames come from NSScreen.
        let appKitScreenByDisplayID = Dictionary(
            NSScreen.screens.map { ($0.displayID, $0) },
            uniquingKeysWith: { firstScreen, _ in firstScreen }
        )

        func appKitFrame(of display: SCDisplay) -> CGRect {
            appKitScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
        }

        let displaysWithCursorFirst = shareableContent.displays.sorted { first, second in
            let firstHoldsCursor = appKitFrame(of: first).contains(pointerLocation)
            let secondHoldsCursor = appKitFrame(of: second).contains(pointerLocation)
            return firstHoldsCursor && !secondHoldsCursor
        }

        var captures: [CompanionScreenCapture] = []

        for (position, display) in displaysWithCursorFirst.enumerated() {
            let displayFrame = appKitFrame(of: display)
            let holdsCursor = displayFrame.contains(pointerLocation)

            let streamConfiguration = SCStreamConfiguration()
            let outputSize = scaledSize(forDisplayWidth: display.width, height: display.height,
                                        longestSide: modelImageLongestSide)
            streamConfiguration.width = outputSize.width
            streamConfiguration.height = outputSize.height

            let frameImage = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: wispWindows),
                configuration: streamConfiguration
            )

            guard let freshJPEG = NSBitmapImageRep(cgImage: frameImage)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                continue
            }

            // Resend the previous frame's exact bytes when the screen hasn't changed.
            // Ollama caches encoded images by their bytes, and a new capture of an
            // unchanged screen never matches (JPEG noise, a ticking clock), which
            // made every follow-up re-encode the same picture for about 6.4s.
            let (jpegData, reusedPreviousFrame) = ScreenshotReuseCache.bytesToSend(
                forDisplay: display.displayID,
                freshData: freshJPEG,
                freshImage: frameImage
            )
            if reusedPreviousFrame {
                print("🖼️ Screen unchanged — reusing the cached frame (skips ~6s of image encoding)")
            }

            // Start on-device OCR now, off the main actor. The push-to-talk capture
            // runs while the user is still speaking, so recognition is usually done
            // by the time the turn needs it. It is keyed on the bytes actually sent,
            // so a reused frame is not recognised twice. See `ScreenTextRecognizer`.
            ScreenTextRecognizer.shared.beginRecognitionIfNeeded(
                forDisplay: display.displayID,
                imageData: jpegData,
                screenshotImage: frameImage
            )

            captures.append(CompanionScreenCapture(
                imageData: jpegData,
                label: label(forDisplayNumber: position + 1, of: displaysWithCursorFirst.count,
                             holdsCursor: holdsCursor),
                isCursorScreen: holdsCursor,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                screenshotWidthInPixels: streamConfiguration.width,
                screenshotHeightInPixels: streamConfiguration.height
            ))
        }

        guard !captures.isEmpty else {
            throw captureError(code: -2, "Failed to capture any screen")
        }

        return captures
    }

    // MARK: - Helpers

    private static func captureError(code: Int, _ description: String) -> NSError {
        NSError(domain: "CompanionScreenCapture", code: code,
                userInfo: [NSLocalizedDescriptionKey: description])
    }

    private static func windowsOwnedByWisp(in shareableContent: SCShareableContent) -> [SCWindow] {
        let wispBundleIdentifier = Bundle.main.bundleIdentifier
        return shareableContent.windows.filter {
            $0.owningApplication?.bundleIdentifier == wispBundleIdentifier
        }
    }

    /// Scales a display's pixel size so its longer side equals `longestSide`,
    /// keeping the aspect ratio.
    private static func scaledSize(forDisplayWidth width: Int, height: Int, longestSide: Int) -> (width: Int, height: Int) {
        let widthToHeight = CGFloat(width) / CGFloat(height)
        if width >= height {
            return (longestSide, Int(CGFloat(longestSide) / widthToHeight))
        }
        return (Int(CGFloat(longestSide) * widthToHeight), longestSide)
    }

    private static func label(forDisplayNumber number: Int, of total: Int, holdsCursor: Bool) -> String {
        if total == 1 {
            return "user's screen (cursor is here)"
        }
        let position = "screen \(number) of \(total)"
        return holdsCursor
            ? "\(position) — cursor is on this screen (primary focus)"
            : "\(position) — secondary screen"
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
