//
//  AccessibilityElementSnapshotter.swift
//  leanring-buddy
//
//  Walks the frontmost native app's Accessibility tree and produces an
//  `AccessibilityElementSnapshot` — the id-addressed element list a turn uses
//  so the model can point with `[POINT:a12:label]` instead of guessing pixel
//  coordinates. See `AccessibilityElementSnapshot.swift` for why.
//
//  This runs at the start of a screen-referring turn, concurrently with the
//  screenshot, so it must never be what the user waits on. Every walk is
//  therefore bounded three ways — tree depth, element count, and wall-clock
//  time — and every individual Accessibility call has a short messaging
//  timeout, because an app that is busy or hung answers AX requests slowly
//  (or not at all) and a single stalled call would otherwise block for the
//  system default of several seconds.
//
//  Local-only: this reads the tree over the Accessibility API on this machine
//  and nothing else. It never modifies another app's accessibility state (for
//  example it does not set `AXEnhancedUserInterface` to coax more out of
//  Chromium apps), and it never reads the value of a secure text field.
//

import AppKit
import ApplicationServices
import Foundation

enum AccessibilityElementSnapshotter {
    /// Most elements listed. About one short prompt line each, so this keeps
    /// the snapshot to a few hundred tokens even for a busy window.
    nonisolated static let maximumListedElementCount = 150
    /// Most tree nodes visited, listed or not. Containers (groups, split
    /// views, scroll areas) vastly outnumber the elements worth listing.
    nonisolated static let maximumVisitedNodeCount = 2500
    /// Deepest level descended to. Native windows are rarely deeper than
    /// fifteen; web-content-based apps can be much deeper, and past this the
    /// elements are seldom what a user is asking about.
    nonisolated static let maximumTreeDepth = 30
    /// Wall-clock budget for the whole walk. Whatever has been collected when
    /// it runs out is used as-is.
    nonisolated static let wallTimeBudgetSeconds: TimeInterval = 0.3
    /// Per-call Accessibility messaging timeout, so one unresponsive app
    /// cannot hold a call past the walk's own budget.
    nonisolated static let perCallMessagingTimeoutSeconds: Float = 0.1
    /// Most children read from any one element. A table or outline can report
    /// thousands of rows; the first few hundred cover what is visible.
    nonisolated static let maximumChildrenReadPerElement = 300

    /// Browsers whose pages the DOM path (`AppleScriptBrowserController`) already
    /// addresses by element id. Their Accessibility trees are large and slow to
    /// walk, and the web content in them is better served by the DOM snapshot,
    /// so no Accessibility snapshot is taken while one is frontmost. Kept in
    /// step with `AppleScriptBrowserController.SupportedBrowser`.
    nonisolated static let domHandledBrowserBundleIdentifiers: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
    ]

    /// Takes a snapshot of the frontmost app's focused window, or returns nil
    /// when there is nothing appropriate to snapshot: no Accessibility
    /// permission, Wisp itself is frontmost, a DOM-handled browser is
    /// frontmost, or the app exposes no usable window.
    ///
    /// The frontmost app is read here on the main actor; the tree walk itself
    /// runs detached, off the main actor, since it is nothing but blocking IPC.
    static func captureFrontmostApplicationSnapshot() async -> AccessibilityElementSnapshot? {
        guard AXIsProcessTrusted() else { return nil }
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else { return nil }
        guard frontmostApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        if let frontmostBundleIdentifier = frontmostApplication.bundleIdentifier,
           domHandledBrowserBundleIdentifiers.contains(frontmostBundleIdentifier) {
            return nil
        }

        let frontmostProcessIdentifier = frontmostApplication.processIdentifier
        let frontmostApplicationName = frontmostApplication.localizedName ?? "the frontmost app"

        return await Task.detached(priority: .userInitiated) {
            AccessibilityElementSnapshotter.walkApplicationTree(
                processIdentifier: frontmostProcessIdentifier,
                applicationName: frontmostApplicationName
            )
        }.value
    }

    // MARK: - Walk

    /// One element's attributes, read in a single Accessibility round trip.
    nonisolated private struct ElementAttributes {
        let role: String?
        let subrole: String?
        let title: String?
        let descriptionText: String?
        let placeholderText: String?
        let frame: CGRect?
    }

    /// Breadth-first so that when a budget runs out the snapshot still covers
    /// the whole window at a shallow level (toolbar, sidebar, main controls)
    /// rather than one deep corner of it.
    private nonisolated static func walkApplicationTree(
        processIdentifier: pid_t,
        applicationName: String
    ) -> AccessibilityElementSnapshot? {
        let walkDeadline = Date().addingTimeInterval(wallTimeBudgetSeconds)
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, perCallMessagingTimeoutSeconds)

        guard let windowElement = copyElementAttribute(applicationElement, attribute: kAXFocusedWindowAttribute)
                ?? copyElementAttribute(applicationElement, attribute: kAXMainWindowAttribute) else {
            return nil
        }
        AXUIElementSetMessagingTimeout(windowElement, perCallMessagingTimeoutSeconds)

        let windowAttributes = readElementAttributes(windowElement)
        guard let windowFrame = windowAttributes?.frame, windowFrame.width > 0, windowFrame.height > 0 else {
            return nil
        }
        let windowTitle = windowAttributes?.title

        var listedElements: [AccessibilityElementSnapshotEntry] = []
        var visitedNodeCount = 0

        // The app's top-level menu bar items first. They are cheap (one level,
        // about a dozen), always visible, and "which menu is X in" is one of
        // the most common questions. Their menus are closed, so their items
        // are not descended into — they have no on-screen frame.
        if let menuBarElement = copyElementAttribute(applicationElement, attribute: kAXMenuBarAttribute) {
            AXUIElementSetMessagingTimeout(menuBarElement, perCallMessagingTimeoutSeconds)
            for menuBarItemElement in copyChildElements(menuBarElement) {
                guard listedElements.count < maximumListedElementCount, Date() < walkDeadline else { break }
                visitedNodeCount += 1
                AXUIElementSetMessagingTimeout(menuBarItemElement, perCallMessagingTimeoutSeconds)
                if let listedEntry = listedEntry(
                    for: menuBarItemElement,
                    attributes: readElementAttributes(menuBarItemElement),
                    visibleBounds: nil,
                    nextElementNumber: listedElements.count + 1
                ) {
                    listedElements.append(listedEntry)
                }
            }
        }

        // Then the focused window, breadth-first. The window itself is not
        // listed; its descendants are, if they fall inside its frame (a child
        // scrolled out of view reports a frame outside it).
        var pendingElementsWithDepth: [(element: AXUIElement, depth: Int)] = copyChildElements(windowElement)
            .map { (element: $0, depth: 1) }
        var nextPendingIndex = 0

        while nextPendingIndex < pendingElementsWithDepth.count {
            if listedElements.count >= maximumListedElementCount { break }
            if visitedNodeCount >= maximumVisitedNodeCount { break }
            if Date() >= walkDeadline { break }
            if Task.isCancelled { break }

            let (currentElement, currentDepth) = pendingElementsWithDepth[nextPendingIndex]
            nextPendingIndex += 1
            visitedNodeCount += 1
            AXUIElementSetMessagingTimeout(currentElement, perCallMessagingTimeoutSeconds)

            // Read once and used for both decisions below — listing and
            // descending — since each read is an IPC round trip.
            let currentAttributes = readElementAttributes(currentElement)

            if let listedEntry = listedEntry(
                for: currentElement,
                attributes: currentAttributes,
                visibleBounds: windowFrame,
                nextElementNumber: listedElements.count + 1
            ) {
                listedElements.append(listedEntry)
            }

            if currentDepth < maximumTreeDepth,
               shouldDescend(into: currentAttributes, visibleBounds: windowFrame) {
                for childElement in copyChildElements(currentElement) {
                    pendingElementsWithDepth.append((element: childElement, depth: currentDepth + 1))
                }
            }
        }

        guard !listedElements.isEmpty else { return nil }
        return AccessibilityElementSnapshot(
            applicationName: applicationName,
            windowTitle: windowTitle,
            elements: listedElements
        )
    }

    /// Roles whose children are never worth the IPC to read: controls whose
    /// label is already on the element itself, and scroll bars. Links are not
    /// here — a web link's visible text often lives on a child.
    private nonisolated static let rolesNotDescendedInto: Set<String> = [
        "AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton",
        "AXTextField", "AXTextArea", "AXStaticText", "AXImage", "AXSlider",
        "AXIncrementor", "AXColorWell", "AXScrollBar", "AXValueIndicator",
        "AXDisclosureTriangle", "AXComboBox",
    ]

    /// Whether the walk reads this element's children. Leaf controls are
    /// skipped, and so is any subtree whose container lies wholly outside the
    /// window (scrolled-away content) — but only when the container reports a
    /// real frame, since some groups report none and still hold visible
    /// children.
    private nonisolated static func shouldDescend(
        into attributes: ElementAttributes?,
        visibleBounds: CGRect
    ) -> Bool {
        guard let attributes else { return true }
        if let role = attributes.role, rolesNotDescendedInto.contains(role) { return false }
        if let frame = attributes.frame, frame.width > 0, frame.height > 0, !visibleBounds.intersects(frame) {
            return false
        }
        return true
    }

    /// Returns an element's snapshot entry if it is a listable role, has a
    /// visible frame, and has something to call it by.
    ///
    /// - Parameter visibleBounds: When given, the element must intersect it —
    ///   the window frame, so off-screen scrolled content is left out.
    private nonisolated static func listedEntry(
        for element: AXUIElement,
        attributes: ElementAttributes?,
        visibleBounds: CGRect?,
        nextElementNumber: Int
    ) -> AccessibilityElementSnapshotEntry? {
        guard let attributes,
              let role = attributes.role,
              let shortRoleName = AccessibilityElementSnapshot.shortRoleName(
                forAccessibilityRole: role,
                subrole: attributes.subrole
              ),
              let frame = attributes.frame,
              frame.width >= 2, frame.height >= 2 else {
            return nil
        }
        if let visibleBounds, !visibleBounds.intersects(frame) { return nil }

        // A secure text field's value is a password; it is never read. Its
        // label is still listed, so "where do I type my password" can point.
        let isSecureTextField = attributes.subrole == "AXSecureTextField"

        // The value is read separately, and only for roles whose value is what
        // the user sees as the element's text. A text area's value can be an
        // entire document, so it is left out rather than copied over IPC.
        var valueText: String?
        let rolesWhoseValueIsShown: Set<String> = ["text", "textfield", "searchfield", "combobox", "popup", "cell"]
        if !isSecureTextField, rolesWhoseValueIsShown.contains(shortRoleName) {
            valueText = copyStringAttribute(element, attribute: kAXValueAttribute)
        }

        let labelText = [attributes.title, attributes.descriptionText, attributes.placeholderText]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        // Static text is named by its value; move it into the label so the
        // line reads `a4 text "Downloads"` rather than an empty label and a value.
        var resolvedLabelText = labelText ?? ""
        var resolvedValueText = valueText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolvedLabelText.isEmpty, shortRoleName == "text", let staticTextValue = resolvedValueText {
            resolvedLabelText = staticTextValue
            resolvedValueText = nil
        }
        if resolvedValueText?.isEmpty == true { resolvedValueText = nil }

        if resolvedLabelText.isEmpty,
           !AccessibilityElementSnapshot.isListedWithoutLabel(shortRoleName: shortRoleName) {
            return nil
        }

        return AccessibilityElementSnapshotEntry(
            elementID: "a\(nextElementNumber)",
            shortRoleName: shortRoleName,
            labelText: resolvedLabelText,
            valueText: resolvedValueText,
            frameInAccessibilityCoordinates: frame
        )
    }

    // MARK: - Accessibility API helpers

    /// Reads role, subrole, title, description, placeholder, position and size
    /// in one `AXUIElementCopyMultipleAttributeValues` round trip, rather than
    /// seven — IPC per call is what dominates a walk's cost.
    private nonisolated static func readElementAttributes(_ element: AXUIElement) -> ElementAttributes? {
        let requestedAttributeNames: [String] = [
            kAXRoleAttribute,
            kAXSubroleAttribute,
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXPlaceholderValueAttribute,
            kAXPositionAttribute,
            kAXSizeAttribute,
        ]

        var attributeValuesArray: CFArray?
        let copyResult = AXUIElementCopyMultipleAttributeValues(
            element,
            requestedAttributeNames as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &attributeValuesArray
        )
        guard copyResult == .success,
              let attributeValues = attributeValuesArray as? [AnyObject],
              attributeValues.count == requestedAttributeNames.count else {
            return nil
        }

        // A missing attribute comes back as an AXValue wrapping an error,
        // rather than failing the whole call; those read as nil here.
        func stringValue(at attributeIndex: Int) -> String? {
            attributeValues[attributeIndex] as? String
        }

        var frame: CGRect?
        if let positionValue = axValue(attributeValues[5], ofType: .cgPoint),
           let sizeValue = axValue(attributeValues[6], ofType: .cgSize) {
            var elementPosition = CGPoint.zero
            var elementSize = CGSize.zero
            if AXValueGetValue(positionValue, .cgPoint, &elementPosition),
               AXValueGetValue(sizeValue, .cgSize, &elementSize) {
                frame = CGRect(origin: elementPosition, size: elementSize)
            }
        }

        return ElementAttributes(
            role: stringValue(at: 0),
            subrole: stringValue(at: 1),
            title: stringValue(at: 2),
            descriptionText: stringValue(at: 3),
            placeholderText: stringValue(at: 4),
            frame: frame
        )
    }

    /// Returns `rawValue` as an `AXValue` if it is one holding `expectedType`.
    private nonisolated static func axValue(_ rawValue: AnyObject, ofType expectedType: AXValueType) -> AXValue? {
        guard CFGetTypeID(rawValue) == AXValueGetTypeID() else { return nil }
        let candidateValue = rawValue as! AXValue
        guard AXValueGetType(candidateValue) == expectedType else { return nil }
        return candidateValue
    }

    private nonisolated static func copyStringAttribute(_ element: AXUIElement, attribute: String) -> String? {
        var attributeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &attributeValue) == .success else {
            return nil
        }
        return attributeValue as? String
    }

    private nonisolated static func copyElementAttribute(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        var attributeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &attributeValue) == .success,
              let attributeValue,
              CFGetTypeID(attributeValue) == AXUIElementGetTypeID() else {
            return nil
        }
        return (attributeValue as! AXUIElement)
    }

    /// The element's children, capped at `maximumChildrenReadPerElement` via
    /// the ranged copy so a huge table is not copied whole.
    private nonisolated static func copyChildElements(_ element: AXUIElement) -> [AXUIElement] {
        var childrenArray: CFArray?
        let copyResult = AXUIElementCopyAttributeValues(
            element,
            kAXChildrenAttribute as CFString,
            0,
            maximumChildrenReadPerElement,
            &childrenArray
        )
        guard copyResult == .success, let children = childrenArray as? [AnyObject] else { return [] }
        return children.compactMap { child in
            guard CFGetTypeID(child) == AXUIElementGetTypeID() else { return nil }
            return (child as! AXUIElement)
        }
    }
}
