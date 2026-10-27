//
//  ScreenshotReuseCache.swift
//  leanring-buddy
//
//  Reuses the previous screenshot's exact bytes when the screen has not
//  meaningfully changed.
//
//  Ollama caches the encoded form of an image, keyed on the bytes it was sent.
//  Measured on this machine, a 896px screenshot costs 6.4s of prompt evaluation
//  the first time and 0.14s when the identical bytes arrive again — a factor of
//  forty-five, and by far the largest single cost in a screen question.
//
//  The catch is that a fresh capture of an unchanged screen is never identical:
//  JPEG quantisation noise, a blinking cursor and a ticking clock are enough to
//  produce different bytes, so the cache missed on every turn. Two consecutive
//  questions about the same screen each paid full price.
//
//  So this compares the new frame against the last one perceptually, and when
//  they match it hands back the *old* bytes rather than the new ones. That is
//  the whole trick: the model must receive the identical payload for the cache
//  to hit, so reuse has to be byte-exact rather than merely equivalent.
//
//  Correctness matters more than the saving here. Answering about a screen the
//  user has since navigated away from is a worse failure than being slow, so
//  the similarity threshold is conservative and reuse expires on a timer
//  regardless of how similar things look.
//

import CoreGraphics
import Foundation

@MainActor
enum ScreenshotReuseCache {
    /// Mean per-pixel difference, 0–255, below which two frames are treated as
    /// the same screen.
    ///
    /// Deliberately small. A clock digit or a caret changes a handful of cells
    /// in a 16×16 reduction and lands well under this; scrolling a page or
    /// switching app does not come close to it.
    private static let sameScreenThreshold: Double = 4.0

    /// Longest a frame may be reused, however unchanged it looks.
    ///
    /// A backstop against the perceptual check being wrong in some way nobody
    /// anticipated: after this, the user gets a genuinely current screenshot
    /// and pays the encode again.
    private static let maximumReuseAge: TimeInterval = 45

    private struct CachedFrame {
        let imageData: Data
        let signature: [UInt8]
        let capturedAt: Date
    }

    private static var framesByDisplay: [CGDirectDisplayID: CachedFrame] = [:]

    /// Returns the bytes to actually send for this display.
    ///
    /// Either `freshData` (and remembers it), or the previous frame's bytes
    /// when the screen has not changed enough to matter.
    static func bytesToSend(
        forDisplay displayID: CGDirectDisplayID,
        freshData: Data,
        freshImage: CGImage
    ) -> (data: Data, didReuse: Bool) {
        let signature = perceptualSignature(of: freshImage)

        if let cached = framesByDisplay[displayID],
           Date().timeIntervalSince(cached.capturedAt) < maximumReuseAge,
           meanDifference(cached.signature, signature) < sameScreenThreshold {
            return (cached.imageData, true)
        }

        framesByDisplay[displayID] = CachedFrame(
            imageData: freshData,
            signature: signature,
            capturedAt: Date()
        )
        return (freshData, false)
    }

    /// Drops everything. Called when displays are reconfigured, since a frame
    /// captured from a display that has since changed resolution is not
    /// comparable to anything.
    static func invalidateAll() {
        framesByDisplay.removeAll()
    }

    // MARK: - Perceptual signature

    /// A 16×16 greyscale reduction of the frame.
    ///
    /// Small enough that comparing two is free, and coarse enough that JPEG
    /// noise and a moving cursor do not register while real content changes do.
    private static func perceptualSignature(of image: CGImage) -> [UInt8] {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side)

        guard let context = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return pixels
        }

        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return pixels
    }

    private static func meanDifference(_ left: [UInt8], _ right: [UInt8]) -> Double {
        guard left.count == right.count, !left.isEmpty else { return .greatestFiniteMagnitude }

        var total = 0
        for index in left.indices {
            total += abs(Int(left[index]) - Int(right[index]))
        }
        return Double(total) / Double(left.count)
    }
}
