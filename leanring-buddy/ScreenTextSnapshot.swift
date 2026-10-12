//
//  ScreenTextSnapshot.swift
//  leanring-buddy
//
//  The text on the user's screen as read by on-device OCR, turned into an
//  id-addressed list the model can read and point into — and everything about
//  it that can be reasoned about without running Vision: reading order,
//  confidence filtering, the prompt-size cap, the compact text rendering, the
//  `t7` id lookup, and the per-display cache keyed on screenshot bytes.
//
//  Why this exists: the local vision model (qwen2.5vl:3b, fed an 896px
//  screenshot) is slow and error-prone at reading text — it misreads error
//  messages, invents file names, and guesses where a label is. Apple's Vision
//  framework reads the same pixels on this machine in a few hundred
//  milliseconds, far more accurately, and says exactly where each line is.
//  Handing the model that text (with ids) means it can quote what the screen
//  says and point at a line by id (`[POINT:t7:label]`) — the same idea as the
//  Accessibility element ids (`a12`), for text that has no Accessibility
//  element (images, canvases, terminals, remote desktops, videos).
//
//  Running the recognition itself lives in `ScreenTextRecognizer`; this file is
//  deliberately free of Vision calls so it can be unit tested.
//

import CoreGraphics
import Foundation

/// One line of text Vision recognised in one screenshot.
nonisolated struct RecognizedScreenTextLine: Sendable, Equatable {
    let text: String
    /// Vision's confidence in the top candidate, 0–1.
    let confidence: Float
    /// Where the line sits in the screenshot the model is shown: pixels, origin
    /// at the top-left, y down — the space every `ScreenAnnotation` stores.
    let boundingBoxInScreenshotPixels: CGRect
}

/// Everything Vision recognised in one display's screenshot.
nonisolated struct ScreenTextRecognitionResult: Sendable, Equatable {
    let lines: [RecognizedScreenTextLine]
    /// How long recognition took, for the log line that tells whether the
    /// time budget is realistic on this machine.
    let recognitionDurationSeconds: TimeInterval
}

/// One line in the snapshot shown to the model.
nonisolated struct ScreenTextSnapshotEntry: Sendable, Equatable {
    /// Stable id for this snapshot only (`t1`, `t2`, …) — what the model names
    /// in a `[POINT:t7:label]` tag.
    let lineID: String
    /// The recognised text, whitespace-collapsed and truncated for the prompt.
    let text: String
    let boundingBoxInScreenshotPixels: CGRect
    /// 1-based screen number, matching the screenshot labels.
    let screenNumber: Int
}

/// The OCR text of every captured screen for one turn, in reading order,
/// filtered and capped.
nonisolated struct ScreenTextSnapshot: Sendable, Equatable {
    let entries: [ScreenTextSnapshotEntry]
    /// How many screens contributed lines. Screen headers are only rendered
    /// when there is more than one, so a single-display prompt stays short.
    let contributingScreenCount: Int

    // MARK: - Limits

    /// Lines below this confidence are dropped. Vision's accurate recogniser
    /// reports 0.3 for text it is genuinely unsure about (usually icon glyphs
    /// or noise read as letters) and 0.5–1.0 for real text.
    static let minimumLineConfidence: Float = 0.35
    /// Most lines shown to the model per turn. Each costs roughly fifteen
    /// prompt tokens with its id and box; past this the list costs more prompt
    /// evaluation than it saves in misreadings.
    static let maximumPromptLineCount = 60
    /// Most characters of recognised text shown to the model per turn, across
    /// all lines — a second cap because a dense page (a log, an article) can
    /// hit this long before the line cap.
    static let maximumPromptCharacterCount = 2500
    /// Longest single line kept. A paragraph Vision reads as one very long line
    /// is rarely what a user is asking about in full.
    static let maximumLineCharacterCount = 120

    // MARK: - Building

    /// Builds the snapshot from each captured screen's recognition result, in
    /// the order the screenshots were labelled (index 0 is "screen 1", the
    /// cursor screen). A nil result is a screen whose recognition did not
    /// finish within the budget; it contributes nothing, but the screens after
    /// it keep their numbers.
    ///
    /// Lines are confidence-filtered, put in reading order per screen, then
    /// capped in that order — so the cursor screen's text wins the budget, and
    /// within a screen the top of the window does.
    static func build(
        fromPerScreenResults perScreenResults: [ScreenTextRecognitionResult?],
        maximumLineCount: Int = maximumPromptLineCount,
        maximumCharacterCount: Int = maximumPromptCharacterCount
    ) -> ScreenTextSnapshot {
        var entries: [ScreenTextSnapshotEntry] = []
        var totalCharacterCount = 0
        var contributingScreenNumbers = Set<Int>()

        screenLoop: for (screenIndex, perScreenResult) in perScreenResults.enumerated() {
            guard let perScreenResult else { continue }

            let keptLines = perScreenResult.lines.compactMap { recognizedLine -> RecognizedScreenTextLine? in
                guard recognizedLine.confidence >= minimumLineConfidence else { return nil }
                let normalizedText = normalizedLineText(recognizedLine.text)
                guard containsLetterOrDigit(normalizedText) else { return nil }
                guard recognizedLine.boundingBoxInScreenshotPixels.width > 0,
                      recognizedLine.boundingBoxInScreenshotPixels.height > 0 else { return nil }
                return RecognizedScreenTextLine(
                    text: normalizedText,
                    confidence: recognizedLine.confidence,
                    boundingBoxInScreenshotPixels: recognizedLine.boundingBoxInScreenshotPixels
                )
            }

            for orderedLine in linesInReadingOrder(keptLines) {
                guard entries.count < maximumLineCount else { break screenLoop }
                guard totalCharacterCount + orderedLine.text.count <= maximumCharacterCount else { break screenLoop }

                totalCharacterCount += orderedLine.text.count
                contributingScreenNumbers.insert(screenIndex + 1)
                entries.append(ScreenTextSnapshotEntry(
                    lineID: "t\(entries.count + 1)",
                    text: orderedLine.text,
                    boundingBoxInScreenshotPixels: orderedLine.boundingBoxInScreenshotPixels,
                    screenNumber: screenIndex + 1
                ))
            }
        }

        return ScreenTextSnapshot(entries: entries, contributingScreenCount: contributingScreenNumbers.count)
    }

    /// Sorts lines top-to-bottom, then left-to-right within a visual row.
    ///
    /// Vision returns lines in no guaranteed order. Sorting by y alone would
    /// scramble a row whose items differ by a pixel or two in height (a
    /// toolbar, a table row), so lines whose vertical centres are within half a
    /// line height of the row's first line are treated as one row and sorted
    /// by x. Multi-column layouts still interleave row by row; the boxes make
    /// the columns recoverable for the model.
    static func linesInReadingOrder(_ lines: [RecognizedScreenTextLine]) -> [RecognizedScreenTextLine] {
        let linesSortedTopToBottom = lines.sorted { firstLine, secondLine in
            if firstLine.boundingBoxInScreenshotPixels.midY != secondLine.boundingBoxInScreenshotPixels.midY {
                return firstLine.boundingBoxInScreenshotPixels.midY < secondLine.boundingBoxInScreenshotPixels.midY
            }
            return firstLine.boundingBoxInScreenshotPixels.minX < secondLine.boundingBoxInScreenshotPixels.minX
        }

        var rows: [[RecognizedScreenTextLine]] = []
        for line in linesSortedTopToBottom {
            if let rowFirstLine = rows.last?.first {
                let rowMidY = rowFirstLine.boundingBoxInScreenshotPixels.midY
                let sameRowTolerance = min(
                    rowFirstLine.boundingBoxInScreenshotPixels.height,
                    line.boundingBoxInScreenshotPixels.height
                ) / 2
                if abs(line.boundingBoxInScreenshotPixels.midY - rowMidY) <= sameRowTolerance {
                    rows[rows.count - 1].append(line)
                    continue
                }
            }
            rows.append([line])
        }

        return rows.flatMap { row in
            row.sorted { $0.boundingBoxInScreenshotPixels.minX < $1.boundingBoxInScreenshotPixels.minX }
        }
    }

    // MARK: - Lookup

    /// Looks a line up by the id the model named. Case-insensitive because a
    /// small model will sometimes write `T7`.
    func entry(withLineID lineID: String) -> ScreenTextSnapshotEntry? {
        let normalizedLineID = lineID.lowercased()
        return entries.first { $0.lineID == normalizedLineID }
    }

    /// Where a line named by id lands, in the same shape an Accessibility
    /// element id resolves to, so both id kinds share one resolver and one
    /// annotation path. The box is already in screenshot pixels — no
    /// coordinate conversion is needed, unlike an Accessibility frame.
    func resolvedRegion(forLineID lineID: String) -> AccessibilityElementResolvedRegion? {
        guard let matchingEntry = entry(withLineID: lineID) else { return nil }
        return AccessibilityElementResolvedRegion(
            regionInScreenshotPixels: matchingEntry.boundingBoxInScreenshotPixels,
            screenNumber: matchingEntry.screenNumber
        )
    }

    // MARK: - Rendering

    /// The compact text added to the user's message for this turn: a header,
    /// one line per recognised line (`t3 412,88,520,104 "Save changes"`), and
    /// the one-line instruction for the `t` id tag form.
    ///
    /// Carried in the user message rather than the system prompt, for the same
    /// reason as the Accessibility element list: the system prompt must stay
    /// byte-identical between turns for the local model's prefix cache.
    func promptText() -> String {
        guard !entries.isEmpty else { return "" }

        var lines: [String] = [
            "text on screen, read by on-device OCR (id, box left,top,right,bottom in screenshot pixels, text):"
        ]
        var lastRenderedScreenNumber: Int?
        for entry in entries {
            if contributingScreenCount > 1, entry.screenNumber != lastRenderedScreenNumber {
                lines.append("screen \(entry.screenNumber):")
                lastRenderedScreenNumber = entry.screenNumber
            }
            lines.append(Self.promptLine(for: entry))
        }
        lines.append(
            "to point at a line of this text, use its id, e.g. [POINT:t3:label]; [BOX:t3:label] and [ARROW:t3:label] work the same way. these ids only work inside those tags; no tool accepts them."
        )
        return lines.joined(separator: "\n")
    }

    /// One line as `t3 412,88,520,104 "Save changes"`.
    static func promptLine(for entry: ScreenTextSnapshotEntry) -> String {
        let box = entry.boundingBoxInScreenshotPixels
        let boxText = "\(Int(box.minX.rounded())),\(Int(box.minY.rounded())),\(Int(box.maxX.rounded())),\(Int(box.maxY.rounded()))"
        return "\(entry.lineID) \(boxText) \"\(sanitizedForPrompt(entry.text))\""
    }

    /// The plain text, one recognised line per output line, for the
    /// `read_screen_text` tool — no ids or boxes, since ids are only valid for
    /// the turn's own snapshot and the tool is about what the screen says.
    func plainText() -> String {
        var lines: [String] = []
        var lastRenderedScreenNumber: Int?
        for entry in entries {
            if contributingScreenCount > 1, entry.screenNumber != lastRenderedScreenNumber {
                if !lines.isEmpty { lines.append("") }
                lines.append("— screen \(entry.screenNumber) —")
                lastRenderedScreenNumber = entry.screenNumber
            }
            lines.append(entry.text)
        }
        return lines.joined(separator: "\n")
    }

    /// Joins the Accessibility element list and the OCR text into the one
    /// screen-context block the turn's user message carries.
    ///
    /// One block rather than two parallel ones so every place that already
    /// handles the Accessibility list — adding it to the request, and stripping
    /// it from the saved history because its ids are only valid for this turn —
    /// handles the OCR text too, unchanged.
    static func screenContextPromptText(
        accessibilityElementPromptText: String,
        screenTextSnapshot: ScreenTextSnapshot?
    ) -> String {
        let screenTextPromptText = screenTextSnapshot?.promptText() ?? ""
        return [accessibilityElementPromptText, screenTextPromptText]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    // MARK: - Text cleanup

    /// Collapses runs of whitespace (Vision sometimes returns tabs or double
    /// spaces for wide gaps) and truncates to `maximumLineCharacterCount`.
    static func normalizedLineText(_ rawText: String) -> String {
        let collapsedText = rawText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsedText.count > maximumLineCharacterCount else { return collapsedText }
        return String(collapsedText.prefix(maximumLineCharacterCount - 1)) + "…"
    }

    /// Swaps characters that would read as tag syntax or break the quoting.
    /// Square brackets become parentheses because a model that copies a line
    /// containing `]` into its tag label would end the tag early.
    static func sanitizedForPrompt(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
    }

    private static func containsLetterOrDigit(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    // MARK: - Geometry

    /// Converts a Vision bounding box — normalised 0–1, origin at the
    /// BOTTOM-left, y up — into screenshot pixels with the origin at the
    /// top-left, y down.
    ///
    /// Scaled by the screenshot's size rather than the recognised image's, so
    /// recognition could run on a larger capture than the one the model sees
    /// and the boxes would still land in the model's pixel space.
    static func screenshotRect(
        fromNormalizedLowerLeftOriginRect normalizedRect: CGRect,
        screenshotSizeInPixels: CGSize
    ) -> CGRect {
        CGRect(
            x: normalizedRect.minX * screenshotSizeInPixels.width,
            y: (1 - normalizedRect.maxY) * screenshotSizeInPixels.height,
            width: normalizedRect.width * screenshotSizeInPixels.width,
            height: normalizedRect.height * screenshotSizeInPixels.height
        )
    }
}

// MARK: - Cache keyed on screenshot bytes

/// Remembers one recognition per display, keyed on the exact screenshot bytes.
///
/// The key is deliberately the same identity `ScreenshotReuseCache` gives a
/// frame: when that cache decides the screen has not meaningfully changed it
/// hands back the previous frame's bytes, byte for byte, so an unchanged screen
/// arrives here with identical data and hits. Any real change produces new
/// bytes and misses. Keying on anything looser (a timestamp, a perceptual
/// signature of its own) could answer with the text of a screen the user has
/// since left.
///
/// One entry per display: a new frame replaces the old, so memory stays
/// bounded to one screenshot's bytes per display.
nonisolated struct ScreenTextRecognitionCache<CachedValue> {
    private struct Entry {
        let imageData: Data
        let cachedValue: CachedValue
    }

    private var entriesByDisplay: [CGDirectDisplayID: Entry] = [:]

    init() {}

    /// The cached value for this display, only if it was stored for exactly
    /// these bytes.
    func cachedValue(forDisplay displayID: CGDirectDisplayID, imageData: Data) -> CachedValue? {
        guard let entry = entriesByDisplay[displayID], entry.imageData == imageData else { return nil }
        return entry.cachedValue
    }

    /// The cached value for whichever display last produced exactly these
    /// bytes. Used when the caller holds a capture but not its display id.
    func cachedValue(matchingImageData imageData: Data) -> CachedValue? {
        entriesByDisplay.values.first { $0.imageData == imageData }?.cachedValue
    }

    mutating func store(_ cachedValue: CachedValue, forDisplay displayID: CGDirectDisplayID, imageData: Data) {
        entriesByDisplay[displayID] = Entry(imageData: imageData, cachedValue: cachedValue)
    }

    mutating func removeAll() {
        entriesByDisplay.removeAll()
    }
}
