//
//  ScreenTextRecognizer.swift
//  leanring-buddy
//
//  Runs on-device OCR (Apple's Vision framework) over the screenshots a turn
//  already captured, and hands the turn a `ScreenTextSnapshot` — the screen's
//  text with ids and boxes. See `ScreenTextSnapshot.swift` for why.
//
//  API choice: the Swift `RecognizeTextRequest` (Vision's async/await API,
//  macOS 15+) rather than `VNRecognizeTextRequest`. It is `perform(on:)` async
//  and returns value-type, Sendable observations, so recognition runs as an
//  ordinary detached task with no completion handler or request-handler
//  lifetime to manage, and a result can be cached and awaited from several
//  places. Both run the same on-device recogniser.
//
//  When it runs: recognition starts the moment a screenshot is captured — from
//  inside `CompanionScreenCaptureUtility` — not when the turn asks for it. The
//  push-to-talk path captures speculatively while the user is still speaking,
//  so recognition usually finishes before the transcript does and the turn
//  waits for nothing. The turn then waits at most `turnWaitBudgetSeconds` for
//  whatever has not finished; a slow recognition is left running into the
//  cache (for the next turn or `read_screen_text`) rather than holding up this
//  one.
//
//  Local-only: Vision recognises text on this machine. Nothing here touches
//  the network, and the text only leaves the machine if the user has chosen a
//  cloud model provider — exactly like the screenshot it was read from.
//

import CoreGraphics
import Foundation
import os
import Vision

@MainActor
final class ScreenTextRecognizer {
    static let shared = ScreenTextRecognizer()

    /// Longest a turn waits for recognition still in progress. Measured on an
    /// M3 Pro, `.accurate` on an 896×582 frame takes ~170ms warm and ~300ms
    /// the first time in a process (model load); this covers that with
    /// headroom, and is the same order as the Accessibility walk's own 300ms
    /// budget that runs beside it.
    static let turnWaitBudgetSeconds: TimeInterval = 0.4

    /// Longest the `read_screen_text` tool waits. The user explicitly asked
    /// what the screen says, so a slower answer beats no answer.
    static let toolWaitBudgetSeconds: TimeInterval = 3.0

    /// Images larger than this many pixels are recognised at `.fast`, because
    /// `.accurate` scales with area and would not fit the turn's budget. The
    /// 896px screenshots Wisp sends today are about half a megapixel and always
    /// get `.accurate` — at that size their text is small, and `.fast` reads
    /// small text badly.
    nonisolated static let largestImagePixelCountForAccurateRecognition = 2_500_000

    /// Shortest text Vision is asked to find, in pixels of the recognised
    /// image. Vision's default minimum is 1/32 of the image height — about 18px
    /// on an 896px-wide screenshot — which would skip nearly all UI text, since
    /// 13pt body text is roughly 8px tall at that scale.
    nonisolated static let minimumRecognisedTextHeightInPixels: CGFloat = 5

    private typealias RecognitionTask = Task<ScreenTextRecognitionResult, Never>

    private var recognitionTaskCache = ScreenTextRecognitionCache<RecognitionTask>()

    /// The last recognition to finish, on any display, and when it finished —
    /// so the brain's activity feed can reuse text Wisp already read rather
    /// than ever capturing the screen for itself.
    private var mostRecentFinishedRecognition: (finishedDate: Date, result: ScreenTextRecognitionResult)?

    private init() {}

    // MARK: - Starting recognition

    /// Starts recognising the text in a freshly captured screenshot, unless
    /// these exact bytes were already recognised (or are being recognised) for
    /// this display. Returns immediately; the work runs off the main actor.
    ///
    /// - Parameters:
    ///   - imageData: The bytes actually sent to the model for this display —
    ///     after `ScreenshotReuseCache` — which are the cache key.
    ///   - screenshotImage: The uncompressed image those bytes were encoded
    ///     from (or, when the reuse cache handed back older bytes, the fresh
    ///     equivalent — only used on a cache miss). Recognising the CGImage
    ///     rather than decoding the JPEG avoids reading through compression
    ///     artefacts.
    func beginRecognitionIfNeeded(
        forDisplay displayID: CGDirectDisplayID,
        imageData: Data,
        screenshotImage: CGImage
    ) {
        if recognitionTaskCache.cachedValue(forDisplay: displayID, imageData: imageData) != nil {
            return
        }

        let screenshotSizeInPixels = CGSize(width: screenshotImage.width, height: screenshotImage.height)
        let recognitionTask = RecognitionTask.detached(priority: .userInitiated) {
            await ScreenTextRecognizer.recognizeText(
                in: screenshotImage,
                screenshotSizeInPixels: screenshotSizeInPixels
            )
        }
        recognitionTaskCache.store(recognitionTask, forDisplay: displayID, imageData: imageData)
        Task { @MainActor in
            let finishedResult = await recognitionTask.value
            self.mostRecentFinishedRecognition = (Date(), finishedResult)
        }
    }

    /// Plain text of the most recently finished recognition, top to bottom,
    /// or nil when there is none newer than `maximumAgeSeconds`. Never starts
    /// a capture or a recognition.
    func mostRecentRecognizedPlainText(maximumAgeSeconds: TimeInterval) -> String? {
        guard let mostRecentFinishedRecognition,
              Date().timeIntervalSince(mostRecentFinishedRecognition.finishedDate) <= maximumAgeSeconds else { return nil }
        let readableLines = mostRecentFinishedRecognition.result.lines
            .filter { $0.confidence >= 0.35 }
            .sorted { lhs, rhs in
                lhs.boundingBoxInScreenshotPixels.minY != rhs.boundingBoxInScreenshotPixels.minY
                    ? lhs.boundingBoxInScreenshotPixels.minY < rhs.boundingBoxInScreenshotPixels.minY
                    : lhs.boundingBoxInScreenshotPixels.minX < rhs.boundingBoxInScreenshotPixels.minX
            }
            .map(\.text)
        return readableLines.isEmpty ? nil : readableLines.joined(separator: "\n")
    }

    // MARK: - Reading results

    /// The OCR snapshot for a turn's captures, waiting at most `maximumWaitSeconds`
    /// in total for recognition still in progress.
    ///
    /// Captures are looked up by their bytes, so this needs no display ids and
    /// works for the speculative capture and a fresh one alike. A capture with
    /// no recognition in the cache (it should not happen — every capture
    /// starts one) or one that does not finish in time contributes nothing.
    /// Returns nil when no screen produced any usable text.
    func snapshot(
        for screenCaptures: [CompanionScreenCapture],
        waitingAtMost maximumWaitSeconds: TimeInterval,
        maximumLineCount: Int = ScreenTextSnapshot.maximumPromptLineCount,
        maximumCharacterCount: Int = ScreenTextSnapshot.maximumPromptCharacterCount
    ) async -> ScreenTextSnapshot? {
        let waitDeadline = Date().addingTimeInterval(maximumWaitSeconds)

        var perScreenResults: [ScreenTextRecognitionResult?] = []
        for screenCapture in screenCaptures {
            guard let recognitionTask = recognitionTaskCache.cachedValue(matchingImageData: screenCapture.imageData) else {
                perScreenResults.append(nil)
                continue
            }
            let remainingWaitSeconds = max(0, waitDeadline.timeIntervalSinceNow)
            let recognitionResult = await Self.value(of: recognitionTask, waitingAtMost: remainingWaitSeconds)
            if let recognitionResult {
                print("🔤 OCR: \(recognitionResult.lines.count) lines in \(Int(recognitionResult.recognitionDurationSeconds * 1000))ms")
            } else {
                print("🔤 OCR: not finished within the \(Int(maximumWaitSeconds * 1000))ms budget — skipped for this screen")
            }
            perScreenResults.append(recognitionResult)
        }

        let builtSnapshot = ScreenTextSnapshot.build(
            fromPerScreenResults: perScreenResults,
            maximumLineCount: maximumLineCount,
            maximumCharacterCount: maximumCharacterCount
        )
        return builtSnapshot.entries.isEmpty ? nil : builtSnapshot
    }

    // MARK: - Recognition (off the main actor)

    /// Recognises the text in one image with Vision. Never throws: a failed
    /// recognition is an empty result, since OCR is an aid to the turn and
    /// never a reason for it to fail.
    nonisolated static func recognizeText(
        in screenshotImage: CGImage,
        screenshotSizeInPixels: CGSize
    ) async -> ScreenTextRecognitionResult {
        let recognitionStartDate = Date()

        var recognizeTextRequest = RecognizeTextRequest()
        let recognitionLevel = recognitionLevel(
            forImagePixelCount: screenshotImage.width * screenshotImage.height
        )
        recognizeTextRequest.recognitionLevel = recognitionLevel
        // Language correction helps `.accurate` turn near-misses into real
        // words; `.fast` ignores it.
        recognizeTextRequest.usesLanguageCorrection = recognitionLevel == .accurate
        recognizeTextRequest.minimumTextHeightFraction = Float(
            minimumTextHeightFraction(forImageHeightInPixels: CGFloat(screenshotImage.height))
        )

        let recognizedLines: [RecognizedScreenTextLine]
        do {
            let observations = try await recognizeTextRequest.perform(on: screenshotImage)
            recognizedLines = observations.compactMap { observation in
                guard let topCandidate = observation.topCandidates(1).first else { return nil }
                return RecognizedScreenTextLine(
                    text: topCandidate.string,
                    confidence: topCandidate.confidence,
                    boundingBoxInScreenshotPixels: ScreenTextSnapshot.screenshotRect(
                        fromNormalizedLowerLeftOriginRect: observation.boundingBox.cgRect,
                        screenshotSizeInPixels: screenshotSizeInPixels
                    )
                )
            }
        } catch {
            print("🔤 OCR failed: \(error.localizedDescription)")
            recognizedLines = []
        }

        return ScreenTextRecognitionResult(
            lines: recognizedLines,
            recognitionDurationSeconds: Date().timeIntervalSince(recognitionStartDate)
        )
    }

    /// `.accurate` unless the image is too large for it to fit the budget.
    nonisolated static func recognitionLevel(forImagePixelCount imagePixelCount: Int) -> RecognizeTextRequest.RecognitionLevel {
        imagePixelCount <= largestImagePixelCountForAccurateRecognition ? .accurate : .fast
    }

    /// The minimum text height as the fraction of image height Vision wants,
    /// clamped so it never exceeds Vision's own default of 1/32.
    nonisolated static func minimumTextHeightFraction(forImageHeightInPixels imageHeightInPixels: CGFloat) -> CGFloat {
        guard imageHeightInPixels > 0 else { return 1.0 / 32.0 }
        return min(1.0 / 32.0, minimumRecognisedTextHeightInPixels / imageHeightInPixels)
    }

    // MARK: - Waiting with a deadline

    /// The task's value if it arrives within `maximumWaitSeconds`, else nil.
    ///
    /// Not a task group: a group waits for every child before returning, and a
    /// Vision request is not guaranteed to stop promptly when cancelled, so a
    /// group would wait out the slow recognition anyway. This returns at the
    /// deadline and leaves the recognition running into the cache.
    nonisolated static func value<Value: Sendable>(
        of task: Task<Value, Never>,
        waitingAtMost maximumWaitSeconds: TimeInterval
    ) async -> Value? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
            let hasResumed = OSAllocatedUnfairLock(initialState: false)
            // Whichever of the two finishes first resumes the continuation;
            // the lock makes sure the other one never resumes it a second time.
            let resumeIfFirst: @Sendable (Value?) -> Void = { resumedValue in
                let isFirstToResume = hasResumed.withLock { alreadyResumed -> Bool in
                    guard !alreadyResumed else { return false }
                    alreadyResumed = true
                    return true
                }
                if isFirstToResume { continuation.resume(returning: resumedValue) }
            }

            Task.detached {
                resumeIfFirst(await task.value)
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(maximumWaitSeconds))
                resumeIfFirst(nil)
            }
        }
    }
}

// MARK: - Resolving an id the model named

extension CompanionManager {
    /// Resolves an id the model named in a `[POINT:…]`, `[BOX:…]`,
    /// `[HIGHLIGHT:…]` or `[ARROW:…]` tag to a region in the right display's
    /// screenshot: an Accessibility element id (`a12`) via this turn's
    /// Accessibility snapshot, or an OCR line id (`t7`) via this turn's
    /// `ScreenTextSnapshot`. Nil for an id that is in neither — a stale or
    /// invented id must not put a marker somewhere arbitrary.
    static func resolveScreenElementRegion(
        elementID: String,
        accessibilityElementSnapshot: AccessibilityElementSnapshot?,
        screenTextSnapshot: ScreenTextSnapshot?,
        screenCaptures: [CompanionScreenCapture]
    ) -> AccessibilityElementResolvedRegion? {
        if elementID.lowercased().hasPrefix("t") {
            return screenTextSnapshot?.resolvedRegion(forLineID: elementID)
        }
        return resolveAccessibilityElementRegion(
            elementID: elementID,
            accessibilityElementSnapshot: accessibilityElementSnapshot,
            screenCaptures: screenCaptures
        )
    }
}
