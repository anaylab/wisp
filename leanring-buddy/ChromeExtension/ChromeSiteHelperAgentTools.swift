//
//  ChromeSiteHelperAgentTools.swift
//  leanring-buddy
//
//  `chrome_canvas_assignment` and `chrome_meeting_captions` (phase 10): the model
//  reads the Canvas assignment open in Chrome (with whether it's on today's
//  checklist and the Wisp calendar), or the recent captions of a Meet / Zoom web
//  call. Both read-only and local (`.reading(.localMachine)`), so they never ask;
//  their `chrome_` names put them in the `.browser` scope and the buddy Browser
//  group. What they return is page data, fenced as such.
//

import Foundation

enum ChromeSiteHelperToolDefinitions {
    static let canvasAssignmentToolName = "chrome_canvas_assignment"
    static let meetingCaptionsToolName = "chrome_meeting_captions"

    static let canvasAssignment = BuddyToolDefinition(
        name: canvasAssignmentToolName,
        description: "Read the Canvas assignment open in Chrome: title, due date, points, rubric and description, and whether it's already on the user's checklist for today and their Wisp calendar.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "tab_id": .object([
                    "type": .string("integer"),
                    "description": .string("A tab id from chrome_list_tabs. Leave out for the tab the user is looking at.")
                ])
            ])
        ]),
        metadata: .reading(.localMachine)
    )

    static let meetingCaptions = BuddyToolDefinition(
        name: meetingCaptionsToolName,
        description: "Read the live captions of the Google Meet or Zoom web call open in Chrome (only when the user turned captions on), to catch them up on what was said.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "last_minutes": .object([
                    "type": .string("integer"),
                    "description": .string("How many recent minutes to read, 1–30. Leave out for everything kept (up to 30).")
                ])
            ])
        ]),
        metadata: .reading(.localMachine)
    )
}

extension AgentToolRegistry {

    /// Always registered: without the extension or the permission the reply
    /// says how to fix it.
    func registerChromeSiteHelperTools() {
        register(ChromeSiteHelperToolDefinitions.canvasAssignment) { input in
            await Self.readCanvasAssignmentForModel(tabID: Self.integerArgument(named: ["tab_id", "tabId", "tab"], in: input))
        }

        register(ChromeSiteHelperToolDefinitions.meetingCaptions) { input in
            await Self.readMeetingCaptionsForModel(lastMinutes: Self.integerArgument(named: ["last_minutes", "lastMinutes", "minutes"], in: input))
        }
    }

    @MainActor
    private static func readCanvasAssignmentForModel(tabID: Int?) async -> String {
        do {
            let (details, _, assignmentStatus) = try await CanvasPageHelper.shared.readAssignment(tabID: tabID)
            let statusLine = CanvasAssignmentReplyText.statusReply(
                title: details.title, dueDate: details.dueDate, status: assignmentStatus, calendar: .current
            )
            return CanvasAssignmentPrompt.promptText(
                for: details,
                statusLine: "wisp's own check (not from the page): \(statusLine)",
                isLocalModel: BuddyChatProviderSelection.current == .localOllama
            )
        } catch {
            return error.localizedDescription
        }
    }

    @MainActor
    private static func readMeetingCaptionsForModel(lastMinutes: Int?) async -> String {
        let clampedMinutes = lastMinutes.map { min(max($0, 1), 30) }
        do {
            let captions = try await MeetingCaptionsHelper.readCaptions(tabID: nil, lastMinutes: clampedMinutes)
            guard captions.captionsFound else { return MeetingCaptionsPrompt.noCaptionsReply(site: captions.site) }
            let request: MeetingCaptionsRequest = clampedMinutes.map { .summarizeLast(minutes: $0) } ?? .summarizeSoFar
            guard !captions.entries.isEmpty else { return MeetingCaptionsPrompt.nothingSaidReply(request: request) }
            return MeetingCaptionsPrompt.userMessage(
                for: captions,
                request: request,
                characterBudget: ChromePageTextPrompt.characterBudget(isLocalModel: BuddyChatProviderSelection.current == .localOllama),
                calendar: .current
            )
        } catch {
            return error.localizedDescription
        }
    }

    private static func integerArgument(named argumentNames: [String], in input: JSONValue) -> Int? {
        guard case .object(let arguments) = input else { return nil }
        for argumentName in argumentNames {
            switch arguments[argumentName] {
            case .number(let numericValue)?:
                return Int(exactly: numericValue.rounded())
            case .string(let textValue)?:
                if let parsedValue = Int(textValue.trimmingCharacters(in: .whitespaces)) { return parsedValue }
            default:
                continue
            }
        }
        return nil
    }
}
