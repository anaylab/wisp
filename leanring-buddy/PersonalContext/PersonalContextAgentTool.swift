//
//  PersonalContextAgentTool.swift
//  leanring-buddy
//
//  `search_personal_context`: the model's way to look something up in the
//  user's own data for a follow-up the per-turn block didn't cover ("and when
//  does it land?", "check my email for the booking number"). Searches every
//  enabled source, Mail/Notes/Messages included, with a longer wait than a
//  turn gets. Read-only and on this Mac, so it doesn't ask.
//
//  It keeps the same privacy rule as the per-turn block: with a cloud model
//  selected it answers only when the user allowed personal context with cloud
//  models, and buddies on a cloud model never get it
//  (`BuddyRunToolPolicy.privateKnowledgeToolNames`).
//

import Foundation

enum PersonalContextAgentTool {
    static let toolName = "search_personal_context"
    static let maximumHits = 10
    static let maximumResultCharacters = 2400
}

extension AgentToolRegistry {

    /// Registers `search_personal_context`.
    func registerPersonalContextTool() {
        let sourceNames = PersonalContextSourceKind.allCases.map(\.rawValue)
        register(
            BuddyToolDefinition(
                name: PersonalContextAgentTool.toolName,
                description: "Search the user's own data on this Mac — calendar events, reminders, contacts, their documents, Mail, Notes and Messages — for something they asked about: a flight, a booking, an address, a person's number, a note, what someone texted. Give a few specific words.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("A few specific words to look for, e.g. \"flight denver\" or \"dentist address\".")
                        ]),
                        "sources": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string"), "enum": .array(sourceNames.map { .string($0) })]),
                            "description": .string("Optional: only these sources.")
                        ])
                    ]),
                    "required": .array([.string("query")])
                ]),
                metadata: .reading(.localMachine)
            )
        ) { input in
            guard case .object(let arguments) = input,
                  case .string(let queryText)? = arguments["query"],
                  !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "i need a few words to search for."
            }

            let personalContextStore = PersonalContextStore.shared
            if BuddyChatProviderSelection.current.sendsScreenshotsOffThisMachine && !personalContextStore.allowsCloudModels {
                return "the user's personal data isn't shared with cloud models. they can allow it in Settings → Connections → Your Data."
            }

            var onlySourceKinds: Set<PersonalContextSourceKind>?
            if case .array(let requestedSourceValues)? = arguments["sources"] {
                let requestedSourceKinds = requestedSourceValues.compactMap { requestedSourceValue -> PersonalContextSourceKind? in
                    guard case .string(let rawSourceName) = requestedSourceValue else { return nil }
                    return PersonalContextSourceKind(rawValue: rawSourceName.lowercased())
                }
                if !requestedSourceKinds.isEmpty { onlySourceKinds = Set(requestedSourceKinds) }
            }

            guard let hits = await personalContextStore.search(
                queryText: queryText,
                onlySourceKinds: onlySourceKinds,
                maximumHitCount: PersonalContextAgentTool.maximumHits
            ) else {
                return "personal context is turned off in Settings → Connections → Your Data."
            }
            guard !hits.isEmpty else {
                return "nothing on this Mac matched \"\(queryText)\"."
            }
            return PersonalContextPromptBlock.promptText(
                for: hits,
                maximumCharacters: PersonalContextAgentTool.maximumResultCharacters
            )
        }
    }
}
