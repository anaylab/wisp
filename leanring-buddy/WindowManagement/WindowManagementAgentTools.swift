//
//  WindowManagementAgentTools.swift
//  leanring-buddy
//
//  The agent's `arrange_windows` tool: the same window placement the direct
//  spoken route uses ("put Safari on the left"), for when the model decides a
//  layout is part of a larger task or the phrasing was too loose for
//  `WindowLayoutCommandParser`.
//
//  Declared as a recoverable local write (`.writing(.localMachine)`): not
//  destructive and nothing leaves the Mac. So it asks once like any write, and
//  session auto-approve covers it — its name carries none of
//  `ToolCallSafety`'s always-ask words.
//

import Foundation

enum WindowManagementToolNames {
    static let arrangeWindows = "arrange_windows"
}

extension AgentToolRegistry {

    /// Registers `arrange_windows`.
    func registerWindowManagementTools() {
        let placementRawValues = WindowPlacement.allCases.map(\.rawValue)
        register(
            BuddyToolDefinition(
                name: WindowManagementToolNames.arrangeWindows,
                description: "Move and resize an app's window on screen: left or right half, top or bottom half, a corner quarter, a third, maximize to fill the screen, center it, or move it to the next display. Use for requests like \"put Safari on the left\", \"make this window full screen\", \"move this to my other screen\". For several windows (e.g. tile Notes and Mail) call it once per window.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "app": .object([
                            "type": .string("string"),
                            "description": .string("The running app whose window to move, e.g. \"Safari\" or \"Google Chrome\". Leave empty for the window the user is working in.")
                        ]),
                        "placement": .object([
                            "type": .string("string"),
                            "enum": .array(placementRawValues.map { .string($0) }),
                            "description": .string("Where the window goes.")
                        ])
                    ]),
                    "required": .array([.string("placement")])
                ]),
                metadata: .writing(.localMachine)
            )
        ) { input in
            guard case .object(let arguments) = input,
                  case .string(let rawPlacementArgument)? = arguments["placement"],
                  let placement = WindowLayoutCommandParser.placement(fromToolArgument: rawPlacementArgument) else {
                let placementList = placementRawValues.joined(separator: ", ")
                return "i need a placement, one of: \(placementList)."
            }

            var rawApplicationArgument = ""
            if case .string(let providedApplicationArgument)? = arguments["app"] {
                rawApplicationArgument = providedApplicationArgument.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let target: WindowLayoutTarget
            let frontWindowWords: Set<String> = ["", "front", "frontmost", "current", "this", "this window", "it", "active"]
            if frontWindowWords.contains(rawApplicationArgument.lowercased()) {
                target = .frontWindow
            } else {
                let runningApplicationNames = WindowLayoutExecutor.runningApplicationNamesForMatching()
                guard let resolvedApplicationName = WindowLayoutApplicationNameMatcher.uniqueApplicationName(
                    matching: rawApplicationArgument,
                    among: runningApplicationNames
                ) else {
                    let runningApplicationList = runningApplicationNames.sorted().prefix(30).joined(separator: ", ")
                    return "no single running app matches \"\(rawApplicationArgument)\". running apps: \(runningApplicationList)."
                }
                target = .application(named: resolvedApplicationName)
            }

            let assignmentResult = await WindowLayoutExecutor.place(
                WindowLayoutAssignment(target: target, placement: placement)
            )
            return WindowLayoutReplyText.reply(for: [assignmentResult])
        }
    }
}
