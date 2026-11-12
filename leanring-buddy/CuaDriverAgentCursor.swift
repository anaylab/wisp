//
//  CuaDriverAgentCursor.swift
//  leanring-buddy
//
//  Shows Wisp's agent cursor on the element a cua-driver action is about to
//  act on. The driver presses elements through Accessibility without moving the
//  user's pointer or taking focus, so without this the work in another app is
//  invisible. This is the same "second cursor" the browser loop already uses
//  (`BrowserCursorGuide`), now also driven by native-app actions.
//

import AppKit

@MainActor
enum CuaDriverAgentCursor {

    /// Actions that touch one element, with the verb shown beside the cursor.
    private static let verbByBareToolName: [String: String] = [
        "click": "Click",
        "double_click": "Double-click",
        "right_click": "Right-click",
        "type_text": "Type into",
        "set_value": "Set",
        "scroll": "Scroll",
    ]

    /// How long the cursor stays after the last action before it goes away.
    private static let lingerSeconds = 2.5

    private static var pendingFadeTask: Task<Void, Never>?

    /// Flies the agent cursor to the element `toolInput` names, if it has one
    /// and Wisp saw its position. Anything else is a quiet no-op: the action
    /// itself must never wait on or fail because of a decoration.
    static func guide(beforeBareToolName bareToolName: String, toolInput: JSONValue) async {
        guard let verb = verbByBareToolName[bareToolName],
              case .object(let inputFields) = toolInput,
              case .string(let elementToken)? = inputFields["element_token"],
              let elementDescription = CuaDriverElementCache.shared.elementDescription(forToken: elementToken),
              let globalTopLeftPoint = elementDescription.screenCenterInGlobalTopLeftPoints,
              let primaryScreen = NSScreen.screens.first,
              let guide = AgentToolRegistry.shared.browserCursorGuide else { return }

        // The driver reports top-left points; the guide wants AppKit's
        // bottom-left, flipped by the primary display's height.
        let appKitPoint = CGPoint(x: globalTopLeftPoint.x, y: primaryScreen.frame.height - globalTopLeftPoint.y)
        guard let displayFrame = NSScreen.screens.first(where: { $0.frame.contains(appKitPoint) })?.frame else { return }

        pendingFadeTask?.cancel()

        var actionText = verb
        if let label = elementDescription.label, !label.isEmpty {
            actionText += " “\(label.prefix(28))”"
        }
        if let appName = elementDescription.appName, !appName.isEmpty {
            actionText += " in \(appName)"
        }
        await guide.guideCursor(to: appKitPoint, on: displayFrame, actionText: actionText)

        pendingFadeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(lingerSeconds))
            guard !Task.isCancelled else { return }
            guide.endCursorGuidance()
        }
    }
}
