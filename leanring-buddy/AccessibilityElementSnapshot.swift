//
//  AccessibilityElementSnapshot.swift
//  leanring-buddy
//
//  A small, id-addressed list of the elements in the frontmost native app,
//  read from the macOS Accessibility tree, and everything about it that can be
//  reasoned about without touching the Accessibility API: the compact text the
//  model is shown, and the geometry that turns an element's frame into a
//  region in a screenshot.
//
//  Why this exists: a [POINT:x,y] tag asks a small local vision model to guess
//  pixel coordinates from a downscaled screenshot, which is the least reliable
//  thing the app does. The browser path already solved the same problem for
//  web pages by giving every element a stable id (`e7`) from a DOM snapshot and
//  letting the model name the id instead. This is that idea for native apps:
//  the model picks `a12` from a list, and Wisp supplies the real frame the
//  Accessibility API reported, so the marker lands on the element exactly.
//
//  The walk itself lives in `AccessibilityElementSnapshotter`; this file is
//  deliberately free of AX calls so it can be unit tested.
//

import CoreGraphics
import Foundation

/// One element in the snapshot.
nonisolated struct AccessibilityElementSnapshotEntry: Sendable, Equatable {
    /// Stable id for this snapshot only (`a1`, `a2`, …) — what the model names
    /// in a `[POINT:a12:label]` tag.
    let elementID: String
    /// A short human role name (`button`, `textfield`, `menu`…), not the raw
    /// `AXButton` string, to keep each prompt line short.
    let shortRoleName: String
    /// Title, description or placeholder — whatever names the element.
    let labelText: String
    /// The element's current value, for fields and static text where the value
    /// is what the user sees. Nil when there is nothing worth showing.
    let valueText: String?
    /// The element's frame as the Accessibility API reports it: global screen
    /// coordinates with the origin at the TOP-left of the primary display and
    /// y increasing downward (Quartz convention, not AppKit's).
    let frameInAccessibilityCoordinates: CGRect
}

/// The snapshot of the frontmost app's window taken for one turn.
nonisolated struct AccessibilityElementSnapshot: Sendable, Equatable {
    let applicationName: String
    let windowTitle: String?
    let elements: [AccessibilityElementSnapshotEntry]

    /// Looks an element up by the id the model named. Ids are matched
    /// case-insensitively because a small model will sometimes write `A12`.
    func element(withID elementID: String) -> AccessibilityElementSnapshotEntry? {
        let normalizedElementID = elementID.lowercased()
        return elements.first { $0.elementID == normalizedElementID }
    }

    // MARK: - Prompt rendering

    /// Longest label or value kept per element. Past this a line costs tokens
    /// without helping the model tell elements apart.
    static let maximumRenderedTextLength = 40

    /// The compact text added to the user's message for this turn: a header,
    /// one short line per element, and the instruction for the id tag form.
    ///
    /// Carried in the user message rather than the system prompt so the
    /// system prompt stays byte-identical between turns — the local model's
    /// prefix cache depends on that — and so the instruction only costs tokens
    /// on turns that actually have a list to point into.
    func promptText() -> String {
        guard !elements.isEmpty else { return "" }

        var headerText = "on-screen elements in \"\(Self.sanitizedForPrompt(applicationName))\""
        if let windowTitle, !windowTitle.isEmpty {
            headerText += " (window \"\(Self.sanitizedForPrompt(windowTitle))\")"
        }
        headerText += ", from the accessibility tree:"

        var lines: [String] = [headerText]
        for element in elements {
            lines.append(Self.promptLine(for: element))
        }

        lines.append(
            "to point at one of these, use its id instead of pixel coordinates, e.g. [POINT:a2:save button]. "
                + "[BOX:a2:label], [HIGHLIGHT:a2:label] and [ARROW:a2:label] take an id the same way. "
                + "only use pixel coordinates for something that is not in this list."
        )
        return lines.joined(separator: "\n")
    }

    /// One element as a single short line, e.g. `a3 textfield "Search" = "report"`.
    static func promptLine(for element: AccessibilityElementSnapshotEntry) -> String {
        var line = "\(element.elementID) \(element.shortRoleName)"
        let sanitizedLabelText = sanitizedForPrompt(element.labelText)
        if !sanitizedLabelText.isEmpty {
            line += " \"\(sanitizedLabelText)\""
        }
        if let valueText = element.valueText {
            let sanitizedValueText = sanitizedForPrompt(valueText)
            if !sanitizedValueText.isEmpty, sanitizedValueText != sanitizedLabelText {
                line += " = \"\(sanitizedValueText)\""
            }
        }
        return line
    }

    /// Collapses whitespace to single spaces, swaps characters that would read
    /// as tag syntax or break the quoting, and truncates.
    ///
    /// Square brackets become parentheses because a model that copies a label
    /// containing `]` into its tag would end the tag early.
    static func sanitizedForPrompt(_ rawText: String) -> String {
        let collapsedText = rawText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")

        guard collapsedText.count > maximumRenderedTextLength else { return collapsedText }
        return String(collapsedText.prefix(maximumRenderedTextLength - 1)) + "…"
    }

    // MARK: - Role names

    /// Maps a raw Accessibility role (and subrole) to the short name shown to
    /// the model, or nil when elements of that role are not worth listing.
    ///
    /// The list is the things a user asks to be shown — controls, fields,
    /// menus, tabs, links — plus labelled static text and images, because
    /// "where's the part that says X" is just as common a question.
    static func shortRoleName(forAccessibilityRole role: String, subrole: String?) -> String? {
        if subrole == "AXSearchField" { return "searchfield" }
        if subrole == "AXTabButton" { return "tab" }
        if subrole == "AXToggle" || subrole == "AXSwitch" { return "toggle" }

        switch role {
        case "AXButton": return "button"
        case "AXMenuButton": return "menubutton"
        case "AXPopUpButton": return "popup"
        case "AXCheckBox": return "checkbox"
        case "AXRadioButton": return "radio"
        case "AXTextField": return "textfield"
        case "AXTextArea": return "textarea"
        case "AXComboBox": return "combobox"
        case "AXSlider": return "slider"
        case "AXIncrementor": return "stepper"
        case "AXDisclosureTriangle": return "disclosure"
        case "AXLink": return "link"
        case "AXMenuBarItem": return "menu"
        case "AXMenuItem": return "menuitem"
        case "AXTab": return "tab"
        case "AXStaticText": return "text"
        case "AXImage": return "image"
        case "AXCell": return "cell"
        case "AXColorWell": return "colorwell"
        case "AXSegmentedControl": return "segments"
        default: return nil
        }
    }

    /// Whether an element of this short role belongs in the list even with no
    /// label. An unlabelled text field is still somewhere to type; an
    /// unlabelled button or image is noise the model cannot reason about.
    static func isListedWithoutLabel(shortRoleName: String) -> Bool {
        switch shortRoleName {
        case "textfield", "textarea", "searchfield", "combobox": return true
        default: return false
        }
    }
}

// MARK: - Resolving an id to a screenshot region

/// Where an element named by id lands in the screenshot the model was shown.
nonisolated struct AccessibilityElementResolvedRegion: Equatable {
    /// The element's frame in the screenshot's pixel space (top-left origin) —
    /// the space every `ScreenAnnotation` stores.
    let regionInScreenshotPixels: CGRect
    /// 1-based screen number, matching the screenshot labels and
    /// `ScreenAnnotation.screenNumber`.
    let screenNumber: Int

    /// The centre point as a zero-size region, the shape markers and arrows use.
    var centerPointRegionInScreenshotPixels: CGRect {
        CGRect(
            x: regionInScreenshotPixels.midX,
            y: regionInScreenshotPixels.midY,
            width: 0,
            height: 0
        )
    }
}

/// Coordinate conversion from Accessibility frames to screenshot pixels.
///
/// Three spaces are involved, and mixing them up is how markers end up a
/// display-height away from their element:
///
/// - Accessibility: global, origin at the top-left of the primary display,
///   y down.
/// - AppKit: global, origin at the bottom-left of the primary display, y up.
///   `CompanionScreenCapture.displayFrame` is in this space.
/// - Screenshot pixels: per display, origin at that display's top-left, y
///   down, scaled to the downsampled screenshot's size.
///
/// The result is expressed in screenshot pixels on purpose, even though the
/// Accessibility frame is exact in points: `CompanionManager.applyAnnotations`
/// stores one screenshot size per display, and an id-resolved annotation has
/// to share that scale with any coordinate-based ones drawn alongside it.
nonisolated enum AccessibilityElementGeometry {
    /// The geometry of one captured display, in the order the screenshots were
    /// labelled (index 0 is "screen 1").
    struct CapturedDisplayGeometry: Equatable {
        /// The display's frame in AppKit global coordinates.
        let displayFrameInAppKitCoordinates: CGRect
        /// The size of the screenshot image sent to the model for this display.
        let screenshotSizeInPixels: CGSize
    }

    /// Converts a top-left-origin Accessibility rectangle into AppKit's
    /// bottom-left-origin global space.
    static func appKitRect(
        fromAccessibilityRect accessibilityRect: CGRect,
        primaryDisplayHeight: CGFloat
    ) -> CGRect {
        CGRect(
            x: accessibilityRect.minX,
            y: primaryDisplayHeight - accessibilityRect.maxY,
            width: accessibilityRect.width,
            height: accessibilityRect.height
        )
    }

    /// Picks the display an element belongs to — the one containing its
    /// centre, or failing that the one it overlaps most — and returns its
    /// frame in that display's screenshot pixel space.
    ///
    /// Returns nil when the element is not on any captured display (for
    /// example a window that has since been moved off-screen).
    static func screenshotRegion(
        forAccessibilityFrame accessibilityFrame: CGRect,
        primaryDisplayHeight: CGFloat,
        capturedDisplays: [CapturedDisplayGeometry]
    ) -> AccessibilityElementResolvedRegion? {
        guard accessibilityFrame.width > 0 || accessibilityFrame.height > 0 else { return nil }

        let elementFrameInAppKitCoordinates = appKitRect(
            fromAccessibilityRect: accessibilityFrame,
            primaryDisplayHeight: primaryDisplayHeight
        )
        let elementCenterInAppKitCoordinates = CGPoint(
            x: elementFrameInAppKitCoordinates.midX,
            y: elementFrameInAppKitCoordinates.midY
        )

        var chosenDisplayIndex = capturedDisplays.firstIndex { capturedDisplay in
            capturedDisplay.displayFrameInAppKitCoordinates.contains(elementCenterInAppKitCoordinates)
        }

        if chosenDisplayIndex == nil {
            var largestOverlapArea: CGFloat = 0
            for (displayIndex, capturedDisplay) in capturedDisplays.enumerated() {
                let overlap = capturedDisplay.displayFrameInAppKitCoordinates
                    .intersection(elementFrameInAppKitCoordinates)
                guard !overlap.isNull else { continue }
                let overlapArea = overlap.width * overlap.height
                if overlapArea > largestOverlapArea {
                    largestOverlapArea = overlapArea
                    chosenDisplayIndex = displayIndex
                }
            }
        }

        guard let chosenDisplayIndex else { return nil }
        let chosenDisplay = capturedDisplays[chosenDisplayIndex]
        let displayFrame = chosenDisplay.displayFrameInAppKitCoordinates
        guard displayFrame.width > 0, displayFrame.height > 0 else { return nil }

        // Display-local, top-left origin, in points.
        let displayLocalFrameInPoints = CGRect(
            x: elementFrameInAppKitCoordinates.minX - displayFrame.minX,
            y: displayFrame.maxY - elementFrameInAppKitCoordinates.maxY,
            width: elementFrameInAppKitCoordinates.width,
            height: elementFrameInAppKitCoordinates.height
        )

        let horizontalPointsToPixelsScale = chosenDisplay.screenshotSizeInPixels.width / displayFrame.width
        let verticalPointsToPixelsScale = chosenDisplay.screenshotSizeInPixels.height / displayFrame.height

        let regionInScreenshotPixels = CGRect(
            x: displayLocalFrameInPoints.minX * horizontalPointsToPixelsScale,
            y: displayLocalFrameInPoints.minY * verticalPointsToPixelsScale,
            width: displayLocalFrameInPoints.width * horizontalPointsToPixelsScale,
            height: displayLocalFrameInPoints.height * verticalPointsToPixelsScale
        )

        return AccessibilityElementResolvedRegion(
            regionInScreenshotPixels: regionInScreenshotPixels,
            screenNumber: chosenDisplayIndex + 1
        )
    }
}
