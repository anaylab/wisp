//
//  ExtensionBrowserReplies.swift
//  leanring-buddy
//
//  The pure side of `ExtensionBrowserController`: what the extension's DOM
//  controller replies mean, in `BrowserControllerError`s worded exactly like
//  the AppleScript controller's, plus the element-id guard and the screen-point
//  flip into AppKit coordinates.
//
//  Pure (Foundation only) so `Tests/ChromeExtDOMController` can compile it.
//

import Foundation

/// The `status` an element action returns (handlers/dom-controller.js, which
/// passes on content/dom-agent.js's answer).
enum ExtensionElementActionStatus: String, Sendable {
    case succeeded = "OK"
    case missing = "MISSING"
    case disabled = "DISABLED"
    case sensitive = "SENSITIVE"
    case ignored = "IGNORED"
    case notASelect = "NOTSELECT"
    case noMatchingOption = "NOOPTION"
    case unsupportedKey = "UNSUPPORTED_KEY"
}

enum ExtensionElementAction: Sendable {
    case click, typeText, hover, selectOption(optionLabel: String), pressKey(keyName: String), scroll

    var failureDescription: String {
        switch self {
        case .click: return "click"
        case .typeText: return "type into"
        case .hover: return "hover over"
        case .selectOption(let optionLabel): return "select \"\(optionLabel)\" in"
        case .pressKey(let keyName): return "press \(keyName) in"
        case .scroll: return "scroll"
        }
    }
}

enum ExtensionBrowserReplies {
    /// Nil when the action happened; otherwise the error to throw, worded as
    /// `AppleScriptBrowserController` words the same outcome.
    static func error(
        forActionStatus rawStatus: String,
        action: ExtensionElementAction,
        elementID: String
    ) -> BrowserControllerError? {
        switch ExtensionElementActionStatus(rawValue: rawStatus) {
        case .succeeded:
            return nil
        case .missing:
            return .elementNotFound(elementID)
        case .disabled:
            return .scriptFailed("\(elementID) is disabled right now.")
        case .sensitive:
            return .scriptFailed("\(elementID) is a password or payment field — only you can fill that in.")
        case .ignored:
            return .scriptFailed("\(elementID) is in a part of the page marked private — Wisp leaves it alone.")
        case .notASelect:
            return .scriptFailed("\(elementID) isn't a dropdown — click it to open it instead.")
        case .noMatchingOption:
            if case .selectOption(let optionLabel) = action {
                return .scriptFailed("No option matching \"\(optionLabel)\".")
            }
            return .scriptFailed("No matching option.")
        case .unsupportedKey:
            return .scriptFailed("Can't press that key.")
        case nil:
            switch action {
            case .pressKey(let keyName): return .scriptFailed("Couldn't press \(keyName).")
            case .scroll: return .scriptFailed("Couldn't scroll.")
            default: return .scriptFailed("Couldn't \(action.failureDescription) \(elementID).")
            }
        }
    }

    /// Element ids come from the model. Only the shapes the snapshot produces
    /// are passed on (`e12`, or `f4e3` for a cross-origin frame); the extension
    /// checks the exact pattern again before anything reaches a page.
    static func sanitizedElementID(_ elementID: String) -> String? {
        let trimmed = elementID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 24,
              trimmed.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII }) else {
            return nil
        }
        return trimmed
    }

    /// Chrome's wording when a tab id no longer exists. A request that fails
    /// this way mid-task means the working tab was closed — the user saying
    /// stop — even if the `tab.removed` event hasn't arrived yet.
    static func isMissingTabErrorMessage(_ message: String) -> Bool {
        message.range(of: "No tab with id", options: .caseInsensitive) != nil
    }

    /// The extension's screen point (top-left origin, anchored at the primary
    /// display, in points) in AppKit's global space (bottom-left origin,
    /// anchored the same way): only y flips, about the primary display's height.
    static func appKitPoint(fromTopLeftScreenPoint topLeftPoint: CGPoint, primaryDisplayHeight: CGFloat) -> CGPoint {
        CGPoint(x: topLeftPoint.x, y: primaryDisplayHeight - topLeftPoint.y)
    }

    /// The wait the extension is asked for, and the slightly longer time Wisp
    /// waits for its reply, inside the bridge's 30s cap.
    static func settleRequestTimeouts(forWaitSeconds waitSeconds: TimeInterval) -> (waitSeconds: Double, requestTimeoutSeconds: Double) {
        let boundedWaitSeconds = min(max(0, waitSeconds), 27)
        return (boundedWaitSeconds, min(boundedWaitSeconds + 3, 30))
    }
}
