//
//  MeetingCaptionsHelper.swift
//  leanring-buddy
//
//  "What did I miss" in a Google Meet or Zoom web call (phase 10): fetches the
//  call's captions from the page's own rolling buffer (`getMeetingCaptions`) and
//  runs one text-only model turn with them fenced as data. The answer goes to
//  the notch; in voice mode its short `[SAY:]` line is spoken.
//
//  Nothing is stored: the captions live in the meeting page, and Wisp holds them
//  only for this one call. No screenshot is taken and no audio is captured.
//  Quiet mode already knows about the call (mic/camera in use) and is unchanged.
//

import Foundation

@MainActor
enum MeetingCaptionsHelper {

    private struct CaptionParameters: Encodable {
        let tabId: Int?
        let lastMinutes: Int?
    }

    static func readCaptions(tabID: Int?, lastMinutes: Int?) async throws -> MeetingCaptions {
        try await ChromeSiteHelpers.sendRequest(
            method: "getMeetingCaptions",
            parameters: CaptionParameters(tabId: tabID, lastMinutes: lastMinutes),
            resultType: MeetingCaptions.self
        )
    }

    /// The router's entry point: the reply to show (with a `[SAY:]` tag the
    /// caller speaks in voice mode).
    static func summarize(_ request: MeetingCaptionsRequest, modelProvider: any ModelProvider) async -> (replyText: String, didSucceed: Bool) {
        let captions: MeetingCaptions
        do {
            captions = try await readCaptions(tabID: nil, lastMinutes: request.lastMinutes)
        } catch {
            return (error.localizedDescription, false)
        }
        guard captions.captionsFound else {
            return (MeetingCaptionsPrompt.noCaptionsReply(site: captions.site), false)
        }
        guard !captions.entries.isEmpty else {
            return (MeetingCaptionsPrompt.nothingSaidReply(request: request), true)
        }

        let isLocalModel = !modelProvider.deployment.sendsDataOffThisMachine
        let modelRequest = ModelRequest(
            systemPrompt: MeetingCaptionsPrompt.systemPrompt,
            messages: [BuddyChatMessage(
                role: .user,
                text: MeetingCaptionsPrompt.userMessage(
                    for: captions,
                    request: request,
                    characterBudget: ChromePageTextPrompt.characterBudget(isLocalModel: isLocalModel),
                    calendar: .current
                )
            )],
            maxOutputTokens: 500,
            temperature: 0.2
        )
        do {
            let summaryTurn = try await ModelAccessGate.shared.withAccess(priority: .interactive) {
                try await modelProvider.completeTurn(modelRequest)
            }
            let summaryText = summaryTurn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summaryText.isEmpty else { return ("i couldn't summarize the captions just now — try again.", false) }
            return (summaryText, true)
        } catch {
            return ("i couldn't summarize the captions: \(error.localizedDescription)", false)
        }
    }
}
