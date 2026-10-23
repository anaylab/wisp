//
//  ScreenWatchAgentTools.swift
//  leanring-buddy
//
//  `watch_screen` and `stop_screen_watch`: the agent's way into screen
//  watchers (and, with `in_chrome_tab`, Chrome page watchers — phase 08), for requests the deterministic `ScreenWatchRequestParser`
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
                description: "Watch the user's screen — or, with in_chrome_tab, a Chrome tab even in the background — and notify them when something happens, e.g. \"tell me when the build finishes\", \"let me know when this tab says Deployed\", \"tell me when the price drops below $80\". No further model calls. condition: text_appears, text_disappears, screen_settles (it was changing and has stopped), number_below / number_above (the number beside near_text passes threshold).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "condition": .object([
                            "type": .string("string"),
                            "enum": .array([.string("text_appears"), .string("text_disappears"), .string("screen_settles"), .string("number_below"), .string("number_above")]),
                            "description": .string("What to wait for.")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("The short text to look for, for text_appears / text_disappears, e.g. \"Succeeded\".")
                        ]),
                        "near_text": .object([
                            "type": .string("string"),
                            "description": .string("For number_below / number_above: the label the number sits beside, e.g. \"price\".")
                        ]),
                        "threshold": .object([
                            "type": .string("number"),
                            "description": .string("For number_below / number_above: the value to pass, e.g. 80.")
                        ]),
                        "in_chrome_tab": .object([
                            "type": .string("boolean"),
                            "description": .string("Watch a Chrome tab's page instead of the screen (needs the Wisp Tabs extension with page reading). Sees the page even when it's not showing.")
                        ]),
                        "chrome_tab": .object([
                            "type": .string("string"),
                            "description": .string("With in_chrome_tab: a tab id from chrome_list_tabs, or a word from its title or address. Leave out for the tab the user is looking at.")
                        ]),
                        "reload_every_minutes": .object([
                            "type": .string("integer"),
                            "description": .string("With in_chrome_tab, for a page that doesn't update by itself (tickets back in stock): reload it in a background tab this often, at least 5.")
                        ])
                    ]),
                    "required": .array([.string("condition")])
                ]),
                metadata: .reading(.localMachine)
            )
        ) { input in
            await Self.startWatchFromTool(input: input)
        }

        register(
            BuddyToolDefinition(
                name: ScreenWatchToolNames.stopScreenWatch,
                description: "Stop every screen watch and Chrome tab watch started with watch_screen (\"stop watching\").",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
                metadata: .reading(.localMachine)
            )
        ) { _ in
            let stoppedWatchCount = ScreenWatcherStore.shared.stopAllWatching() + ChromePageWatchStore.shared.stopAllWatching()
            if stoppedWatchCount == 0 { return "there were no watches running." }
            return stoppedWatchCount == 1 ? "stopped the watch." : "stopped \(stoppedWatchCount) watches."
        }
    }

    @MainActor
    private static func startWatchFromTool(input: JSONValue) async -> String {
        guard case .object(let arguments) = input,
              case .string(let conditionName)? = arguments["condition"] else {
            return "i need a condition: text_appears, text_disappears, screen_settles, number_below or number_above."
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
        case "number_below", "number_above":
            guard case .string(let nearText)? = arguments["near_text"],
                  !ScreenWatchTextMatching.normalizedText(nearText).isEmpty,
                  case .number(let threshold)? = arguments["threshold"] else {
                return "\(conditionName) needs near_text (the label beside the number) and threshold."
            }
            let trimmedNearText = String(nearText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            condition = .numberCrosses(ScreenWatchNumberThreshold(
                subjectText: trimmedNearText,
                nearText: trimmedNearText,
                direction: conditionName.lowercased() == "number_below" ? .below : .above,
                threshold: threshold,
                thresholdText: ChromePageWatchWireCondition.displayText(forThreshold: threshold)
            ))
        default:
            return "unknown condition \"\(conditionName)\" — use text_appears, text_disappears, screen_settles, number_below or number_above."
        }

        if case .bool(true)? = arguments["in_chrome_tab"] {
            return await startChromeTabWatchFromTool(condition: condition, arguments: arguments)
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

    @MainActor
    private static func startChromeTabWatchFromTool(condition: ScreenWatchCondition, arguments: [String: JSONValue]) async -> String {
        var reloadEveryMinutes: Int?
        if case .number(let requestedMinutes)? = arguments["reload_every_minutes"], requestedMinutes > 0 {
            reloadEveryMinutes = min(
                max(Int(requestedMinutes.rounded()), ChromePageWatchRouter.minimumReloadEveryMinutes),
                ChromePageWatchRouter.maximumReloadEveryMinutes
            )
        }
        do {
            var tabID: Int?
            if case .string(let rawTabReference)? = arguments["chrome_tab"],
               !rawTabReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let snapshot = try await ChromeTabOrganizer.fetchSnapshot()
                let candidates = snapshot.tabs.map { tab in
                    ChromeTabReferenceResolver.Candidate(id: tab.id, windowId: tab.windowId, title: tab.title, url: tab.url, isActive: tab.active)
                }
                switch ChromeTabReferenceResolver.resolve(rawTabReference, among: candidates, focusedWindowID: snapshot.focusedWindowId) {
                case .showingTab:
                    tabID = nil
                case .tab(let resolvedTabID):
                    tabID = resolvedTabID
                case .ambiguous(let ambiguousCandidates):
                    return ChromeTabReferenceResolver.ambiguityReply(for: ambiguousCandidates)
                case .notFound:
                    return "no open chrome tab matches that. call chrome_list_tabs for the open tabs and their ids."
                }
            }
            switch try await ChromePageWatchStore.shared.startWatching(condition, tabID: tabID, reloadEveryMinutes: reloadEveryMinutes) {
            case .started(let startedWatch):
                return "now watching the chrome tab \"\(startedWatch.tabDisplayName)\" until \(condition.summaryText)\(reloadEveryMinutes.map { ", reloading it in a background tab every \($0) minutes" } ?? ""). the user will get a notification then; tell them that."
            case .alreadyWatching:
                return "already watching that tab until \(condition.summaryText)."
            case .tooManyWatches:
                return "already watching \(ChromePageWatchStore.maximumActiveWatchCount) chrome tabs, the most at once. the user can say \"stop watching\" first."
            }
        } catch {
            return error.localizedDescription
        }
    }
}
