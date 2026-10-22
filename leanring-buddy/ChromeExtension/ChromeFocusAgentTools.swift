//
//  ChromeFocusAgentTools.swift
//  leanring-buddy
//
//  The `chrome_focus_mode` agent tool (phase 09): start or stop Chrome focus mode.
//  Plain spoken commands ("focus on my essay for 45 minutes") don't need it —
//  `ChromeTabCommandRouter` runs those without the model — so this is for the
//  model's own phrasing ("help me concentrate on chemistry until 5").
//
//  `.writing(.localMachine)`: it rearranges the browser, so it asks once and
//  session auto-approve covers it. It is reversible and closes nothing.
//

import Foundation

enum ChromeFocusToolDefinitions {
    static let focusModeToolName = "chrome_focus_mode"

    static let focusMode = BuddyToolDefinition(
        name: focusModeToolName,
        description: "Start or stop Chrome focus mode: for a set time, collapse tab groups that aren't about the topic, mute off-topic tabs playing sound and group on-topic tabs as \"Focus\"; everything is put back when time is up or on stop. Nothing is closed.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "action": .object([
                    "type": .string("string"),
                    "enum": .array([.string("start"), .string("stop")]),
                    "description": .string("\"start\" (default) or \"stop\".")
                ]),
                "topic": .object([
                    "type": .string("string"),
                    "description": .string("What the user is working on, e.g. \"history essay\". Tabs sharing its words stay in view.")
                ]),
                "minutes": .object([
                    "type": .string("integer"),
                    "description": .string("How long, 1 to 240. Default 45.")
                ])
            ])
        ]),
        metadata: .writing(.localMachine)
    )
}

extension AgentToolRegistry {

    func registerChromeFocusTools() {
        register(ChromeFocusToolDefinitions.focusMode) { input in
            var requestedAction = "start"
            var topic = ""
            var minutes = ChromeFocusCommandParser.defaultMinutes
            if case .object(let arguments) = input {
                if case .string(let rawAction)? = arguments["action"] { requestedAction = rawAction.lowercased() }
                if case .string(let rawTopic)? = arguments["topic"] { topic = rawTopic.trimmingCharacters(in: .whitespacesAndNewlines) }
                switch arguments["minutes"] {
                case .number(let numericMinutes)?: minutes = Int(numericMinutes.rounded())
                case .string(let textMinutes)?: minutes = Int(textMinutes) ?? minutes
                default: break
                }
            }
            if requestedAction == "stop" {
                return await ChromeFocusSession.shared.stopFocus().replyText
            }
            guard ChromeFocusCommandParser.allowedMinutes.contains(minutes) else {
                return "focus mode runs for 1 to 240 minutes."
            }
            return await ChromeFocusSession.shared.startFocus(topic: topic, minutes: minutes).replyText
        }
    }
}
