//
//  ScreenWatchAgentTools.swift
//  leanring-buddy
//
//  `watch_screen` and `stop_screen_watch`: the agent's way into screen
//  watchers, for requests the deterministic `ScreenWatchRequestParser`
//  declined ("tell me when an error appears", "let me know when the spinner
//  goes away"). Both read the screen on this Mac and change nothing, so they
//  are read-only and need no confirmation; the watch itself runs in
//  `ScreenWatcherStore` with no model call, and its result lands in the same
//  place as a spoken watch (notification + notch).
//
//  Kept in its own file (registered with one line in `registerBuiltInTools`)
//  so the shared registry stays easy to merge.
//

import Foundation

enum ScreenWatchToolNames {
    static let watchScreen = "watch_screen"
    static let stopScreenWatch = "stop_screen_watch"
}

extension AgentToolRegistry {
    func registerScreenWatchTools() {
        register(
            BuddyToolDefinition(
                name: ScreenWatchToolNames.watchScreen,
                description: "Watch the user's screen in the background and notify them when something happens — e.g. \"tell me when the build finishes\" or \"let me know when it says Succeeded\". Uses on-device text recognition every few seconds; no further model calls. condition: text_appears (text shows up), text_disappears (text goes away), or screen_settles (the screen's text was changing and has stopped — a build, download or export finishing).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "condition": .object([
                            "type": .string("string"),
                            "enum": .array([.string("text_appears"), .string("text_disappears"), .string("screen_settles")]),
                            "description": .string("What to wait for.")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("The short text to look for on screen, for text_appears / text_disappears, e.g. \"Succeeded\" or \"Downloading\".")
                        ])
                    ]),
                    "required": .array([.string("condition")])
                ]),
                metadata: .reading(.localMachine)
            )
        ) { input in
            guard case .object(let arguments) = input,
                  case .string(let conditionName)? = arguments["condition"] else {
                return "i need a condition: text_appears, text_disappears or screen_settles."
            }
            var requestedText: String?
            if case .string(let textArgument)? = arguments["text"] {
                requestedText = ScreenWatchRequestParser.cleanedTargetText(textArgument, requiresExplicitTextMarker: false)
            }

            let condition: ScreenWatchCondition
            switch conditionName.lowercased() {
            case "text_appears":
                guard let requestedText else { return "text_appears needs the short text to look for." }
                condition = .textAppears(requestedText)
            case "text_disappears":
                guard let requestedText else { return "text_disappears needs the short text to look for." }
                condition = .textDisappears(requestedText)
            case "screen_settles":
                condition = .screenTextSettles
            default:
                return "unknown condition \"\(conditionName)\" — use text_appears, text_disappears or screen_settles."
            }

            switch ScreenWatcherStore.shared.startWatching(condition) {
            case .started:
                return "now watching the screen until \(condition.summaryText). the user will get a notification then; tell them that."
            case .alreadyWatching:
                return "already watching the screen until \(condition.summaryText)."
            case .tooManyWatchers:
                return "already running \(ScreenWatcherStore.maximumActiveWatcherCount) screen watches, the most at once. the user can say \"stop watching\" first."
            }
        }

        register(
            BuddyToolDefinition(
                name: ScreenWatchToolNames.stopScreenWatch,
                description: "Stop every screen watch started with watch_screen (\"stop watching\").",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
                metadata: .reading(.localMachine)
            )
        ) { _ in
            let stoppedWatcherCount = ScreenWatcherStore.shared.stopAllWatching()
            if stoppedWatcherCount == 0 { return "there were no screen watches running." }
            return stoppedWatcherCount == 1 ? "stopped the screen watch." : "stopped \(stoppedWatcherCount) screen watches."
        }
    }
}
