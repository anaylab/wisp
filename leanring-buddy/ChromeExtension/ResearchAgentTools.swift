//
//  ResearchAgentTools.swift
//  leanring-buddy
//
//  `chrome_research_topic` (phase 11): the model can start a research run —
//  search, open and read up to 5 (local) or 8 (cloud) pages in the Wisp tab
//  group, write an answer whose every quote is checked against its page — and
//  gets the report back when it's done. The `chrome_` name puts it in the
//  `.browser` scope and the buddy Browser group (as phase 07's tools did), so
//  no scope or group table changes.
//
//  `.writing(.localMachine)`: it opens tabs in the user's Chrome, so it asks
//  once (session auto-approve covers it). The run is the same background task
//  the spoken "research …" starts, with its own History entry.
//

import Foundation

enum ResearchToolDefinitions {
    static let researchTopic = BuddyToolDefinition(
        name: ResearchToolNames.researchTopic,
        description: "Research a topic on the web: Wisp searches, opens up to 8 pages in Chrome's Wisp tab group, reads them and returns a short answer with numbered claims, each backed by an exact quote from a source. Takes a few minutes.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "topic": .object([
                    "type": .string("string"),
                    "description": .string("What to research, in the user's words, e.g. \"how mrna vaccines work for my bio essay\"."),
                ]),
                "save_to_brain": .object([
                    "type": .string("boolean"),
                    "description": .string("Also save the result as Brain pages. Only when the user asked."),
                ]),
            ]),
            "required": .array([.string("topic")]),
        ]),
        metadata: .writing(.localMachine)
    )
}

extension AgentToolRegistry {

    /// Always registered: without the extension or the permission the reply
    /// says how to fix it.
    func registerResearchTools() {
        register(ResearchToolDefinitions.researchTopic) { input in
            await Self.researchTopicForModel(input)
        }
    }

    @MainActor
    private static func researchTopicForModel(_ input: JSONValue) async -> String {
        guard case .object(let arguments) = input,
              case .string(let rawTopic)? = arguments["topic"] ?? arguments["query"] else {
            return "research_topic needs a topic."
        }
        let topic = rawTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard topic.count >= 3 else { return "research_topic needs a topic." }
        var savesToBrain = false
        if case .bool(let saveFlag)? = arguments["save_to_brain"] { savesToBrain = saveFlag }
        // The model's topic goes into the search box as it is; the parser is
        // only for spoken phrasings.
        let searchQuery = ResearchRequestParser.request(from: "research " + topic)?.searchQuery ?? topic
        let request = ResearchRequest(topic: topic, searchQuery: searchQuery, savesToBrain: savesToBrain)

        return await withCheckedContinuation { continuation in
            var hasResumed = false
            let started = ResearchSessionController.shared.start(request, modelProvider: ModelProviderFactory.make()) { result in
                guard !hasResumed else { return }
                hasResumed = true
                switch result {
                case .success(let report):
                    continuation.resume(returning: "research done. the user can see this report, with clickable citations, on wisp's chat page:\n\n" + report.plainText)
                case .failure(let error):
                    continuation.resume(returning: "the research didn't finish: \(error.localizedDescription)")
                }
            }
            if !started.didStart {
                hasResumed = true
                continuation.resume(returning: started.replyText)
            }
        }
    }
}
