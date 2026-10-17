//
//  ScreenAnnotation.swift
//  leanring-buddy
//
//  Shapes the assistant can draw over the user's screen.
//
//  The cursor could already fly to a single point. An annotation is the more
//  general form of that: a box around a region, an arrow toward it, or a
//  label naming it — several at once if a explanation needs them, and
//  persisting while the user looks rather than animating past.
//
//  Coordinates arrive from the model in the screenshot's own pixel space, the
//  same space the existing [POINT:...] tag uses. That choice is load-bearing:
//  measured against a screenshot whose declared size matches its real size,
//  the model placed points inside the intended element in five of five cases
//  with a six pixel median error, so a rectangle derived the same way lands
//  where it should.
//
//  Converting that rectangle for display is simpler than it first appears.
//  Screenshot space and SwiftUI's overlay space share a top-left origin, so
//  the transform is a scale and nothing else — no vertical flip. Going via
//  AppKit's bottom-left global coordinates, as the pointing code does, would
//  mean flipping twice for no benefit.
//

import Foundation
import SwiftUI

struct ScreenAnnotation: Identifiable, Equatable {
    enum Style: String, Equatable {
        /// Outlined rectangle around a region.
        case box
        /// Arrow pointing at a spot, useful when a box would cover content.
        case arrow
        /// Translucent wash over a region, for "this whole area".
        case highlight
        /// A pulsing ring centred on a single point — the replacement for the
        /// old flying cursor's [POINT:] gesture. The region carries the point as
        /// its origin with zero size, the same shape an arrow's region uses.
        case marker
        /// Ellipse drawn around a region — a chart bar, one answer choice, a
        /// term in an equation — the way a tutor circles something by hand.
        case circle
        /// Handwritten text written on the screen. The text is the label. A
        /// zero-size region is the point the text starts at (left edge,
        /// vertically centred); a real region is an element's frame, and the
        /// note is written just to its right. Never numbered as a walkthrough step.
        case note
    }

    let id: UUID
    let style: Style
    /// Region in the screenshot's pixel coordinate space, top-left origin.
    let regionInScreenshotPixels: CGRect
    let label: String?
    /// Which screen this belongs to, 1-based, matching the image labels sent
    /// to the model. Nil means the screen the cursor is on.
    let screenNumber: Int?
    /// Position in a numbered walkthrough (1-based), or nil for a lone
    /// annotation. Assigned by the parser in the order the tags appear.
    var stepNumber: Int?

    init(
        id: UUID = UUID(),
        style: Style,
        regionInScreenshotPixels: CGRect,
        label: String?,
        screenNumber: Int?,
        stepNumber: Int? = nil
    ) {
        self.id = id
        self.style = style
        self.regionInScreenshotPixels = regionInScreenshotPixels
        self.label = label
        self.screenNumber = screenNumber
        self.stepNumber = stepNumber
    }

    /// A walkthrough step the model named without a position (`[STEP:…]`).
    /// It has nothing to draw until the guided walkthrough finds it on screen.
    var isUnplacedWalkthroughStep: Bool {
        style == .box && regionInScreenshotPixels == .zero
    }

    /// Converts to the overlay's coordinate space.
    ///
    /// Both spaces put the origin at the top left, so this is a pure scale.
    /// The rectangle is clamped to the screen because a model that overshoots
    /// slightly should produce a box at the edge rather than one drawn off it.
    func regionInOverlayCoordinates(
        screenshotSize: CGSize,
        displaySize: CGSize
    ) -> CGRect {
        guard screenshotSize.width > 0, screenshotSize.height > 0 else { return .zero }

        let horizontalScale = displaySize.width / screenshotSize.width
        let verticalScale = displaySize.height / screenshotSize.height

        let scaled = CGRect(
            x: regionInScreenshotPixels.minX * horizontalScale,
            y: regionInScreenshotPixels.minY * verticalScale,
            width: regionInScreenshotPixels.width * horizontalScale,
            height: regionInScreenshotPixels.height * verticalScale
        )

        let clampedX = max(0, min(scaled.minX, displaySize.width))
        let clampedY = max(0, min(scaled.minY, displaySize.height))
        return CGRect(
            x: clampedX,
            y: clampedY,
            width: min(scaled.width, displaySize.width - clampedX),
            height: min(scaled.height, displaySize.height - clampedY)
        )
    }
}

// MARK: - Tag parsing

enum ScreenAnnotationParser {
    struct ParseResult {
        /// The reply with annotation tags removed — what gets spoken.
        let spokenText: String
        let annotations: [ScreenAnnotation]
    }

    /// Instructions describing the annotation tags, appended to the system
    /// prompt.
    ///
    /// Written to mirror the [POINT:...] tag the model already produces
    /// reliably, since consistency between the two is what makes a small model
    /// get either of them right.
    static let promptInstructions = """


    drawing on screen:
    besides pointing, you can draw a box, an arrow, a circle, a highlight or handwritten notes over part of the screen. use these when showing someone *where* something is matters more than describing it, or when several things need marking at once.

    put the tags at the very end of your reply, after the spoken text. coordinates are pixels in the screenshot's own coordinate space, origin (0,0) at the top-left.

    - [BOX:left,top,right,bottom:label] — outline a region, for example a button or a panel. give the two opposite corners.
    - [ARROW:x,y:label] — point at a spot without covering it.
    - [HIGHLIGHT:left,top,right,bottom:label] — wash over a whole area, same two corners.
    - [CIRCLE:left,top,right,bottom] — hand-drawn ellipse around something small: a chart bar, one term of an equation, the right answer choice. label optional.
    - [NOTE:x,y:text] — handwritten text starting at that point. [NOTE:t7:text] writes it just to the right of that element instead.

    teaching math, charts and other visual problems: when the user asks you to explain, teach or work through something on screen, do it on the screen itself, like a tutor with a pen. one line of working per note, written beside the thing it is about (next to each answer choice, beside the table row), e.g. [NOTE:t12:141 + 3 = 144]. highlight or circle the parts the working uses, work in order from the first line to the last, finish by circling the answer, and say the idea out loud in [SAY:] rather than reading the notes. use at most about ten notes; notes are text, so keep each under about eight words and put numbers and symbols in plain text (235 + 1 = 236).

    keep labels to one to three words. if drawing wouldn't help, don't use any.

    step-by-step walkthroughs — this takes priority over the single-pointer examples above:
    whenever the user asks how to do something that takes two or more actions (open a pane, then click a switch; choose a menu item, then a format), do NOT point at just the first control and describe the rest. give one [STEP:label] tag per action, in order, up to about eight, and use [POINT:none]. a step tag has no coordinates — wisp finds each control on screen itself, one step at a time, as the user gets there — so include steps whose control isn't visible yet (a menu that isn't open, a pane that comes after a click). write each label as the action plus the control's name exactly as it reads on screen.

    example — user asks how to turn on dark mode in system settings: "open appearance in the sidebar, then pick dark. [STEP:click Appearance] [STEP:pick Dark] [POINT:none]"

    a single action is still just a pointer: [POINT:a12:label].
    """

    /// Extracts annotation tags and strips them from the spoken text.
    ///
    /// - Parameter accessibilityElementRegionResolver: Resolves an
    ///   Accessibility element id (`a12`, from this turn's
    ///   `AccessibilityElementSnapshot`) or an OCR line id (`t7`, from this
    ///   turn's `ScreenTextSnapshot`) to its region in the screenshot. When
    ///   given, `[BOX:a12:label]`, `[HIGHLIGHT:a12:label]` and
    ///   `[ARROW:a12:label]` draw over that element's real frame. An id tag is
    ///   always stripped from the spoken text, but draws nothing when there is
    ///   no resolver or the id is unknown — a stale or invented id must not
    ///   put a box somewhere arbitrary.
    static func parse(
        _ responseText: String,
        accessibilityElementRegionResolver: ((String) -> AccessibilityElementResolvedRegion?)? = nil
    ) -> ParseResult {
        // Paired with the tag's start offset so the final list can be restored to
        // the order the steps appear in the reply — the two regex passes below
        // would otherwise group all regions before all arrows, scrambling a
        // walkthrough's order.
        var annotationsWithOffset: [(offset: Int, annotation: ScreenAnnotation)] = []
        var rangesToRemove: [Range<String.Index>] = []

        // Region tags carry four numbers; arrows carry two. The optional
        // trailing :screenN matches the existing point tag's convention.
        // The label separator is ":" by specification, but the model often
        // writes a space instead; both are accepted rather than discarding an
        // otherwise perfectly good box over punctuation.
        //
        // The separator class is written `[\s:]`, never `[:\s]`: ICU (behind
        // NSRegularExpression) reads `[:` … `:]` as a POSIX class like
        // `[:alpha:]`, and with the label's `[^\]:]` later in the pattern that
        // made the whole pattern fail to compile — `try?` then silently
        // dropped every box, highlight and arrow.
        let regionPattern = #"\[(BOX|HIGHLIGHT|CIRCLE):\s*(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*(?:[\s:]\s*([^\]:]+?))?\s*(?::screen(\d+))?\]"#
        let arrowPattern = #"\[(ARROW):\s*(-?\d+)\s*,\s*(-?\d+)\s*(?:[\s:]\s*([^\]:]+?))?\s*(?::screen(\d+))?\]"#

        for (pattern, isRegion) in [(regionPattern, true), (arrowPattern, false)] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(responseText.startIndex..., in: responseText)

            for match in regex.matches(in: responseText, range: range) {
                guard let tagRange = Range(match.range, in: responseText),
                      let styleRange = Range(match.range(at: 1), in: responseText),
                      let xRange = Range(match.range(at: 2), in: responseText),
                      let yRange = Range(match.range(at: 3), in: responseText),
                      let x = Double(responseText[xRange]),
                      let y = Double(responseText[yRange]) else { continue }

                let style: ScreenAnnotation.Style
                switch String(responseText[styleRange]).uppercased() {
                case "BOX": style = .box
                case "HIGHLIGHT": style = .highlight
                case "CIRCLE": style = .circle
                default: style = .arrow
                }

                var region = CGRect(x: x, y: y, width: 0, height: 0)
                var labelGroupIndex = 4
                var screenGroupIndex = 5

                if isRegion {
                    // Two opposite corners, which is the form the model
                    // actually produces and the convention such models are
                    // generally trained on. Normalised so the corners may
                    // arrive in either order.
                    guard let rightRange = Range(match.range(at: 4), in: responseText),
                          let bottomRange = Range(match.range(at: 5), in: responseText),
                          let right = Double(responseText[rightRange]),
                          let bottom = Double(responseText[bottomRange]) else { continue }

                    let width = abs(right - x)
                    let height = abs(bottom - y)
                    guard width > 1, height > 1 else { continue }

                    region = CGRect(x: min(x, right), y: min(y, bottom), width: width, height: height)
                    labelGroupIndex = 6
                    screenGroupIndex = 7
                }

                var label: String?
                if match.numberOfRanges > labelGroupIndex,
                   let labelRange = Range(match.range(at: labelGroupIndex), in: responseText) {
                    let text = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
                    label = text.isEmpty ? nil : text
                }

                var screenNumber: Int?
                if match.numberOfRanges > screenGroupIndex,
                   let screenRange = Range(match.range(at: screenGroupIndex), in: responseText) {
                    screenNumber = Int(responseText[screenRange])
                }

                let tagStartOffset = responseText.distance(from: responseText.startIndex, to: tagRange.lowerBound)
                annotationsWithOffset.append((
                    offset: tagStartOffset,
                    annotation: ScreenAnnotation(
                        style: style,
                        regionInScreenshotPixels: region,
                        label: label,
                        screenNumber: screenNumber
                    )
                ))
                rangesToRemove.append(tagRange)
            }
        }

        // Id-addressed tags: [BOX:a12:label], [HIGHLIGHT:a12:label] and
        // [ARROW:a12:label] — or the same with an OCR line id (`t7`, from this
        // turn's `ScreenTextSnapshot`), which the same resolver handles. The
        // numeric patterns above cannot match these, since an id starts with a
        // letter. A box or highlight takes the element's whole frame; an arrow
        // aims at its centre.
        let accessibilityElementIDPattern = #"\[(BOX|HIGHLIGHT|ARROW|CIRCLE):\s*([aAtT]\d+)\s*(?:[\s:]\s*([^\]:]+?))?\s*(?::screen\d+)?\]"#
        if let accessibilityElementIDRegex = try? NSRegularExpression(pattern: accessibilityElementIDPattern) {
            let range = NSRange(responseText.startIndex..., in: responseText)
            for match in accessibilityElementIDRegex.matches(in: responseText, range: range) {
                guard let tagRange = Range(match.range, in: responseText),
                      let styleRange = Range(match.range(at: 1), in: responseText),
                      let elementIDRange = Range(match.range(at: 2), in: responseText) else { continue }

                // Stripped whether or not it resolves: the tag is never speech.
                rangesToRemove.append(tagRange)

                let elementID = String(responseText[elementIDRange]).lowercased()
                guard let resolvedRegion = accessibilityElementRegionResolver?(elementID) else { continue }

                let style: ScreenAnnotation.Style
                switch String(responseText[styleRange]).uppercased() {
                case "BOX": style = .box
                case "HIGHLIGHT": style = .highlight
                case "CIRCLE": style = .circle
                default: style = .arrow
                }

                var label: String?
                if let labelRange = Range(match.range(at: 3), in: responseText) {
                    let text = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
                    label = text.isEmpty ? nil : text
                }

                let tagStartOffset = responseText.distance(from: responseText.startIndex, to: tagRange.lowerBound)
                annotationsWithOffset.append((
                    offset: tagStartOffset,
                    annotation: ScreenAnnotation(
                        style: style,
                        regionInScreenshotPixels: style == .arrow
                            ? resolvedRegion.centerPointRegionInScreenshotPixels
                            : resolvedRegion.regionInScreenshotPixels,
                        label: label,
                        // The element's own display rather than a screen the
                        // model named: the Accessibility frame already says
                        // where the element is.
                        screenNumber: resolvedRegion.screenNumber
                    )
                ))
            }
        }

        // Handwritten notes: [NOTE:x,y:text] and [NOTE:t7:text]. Unlike a
        // label, a note's text is working — "235 + 1 = 236" — so it may contain
        // colons and symbols and runs to the closing bracket. An id note keeps
        // the whole element frame; the layer writes it to the element's right.
        // As with other id tags, one that doesn't resolve is stripped silently.
        let coordinateNotePattern = #"\[NOTE:\s*(-?\d+)\s*,\s*(-?\d+)\s*[\s:]\s*([^\]]+?)\s*\]"#
        let elementNotePattern = #"\[NOTE:\s*([aAtT]\d+)\s*[\s:]\s*([^\]]+?)\s*\]"#
        for (pattern, isElementNote) in [(coordinateNotePattern, false), (elementNotePattern, true)] {
            guard let noteRegex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(responseText.startIndex..., in: responseText)
            for match in noteRegex.matches(in: responseText, range: range) {
                guard let tagRange = Range(match.range, in: responseText) else { continue }
                rangesToRemove.append(tagRange)

                var noteRegion: CGRect
                var noteScreenNumber: Int?
                let textGroupIndex: Int
                if isElementNote {
                    guard let elementIDRange = Range(match.range(at: 1), in: responseText),
                          let resolvedRegion = accessibilityElementRegionResolver?(
                              String(responseText[elementIDRange]).lowercased()
                          ) else { continue }
                    noteRegion = resolvedRegion.regionInScreenshotPixels
                    noteScreenNumber = resolvedRegion.screenNumber
                    textGroupIndex = 2
                } else {
                    guard let xRange = Range(match.range(at: 1), in: responseText),
                          let yRange = Range(match.range(at: 2), in: responseText),
                          let noteX = Double(responseText[xRange]),
                          let noteY = Double(responseText[yRange]) else { continue }
                    noteRegion = CGRect(x: noteX, y: noteY, width: 0, height: 0)
                    textGroupIndex = 3
                }

                guard let textRange = Range(match.range(at: textGroupIndex), in: responseText) else { continue }
                let noteText = String(responseText[textRange]).trimmingCharacters(in: .whitespaces)
                guard !noteText.isEmpty else { continue }

                let tagStartOffset = responseText.distance(from: responseText.startIndex, to: tagRange.lowerBound)
                annotationsWithOffset.append((
                    offset: tagStartOffset,
                    annotation: ScreenAnnotation(
                        style: .note,
                        regionInScreenshotPixels: noteRegion,
                        label: String(noteText.prefix(80)),
                        screenNumber: noteScreenNumber
                    )
                ))
            }
        }

        // Coordinate-free walkthrough steps: [STEP:click Appearance]. The model
        // can't give a position for a control that isn't on screen yet, so a
        // step carries only its words (an empty region) and the guided
        // walkthrough finds it on the live screen when its turn comes.
        let walkthroughStepPattern = #"\[STEP:\s*([^\]]+?)\s*\]"#
        if let walkthroughStepRegex = try? NSRegularExpression(pattern: walkthroughStepPattern) {
            let range = NSRange(responseText.startIndex..., in: responseText)
            for match in walkthroughStepRegex.matches(in: responseText, range: range) {
                guard let tagRange = Range(match.range, in: responseText),
                      let labelRange = Range(match.range(at: 1), in: responseText) else { continue }
                rangesToRemove.append(tagRange)

                let label = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
                guard !label.isEmpty else { continue }
                let tagStartOffset = responseText.distance(from: responseText.startIndex, to: tagRange.lowerBound)
                annotationsWithOffset.append((
                    offset: tagStartOffset,
                    annotation: ScreenAnnotation(
                        style: .box,
                        regionInScreenshotPixels: .zero,
                        label: label,
                        screenNumber: nil
                    )
                ))
            }
        }

        // Remove back-to-front so earlier indices stay valid.
        var spokenText = responseText
        for range in rangesToRemove.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            spokenText.removeSubrange(range)
        }

        // Restore the order the steps appeared in the reply.
        let orderedAnnotations = annotationsWithOffset
            .sorted { $0.offset < $1.offset }
            .map(\.annotation)

        // Enough for a real walkthrough, but past this shapes stop clarifying
        // and start obscuring. Notes are counted apart — a worked problem is
        // mostly notes — and neither notes nor circles are walkthrough steps.
        let maximumShapes = 8
        let maximumNotes = 12
        var shapeCount = 0
        var noteCount = 0
        var cappedAnnotations: [ScreenAnnotation] = []
        for annotation in orderedAnnotations {
            if annotation.style == .note {
                guard noteCount < maximumNotes else { continue }
                noteCount += 1
            } else {
                guard shapeCount < maximumShapes else { continue }
                shapeCount += 1
            }
            cappedAnnotations.append(annotation)
        }

        // Number the steps only when there are several — a lone pointer needs no
        // "1" badge.
        let stepIndices = cappedAnnotations.indices.filter {
            cappedAnnotations[$0].style != .note && cappedAnnotations[$0].style != .circle
        }
        if stepIndices.count >= 2 {
            for (stepOffset, annotationIndex) in stepIndices.enumerated() {
                cappedAnnotations[annotationIndex].stepNumber = stepOffset + 1
            }
        }

        return ParseResult(
            spokenText: spokenText.trimmingCharacters(in: .whitespacesAndNewlines),
            annotations: cappedAnnotations
        )
    }
}
